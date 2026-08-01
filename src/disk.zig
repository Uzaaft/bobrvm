//! Cross-platform sparse-disk operations shared by every frontend.

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const config = @import("config.zig");
const global = @import("global.zig");

pub const Error = error{
    InvalidPath,
    InvalidSize,
    CannotShrink,
    UnsupportedFormat,
} || std.Io.File.OpenError || std.Io.File.SetLengthError || std.Io.File.LengthError;

pub fn createSparse(path: []const u8, size_bytes: u64) Error!void {
    assert(@sizeOf(usize) >= @sizeOf(u32));
    assert(std.fs.path.sep != 0);
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidPath;
    if (size_bytes == 0) return error.InvalidSize;

    const io = global.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
    errdefer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer file.close(io);
    try file.setLength(io, size_bytes);
    assert(try file.length(io) == size_bytes);
}

pub fn growRaw(path: []const u8, size_bytes: u64) Error!void {
    assert(@sizeOf(usize) >= @sizeOf(u32));
    assert(std.fs.path.sep != 0);
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidPath;
    if (!config.isRawPath(path)) return error.UnsupportedFormat;
    if (size_bytes == 0) return error.InvalidSize;

    const io = global.io();
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
    defer file.close(io);
    const size_bytes_current = try file.length(io);
    if (size_bytes < size_bytes_current) return error.CannotShrink;
    if (size_bytes == size_bytes_current) return;
    try file.setLength(io, size_bytes);
    assert(try file.length(io) == size_bytes);
}

pub fn logicalSize(path: []const u8) Error!u64 {
    assert(@sizeOf(usize) >= @sizeOf(u32));
    assert(std.fs.path.sep != 0);
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidPath;
    const io = global.io();
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const size_bytes = try file.length(io);
    assert(size_bytes <= std.math.maxInt(u64));
    return size_bytes;
}

test "sparse disk grows but never shrinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_length = try tmp.dir.realPath(global.io(), &dir_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/disk.raw", .{
        dir_buffer[0..dir_length],
    });

    try createSparse(path, 4096);
    try std.testing.expectEqual(@as(u64, 4096), try logicalSize(path));
    try growRaw(path, 8192);
    try std.testing.expectEqual(@as(u64, 8192), try logicalSize(path));
    try std.testing.expectError(error.CannotShrink, growRaw(path, 4096));
}

test "only raw disks grow" {
    try std.testing.expectError(error.UnsupportedFormat, growRaw("/tmp/disk.qcow2", 4096));
    try std.testing.expectError(error.InvalidPath, createSparse("disk.raw", 4096));
}
