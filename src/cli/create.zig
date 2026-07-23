//! `bobrvm create` - Create a named VM configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");

const log = std.log.scoped(.cli);

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    const name = args.next() orelse {
        log.err("missing VM name", .{});
        printHelp();
        return error.MissingName;
    };

    if (std.mem.startsWith(u8, name, "-")) {
        if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            printHelp();
            return;
        }
        log.err("VM name cannot start with '-': {s}", .{name});
        return error.InvalidArgument;
    }

    var config = Config.parseArgs(args) catch |err| {
        if (err == error.HelpRequested) {
            printHelp();
            return;
        }
        return err;
    };

    config.name = name;
    try config.save(alloc);

    const stdout = std.posix.STDOUT_FILENO;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Created VM '{s}'\n", .{name}) catch return;
    _ = std.c.write(stdout, msg.ptr, msg.len);
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm create <name> [options]
        \\
        \\Create a named VM configuration that can be started later.
        \\
        \\Arguments:
        \\  <name>    Name for the VM configuration
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
    Config.printOptions();

    const examples =
        \\Examples:
        \\  bobrvm create myvm --memory 2048 --disk vm.raw
        \\  bobrvm create devbox --kernel vmlinuz --disk root.raw
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, examples.ptr, examples.len);
}
