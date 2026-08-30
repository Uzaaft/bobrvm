//! Monotonic readers for guest-owned scatter/gather backing.

const std = @import("std");
const ring = @import("virtio/ring.zig");

/// Build a reader for an entry type with `addr: u64` and `length: u32` fields.
/// The accessor remains comptime-known while each reader retains its current
/// entry, avoiding repeated scans from the start of a guest backing list.
pub fn Reader(comptime Entry: type) type {
    return struct {
        const Self = @This();

        entries: []const Entry,
        entry_index: usize = 0,
        entry_offset: u32 = 0,

        pub fn init(entries: []const Entry, offset: u64) ?Self {
            var reader = Self{ .entries = entries };
            if (!reader.skip(offset)) return null;
            return reader;
        }

        pub fn skip(self: *Self, length: u64) bool {
            var remaining = length;
            while (remaining > 0) {
                if (self.entry_index >= self.entries.len) return false;
                const entry = self.entries[self.entry_index];
                const available = entry.length - self.entry_offset;
                const consumed: u32 = @intCast(@min(remaining, available));
                self.entry_offset += consumed;
                remaining -= consumed;
                if (self.entry_offset == entry.length) self.nextEntry();
            }
            return true;
        }

        pub fn read(self: *Self, dst: []u8, get_mem: anytype) bool {
            var remaining = dst;
            while (remaining.len > 0) {
                if (self.entry_index >= self.entries.len) return false;
                const entry = self.entries[self.entry_index];
                const available = entry.length - self.entry_offset;
                if (available == 0) {
                    self.nextEntry();
                    continue;
                }
                const copied: usize = @min(remaining.len, available);
                const address = std.math.add(u64, entry.addr, self.entry_offset) catch
                    return false;
                const src = ring.get(get_mem, address, copied) orelse return false;
                @memcpy(remaining[0..copied], src[0..copied]);
                remaining = remaining[copied..];
                if (!self.skip(copied)) return false;
            }
            return true;
        }

        fn nextEntry(self: *Self) void {
            self.entry_index += 1;
            self.entry_offset = 0;
        }
    };
}

const TestEntry = struct {
    addr: u64,
    length: u32,
};

test "Reader advances once across fragmented and empty entries" {
    const Memory = struct {
        var bytes = [_]u8{ 10, 11, 12, 13, 14, 15, 16, 17 };

        fn get(address: u64, length: usize) ?[]u8 {
            if (address > bytes.len or length > bytes.len - address) return null;
            return bytes[@intCast(address)..][0..length];
        }
    };
    const entries = [_]TestEntry{
        .{ .addr = 0, .length = 3 },
        .{ .addr = 3, .length = 0 },
        .{ .addr = 3, .length = 5 },
    };
    var reader = Reader(TestEntry).init(&entries, 2).?;
    var first: [4]u8 = undefined;
    try std.testing.expect(reader.read(&first, Memory.get));
    try std.testing.expectEqualSlices(u8, &.{ 12, 13, 14, 15 }, &first);
    try std.testing.expect(reader.skip(1));
    var last: [1]u8 = undefined;
    try std.testing.expect(reader.read(&last, Memory.get));
    try std.testing.expectEqual(@as(u8, 17), last[0]);
    try std.testing.expect(Reader(TestEntry).init(&entries, 9) == null);
}

test "Reader rejects overflowing guest addresses" {
    const Memory = struct {
        fn get(_: u64, _: usize) ?[]u8 {
            return null;
        }
    };
    const entries = [_]TestEntry{.{ .addr = std.math.maxInt(u64), .length = 2 }};
    var reader = Reader(TestEntry).init(&entries, 1).?;
    var byte: [1]u8 = undefined;
    try std.testing.expect(!reader.read(&byte, Memory.get));
}
