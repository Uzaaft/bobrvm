//! Helpers for manually vectorized hot loops with a scalar fallback.

const std = @import("std");

/// Return a two-register chunk size for `T`, or null when the target does not
/// suggest a usable vector width. Callers retain their scalar loop as both the
/// unsupported-target fallback and the remainder path.
pub fn lanes(comptime T: type) ?comptime_int {
    const native = std.simd.suggestVectorLength(T) orelse return null;
    return native * 2;
}

test "lanes use two native vectors" {
    const native = std.simd.suggestVectorLength(u8) orelse {
        try std.testing.expect(lanes(u8) == null);
        return;
    };
    try std.testing.expectEqual(native * 2, lanes(u8).?);
}
