//! Bounds-checked decoding for the persisted snapshot container.

const std = @import("std");

pub const MAGIC = "BBRSNAP1";
pub const VERSION: u32 = 1;

pub const Reader = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) error{ Truncated, BadMagic, BadVersion }!Reader {
        if (bytes.len < MAGIC.len + @sizeOf(u32)) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return error.BadMagic;
        const version = std.mem.readInt(u32, bytes[MAGIC.len..][0..4], .little);
        if (version != VERSION) return error.BadVersion;
        return .{ .bytes = bytes };
    }

    /// Find the first section with `name`, rejecting a malformed suffix.
    pub fn section(self: Reader, name: []const u8) ?[]const u8 {
        var off: usize = MAGIC.len + @sizeOf(u32);
        while (off < self.bytes.len) {
            const name_len = self.bytes[off];
            off += 1;
            if (name_len > self.bytes.len - off) return null;
            const section_name = self.bytes[off..][0..name_len];
            off += name_len;
            if (@sizeOf(u64) > self.bytes.len - off) return null;
            const size = std.mem.readInt(u64, self.bytes[off..][0..8], .little);
            off += @sizeOf(u64);
            if (size > self.bytes.len - off) return null;
            const size_usize: usize = @intCast(size);
            if (std.mem.eql(u8, section_name, name)) {
                return self.bytes[off..][0..size_usize];
            }
            off += size_usize;
        }
        return null;
    }
};
