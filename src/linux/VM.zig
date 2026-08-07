//! Owned lifecycle for one direct-boot Linux VM.
//!
//! Paths in Config are borrowed only during create. The VM owns all KVM resources and its
//! vCPU thread until destroy; SerialSink must remain valid until join returns.

const VM = @This();

const std = @import("std");
const agent = @import("../agent/main.zig");
const config_policy = @import("../config.zig");
const file_compat = @import("../compat/file.zig");
const global = @import("../global.zig");
const boot = @import("../machine/x86/boot.zig");
const mininat = @import("../net/mininat.zig");
const x86 = @import("../machine/x86/main.zig");
const Audio = @import("Audio.zig");

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
audio: ?*Audio = null,

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
    display_width: u32 = config_policy.display_width_default,
    display_height: u32 = config_policy.display_height_default,
    gpu_memory_bytes: u64 = config_policy.gpu_memory_bytes_default,
    gpu_3d_enabled: bool = false,
    shared_dir: ?[]const u8 = null,
    restore_path: ?[]const u8 = null,
    audio_enabled: bool = false,
    command_line: []const u8,
    exits_max: u64,
};

pub const CreateError = boot.ParseError || config_policy.ValidationError || x86.Machine.InitError ||
    x86.Machine.AttachDiskError || x86.Machine.AttachNetworkError ||
    x86.Machine.AttachDisplayError || x86.Machine.AttachInputError ||
    x86.Machine.AttachRngError || x86.Machine.AttachGuestServicesError ||
    x86.Machine.AttachSoundError || error{
    OpenKernelFailed,
    ReadKernelFailed,
    OpenInitrdFailed,
    ReadInitrdFailed,
    OpenFirmwareFailed,
    ReadFirmwareFailed,
    OpenVariablesFailed,
    ReadVariablesFailed,
    InvalidBootConfig,
    RestoreFailed,
};

pub const StartError = std.Thread.SpawnError || error{InvalidState};
pub const JoinError = x86.Machine.RunError || error{InvalidState};
pub const ConsoleWriteError = x86.Machine.SerialInputError || error{InvalidState};

