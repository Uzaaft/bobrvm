//! `bobrvm bench-command` - Measure a command and its host runtime processes.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const metrics = @import("host_metrics.zig");

const log = std.log.scoped(.cli);
const pid_count_max: usize = 64;

const Options = struct {
    pids: [pid_count_max]i32 = undefined,
    pid_count: usize = 0,
    trials: u32 = 5,
    warmups: u32 = 0,
    label: []const u8 = "command",
};

const Trial = struct {
    duration_ns: u64,
    exit_code: ?u8,
    signal: ?u32,
    processes: []const metrics.Delta,
    totals: metrics.Totals,
    client: ClientUsage,
    accounted_cpu_ns: u64,
};

const ClientUsage = struct {
    available: bool = false,
    user_cpu_ns: u64 = 0,
    system_cpu_ns: u64 = 0,
    max_resident_bytes: u64 = 0,
    minor_page_faults: u64 = 0,
    major_page_faults: u64 = 0,
    input_blocks: u64 = 0,
    output_blocks: u64 = 0,
    voluntary_context_switches: u64 = 0,
    involuntary_context_switches: u64 = 0,

    fn from(statistics: std.process.Child.ResourceUsageStatistics) ClientUsage {
        if (builtin.os.tag != .macos) return .{};
        const usage = statistics.rusage orelse return .{};
        return .{
            .available = true,
            .user_cpu_ns = timevalNs(usage.utime),
            .system_cpu_ns = timevalNs(usage.stime),
            .max_resident_bytes = nonnegative(usage.maxrss),
            .minor_page_faults = nonnegative(usage.minflt),
            .major_page_faults = nonnegative(usage.majflt),
            .input_blocks = nonnegative(usage.inblock),
            .output_blocks = nonnegative(usage.oublock),
            .voluntary_context_switches = nonnegative(usage.nvcsw),
            .involuntary_context_switches = nonnegative(usage.nivcsw),
        };
    }

    fn cpuTimeNs(self: ClientUsage) u64 {
        return self.user_cpu_ns +| self.system_cpu_ns;
    }
};

const Summary = struct {
    min_ns: u64,
    median_ns: u64,
    mean_ns: u64,
    max_ns: u64,
};

const Output = struct {
    schema_version: u32 = 2,
    label: []const u8,
    command: []const []const u8,
    trials: []const Trial,
    duration: Summary,
};

pub fn execute(
    alloc: Allocator,
    args: *std.process.Args.Iterator,
    environ: std.process.Environ,
) !void {
    var command: std.ArrayListUnmanaged([]const u8) = .empty;
    defer command.deinit(alloc);
    const options = try parseOptions(args, &command, alloc) orelse return;

    var io_impl = std.Io.Threaded.init(alloc, .{ .environ = environ });
    defer io_impl.deinit();
    const io = io_impl.io();

    for (0..options.warmups) |_| try runWarmup(io, command.items);
    const trials = try alloc.alloc(Trial, options.trials);
    defer alloc.free(trials);
    const deltas = try alloc.alloc(metrics.Delta, options.trials * options.pid_count);
    defer alloc.free(deltas);
    const before = try alloc.alloc(metrics.Snapshot, options.pid_count);
    defer alloc.free(before);

    for (trials, 0..) |*trial, index| {
        const start = index * options.pid_count;
        trial.* = try runTrial(
            io,
            options.pids[0..options.pid_count],
            command.items,
            before,
            deltas[start .. start + options.pid_count],
        );
    }
    try writeOutput(alloc, .{
        .label = options.label,
        .command = command.items,
        .trials = trials,
        .duration = try summarize(alloc, trials),
    });
}

fn parseOptions(
    args: *std.process.Args.Iterator,
    command: *std.ArrayListUnmanaged([]const u8),
    alloc: Allocator,
) !?Options {
    var options = Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        }
        try parseOption(args, arg, &options);
    }
    while (args.next()) |arg| try command.append(alloc, arg);
    if (options.pid_count == 0 or command.items.len == 0) {
        log.err("bench-command needs at least one --pid and a command after --", .{});
        return error.InvalidArgument;
    }
    return options;
}

fn parseOption(args: *std.process.Args.Iterator, arg: []const u8, options: *Options) !void {
    if (std.mem.eql(u8, arg, "--pid")) {
        const value = args.next() orelse return error.InvalidArgument;
        const pid = std.fmt.parseInt(i32, value, 10) catch return error.InvalidArgument;
        if (pid <= 0 or options.pid_count >= options.pids.len or
            containsPid(options.pids[0..options.pid_count], pid))
        {
            return error.InvalidArgument;
        }
        options.pids[options.pid_count] = pid;
        options.pid_count += 1;
    } else if (std.mem.eql(u8, arg, "--trials")) {
        options.trials = try parseCount(args, 1, 100);
    } else if (std.mem.eql(u8, arg, "--warmups")) {
        options.warmups = try parseCount(args, 0, 100);
    } else if (std.mem.eql(u8, arg, "--label")) {
        options.label = args.next() orelse return error.InvalidArgument;
        if (options.label.len == 0 or options.label.len > 128) return error.InvalidArgument;
    } else {
        log.err("unknown argument: {s}", .{arg});
        return error.InvalidArgument;
    }
}

