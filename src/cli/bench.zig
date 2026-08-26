//! `bobrvm bench-warm` - Measure warm-restore latency.
//!
//! Runs N trials of "restore a fork of the warm state and wait until
//! the guest shell responds," reporting the min / median / max
//! wall-clock time. This is the headline number: how long `bobrvm up`
//! takes to bring a suspended guest back to a working shell.

const std = @import("std");
const Allocator = std.mem.Allocator;

const console_exec = @import("console_exec.zig");
const fork = @import("fork.zig");
const global = @import("../global.zig");
const host_metrics = @import("host_metrics.zig");
const machine = @import("../machine/main.zig");
const project = @import("project.zig");

const log = std.log.scoped(.cli);

const Options = struct {
    trials: u32 = 5,
    json: bool = false,
};

const Trial = struct {
    restore_ns: u64,
    ready_ns: u64,
    command_ns: u64,
    total_ns: u64,
    host: ?host_metrics.Delta,
};

const Timing = struct {
    restore_ns: u64,
    ready_ns: u64,
    command_ns: u64,
};

const Summary = struct {
    min_ns: u64,
    median_ns: u64,
    mean_ns: u64,
    max_ns: u64,
};

const JsonOutput = struct {
    schema_version: u32 = 1,
    name: []const u8,
    trials: []const Trial,
    restore: Summary,
    ready: Summary,
    command_roundtrip: Summary,
    total: Summary,
};

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    const options = try parseOptions(args) orelse return;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cwd_buf: [1024]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    const root = (try project.findRoot(arena, cwd)) orelse {
        log.err("no {s} found in {s} or any parent directory", .{ project.FILE_NAME, cwd });
        return error.NoProjectFile;
    };
    const proj = try project.load(arena, root);

    global.state.init();
    defer global.state.deinit();

    const samples = try arena.alloc(Trial, options.trials);
    for (samples, 0..) |*sample, i| {
        sample.* = try measuredTrial(alloc, arena, &proj);
        log.info("trial {d}/{d}: restore {d} us, ready {d} us, command {d} us", .{
            i + 1,
            options.trials,
            sample.restore_ns / std.time.ns_per_us,
            sample.ready_ns / std.time.ns_per_us,
            sample.command_ns / std.time.ns_per_us,
        });
    }

    const restore = try summarize(arena, samples, .restore_ns);
    const ready = try summarize(arena, samples, .ready_ns);
    const command = try summarize(arena, samples, .command_ns);
    const total = try summarize(arena, samples, .total_ns);
    if (options.json) {
        try printJson(arena, .{
            .name = proj.config.name,
            .trials = samples,
            .restore = restore,
            .ready = ready,
            .command_roundtrip = command,
            .total = total,
        });
    } else {
        printResult(arena, proj.config.name, "warm restore (VM live)", restore);
        printResult(arena, proj.config.name, "shell responsive", ready);
        printResult(arena, proj.config.name, "ready command round-trip", command);
        printResult(arena, proj.config.name, "trial including cleanup", total);
    }
}

fn parseOptions(args: *std.process.Args.Iterator) !?Options {
    var options = Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return null;
        } else if (std.mem.eql(u8, arg, "--trials") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.InvalidArgument;
            options.trials = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidArgument;
            if (options.trials == 0 or options.trials > 100) return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }
    return options;
}

fn measuredTrial(alloc: Allocator, arena: Allocator, proj: *const project.Project) !Trial {
    const before = host_metrics.sample(std.c.getpid()) catch null;
    const started_ns = nowNs();
    const timing = try trial(alloc, arena, proj);
    const total_ns = nowNs() - started_ns;
    const after = if (before != null)
        host_metrics.sample(std.c.getpid()) catch null
    else
        null;
    return .{
        .restore_ns = timing.restore_ns,
        .ready_ns = timing.ready_ns,
        .command_ns = timing.command_ns,
        .total_ns = total_ns,
        .host = if (before != null and after != null)
            host_metrics.Delta.between(before.?, after.?)
        else
            null,
    };
}

