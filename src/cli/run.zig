//! `bobrvm run` - Run a VM directly with options.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const runner = @import("runner.zig");

const log = std.log.scoped(.cli);

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    const config = Config.parseArgs(args) catch |err| {
        if (err == error.HelpRequested) {
            printHelp();
            return;
        }
        return err;
    };

    try runner.run(alloc, &config);
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm run [options]
        \\
        \\Run a VM directly with the specified options.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
    Config.printOptions();

    const examples =
        \\Examples:
        \\  bobrvm run --memory 1024 --cpus 4
        \\  bobrvm run --kernel vmlinuz --initrd initrd.img --disk root.raw
        \\  bobrvm run --firmware QEMU_EFI.fd --disk root.raw --disk2 install.iso
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, examples.ptr, examples.len);
}
