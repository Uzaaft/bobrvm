//! Guest diagnostics for bobrvm integration channels.

const std = @import("std");

const ports = [_][]const u8{
    "org.qemu.guest_agent.0",
    "com.redhat.spice.0",
    "org.bobrvm.agent.0",
    "org.bobrvm.clipboard.0",
};

pub fn main(minimal: std.process.Init.Minimal) !void {
    var args = minimal.args.iterate();
    _ = args.skip();
    const command = args.next() orelse return usage();
    if (std.mem.eql(u8, command, "status")) return status();
    if (std.mem.eql(u8, command, "doctor")) return doctor();
    usage();
}

fn status() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    for (ports) |name| {
        var path: [128]u8 = undefined;
        const absolute = try std.fmt.bufPrint(&path, "/dev/virtio-ports/{s}", .{name});
        const state: []const u8 = if (std.Io.Dir.accessAbsolute(io, absolute, .{}))
            "present"
        else |_|
            "missing";
        var line: [192]u8 = undefined;
        const output = try std.fmt.bufPrint(&line, "{s}: {s}\n", .{ name, state });
        _ = std.c.write(std.posix.STDOUT_FILENO, output.ptr, output.len);
    }
}

fn doctor() !void {
    try status();
    if (std.c.getenv("WAYLAND_DISPLAY") != null) {
        write("wayland: session detected; check systemctl --user status bobrvm-session-agent\n");
    }
    if (std.Io.Dir.accessAbsolute(
        std.Io.Threaded.global_single_threaded.io(),
        "/etc/NIXOS",
        .{},
    )) {
        write("activation: managed by virtualisation.bobrvm.guest\n");
    } else |_| {
        write("activation: install service and udev integration for this distribution\n");
    }
}

fn usage() void {
    write("usage: bobrvm-toolbox <status|doctor>\n");
}

fn write(message: []const u8) void {
    _ = std.c.write(std.posix.STDOUT_FILENO, message.ptr, message.len);
}
