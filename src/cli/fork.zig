//! `bobrvm fork` - Run a disposable clone of the project's warm state.
//!
//! Forks are the sandbox primitive: each one resumes from a
//! copy-on-write clone of the warm image (and clones of the writable
//! disks), runs interactively, and is destroyed on exit. The warm
//! state and the project's disks are never touched, so any number of
//! sequential forks resume from exactly the same moment.

const std = @import("std");
const Allocator = std.mem.Allocator;

const machine = @import("../machine/main.zig");
const global = @import("../global.zig");
const project = @import("project.zig");
const runner = @import("runner.zig");

const log = std.log.scoped(.cli);

// zig 0.16's std.c lacks this on macOS; same workaround as virtio/rng.
extern "c" fn getentropy(buf: [*]u8, len: usize) c_int;

/// A prepared disposable clone: a private directory holding the cloned
/// warm image and disks, plus a config pointing at them. Delete `dir`
/// when the clone exits.
pub const Clone = struct {
    dir: []const u8,
    config: @import("Config.zig"),
};

/// Clone the project's warm state into a private fork directory and
/// derive the config that runs it: restore from the cloned image,
/// write to cloned disks, no suspend target, no host port forwards
/// (concurrent forks would collide on the ports).
pub fn prepare(arena: Allocator, proj: *const project.Project) !Clone {
    if (proj.engine != .native) {
        log.err("fork and mcp sandboxes need the native engine (this project sets engine = \"vz\")", .{});
        return error.UnsupportedEngine;
    }
    if (!project.fileExists(proj.warm_image)) {
        log.err(
            "no warm state for {s}: run bobrvm up, then quit with Ctrl-B z first",
            .{proj.config.name},
        );
        return error.NoWarmState;
    }

    var seed_bytes: [8]u8 = undefined;
    if (getentropy(&seed_bytes, seed_bytes.len) != 0) return error.Unexpected;
    const dir = std.fmt.allocPrint(arena, "{s}/forks/{x:0>16}", .{
        proj.state_dir, std.mem.readInt(u64, &seed_bytes, .little),
    }) catch return error.OutOfMemory;
    try std.Io.Dir.cwd().createDirPath(global.io(), dir);
    errdefer deleteTree(dir);

    var config = proj.config;
    const warm_clone = try std.fs.path.join(arena, &.{ dir, "warm.img" });
    try machine.Machine.cloneFile(arena, proj.warm_image, warm_clone);
    config.restore_path = warm_clone;
    config.suspend_path = null;
    if (config.forward_count > 0) {
        log.info("fork: dropping {d} port forward(s); forks own no host ports", .{
            config.forward_count,
        });
        config.forward_count = 0;
    }

    // Writable disks: the warm image's device state references their
    // content, so each fork gets its own copy-on-write clone.
    if (config.disk_path) |disk| {
        if (!config.disk_read_only) {
            const clone = try std.fs.path.join(arena, &.{ dir, "disk0.raw" });
            try machine.Machine.cloneFile(arena, disk, clone);
            config.disk_path = clone;
        }
    }
    if (config.disk2_path) |disk| {
        if (!config.disk2_read_only) {
            const clone = try std.fs.path.join(arena, &.{ dir, "disk1.raw" });
            try machine.Machine.cloneFile(arena, disk, clone);
            config.disk2_path = clone;
        }
    }

    return .{ .dir = dir, .config = config };
}

/// Best-effort recursive delete of a fork directory.
pub fn deleteTree(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(global.io(), path) catch |err| {
        log.warn("fork cleanup of {s} failed: {}", .{ path, err });
    };
}

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
        log.err("unknown argument: {s}", .{arg});
        return error.InvalidArgument;
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

    const clone = try prepare(arena, &proj);
    defer deleteTree(clone.dir);

    log.info("fork: {s} — disposable clone of the warm state (Ctrl-] to quit)", .{
        clone.config.name,
    });
    try runner.run(alloc, &clone.config);
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm fork
        \\
        \\Run a disposable clone of the project's warm state. The clone
        \\resumes from a copy-on-write copy of the warm image and of any
        \\writable disks; the originals are never modified, and the
        \\clone's state is deleted when it exits. Requires warm state
        \\(run bobrvm up, then quit with Ctrl-B z).
        \\
        \\Host port forwards are dropped in forks so several can run
        \\concurrently.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}
