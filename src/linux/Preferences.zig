//! Persistent defaults for new virtual machines created by the Linux application.

const Preferences = @This();

const std = @import("std");
const config_policy = @import("../config.zig");
const file_compat = @import("../compat/file.zig");
const global = @import("../global.zig");
const SavedConfig = @import("../cli/Config.zig");

memory_mib: u64 = config_policy.memory_bytes_default / (1024 * 1024),
vcpu_count: u8 = config_policy.vcpu_count_default,

const settings_bytes_max: usize = 4096;

pub fn load(allocator: std.mem.Allocator) !Preferences {
    const path = try settingsPath(allocator);
    defer allocator.free(path);
    const file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(global.io());
    const bytes = try file_compat.readToEndAlloc(file, allocator, settings_bytes_max);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Preferences, allocator, bytes, .{});
    defer parsed.deinit();
    try parsed.value.validate();
    return parsed.value;
}

pub fn save(self: Preferences, allocator: std.mem.Allocator) !void {
    try self.validate();
    const config_dir = try SavedConfig.ensureConfigDir(allocator);
    allocator.free(config_dir);
    const path = try settingsPath(allocator);
    defer allocator.free(path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, self, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(bytes);
    const file = try std.Io.Dir.createFileAbsolute(global.io(), path, .{});
    defer file.close(global.io());
    try file.writePositionalAll(global.io(), bytes, 0);
    try file.writePositionalAll(global.io(), "\n", bytes.len);
}

pub fn validate(self: Preferences) config_policy.ValidationError!void {
    const memory_bytes = std.math.mul(u64, self.memory_mib, 1024 * 1024) catch {
        return error.InvalidMemory;
    };
    try config_policy.validate(.{
        .memory_bytes = memory_bytes,
        .vcpu_count = self.vcpu_count,
    });
}

fn settingsPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHomeDir);
    return std.fs.path.join(allocator, &.{ home, ".config", "bobrvm", "settings.json" });
}

test "default preferences follow shared configuration policy" {
    try (Preferences{}).validate();
}

test "invalid default resources are rejected" {
    try std.testing.expectError(error.InvalidMemory, (Preferences{ .memory_mib = 0 }).validate());
    try std.testing.expectError(
        error.InvalidVcpuCount,
        (Preferences{ .vcpu_count = 0 }).validate(),
    );
}
