//! bobrvm CLI entry point.
//!
//! Usage: bobrvm <command> [options]
//!
//! Commands:
//!   run              Run a VM directly with options
//!   create <name>    Create a named VM configuration
//!   list             List saved VM configurations
//!   start <name>     Start a saved VM by name
//!   delete <name>    Delete a saved VM configuration
//!
//! Run 'bobrvm --help' for more information.

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
    _ = std.posix.write(stderr, msg) catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    cli.dispatch(alloc) catch |err| {
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
