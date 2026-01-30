//! `bobrvm list` - List saved VM configurations.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");

const log = std.log.scoped(.cli);

pub fn execute(alloc: Allocator) !void {
    const names = try Config.listAll(alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    const stdout = std.posix.STDOUT_FILENO;

    if (names.len == 0) {
        _ = std.posix.write(stdout, "No VMs configured.\n") catch {};
        _ = std.posix.write(stdout, "Use 'bobrvm create <name> [options]' to create one.\n") catch {};
        return;
    }

    var buf: [4096]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "{s:<20} {s:<8} {s:<6} {s}\n", .{
        "NAME",
        "MEMORY",
        "CPUS",
        "DISK",
    }) catch return;
    _ = std.posix.write(stdout, header) catch {};

    for (names) |name| {
        var loaded = Config.load(alloc, name) catch |err| {
            log.warn("failed to load '{s}': {}", .{ name, err });
            continue;
        };
        defer loaded.deinit();

        const config = loaded.config;
        const disk_display: []const u8 = if (config.disk_path) |p|
            std.fs.path.basename(p)
        else
            "-";

        const line = std.fmt.bufPrint(&buf, "{s:<20} {d:<8} {d:<6} {s}\n", .{
            name,
            config.memory_mb,
            config.vcpu_count,
            disk_display,
        }) catch continue;
        _ = std.posix.write(stdout, line) catch {};
    }
}
