//! CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli/main.zig");
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
