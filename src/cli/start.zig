//! `bobrvm start` - Start a saved VM by name.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const runner = @import("runner.zig");

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

    var loaded = try Config.load(alloc, name);
    defer loaded.deinit();

    log.info("starting VM '{s}'", .{name});
    try runner.run(alloc, &loaded.config);
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm start <name>
        \\
        \\Start a previously saved VM configuration.
        \\
        \\Arguments:
        \\  <name>    Name of the VM to start
        \\
        \\Examples:
        \\  bobrvm start myvm
        \\  bobrvm start devbox
        \\
        \\Use 'bobrvm list' to see available VMs.
        \\
    ;
    _ = std.posix.write(std.posix.STDOUT_FILENO, help) catch {};
}
