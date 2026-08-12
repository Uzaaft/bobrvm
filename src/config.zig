//! Shared virtual-machine configuration policy.
//!
//! Frontends own presentation and platform integration. Defaults, validation,
//! and media safety rules live here so macOS and Linux behave identically.

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;

pub const memory_bytes_default: u64 = 512 * 1024 * 1024;
pub const vcpu_count_default: u8 = 2;
pub const display_width_default: u32 = 1280;
pub const display_height_default: u32 = 800;
pub const display_dimension_min: u32 = 320;
pub const display_dimension_max: u32 = 8192;
pub const gpu_memory_bytes_default: u64 = 512 * 1024 * 1024;
pub const gpu_memory_bytes_min: u64 = 64 * 1024 * 1024;
pub const gpu_memory_bytes_max: u64 = 2048 * 1024 * 1024;

pub const Values = struct {
    memory_bytes: u64 = memory_bytes_default,
    vcpu_count: u8 = vcpu_count_default,
    display_width: u32 = display_width_default,
    display_height: u32 = display_height_default,
    gpu_memory_bytes: u64 = gpu_memory_bytes_default,
    disk_path: ?[]const u8 = null,
    disk_read_only: bool = false,
    disk2_path: ?[]const u8 = null,
    disk2_read_only: bool = true,
};

pub const ValidationError = error{
    InvalidMemory,
    InvalidVcpuCount,
    InvalidDisplaySize,
    InvalidGpuMemory,
    WritableIso,
};

pub fn validate(values: Values) ValidationError!void {
    assert(gpu_memory_bytes_min > 0);
    assert(gpu_memory_bytes_max >= gpu_memory_bytes_min);

    if (values.memory_bytes == 0) return error.InvalidMemory;
    if (values.vcpu_count == 0) return error.InvalidVcpuCount;
    const display_enabled = values.display_width > 0 and values.display_height > 0;
    if ((values.display_width == 0) != (values.display_height == 0) or
        display_enabled and (values.display_width < display_dimension_min or
            values.display_height < display_dimension_min or
            values.display_width > display_dimension_max or
            values.display_height > display_dimension_max))
    {
        return error.InvalidDisplaySize;
    }
    if (values.gpu_memory_bytes != 0 and
        (values.gpu_memory_bytes < gpu_memory_bytes_min or
            values.gpu_memory_bytes > gpu_memory_bytes_max))
    {
        return error.InvalidGpuMemory;
    }
    if (display_enabled and values.gpu_memory_bytes > 0) {
        const pixels = @as(u64, values.display_width) * values.display_height;
        if (pixels * 4 > values.gpu_memory_bytes) return error.InvalidDisplaySize;
    }
    if (values.disk_path) |path| {
        if (isIsoPath(path) and !values.disk_read_only) return error.WritableIso;
    }
    if (values.disk2_path) |path| {
        if (isIsoPath(path) and !values.disk2_read_only) return error.WritableIso;
    }
}

pub fn isIsoPath(path: []const u8) bool {
    assert(path.len <= std.math.maxInt(u32));
    assert(".iso".len == 4);
    return endsWithAsciiIgnoreCase(path, ".iso");
}

pub fn isRawPath(path: []const u8) bool {
    assert(path.len <= std.math.maxInt(u32));
    assert(".raw".len == 4);
    return endsWithAsciiIgnoreCase(path, ".raw");
}

pub fn sanitizeFilename(input: []const u8, output: []u8) error{BufferTooSmall}![]const u8 {
    assert(input.len <= std.math.maxInt(u32));
    assert(output.len <= std.math.maxInt(u32));
    if (output.len < input.len) return error.BufferTooSmall;
    for (input, output[0..input.len]) |source, *target| {
        target.* = switch (source) {
            '/', ':' => '-',
            ' ' => '_',
            else => source,
        };
    }
    assert(output.len >= input.len);
    return output[0..input.len];
}

fn endsWithAsciiIgnoreCase(value: []const u8, suffix: []const u8) bool {
    assert(suffix.len > 0);
    assert(suffix.len <= std.math.maxInt(u8));
    if (value.len < suffix.len) return false;
    const tail = value[value.len - suffix.len ..];
    return std.ascii.eqlIgnoreCase(tail, suffix);
}

test "shared defaults validate" {
    try validate(.{});
}

test "display dimensions and framebuffer budget are bounded" {
    try std.testing.expectError(error.InvalidDisplaySize, validate(.{
        .display_width = display_dimension_min - 1,
        .display_height = display_height_default,
    }));
    try std.testing.expectError(error.InvalidDisplaySize, validate(.{
        .display_width = display_dimension_max,
        .display_height = display_dimension_max,
        .gpu_memory_bytes = gpu_memory_bytes_min,
    }));
}

test "configuration policy accepts and rejects exact boundaries" {
    try std.testing.expectError(error.InvalidMemory, validate(.{ .memory_bytes = 0 }));
    try std.testing.expectError(error.InvalidVcpuCount, validate(.{ .vcpu_count = 0 }));
    try std.testing.expectError(error.InvalidDisplaySize, validate(.{ .display_width = 0 }));
    try std.testing.expectError(error.InvalidDisplaySize, validate(.{ .display_height = 0 }));
    try validate(.{ .display_width = 0, .display_height = 0 });

    try validate(.{ .gpu_memory_bytes = 0 });
    try validate(.{ .gpu_memory_bytes = gpu_memory_bytes_min });
    try validate(.{ .gpu_memory_bytes = gpu_memory_bytes_max });
    try std.testing.expectError(error.InvalidGpuMemory, validate(.{
        .gpu_memory_bytes = gpu_memory_bytes_min - 1,
    }));
    try std.testing.expectError(error.InvalidGpuMemory, validate(.{
        .gpu_memory_bytes = gpu_memory_bytes_max + 1,
    }));
}

test "ISO safety is case insensitive" {
    try std.testing.expect(isIsoPath("installer.ISO"));
    try std.testing.expectError(error.WritableIso, validate(.{
        .disk2_path = "installer.ISO",
        .disk2_read_only = false,
    }));
    try std.testing.expectError(error.WritableIso, validate(.{
        .disk_path = "installer.iso",
        .disk_read_only = false,
    }));
    try validate(.{ .disk_path = "installer.iso", .disk_read_only = true });
    try validate(.{ .disk2_path = "installer.ISO", .disk2_read_only = true });
}

test "raw disk extension is case insensitive" {
    try std.testing.expect(isRawPath("machine.RAW"));
    try std.testing.expect(!isRawPath("machine.qcow2"));
}

test "filename sanitization needs no allocation" {
    var output: [32]u8 = undefined;
    const result = try sanitizeFilename("NixOS VM:1", &output);
    try std.testing.expectEqualStrings("NixOS_VM-1", result);
    try std.testing.expectError(error.BufferTooSmall, sanitizeFilename("large", output[0..4]));
}
