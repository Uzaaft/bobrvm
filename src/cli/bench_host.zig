//! `bobrvm bench-host` - Measure a macOS process set over a fixed interval.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const metrics = @import("host_metrics.zig");

const log = std.log.scoped(.cli);
const pid_count_max: usize = 64;

const Output = struct {
    schema_version: u32 = 1,
    label: []const u8,
    duration_ns: u64,
    processes: []const metrics.Delta,
    totals: metrics.Totals,
};

const Options = struct {
    pids: [pid_count_max]i32 = undefined,
    pid_count: usize = 0,
    duration_ms: u64 = 10_000,
    label: []const u8 = "process-set",
};

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    const options = try parseOptions(args) orelse return;
    const before = try alloc.alloc(metrics.Snapshot, options.pid_count);
    defer alloc.free(before);
    const deltas = try alloc.alloc(metrics.Delta, options.pid_count);
    defer alloc.free(deltas);

    try sampleBefore(options.pids[0..options.pid_count], before);
    const started_ns = monotonicNs();
    try sleepMs(options.duration_ms);
    const finished_ns = monotonicNs();
    const totals = try sampleAfter(
        options.pids[0..options.pid_count],
        before,
        deltas,
    );
    try writeOutput(alloc, .{
        .label = options.label,
        .duration_ns = finished_ns - started_ns,
        .processes = deltas,
        .totals = totals,
    });
}

fn parseOptions(args: *std.process.Args.Iterator) !?Options {
    var options = Options{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        } else if (std.mem.eql(u8, arg, "--pid")) {
            const value = args.next() orelse return error.InvalidArgument;
            const pid = std.fmt.parseInt(i32, value, 10) catch return error.InvalidArgument;
            if (pid <= 0 or
                options.pid_count >= options.pids.len or
                containsPid(options.pids[0..options.pid_count], pid))
            {
                return error.InvalidArgument;
            }
            options.pids[options.pid_count] = pid;
            options.pid_count += 1;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            const value = args.next() orelse return error.InvalidArgument;
            const seconds = std.fmt.parseInt(u64, value, 10) catch
                return error.InvalidArgument;
            if (seconds == 0 or seconds > 3600) return error.InvalidArgument;
            options.duration_ms = seconds * std.time.ms_per_s;
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            const value = args.next() orelse return error.InvalidArgument;
            options.duration_ms = std.fmt.parseInt(u64, value, 10) catch
                return error.InvalidArgument;
            if (options.duration_ms == 0 or options.duration_ms > 3_600_000) {
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--label")) {
            options.label = args.next() orelse return error.InvalidArgument;
            if (options.label.len == 0 or options.label.len > 128) {
                return error.InvalidArgument;
            }
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }
    if (options.pid_count == 0) {
        log.err("bench-host needs at least one --pid", .{});
        return error.InvalidArgument;
    }
    return options;
}

fn sampleBefore(pids: []const i32, before: []metrics.Snapshot) !void {
    for (pids, before) |pid, *snapshot| {
        snapshot.* = metrics.sample(pid) catch |err| {
            log.err("cannot sample pid {d}: {}", .{ pid, err });
            return err;
        };
    }
}

fn sleepMs(duration_ms: u64) !void {
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = duration_ms * std.time.ns_per_ms },
        .clock = .awake,
    }, global.io()) catch return error.Unexpected;
}

fn sampleAfter(
    pids: []const i32,
    before: []const metrics.Snapshot,
    deltas: []metrics.Delta,
) !metrics.Totals {
    var totals = metrics.Totals{};
    for (pids, before, deltas) |pid, start, *delta| {
        const finish = metrics.sample(pid) catch |err| {
            log.err("pid {d} exited during the measurement: {}", .{ pid, err });
            return err;
        };
        delta.* = metrics.Delta.between(start, finish);
        totals.add(delta.*);
    }
    return totals;
}

fn writeOutput(alloc: Allocator, output: Output) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, output, .{
        .whitespace = .indent_2,
    });
    defer alloc.free(json);
    try writeStdout(json);
    try writeStdout("\n");
}

fn containsPid(pids: []const i32, candidate: i32) bool {
    for (pids) |pid| {
        if (pid == candidate) return true;
    }
    return false;
}

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

fn writeStdout(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = std.c.write(
            std.posix.STDOUT_FILENO,
            remaining.ptr,
            remaining.len,
        );
        if (written <= 0) return error.Unexpected;
        remaining = remaining[@intCast(written)..];
    }
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm bench-host --pid PID [--pid PID ...] [options]
        \\
        \\Measure cumulative macOS process counters over one quiet interval.
        \\Repeat --pid to aggregate a multi-process runtime such as OrbStack.
        \\The versioned JSON includes CPU time, package-idle and interrupt
        \\wakeups, resident/physical memory, disk I/O, instructions, cycles,
        \\and energy in nanojoules when the running macOS exposes it.
        \\
        \\Options:
        \\  --seconds N       Measurement duration (default 10, max 3600)
        \\  --duration-ms N   Millisecond duration for automated tests
        \\  --label NAME      Result label (default process-set)
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}

test "bench-host rejects duplicate pids" {
    try std.testing.expect(containsPid(&.{ 1, 2 }, 2));
    try std.testing.expect(!containsPid(&.{ 1, 2 }, 3));
}
