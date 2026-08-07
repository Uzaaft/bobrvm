//! Linux host launch configuration shared by the GTK and command-line entry points.

const std = @import("std");
const config_policy = @import("../config.zig");
const mininat = @import("../net/mininat.zig");

const AppConfig = @This();

memory_bytes: usize = config_policy.memory_bytes_default,
vcpu_count: u8 = config_policy.vcpu_count_default,
firmware_path: ?[]const u8 = null,
kernel_path: ?[]const u8 = null,
initrd_path: ?[]const u8 = null,
disk_path: ?[]const u8 = null,
iso_path: ?[]const u8 = null,
shared_dir: ?[]const u8 = null,
network_enabled: bool = true,
forwards: [MAX_FORWARDS]mininat.Forward = @splat(.{ .host_port = 0, .guest_port = 0 }),
forward_count: u8 = 0,
command_line: []const u8 = @import("run_kernel.zig").command_line,

pub const MAX_FORWARDS: usize = 8;

pub const ParseError = error{
    InvalidArgument,
    TooManyArguments,
};

pub fn parse(args: []const []const u8) ParseError!AppConfig {
    var result = AppConfig{};
    var positional: u8 = 0;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (!std.mem.startsWith(u8, argument, "--")) {
            switch (positional) {
                0 => result.kernel_path = argument,
                1 => result.initrd_path = argument,
                2 => result.disk_path = argument,
                else => return error.TooManyArguments,
            }
            positional += 1;
            continue;
        }
        if (std.mem.eql(u8, argument, "--no-net")) {
            result.network_enabled = false;
            continue;
        }
        index += 1;
        if (index == args.len) return error.InvalidArgument;
        const value = args[index];
        if (std.mem.eql(u8, argument, "--firmware")) {
            result.firmware_path = value;
        } else if (std.mem.eql(u8, argument, "--kernel")) {
            result.kernel_path = value;
        } else if (std.mem.eql(u8, argument, "--initrd")) {
            result.initrd_path = value;
        } else if (std.mem.eql(u8, argument, "--disk")) {
            result.disk_path = value;
        } else if (std.mem.eql(u8, argument, "--iso")) {
            result.iso_path = value;
        } else if (std.mem.eql(u8, argument, "--share")) {
            result.shared_dir = value;
        } else if (std.mem.eql(u8, argument, "--forward")) {
            if (result.forward_count == MAX_FORWARDS) return error.InvalidArgument;
            result.forwards[result.forward_count] = try parseForward(value);
            result.forward_count += 1;
            result.network_enabled = true;
        } else if (std.mem.eql(u8, argument, "--cmdline")) {
            result.command_line = value;
        } else if (std.mem.eql(u8, argument, "--memory")) {
            const memory_mib = std.fmt.parseInt(usize, value, 10) catch {
                return error.InvalidArgument;
            };
            result.memory_bytes = std.math.mul(usize, memory_mib, 1024 * 1024) catch {
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, argument, "--cpus")) {
            result.vcpu_count = std.fmt.parseInt(u8, value, 10) catch {
                return error.InvalidArgument;
            };
        } else {
            return error.InvalidArgument;
        }
    }
    if (result.firmware_path != null and result.kernel_path != null) {
        return error.InvalidArgument;
    }
    if (result.forward_count > 0) result.network_enabled = true;
    if (result.memory_bytes == 0 or result.vcpu_count == 0) return error.InvalidArgument;
    return result;
}

pub fn parseForward(value: []const u8) ParseError!mininat.Forward {
    const separator = std.mem.indexOfScalar(u8, value, ':') orelse {
        return error.InvalidArgument;
    };
    if (std.mem.indexOfScalar(u8, value[separator + 1 ..], ':') != null) {
        return error.InvalidArgument;
    }
    const host_port = std.fmt.parseInt(u16, value[0..separator], 10) catch {
        return error.InvalidArgument;
    };
    const guest_port = std.fmt.parseInt(u16, value[separator + 1 ..], 10) catch {
        return error.InvalidArgument;
    };
    if (host_port == 0 or guest_port == 0) return error.InvalidArgument;
    return .{ .host_port = host_port, .guest_port = guest_port };
}

test "ISO launch accepts firmware and two disks" {
    const result = try parse(&.{
        "--firmware",
        "/usr/share/bobrvm/OVMF.fd",
        "--disk",
        "/vms/linux.raw",
        "--iso",
        "/images/linux.iso",
        "--memory",
        "4096",
        "--cpus",
        "4",
    });
    try std.testing.expectEqualStrings("/usr/share/bobrvm/OVMF.fd", result.firmware_path.?);
    try std.testing.expectEqualStrings("/vms/linux.raw", result.disk_path.?);
    try std.testing.expectEqualStrings("/images/linux.iso", result.iso_path.?);
    try std.testing.expectEqual(@as(usize, 4096 * 1024 * 1024), result.memory_bytes);
    try std.testing.expectEqual(@as(u8, 4), result.vcpu_count);
}

test "legacy positional direct boot remains supported" {
    const result = try parse(&.{ "bzImage", "initrd", "root.raw" });
    try std.testing.expectEqualStrings("bzImage", result.kernel_path.?);
    try std.testing.expectEqualStrings("initrd", result.initrd_path.?);
    try std.testing.expectEqualStrings("root.raw", result.disk_path.?);
}

test "firmware and direct kernel are mutually exclusive" {
    try std.testing.expectError(error.InvalidArgument, parse(&.{
        "--firmware",
        "OVMF.fd",
        "--kernel",
        "bzImage",
    }));
}

test "port forwards are validated and enable networking" {
    const result = try parse(&.{ "--no-net", "--forward", "2222:22" });
    try std.testing.expect(result.network_enabled);
    try std.testing.expectEqual(@as(u8, 1), result.forward_count);
    try std.testing.expectEqual(@as(u16, 2222), result.forwards[0].host_port);
    try std.testing.expectEqual(@as(u16, 22), result.forwards[0].guest_port);
    try std.testing.expectError(error.InvalidArgument, parseForward("0:22"));
    try std.testing.expectError(error.InvalidArgument, parseForward("22"));
}
