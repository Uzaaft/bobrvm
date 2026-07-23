//! Vendored from Ghostty's src/lib/compat/file.zig (itself lifted from
//! zig 0.15.2 std.fs.File, MIT licensed) since zig 0.16 removed
//! File.readToEndAlloc when it restructured file I/O into std.Io.

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