fn parseCount(args: *std.process.Args.Iterator, min: u32, max: u32) !u32 {
    const value = args.next() orelse return error.InvalidArgument;
    const count = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArgument;
    if (count < min or count > max) return error.InvalidArgument;
    return count;
}

fn runWarmup(io: std.Io, command: []const []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = command,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.CommandSpawnFailed;
    try requireSuccess(try child.wait(io));
}

fn runTrial(
    io: std.Io,
    pids: []const i32,
    command: []const []const u8,
    before: []metrics.Snapshot,
    deltas: []metrics.Delta,
) !Trial {
    for (pids, before) |pid, *snapshot| snapshot.* = try metrics.sample(pid);
    const started_ns = monotonicNs();
    var child = std.process.spawn(io, .{
        .argv = command,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = true,
    }) catch return error.CommandSpawnFailed;
    const term = try child.wait(io);
    const finished_ns = monotonicNs();
    const client = ClientUsage.from(child.resource_usage_statistics);

    var totals = metrics.Totals{};
    for (pids, before, deltas) |pid, start, *delta| {
        delta.* = metrics.Delta.between(start, try metrics.sample(pid));
        totals.add(delta.*);
    }
    return .{
        .duration_ns = finished_ns - started_ns,
        .exit_code = if (term == .exited) term.exited else null,
        .signal = if (term == .signal) @intFromEnum(term.signal) else null,
        .processes = deltas,
        .totals = totals,
        .client = client,
        .accounted_cpu_ns = totals.cpuTimeNs() +| client.cpuTimeNs(),
    };
}

fn timevalNs(value: std.c.timeval) u64 {
    const seconds = nonnegative(value.sec);
    const microseconds: u64 = @min(
        nonnegative(value.usec),
        @as(u64, std.time.us_per_s - 1),
    );
    return seconds *| @as(u64, std.time.ns_per_s) +|
        microseconds *| @as(u64, std.time.ns_per_us);
}

fn nonnegative(value: anytype) u64 {
    return if (value > 0) @intCast(value) else 0;
}

fn requireSuccess(term: std.process.Child.Term) !void {
    if (term != .exited or term.exited != 0) return error.CommandFailed;
}

fn summarize(alloc: Allocator, trials: []const Trial) !Summary {
    const values = try alloc.alloc(u64, trials.len);
    defer alloc.free(values);
    var sum: u128 = 0;
    for (trials, values) |trial, *value| {
        value.* = trial.duration_ns;
        sum += value.*;
    }
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{
        .min_ns = values[0],
        .median_ns = values[values.len / 2],
        .mean_ns = @intCast(sum / @as(u128, values.len)),
        .max_ns = values[values.len - 1],
    };
}

fn containsPid(pids: []const i32, candidate: i32) bool {
    for (pids) |pid| if (pid == candidate) return true;
    return false;
}

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

fn writeOutput(alloc: Allocator, output: Output) !void {
    const json = try std.json.Stringify.valueAlloc(alloc, output, .{
        .whitespace = .indent_2,
    });
    defer alloc.free(json);
    var remaining: []const u8 = json;
    while (remaining.len > 0) {
        const written = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        if (written <= 0) return error.Unexpected;
        remaining = remaining[@intCast(written)..];
    }
    _ = std.c.write(std.posix.STDOUT_FILENO, "\n", 1);
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm bench-command --pid PID [--pid PID ...] [options] -- COMMAND [ARG ...]
        \\
        \\Run a command repeatedly while measuring the long-lived macOS
        \\runtime processes named by --pid and wait4 resource usage for the
        \\short-lived client. JSON includes per-trial wall latency, accounted
        \\CPU, and host wakeup, memory, I/O, cycle, and energy counters.
        \\Client energy, instructions, cycles, and wakeups are unavailable.
        \\
        \\Options:
        \\  --trials N       Measured trials (default 5, max 100)
        \\  --warmups N      Unmeasured warmup commands (default 0, max 100)
        \\  --label NAME     Result label (default command)
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}

test "bench-command detects duplicate process ids" {
    try std.testing.expect(containsPid(&.{ 1, 2 }, 2));
    try std.testing.expect(!containsPid(&.{ 1, 2 }, 3));
}

test "bench-command converts child resource counters safely" {
    try std.testing.expectEqual(@as(u64, 0), nonnegative(@as(isize, -1)));
    try std.testing.expectEqual(@as(u64, 7), nonnegative(@as(isize, 7)));
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(@as(u64, 2_999_999_000), timevalNs(.{
            .sec = 2,
            .usec = 999_999,
        }));
    }
}
