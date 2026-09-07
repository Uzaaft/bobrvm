//! `bobrvm exec -- <command>` - Run a command in a disposable clone of
//! the project's warm state and print its output and exit code.
//!
//! Like `fork`, but non-interactive: boot a copy-on-write clone of the
//! warm image in-process, run the command over the guest console, then
//! discard everything. The project's warm state and disks are never
//! touched.

const std = @import("std");
const Allocator = std.mem.Allocator;

const console_exec = @import("console_exec.zig");
const fork = @import("fork.zig");
const global = @import("../global.zig");
const machine_config = @import("machine_config.zig");
const machine = @import("../machine/main.zig");
const shell = @import("shell.zig");
const project = @import("project.zig");

const log = std.log.scoped(.cli);

const EXEC_TIMEOUT_MS: u32 = 120_000;

const ExecProfile = struct {
    enabled: bool,
    started_ns: u64,

    fn init() ExecProfile {
        return .{
            .enabled = std.c.getenv("BOBRVM_BENCHMARK_EXEC") != null,
            .started_ns = monotonicNs(),
        };
    }

    fn mark(self: ExecProfile, label: []const u8) void {
        if (!self.enabled) return;
        log.info("exec profile: {s} at {d} us", .{
            label,
            (monotonicNs() - self.started_ns) / std.time.ns_per_us,
        });
    }
};

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    const exit_code = try run(alloc, args);
    if (exit_code != 0) std.process.exit(exit_code);
}

/// Return the guest status only after VM and clone cleanup have unwound.
fn run(alloc: Allocator, args: *std.process.Args.Iterator) !u8 {
    const profile = ExecProfile.init();
    defer profile.mark("complete");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Collect the command after an optional `--` separator.
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var saw_separator = false;
    while (args.next()) |arg| {
        if (!saw_separator and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            printHelp();
            return 0;
        }
        if (!saw_separator and std.mem.eql(u8, arg, "--")) {
            saw_separator = true;
            continue;
        }
        try parts.append(arena, try arena.dupe(u8, arg));
    }
    if (parts.items.len == 0) {
        log.err("exec requires a command (bobrvm exec -- <command>)", .{});
        return error.InvalidArgument;
    }
    // Shell-quote each argv element so multi-word arguments survive as
    // one word in the injected command line — otherwise
    // `exec -- sh -c 'a b'` would flatten to `sh -c a b`.
    const command = try shell.join(arena, parts.items);
    profile.mark("arguments parsed");

    var cwd_buf: [1024]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    const root = (try project.findRoot(arena, cwd)) orelse {
        log.err("no {s} found in {s} or any parent directory", .{ project.FILE_NAME, cwd });
        return error.NoProjectFile;
    };
    const proj = try project.load(arena, root);
    profile.mark("project loaded");

    global.state.init();
    defer {
        global.state.deinit();
        profile.mark("global state released");
    }

    const clone = try fork.prepare(arena, &proj, null);
    defer {
        fork.deleteTree(clone.dir);
        profile.mark("clone deleted");
    }
    profile.mark("clone prepared");

    var hw = try machine.Machine.init(alloc, machine_config.base(&clone.config));
    defer {
        hw.deinit();
        profile.mark("machine deinitialized");
    }
    profile.mark("machine initialized");

    var session = console_exec.Session.init(alloc, hw);
    defer {
        session.deinit();
        profile.mark("session released");
    }
    hw.setConsoleOutput(console_exec.Session.sink, &session);

    const vm_thread = std.Thread.spawn(.{}, machineMain, .{hw}) catch return error.Unexpected;
    defer {
        hw.requestStop();
        vm_thread.join();
        profile.mark("vCPU joined");
    }
    profile.mark("vCPU spawned");

    if (!session.waitForPrompt(alloc, 30_000, .restored)) {
        log.err("guest did not reach a shell prompt", .{});
        return error.ExecTimeout;
    }
    profile.mark("shell ready");

    const result = try session.run(alloc, command, EXEC_TIMEOUT_MS);
    defer alloc.free(result.output);
    _ = std.c.write(std.posix.STDOUT_FILENO, result.output.ptr, result.output.len);
    profile.mark("command complete");
    if (result.exit_code != 0) log.info("exit code {d}", .{result.exit_code});
    return @intCast(result.exit_code);
}

fn machineMain(hw: *machine.Machine) void {
    hw.startSync() catch |err| log.err("machine failed: {}", .{err});
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm exec -- <command>
        \\
        \\Run a command in a disposable clone of the project's warm state
        \\and print its output. The clone is discarded afterwards, so the
        \\command cannot affect the project. Requires warm state (bobrvm
        \\up, then quit with Ctrl-B z).
        \\
        \\  bobrvm exec -- ls -la /workspace
        \\  bobrvm exec -- sh -c 'make && ./run-tests'
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}
