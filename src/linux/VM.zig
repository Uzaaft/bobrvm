//! Owned lifecycle for one direct-boot Linux VM.
//!
//! Paths in Config are borrowed only during create. The VM owns all KVM resources and its
//! vCPU thread until destroy; SerialSink must remain valid until join returns.

const VM = @This();

const std = @import("std");
const file_compat = @import("../compat/file.zig");
const global = @import("../global.zig");
const boot = @import("../machine/x86/boot.zig");
const mininat = @import("../net/mininat.zig");
const x86 = @import("../machine/x86/main.zig");

const kernel_bytes_max: usize = 512 * 1024 * 1024;
const initrd_bytes_max: usize = 1024 * 1024 * 1024;
const firmware_bytes_max: usize = 16 * 1024 * 1024;

allocator: std.mem.Allocator,
machine: x86.Machine,
serial: x86.SerialSink,
thread: ?std.Thread = null,
run_result: ?x86.Machine.RunError!x86.Machine.RunOutcome = null,
state_value: std.atomic.Value(State) = std.atomic.Value(State).init(.ready),
exits_max: u64,

pub const State = enum(u8) {
    ready,
    running,
    paused,
    stopping,
    stopped,
};

pub const Config = struct {
    memory_bytes: usize,
    vcpu_count: u8 = 2,
    firmware_path: ?[]const u8 = null,
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    disk_path: ?[]const u8 = null,
    disk_read_only: bool = false,
    disk2_path: ?[]const u8 = null,
    disk2_read_only: bool = true,
    network_enabled: bool = false,
    forwards: []const mininat.Forward = &.{},
    display_enabled: bool = false,
    display_width: u32 = 1280,
    display_height: u32 = 800,
    shared_dir: ?[]const u8 = null,
    command_line: []const u8,
    exits_max: u64,
};

pub const CreateError = boot.ParseError || x86.Machine.InitError ||
    x86.Machine.AttachDiskError || x86.Machine.AttachNetworkError ||
    x86.Machine.AttachDisplayError || x86.Machine.AttachInputError ||
    x86.Machine.AttachRngError || error{
    OpenKernelFailed,
    ReadKernelFailed,
    OpenInitrdFailed,
    ReadInitrdFailed,
    OpenFirmwareFailed,
    ReadFirmwareFailed,
    InvalidBootConfig,
};

pub const StartError = std.Thread.SpawnError || error{InvalidState};
pub const JoinError = x86.Machine.RunError || error{InvalidState};
pub const ConsoleWriteError = x86.Machine.SerialInputError || error{InvalidState};

pub fn create(
    allocator: std.mem.Allocator,
    config: Config,
    serial: x86.SerialSink,
) CreateError!*VM {
    if ((config.kernel_path == null) == (config.firmware_path == null)) {
        return error.InvalidBootConfig;
    }
    const kernel = if (config.kernel_path) |path|
        try readFile(allocator, path, kernel_bytes_max, .kernel)
    else
        null;
    defer if (kernel) |bytes| allocator.free(bytes);
    const initrd = if (config.initrd_path) |path|
        try readFile(allocator, path, initrd_bytes_max, .initrd)
    else
        null;
    defer if (initrd) |bytes| allocator.free(bytes);
    const firmware = if (config.firmware_path) |path|
        try readFile(allocator, path, firmware_bytes_max, .firmware)
    else
        null;
    defer if (firmware) |bytes| allocator.free(bytes);

    const boot_source: x86.Machine.BootSource = if (kernel) |bytes|
        .{ .linux = .{
            .image = try boot.Image.parse(bytes),
            .command_line = config.command_line,
            .initrd = initrd,
        } }
    else
        .{ .firmware = firmware.? };

    const self = try allocator.create(VM);
    errdefer allocator.destroy(self);
    const machine = try x86.Machine.init(
        allocator,
        config.memory_bytes,
        config.vcpu_count,
        boot_source,
    );
    self.* = .{
        .allocator = allocator,
        .machine = machine,
        .serial = serial,
        .exits_max = config.exits_max,
    };
    errdefer self.machine.deinit();
    if (config.disk_path) |path| {
        try self.machine.attachDisk(allocator, path, config.disk_read_only);
    }
    if (config.disk2_path) |path| {
        try self.machine.attachDisk2(allocator, path, config.disk2_read_only);
    }
    if (config.network_enabled) try self.machine.attachNetwork(allocator, config.forwards);
    if (config.display_enabled) {
        try self.machine.attachDisplay(allocator, config.display_width, config.display_height);
        try self.machine.attachInputDevices(allocator);
    }
    if (config.shared_dir) |path| try self.machine.attachSharedFolder(allocator, path);
    try self.machine.attachRng(allocator);
    return self;
}

