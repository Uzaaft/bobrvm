//! Project lifecycle verbs for detached runners: `bobrvm status`,
//! `bobrvm halt`, and `bobrvm suspend`.
//!
//! `bobrvm up --detach` records the runner's pid in the project state
//! directory; these verbs act on it. halt sends SIGTERM (the runner's
//! graceful-shutdown path); suspend sends SIGUSR1, which the runner
//! answers by saving the warm image and quitting — so the next `up`
//! resumes it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const project = @import("project.zig");

const log = std.log.scoped(.cli);

// Raw kill: probing liveness needs signal 0, which the typed
// std.c.kill wrapper's SIG enum cannot express.
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;
const SIGTERM: c_int = 15;
const SIGUSR1: c_int = 30; // Darwin numbering

pub const Verb = enum { status, halt, @"suspend" };

pub fn execute(alloc: Allocator, verb: Verb) !void {
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

    const pid_path = try std.fs.path.join(arena, &.{ proj.state_dir, "runner.pid" });
    const pid = readPid(arena, pid_path);
    const alive = pid != null and kill(pid.?, 0) == 0;

    switch (verb) {
        .status => {
            if (alive) {
                print(arena, "{s}: running (pid {d})\n", .{ proj.config.name, pid.? });
            } else {
                print(arena, "{s}: not running\n", .{proj.config.name});
            }
            if (project.fileExists(proj.warm_image)) {
                print(arena, "warm state present: next `bobrvm up` resumes it\n", .{});
            } else {
                print(arena, "no warm state: next `bobrvm up` boots cold\n", .{});
            }
        },
        .halt => {
            const target = pid orelse return notRunning(proj.config.name);
            if (!alive) return notRunning(proj.config.name);
            _ = kill(target, SIGTERM);
            try waitForExit(target, 15_000);
            deleteFile(pid_path);
            print(arena, "{s}: halted\n", .{proj.config.name});
        },
        .@"suspend" => {
            const target = pid orelse return notRunning(proj.config.name);
            if (!alive) return notRunning(proj.config.name);
            _ = kill(target, SIGUSR1);
            // The runner saves the warm image and exits.
            try waitForExit(target, 60_000);
            deleteFile(pid_path);
            if (!project.fileExists(proj.warm_image)) {
                log.err("runner exited but wrote no warm image", .{});
                return error.SuspendFailed;
            }
            print(arena, "{s}: suspended; next `bobrvm up` resumes it\n", .{proj.config.name});
        },
    }
}

fn notRunning(name: []const u8) error{NotRunning} {
    log.err("{s}: no detached runner (start one with bobrvm up --detach)", .{name});
    return error.NotRunning;
}

fn readPid(arena: Allocator, path: []const u8) ?std.c.pid_t {
    const io = global.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    var buf: [32]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    _ = arena;
    const text = std.mem.trim(u8, buf[0..n], " \n\t");
    return std.fmt.parseInt(std.c.pid_t, text, 10) catch null;
}

fn waitForExit(pid: std.c.pid_t, timeout_ms: u32) !void {
    var waited_ms: u32 = 0;
    while (kill(pid, 0) == 0) {
        if (waited_ms >= timeout_ms) return error.Timeout;
        std.Io.Clock.Duration.sleep(.{
            .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms },
            .clock = .awake,
        }, global.io()) catch {};
        waited_ms += 50;
    }
}

fn deleteFile(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(global.io(), path) catch {};
}

fn print(arena: Allocator, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(arena, fmt, args) catch return;
    _ = std.c.write(std.posix.STDOUT_FILENO, text.ptr, text.len);
}
