//! Linux direct-kernel boot command.

const std = @import("std");
const global = @import("../global.zig");
const x86 = @import("../machine/x86/main.zig");
const VM = @import("VM.zig");

const memory_bytes: usize = 512 * 1024 * 1024;
const exits_max: u64 = 100_000_000;
pub const command_line =
    "console=ttyS0,115200 earlycon=uart,io,0x3f8,115200n8 " ++
    "nokaslr acpi=off pci=conf1 panic=-1 reboot=t";

pub const Error = VM.CreateError || VM.StartError || VM.JoinError;

pub fn execute(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: ?[]const u8,
    disk_path: ?[]const u8,
) Error!void {
    var output = Stdout{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .disk_path = disk_path,
        .command_line = command_line,
        .exits_max = exits_max,
    }, x86.SerialSink.bind(Stdout, &output, Stdout.write));
    defer vm.destroy();
    try vm.start();
    _ = try vm.join();
    if (disk_path != null) output.writeFastBlockStats(vm.fastBlockStats());
}

pub fn executeStopSmoke(allocator: std.mem.Allocator, kernel_path: []const u8) !void {
    var output = DiscardOutput{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = 128 * 1024 * 1024,
        .kernel_path = kernel_path,
        .command_line = command_line,
        .exits_max = exits_max,
    }, x86.SerialSink.bind(DiscardOutput, &output, DiscardOutput.write));
    defer vm.destroy();
    try vm.start();
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms },
        .clock = .awake,
    }, global.io()) catch {};
    vm.requestStop();
    if (try vm.join() != .stopped) return error.UnexpectedRunOutcome;
}

pub fn executeConsoleSmoke(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: []const u8,
    disk_path: []const u8,
) !void {
    var output = ConsoleSmokeOutput{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .disk_path = disk_path,
        .command_line = command_line ++ " bobrvm.console_test=1",
        .exits_max = exits_max,
    }, x86.SerialSink.bind(ConsoleSmokeOutput, &output, ConsoleSmokeOutput.write));
    defer vm.destroy();
    try vm.start();

    if (!waitForSignal(vm, &output.ready, 500)) return error.ConsoleReadyTimeout;
    const input = "bobrvm-input-ok\n";
    if (try vm.writeConsole(input) != input.len) return error.ConsoleInputQueueFull;
    if (!waitForSignal(vm, &output.accepted, 500)) return error.ConsoleInputTimeout;
    if (try vm.join() != .guest_shutdown) return error.UnexpectedRunOutcome;
}

fn waitForSignal(vm: *VM, signal: *const std.atomic.Value(bool), polls_max: usize) bool {
    for (0..polls_max) |_| {
        if (signal.load(.acquire)) return true;
        if (vm.state() == .stopped) return signal.load(.acquire);
        std.Io.Clock.Duration.sleep(.{
            .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
            .clock = .awake,
        }, global.io()) catch {};
    }
    vm.requestStop();
    return false;
}

const DiscardOutput = struct {
    fn write(_: *DiscardOutput, _: []const u8) void {}
};

const ConsoleSmokeOutput = struct {
    const ready_marker = "BOBRVM_CONSOLE_INPUT_READY";
    const accepted_marker = "BOBRVM_CONSOLE_INPUT_OK";

    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ready_index: usize = 0,
    accepted_index: usize = 0,

    fn write(self: *ConsoleSmokeOutput, bytes: []const u8) void {
        var stdout = Stdout{};
        stdout.write(bytes);
        self.feedMarker(bytes, ready_marker, &self.ready_index, &self.ready);
        self.feedMarker(bytes, accepted_marker, &self.accepted_index, &self.accepted);
    }

    fn feedMarker(
        _: *ConsoleSmokeOutput,
        bytes: []const u8,
        marker: []const u8,
        index: *usize,
        found: *std.atomic.Value(bool),
    ) void {
        for (bytes) |byte| {
            if (byte == marker[index.*]) {
                index.* += 1;
                if (index.* == marker.len) {
                    found.store(true, .release);
                    index.* = 0;
                }
            } else {
                index.* = @intFromBool(byte == marker[0]);
            }
        }
    }
};

const Stdout = struct {
    fn write(_: *Stdout, bytes: []const u8) void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const count = std.c.write(
                std.posix.STDOUT_FILENO,
                remaining.ptr,
                remaining.len,
            );
            if (count <= 0) return;
            remaining = remaining[@intCast(count)..];
        }
    }

    fn writeFastBlockStats(self: *Stdout, stats: x86.Machine.FastBlockStats) void {
        const healthy = stats.enabled and !stats.worker_failed and stats.kicks > 0 and
            stats.interrupts > 0 and stats.notify_mmio_exits == 0;
        const marker = if (healthy)
            "BOBRVM_KVM_FAST_BLOCK_OK"
        else
            "BOBRVM_KVM_FAST_BLOCK_FAILED";
        var buffer: [192]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "{s} kicks={d} interrupts={d} notify_mmio_exits={d}\n",
            .{ marker, stats.kicks, stats.interrupts, stats.notify_mmio_exits },
        ) catch unreachable;
        self.write(line);
    }
};
