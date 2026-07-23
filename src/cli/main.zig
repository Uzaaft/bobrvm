//! CLI subcommand dispatcher and config management.
//!
//! Subcommands:
//!   run      Run a VM directly with options
//!   create   Create a named VM configuration
//!   list     List saved VM configurations
//!   start    Start a saved VM by name
//!   delete   Delete a saved VM configuration

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Config = @import("Config.zig");
pub const run = @import("run.zig");
pub const create = @import("create.zig");
pub const list = @import("list.zig");
pub const start = @import("start.zig");
pub const delete = @import("delete.zig");

const log = std.log.scoped(.cli);

pub const Subcommand = enum {
    run,
    create,
    list,
    start,
    delete,
    help,
    version,
};

pub const DispatchError = error{
    UnknownSubcommand,
    HelpRequested,
    VersionRequested,
};

pub fn dispatch(alloc: Allocator, minimal: std.process.Init.Minimal) !void {
    var args = minimal.args.iterate();
    _ = args.skip();

    const subcmd_str = args.next() orelse {
        printUsage();
        return DispatchError.HelpRequested;
    };

    const subcmd = parseSubcommand(subcmd_str) orelse {
        log.err("unknown subcommand: {s}", .{subcmd_str});
        printUsage();
        return DispatchError.UnknownSubcommand;
    };

    switch (subcmd) {
        .run => try run.execute(alloc, &args),
        .create => try create.execute(alloc, &args),
        .list => try list.execute(alloc),
        .start => try start.execute(alloc, &args),
        .delete => try delete.execute(alloc, &args),
        .help => {
            printUsage();
            return DispatchError.HelpRequested;
        },
        .version => {
            printVersion();
            return DispatchError.VersionRequested;
        },
    }
}

fn parseSubcommand(str: []const u8) ?Subcommand {
    const map = std.StaticStringMap(Subcommand).initComptime(.{
        .{ "run", .run },
        .{ "create", .create },
        .{ "list", .list },
        .{ "ls", .list },
        .{ "start", .start },
        .{ "delete", .delete },
        .{ "rm", .delete },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
        .{ "version", .version },
        .{ "--version", .version },
        .{ "-v", .version },
    });
    return map.get(str);
}

fn printUsage() void {
    const usage =
        \\bobrvm - Linux virtualization for macOS
        \\
        \\Usage: bobrvm <command> [options]
        \\
        \\Commands:
        \\  run              Run a VM directly with options
        \\  create <name>    Create a named VM configuration
        \\  list, ls         List saved VM configurations
        \\  start <name>     Start a saved VM by name
        \\  delete, rm       Delete a saved VM configuration
        \\  help             Show this help message
        \\  version          Show version information
        \\
        \\Examples:
        \\  bobrvm run --memory 1024 --disk root.raw
        \\  bobrvm create myvm --memory 2048 --disk vm.raw
        \\  bobrvm start myvm
        \\  bobrvm list
        \\
        \\Run 'bobrvm <command> --help' for command-specific help.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, usage.ptr, usage.len);
}

fn printVersion() void {
    const version = "bobrvm 0.1.0\n";
    _ = std.c.write(std.posix.STDOUT_FILENO, version.ptr, version.len);
}
