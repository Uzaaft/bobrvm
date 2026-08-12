//! PCI type-0 configuration-space write policy.

const std = @import("std");

pub const space_size = 4096;
pub const bar0_offset = 0x10;
pub const bar0_mask: u32 = 0xFFFF_F000;

pub const WriteEffect = union(enum) {
    none,
    bar0_probe,
    bar0_assigned: u32,
};

pub fn writeType0(
    config: *[space_size]u8,
    offset: u12,
    size: u8,
    value: u64,
) WriteEffect {
    if (@as(usize, offset) + size > config.len) return .none;
    if (offset == bar0_offset and size == 4 and @as(u32, @truncate(value)) ==
        std.math.maxInt(u32))
    {
        writeU32(config, bar0_offset, bar0_mask);
        return .bar0_probe;
    }

    var bar0_touched = false;
    for (0..size) |index| {
        const byte_offset = @as(usize, offset) + index;
        const byte: u8 = @truncate(value >> @intCast(index * 8));
        switch (byte_offset) {
            0x04 => config[byte_offset] = byte & 0x07,
            0x0C, 0x0D, 0x3C => config[byte_offset] = byte,
            bar0_offset...bar0_offset + 3 => {
                config[byte_offset] = byte;
                bar0_touched = true;
            },
            else => {},
        }
    }

    if (!bar0_touched) return .none;
    const assigned = readU32(config, bar0_offset) & bar0_mask;
    writeU32(config, bar0_offset, assigned);
    return .{ .bar0_assigned = assigned };
}

fn readU32(config: *const [space_size]u8, offset: usize) u32 {
    return @as(u32, config[offset]) |
        (@as(u32, config[offset + 1]) << 8) |
        (@as(u32, config[offset + 2]) << 16) |
        (@as(u32, config[offset + 3]) << 24);
}

fn writeU32(config: *[space_size]u8, offset: usize, value: u32) void {
    config[offset] = @truncate(value);
    config[offset + 1] = @truncate(value >> 8);
    config[offset + 2] = @truncate(value >> 16);
    config[offset + 3] = @truncate(value >> 24);
}
