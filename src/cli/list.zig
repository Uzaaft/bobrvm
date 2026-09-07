//! `bobrvm list` discovers saved CLI and native-app VMs without importing them.

const std = @import("std");
const Inventory = @import("Inventory.zig");

pub fn execute(alloc: std.mem.Allocator) !void {
    var inventory = try Inventory.discover(alloc);
    defer inventory.deinit();
    if (inventory.entries.len == 0) {
        write("No VMs configured.\nUse 'bobrvm create <name> [options]' to create one.\n");
        return;
    }
    write("ID\tNAME\tBACKEND\tMEMORY (MiB)\tCPUS\tDISK\tDISK STATUS\n");
    var has_app = false;
    for (inventory.entries) |entry| {
        const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\t{d}\t{d}\t{s}\t{s}\n", .{
            entry.id,
            entry.name,
            entry.backend,
            entry.memory_bytes / (1024 * 1024),
            entry.cpus,
            if (entry.disk_path) |path| std.fs.path.basename(path) else "-",
            @tagName(entry.disk_status),
        });
        defer alloc.free(line);
        write(line);
        has_app = has_app or entry.source == .app;
    }
    write("\nStart CLI VMs with 'bobrvm start <name>' (without the cli: prefix).\n");
    if (has_app) write("App VMs are listed for discovery; start them in the Bobrvm app.\n");
}

fn write(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
}
