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
const machine = @import("../machine/main.zig");
const project = @import("project.zig");

const log = std.log.scoped(.cli);

fn nowMs() i64 {
    return @intCast(@divTrunc(
        std.Io.Clock.real.now(global.io()).nanoseconds,
        std.time.ns_per_ms,
    ));
}

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    var trials: u32 = 5;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--trials") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.InvalidArgument;
            trials = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArgument;
            if (trials == 0 or trials > 100) return error.InvalidArgument;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

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

    const restore = try arena.alloc(i64, trials);
    const ready = try arena.alloc(i64, trials);
    for (restore, ready, 0..) |*r, *rd, i| {
        const t = try trial(alloc, arena, &proj);
        r.* = t.restore_ms;
        rd.* = t.ready_ms;
        log.info("trial {d}/{d}: restore {d} ms, shell-ready {d} ms", .{
            i + 1, trials, t.restore_ms, t.ready_ms,
        });
    }

    printResult(arena, proj.config.name, "warm restore (VM live)", restore);
    printResult(arena, proj.config.name, "shell responsive", ready);
}

const Trial = struct { restore_ms: i64, ready_ms: i64 };

/// One trial: restore a fork, time until the VM is live (pure restore)
/// and until the guest shell responds to a command.
fn trial(alloc: Allocator, arena: Allocator, proj: *const project.Project) !Trial {
    const clone = try fork.prepare(arena, proj);
    defer fork.deleteTree(clone.dir);

    const start_ms = nowMs();
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
    var waited_us: u32 = 0;
    while (!hw.isRunning()) {
        if (waited_us >= 30_000_000) return error.ExecTimeout;
        std.Io.Clock.Duration.sleep(.{
            .raw = .{ .nanoseconds = 100 * std.time.ns_per_us },
            .clock = .awake,
        }, global.io()) catch {};
        waited_us += 100;
    }
    const restore_ms = nowMs() - start_ms;

    if (!session.waitForPrompt(alloc, 30_000)) return error.ExecTimeout;
    return .{ .restore_ms = restore_ms, .ready_ms = nowMs() - start_ms };
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

fn printResult(arena: Allocator, name: []const u8, label: []const u8, samples: []i64) void {
    std.mem.sort(i64, samples, {}, std.sort.asc(i64));
    var sum: i64 = 0;
    for (samples) |s| sum += s;
    const text = std.fmt.allocPrint(
        arena,
        "\n{s} — {s}:\n  min {d} ms   median {d} ms   mean {d} ms   max {d} ms\n",
        .{
            name,
            label,
            samples[0],
            samples[samples.len / 2],
            @divTrunc(sum, @as(i64, @intCast(samples.len))),
            samples[samples.len - 1],
        },
    ) catch return;
    _ = std.c.write(std.posix.STDOUT_FILENO, text.ptr, text.len);
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm bench-warm [--trials N]
        \\
        \\Measure how long a warm restore takes: N trials (default 5) of
        \\restoring a fork of the project's warm state and waiting until
        \\the guest shell responds. Reports min / median / mean / max.
        \\Requires warm state (bobrvm up, then quit with Ctrl-B z).
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}