/// One trial: restore a fork, time until the VM is live (pure restore)
/// and until the guest shell responds to a command.
fn trial(alloc: Allocator, arena: Allocator, proj: *const project.Project) !Timing {
    const clone = try fork.prepare(arena, proj);
    defer fork.deleteTree(clone.dir);

    const start_ns = nowNs();
    var hw = try machine.Machine.init(alloc, machineConfig(&clone.config));
    defer hw.deinit();

    var session = console_exec.Session.init(alloc, hw);
    defer session.deinit();
    hw.setConsoleOutput(console_exec.Session.sink, &session);

    const vm_thread = std.Thread.spawn(.{}, machineMain, .{hw}) catch return error.Unexpected;
    defer {
        hw.requestStop();
        vm_thread.join();
    }

    // Pure restore latency: the machine flips to running once startup
    // (including the restore) is done, before any shell round-trip.
    if (!hw.waitUntilRunning(30 * std.time.ns_per_s)) return error.ExecTimeout;
    const restore_ns = nowNs() - start_ns;

    if (!session.waitForPrompt(alloc, 30_000)) return error.ExecTimeout;
    const ready_ns = nowNs() - start_ns;
    const command_started_ns = nowNs();
    const result = try session.run(alloc, "true", 30_000);
    defer alloc.free(result.output);
    if (result.exit_code != 0) return error.CommandFailed;
    return .{
        .restore_ns = restore_ns,
        .ready_ns = ready_ns,
        .command_ns = nowNs() - command_started_ns,
    };
}

fn machineMain(hw: *machine.Machine) void {
    hw.startSync() catch |err| log.err("machine failed: {}", .{err});
}

fn machineConfig(config: *const @import("Config.zig")) machine.MachineConfig {
    return .{
        .ram_size = config.memory_mb * 1024 * 1024,
        .vcpu_count = config.vcpu_count,
        .firmware_path = config.firmware_path,
        .vars_path = config.vars_path,
        .kernel_path = config.kernel_path,
        .initrd_path = config.initrd_path,
        .cmdline = config.cmdline,
        .disk_path = config.disk_path,
        .disk_read_only = config.disk_read_only,
        .disk2_path = config.disk2_path,
        .disk2_read_only = config.disk2_read_only,
        .enable_net = config.enable_net,
        .shared_dir = config.shared_dir,
        .share_read_only = config.share_read_only,
        .restore_path = config.restore_path,
    };
}

const TimingField = enum { restore_ns, ready_ns, command_ns, total_ns };

fn summarize(arena: Allocator, samples: []const Trial, comptime field: TimingField) !Summary {
    const values = try arena.alloc(u64, samples.len);
    var sum: u128 = 0;
    for (samples, values) |sample, *value| {
        value.* = @field(sample, @tagName(field));
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

fn printResult(
    arena: Allocator,
    name: []const u8,
    label: []const u8,
    result: Summary,
) void {
    const text = std.fmt.allocPrint(
        arena,
        "\n{s} — {s}:\n  min {d} us   median {d} us   mean {d} us   max {d} us\n",
        .{
            name,
            label,
            result.min_ns / std.time.ns_per_us,
            result.median_ns / std.time.ns_per_us,
            result.mean_ns / std.time.ns_per_us,
            result.max_ns / std.time.ns_per_us,
        },
    ) catch return;
    _ = std.c.write(std.posix.STDOUT_FILENO, text.ptr, text.len);
}

fn printJson(arena: Allocator, output: JsonOutput) !void {
    const json = try std.json.Stringify.valueAlloc(arena, output, .{
        .whitespace = .indent_2,
    });
    try writeStdout(json);
    try writeStdout("\n");
}

fn writeStdout(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        if (written <= 0) return error.Unexpected;
        remaining = remaining[@intCast(written)..];
    }
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm bench-warm [--trials N] [--json]
        \\
        \\Measure how long a warm restore takes: N trials (default 5) of
        \\restoring a fork of the project's warm state and waiting until
        \\the guest shell responds. Reports min / median / mean / max;
        \\--json includes nanosecond timings and per-trial host counters.
        \\Requires warm state (bobrvm up, then quit with Ctrl-B z).
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}
