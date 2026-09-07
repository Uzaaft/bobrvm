//! POSIX-shell argument encoding for CLI commands.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Quote one shell argument. The caller owns the returned allocation.
pub fn quote(alloc: Allocator, value: []const u8) Allocator.Error![]const u8 {
    return join(alloc, &.{value});
}

/// Return a caller-owned POSIX-shell command line, single-quoting
/// each word (embedded single quotes become '\'').
pub fn join(alloc: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    for (parts, 0..) |part, i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.append(alloc, '\'');
        for (part) |byte| {
            if (byte == '\'') {
                try out.appendSlice(alloc, "'\\''");
            } else {
                try out.append(alloc, byte);
            }
        }
        try out.append(alloc, '\'');
    }
    return out.toOwnedSlice(alloc);
}

test "join quotes each argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "'sh' '-c' 'exit 7'",
        try join(arena, &.{ "sh", "-c", "exit 7" }),
    );
    try std.testing.expectEqualStrings(
        "'echo' 'it'\\''s'",
        try join(arena, &.{ "echo", "it's" }),
    );
}
