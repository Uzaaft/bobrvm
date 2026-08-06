//! Adapted from MIT-licensed compatibility work by the Ghostty maintainers,
//! originally based on Zig 0.15.2 std.fs.File. Zig 0.16 removed
//! File.readToEndAlloc when file I/O moved into std.Io.

const std = @import("std");
const global = @import("../global.zig");

pub const ReadToEndAllocError = error{FileTooBig} ||
    std.Io.File.ReadStreamingError ||
    std.mem.Allocator.Error;

/// Read the file from its current position through end-of-stream, returning
/// `error.FileTooBig` if the result exceeds `max_bytes`.
///
/// Caller owns the memory.
pub fn readToEndAlloc(file: std.Io.File, alloc: std.mem.Allocator, max_bytes: usize) ReadToEndAllocError![]u8 {
    var read_buf: [4096]u8 = undefined;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    while (true) {
        const n = file.readStreaming(global.io(), &.{&read_buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) continue;
        if (n > max_bytes - result.items.len) return error.FileTooBig;
        try result.appendSlice(alloc, read_buf[0..n]);
    }

    return result.toOwnedSlice(alloc);
}

test "bounded file read preserves binary data from the current position" {
    const testing = std.testing;
    const io = global.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const output = try tmp.dir.createFile(io, "binary", .{});
    try output.writeStreamingAll(io, "skip\x00payload");
    output.close(io);

    const input = try tmp.dir.openFile(io, "binary", .{});
    defer input.close(io);
    var prefix: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try input.readStreaming(io, &.{&prefix}));
    try testing.expectEqualSlices(u8, "skip\x00", &prefix);

    const result = try readToEndAlloc(input, testing.allocator, 7);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, "payload", result);
}

test "bounded file read rejects data beyond the limit across chunks" {
    const testing = std.testing;
    const io = global.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var data: [4097]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index);
    const output = try tmp.dir.createFile(io, "oversized", .{});
    try output.writeStreamingAll(io, &data);
    output.close(io);

    const input = try tmp.dir.openFile(io, "oversized", .{});
    defer input.close(io);
    try testing.expectError(error.FileTooBig, readToEndAlloc(input, testing.allocator, 4096));
}