pub fn create(
    allocator: std.mem.Allocator,
    config: Config,
    serial: x86.SerialSink,
) CreateError!*VM {
    try config_policy.validate(.{
        .memory_bytes = std.math.cast(u64, config.memory_bytes) orelse {
            return error.InvalidMemory;
        },
        .vcpu_count = config.vcpu_count,
        .display_width = if (config.display_enabled) config.display_width else 0,
        .display_height = if (config.display_enabled) config.display_height else 0,
        .gpu_memory_bytes = if (config.display_enabled) config.gpu_memory_bytes else 0,
        .disk_path = config.disk_path,
        .disk_read_only = config.disk_read_only,
        .disk2_path = config.disk2_path,
        .disk2_read_only = config.disk2_read_only,
    });
    if ((config.kernel_path == null) == (config.firmware_path == null)) {
        return error.InvalidBootConfig;
    }
    var restore_buffer: [1024]u8 = undefined;
    var restore_file_path = config.restore_path;
    var restore_directory: ?[]const u8 = null;
    if (config.restore_path) |path| {
        if (isDirectory(path)) {
            restore_directory = path;
            restore_file_path = std.fmt.bufPrint(
                &restore_buffer,
                "{s}/state.img",
                .{path},
            ) catch return error.RestoreFailed;
        }
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
    if (restore_file_path) |path| {
        x86.Machine.validateSuspendImage(
            path,
            config.memory_bytes,
            if (firmware) |bytes| bytes.len else 0,
        ) catch |err| {
            log.err("invalid snapshot {s}: {}", .{ path, err });
            return error.RestoreFailed;
        };
    }
    if (restore_directory) |path| {
        x86.Machine.restoreSnapshotDisks(
            allocator,
            path,
            config.disk_path,
            config.disk2_path,
        ) catch |err| {
            log.err("failed to restore snapshot disks from {s}: {}", .{ path, err });
            return error.RestoreFailed;
        };
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
        try self.machine.attachDisplay(
            allocator,
            config.display_width,
            config.display_height,
            config.gpu_memory_bytes,
            config.gpu_3d_enabled,
        );
        try self.machine.attachInputDevices(allocator);
    }
    if (config.shared_dir) |path| try self.machine.attachSharedFolder(allocator, path);
    try self.machine.attachRng(allocator);
    try self.machine.attachGuestServices(allocator);
    if (config.audio_enabled) {
        const audio = Audio.create(allocator) catch |err| audio: {
            log.warn("host audio unavailable, using silent playback: {}", .{err});
            break :audio null;
        };
        self.audio = audio;
        errdefer if (audio) |value| {
            value.destroy();
            self.audio = null;
        };
        try self.machine.attachSound(
            allocator,
            if (audio) |value| value.playbackSink() else .{},
        );
    }
    if (config.network_enabled) try self.machine.attachNetwork(allocator, config.forwards);
    if (restore_file_path) |path| {
        self.machine.restoreFromDisk(path) catch |err| {
            log.err("failed to restore snapshot {s}: {}", .{ path, err });
            return error.RestoreFailed;
        };
    }
    return self;
}

fn isDirectory(path: []const u8) bool {
    const directory = std.Io.Dir.cwd().openDir(global.io(), path, .{}) catch return false;
    directory.close(global.io());
    return true;
}

pub fn destroy(self: *VM) void {
    if (self.thread != null) {
        self.requestStop();
        _ = self.join() catch {};
    }
    self.machine.deinit();
    if (self.audio) |audio| audio.destroy();
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

pub fn requestDisplayResize(self: *VM, width: u32, height: u32) void {
    self.machine.requestDisplayResize(width, height);
}

pub fn guestToolsStatus(self: *const VM) agent.native.Status {
    return self.machine.guestToolsStatus();
}

pub fn guestToolsCapabilities(self: *const VM) u64 {
    return self.machine.guestToolsCapabilities();
}

pub fn guestManagementReady(self: *const VM) bool {
    return self.machine.guestManagementReady();
}

pub fn setClipboardHandlers(
    self: *VM,
    on_guest_clipboard: *const fn ([]const u8, ?*anyopaque) void,
    request_host_clipboard: *const fn (?*anyopaque) void,
    userdata: ?*anyopaque,
) void {
    self.machine.setClipboardHandlers(
        on_guest_clipboard,
        request_host_clipboard,
        userdata,
    );
}

pub fn hostClipboardGrab(self: *VM) void {
    self.machine.hostClipboardGrab();
}

pub fn sendHostClipboard(self: *VM, text: []const u8) void {
    self.machine.sendHostClipboard(text);
}

pub fn sendFileToGuest(self: *VM, path: []const u8) !void {
    try self.machine.sendFileToGuest(path);
}

pub fn snapshotQuiesced(self: *VM, directory: []const u8) !void {
    if (self.state_value.load(.acquire) != .running) return error.InvalidState;
    try self.machine.snapshotToQuiesced(directory);
}

pub fn verifySnapshotRoundTrip(self: *VM, allocator: std.mem.Allocator) !void {
    if (!self.requestPause()) return error.InvalidState;
    var paused = true;
    defer {
        if (paused) _ = self.requestResume();
    }
    const snapshot_state = try self.machine.captureState(allocator);
    defer allocator.free(snapshot_state);
    try self.machine.applyState(allocator, snapshot_state);
    if (!self.requestResume()) return error.InvalidState;
    paused = false;
}

pub fn suspendToDisk(self: *VM, path: []const u8) !void {
    if (!self.requestPause()) return error.InvalidState;
    errdefer _ = self.requestResume();
    try self.machine.suspendToDisk(path);
}

pub fn requestGuestShutdown(self: *VM) void {
    self.machine.requestGuestShutdown();
}

pub fn requestGuestReboot(self: *VM) void {
    self.machine.requestGuestReboot();
}

pub fn trimGuestFilesystems(self: *VM) void {
    self.machine.trimGuestFilesystems();
}

pub fn syncGuestTime(self: *VM) void {
    self.machine.syncGuestTime();
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
