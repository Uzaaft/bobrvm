//! `bobrvm delete` - Delete a saved VM configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");

const log = std.log.scoped(.cli);

pub fn execute(alloc: Allocator, args: *std.process.ArgIterator) !void {
    const name = args.next() orelse {
        log.err("missing VM name", .{});
        printHelp();
        return error.MissingName;
    };

    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
        printHelp();
        return;
    }

    try Config.delete(alloc, name);

    const stdout = std.posix.STDOUT_FILENO;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Deleted VM '{s}'\n", .{name}) catch return;
    _ = std.posix.write(stdout, msg) catch {};
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm delete <name>
        \\
        \\Delete a saved VM configuration.
        \\
        \\Arguments:
        \\  <name>    Name of the VM to delete
        \\
        \\Examples:
        \\  bobrvm delete myvm
        \\  bobrvm rm devbox
        \\
        \\Note: This only removes the configuration file, not any disk images.
        \\
    ;
    _ = std.posix.write(std.posix.STDOUT_FILENO, help) catch {};
}
