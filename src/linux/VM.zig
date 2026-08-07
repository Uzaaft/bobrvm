//! Owned lifecycle for one direct-boot Linux VM.
//!
//! Paths in Config are borrowed only during create. The VM owns all KVM resources and its
//! vCPU thread until destroy; SerialSink must remain valid until join returns.

const VM = @This();

const std = @import("std");
const file_compat = @import("../compat/file.zig");
const global = @import("../global.zig");
const boot = @import("../machine/x86/boot.zig");
const x86 = @import("../machine/x86/main.zig");

const kernel_bytes_max: usize = 512 * 1024 * 1024;
const initrd_bytes_max: usize = 1024 * 1024 * 1024;

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
    stopping,
    stopped,
};

pub const Config = struct {
    memory_bytes: usize,
    kernel_path: []const u8,
    initrd_path: ?[]const u8 = null,
    disk_path: ?[]const u8 = null,
    disk_read_only: bool = false,
    command_line: []const u8,
    exits_max: u64,
};

pub const CreateError = boot.ParseError || x86.Machine.InitError ||
    x86.Machine.AttachDiskError || error{
    OpenKernelFailed,
    ReadKernelFailed,
    OpenInitrdFailed,
    ReadInitrdFailed,
};

pub const StartError = std.Thread.SpawnError || error{InvalidState};
pub const JoinError = x86.Machine.RunError || error{InvalidState};

pub fn create(
    allocator: std.mem.Allocator,
    config: Config,
    serial: x86.SerialSink,
) CreateError!*VM {
    const kernel = try readFile(allocator, config.kernel_path, kernel_bytes_max, .kernel);
    defer allocator.free(kernel);
    const image = try boot.Image.parse(kernel);

    const initrd = if (config.initrd_path) |path|
        try readFile(allocator, path, initrd_bytes_max, .initrd)
    else
        null;
    defer if (initrd) |bytes| allocator.free(bytes);

    const self = try allocator.create(VM);
    errdefer allocator.destroy(self);
    const machine = try x86.Machine.init(
        config.memory_bytes,
        image,
        config.command_line,
        initrd,
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
    if (self.state_value.cmpxchgStrong(
        .running,
        .stopping,
        .acq_rel,
        .acquire,
    ) == null) self.machine.requestStop();
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

pub fn fastBlockStats(self: *const VM) x86.Machine.FastBlockStats {
    return self.machine.fastBlockStats();
}

fn threadMain(self: *VM) void {
    self.run_result = self.machine.run(self.serial, self.exits_max);
    self.state_value.store(.stopped, .release);
}

fn readFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes_max: usize,
    kind: enum { kernel, initrd },
) error{ OpenKernelFailed, ReadKernelFailed, OpenInitrdFailed, ReadInitrdFailed }![]u8 {
    const file = std.Io.Dir.cwd().openFile(global.io(), path, .{ .mode = .read_only }) catch {
        return switch (kind) {
            .kernel => error.OpenKernelFailed,
            .initrd => error.OpenInitrdFailed,
        };
    };
    defer file.close(global.io());
    return file_compat.readToEndAlloc(file, allocator, bytes_max) catch return switch (kind) {
        .kernel => error.ReadKernelFailed,
        .initrd => error.ReadInitrdFailed,
    };
}

test "Linux VM lifecycle states have a stable order" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(State.ready));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(State.stopped));
}
