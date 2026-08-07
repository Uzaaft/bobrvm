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

const DiscardOutput = struct {
    fn write(_: *DiscardOutput, _: []const u8) void {}
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
