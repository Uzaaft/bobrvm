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
const variables_bytes_max: usize = 16 * 1024 * 1024;

const log = std.log.scoped(.linux_vm);

allocator: std.mem.Allocator,
machine: x86.Machine,
serial: x86.SerialSink,
thread: ?std.Thread = null,
run_result: ?x86.Machine.RunError!x86.Machine.RunOutcome = null,
state_value: std.atomic.Value(State) = std.atomic.Value(State).init(.ready),
exits_max: u64,
vars_path: ?[]u8 = null,

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
    vars_path: ?[]const u8 = null,
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
    OpenVariablesFailed,
    ReadVariablesFailed,
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
    const variables = if (config.vars_path) |path|
        try readFile(allocator, path, variables_bytes_max, .variables)
    else
        null;
    defer if (variables) |bytes| allocator.free(bytes);
    if (variables) |bytes| {
        const firmware_bytes = firmware orelse return error.InvalidBootConfig;
        if (bytes.len == 0 or bytes.len > firmware_bytes.len or
            bytes.len % std.heap.page_size_min != 0)
        {
            return error.InvalidBootConfig;
        }
        @memcpy(firmware_bytes[0..bytes.len], bytes);
    }

    const boot_source: x86.Machine.BootSource = if (kernel) |bytes|
        .{ .linux = .{
            .image = try boot.Image.parse(bytes),
            .command_line = config.command_line,
            .initrd = initrd,
        } }
    else
        .{ .firmware = .{
            .bytes = firmware.?,
            .vars_bytes = if (variables) |bytes| bytes.len else 0,
        } };

    const vars_path = if (config.vars_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (vars_path) |path| allocator.free(path);

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
        .vars_path = vars_path,
    };
    errdefer self.machine.deinit();
    if (config.disk_path) |path| {
        try self.machine.attachDisk(allocator, path, config.disk_read_only);
    }
    if (config.disk2_path) |path| {
        try self.machine.attachDisk2(allocator, path, config.disk2_read_only);
    }
    if (config.display_enabled) {
        try self.machine.attachDisplay(allocator, config.display_width, config.display_height);
        try self.machine.attachInputDevices(allocator);
    }
    if (config.shared_dir) |path| try self.machine.attachSharedFolder(allocator, path);
    try self.machine.attachRng(allocator);
    if (config.network_enabled) try self.machine.attachNetwork(allocator, config.forwards);
    return self;
}

pub fn destroy(self: *VM) void {
    if (self.thread != null) {
        self.requestStop();
        _ = self.join() catch {};
    }
    self.machine.deinit();
    if (self.vars_path) |path| self.allocator.free(path);
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
    self.persistVariables() catch |err| {
        log.err("failed to persist UEFI variables: {}", .{err});
    };
    self.state_value.store(.stopped, .release);
}

fn persistVariables(self: *VM) !void {
    const path = self.vars_path orelse return;
    const bytes = self.machine.firmwareVariables() orelse return;
    const file = try std.Io.Dir.cwd().createFile(global.io(), path, .{});
    defer file.close(global.io());
    try file.writePositionalAll(global.io(), bytes, 0);
}

fn readFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes_max: usize,
    kind: enum { kernel, initrd, firmware, variables },
) error{
    OpenKernelFailed,
    ReadKernelFailed,
    OpenInitrdFailed,
    ReadInitrdFailed,
    OpenFirmwareFailed,
    OpenVariablesFailed,
    ReadFirmwareFailed,
    ReadVariablesFailed,
}![]u8 {
    const file = std.Io.Dir.cwd().openFile(global.io(), path, .{ .mode = .read_only }) catch {
        return switch (kind) {
            .kernel => error.OpenKernelFailed,
            .initrd => error.OpenInitrdFailed,
            .firmware => error.OpenFirmwareFailed,
            .variables => error.OpenVariablesFailed,
        };
    };
    defer file.close(global.io());
    return file_compat.readToEndAlloc(file, allocator, bytes_max) catch return switch (kind) {
        .kernel => error.ReadKernelFailed,
        .initrd => error.ReadInitrdFailed,
        .firmware => error.ReadFirmwareFailed,
        .variables => error.ReadVariablesFailed,
    };
}

test "Linux VM lifecycle states have a stable order" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(State.ready));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(State.stopped));
}