pub fn destroy(self: *VM) void {
    if (self.thread != null) {
        self.requestStop();
        _ = self.join() catch {};
    }
    self.machine.deinit();
    self.allocator.destroy(self);
}

pub fn start(self: *VM) StartError!void {
    if (self.state_value.cmpxchgStrong(
        .ready,
        .running,
        .acq_rel,
        .acquire,
    ) != null) return error.InvalidState;
    self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
        self.state_value.store(.ready, .release);
        return err;
    };
}

pub fn requestStop(self: *VM) void {
    var current = self.state_value.load(.acquire);
    while (current == .running or current == .paused) {
        current = self.state_value.cmpxchgWeak(
            current,
            .stopping,
            .acq_rel,
            .acquire,
        ) orelse {
            self.machine.requestStop();
            return;
        };
    }
}

pub fn requestPause(self: *VM) bool {
    if (self.state_value.cmpxchgStrong(
        .running,
        .paused,
        .acq_rel,
        .acquire,
    ) != null) return false;
    if (self.machine.requestPause()) return true;
    self.state_value.store(.running, .release);
    return false;
}

pub fn requestResume(self: *VM) bool {
    if (self.state_value.cmpxchgStrong(
        .paused,
        .running,
        .acq_rel,
        .acquire,
    ) != null) return false;
    if (self.machine.requestResume()) return true;
    self.state_value.store(.paused, .release);
    return false;
}

pub fn join(self: *VM) JoinError!x86.Machine.RunOutcome {
    const thread = self.thread orelse return error.InvalidState;
    thread.join();
    self.thread = null;
    self.state_value.store(.stopped, .release);
    return self.run_result orelse return error.InvalidState;
}

pub fn state(self: *const VM) State {
    return self.state_value.load(.acquire);
}

/// Queue terminal input for the guest while its vCPU is running.
pub fn writeConsole(self: *VM, bytes: []const u8) ConsoleWriteError!usize {
    if (self.state() != .running) return error.InvalidState;
    return self.machine.queueSerialInput(bytes);
}

pub fn fastBlockStats(self: *const VM) x86.Machine.FastBlockStats {
    return self.machine.fastBlockStats();
}

pub fn secondaryBlockNotifications(self: *const VM) u64 {
    return self.machine.secondaryBlockNotifications();
}

pub fn pciConfigReads(self: *const VM) u64 {
    return self.machine.pciConfigReads();
}

pub fn pciDeviceReads(self: *const VM) [32]u64 {
    return self.machine.pciDeviceReads();
}

pub fn mmioExitStats(self: *const VM) x86.Machine.MmioExitStats {
    return self.machine.mmioExitStats();
}

pub fn copyScanout(self: *VM, destination: []u8) ?x86.Machine.Scanout {
    return self.machine.copyScanout(destination);
}

pub fn injectKey(self: *VM, keycode: u16, pressed: bool) x86.Machine.InputError!void {
    return self.machine.injectKey(keycode, pressed);
}

pub fn injectPointer(self: *VM, x: i32, y: i32) x86.Machine.InputError!void {
    return self.machine.injectPointer(x, y);
}

pub fn injectButton(self: *VM, button: u16, pressed: bool) x86.Machine.InputError!void {
    return self.machine.injectButton(button, pressed);
}

pub fn injectScroll(self: *VM, x: i32, y: i32) x86.Machine.InputError!void {
    return self.machine.injectScroll(x, y);
}

fn threadMain(self: *VM) void {
    self.run_result = self.machine.run(self.serial, self.exits_max);
    self.state_value.store(.stopped, .release);
}

fn readFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes_max: usize,
    kind: enum { kernel, initrd, firmware },
) error{
    OpenKernelFailed,
    ReadKernelFailed,
    OpenInitrdFailed,
    ReadInitrdFailed,
    OpenFirmwareFailed,
    ReadFirmwareFailed,
}![]u8 {
    const file = std.Io.Dir.cwd().openFile(global.io(), path, .{ .mode = .read_only }) catch {
        return switch (kind) {
            .kernel => error.OpenKernelFailed,
            .initrd => error.OpenInitrdFailed,
            .firmware => error.OpenFirmwareFailed,
        };
    };
    defer file.close(global.io());
    return file_compat.readToEndAlloc(file, allocator, bytes_max) catch return switch (kind) {
        .kernel => error.ReadKernelFailed,
        .initrd => error.ReadInitrdFailed,
        .firmware => error.ReadFirmwareFailed,
    };
}

test "Linux VM lifecycle states have a stable order" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(State.ready));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(State.stopped));
}
