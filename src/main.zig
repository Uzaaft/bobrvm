//! CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli/main.zig");
const docker = @import("cli/docker.zig");
const global = @import("global.zig");
const logging = @import("logging.zig");

const log = std.log.scoped(.cli);

pub const std_options = logging.std_options;

pub fn main(minimal: std.process.Init.Minimal) !void {
    global.state.initWithLogging(.{ .stderr = true });
    defer global.state.deinit();

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (builtin.mode == .Debug) _ = debug_allocator.deinit();
    }
    const alloc = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.c_allocator;

    var args = minimal.args.iterate();
    const executable = args.next() orelse return;
    const invocation: ?docker.Invocation = if (std.mem.eql(
        u8,
        std.fs.path.basename(executable),
        "docker",
    ))
        .docker
    else if (std.mem.eql(u8, std.fs.path.basename(executable), "docker-compose"))
        .compose
    else
        null;
    if (invocation) |kind| {
        docker.execute(alloc, minimal, kind) catch |err| {
            log.err("fatal: {}", .{err});
            std.process.exit(1);
        };
        return;
    }

    cli.dispatch(alloc, minimal) catch |err| {
        switch (err) {
            error.HelpRequested, error.VersionRequested => return,
            error.UnknownSubcommand => std.process.exit(1),
            else => {
                log.err("fatal: {}", .{err});
                std.process.exit(1);
            },
        }
    };
}
