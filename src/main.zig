//! CLI entry point.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli/main.zig");

const log = std.log.scoped(.cli);

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = level_txt ++ ": " ++ scope_prefix;

    const stderr = std.posix.STDERR_FILENO;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch return;
    _ = std.c.write(stderr, msg.ptr, msg.len);
}

pub fn main(minimal: std.process.Init.Minimal) !void {
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
