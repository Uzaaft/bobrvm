const std = @import("std");
const testing = std.testing;
const container = @import("machine/snapshot_container.zig");

const header_bytes = container.MAGIC.len + @sizeOf(u32);
const input_bytes_max = 1024;
const query_bytes_max = 32;
const generated_sections_max = 8;

fn modelSection(bytes: []const u8, query: []const u8) ?[]const u8 {
    var offset: usize = header_bytes;
    while (offset < bytes.len) {
        const name_len = bytes[offset];
        offset += 1;
        const remaining_name = bytes.len - offset;
        if (name_len > remaining_name) return null;
        const name = bytes[offset..][0..name_len];
        offset += name_len;

        const remaining_header = bytes.len - offset;
        if (remaining_header < @sizeOf(u64)) return null;
        const data_len_u64 = std.mem.readInt(u64, bytes[offset..][0..8], .little);
        offset += @sizeOf(u64);
        const remaining_data = bytes.len - offset;
        if (data_len_u64 > remaining_data) return null;
        const data_len: usize = @intCast(data_len_u64);
        if (std.mem.eql(u8, name, query)) return bytes[offset..][0..data_len];
        offset += data_len;
    }
    return null;
}

fn checkInit(bytes: []const u8) !void {
    const result = container.Reader.init(bytes);
    if (bytes.len < header_bytes) {
        try testing.expectError(error.Truncated, result);
    } else if (!std.mem.eql(u8, bytes[0..container.MAGIC.len], container.MAGIC)) {
        try testing.expectError(error.BadMagic, result);
    } else if (std.mem.readInt(u32, bytes[container.MAGIC.len..][0..4], .little) !=
        container.VERSION)
    {
        try testing.expectError(error.BadVersion, result);
    } else {
        _ = try result;
    }
}

fn expectSection(bytes: []const u8, query: []const u8) !void {
    const reader = try container.Reader.init(bytes);
    const expected = modelSection(bytes, query);
    const actual = reader.section(query);
    try testing.expectEqual(expected == null, actual == null);
    if (expected) |expected_data| {
        try testing.expectEqualSlices(u8, expected_data, actual.?);
    }
}

fn checkGeneratedContainer(smith: *testing.Smith) !void {
    var bytes: [header_bytes + generated_sections_max * (1 + 16 + 8 + 64)]u8 = undefined;
    @memcpy(bytes[0..container.MAGIC.len], container.MAGIC);
    std.mem.writeInt(
        u32,
        bytes[container.MAGIC.len..][0..4],
        container.VERSION,
        .little,
    );

    var names: [generated_sections_max][16]u8 = undefined;
    var name_lengths: [generated_sections_max]usize = undefined;
    const section_count = smith.valueRangeAtMost(u8, 0, generated_sections_max);
    var offset: usize = header_bytes;
    for (0..section_count) |index| {
        name_lengths[index] = smith.slice(&names[index]);
        bytes[offset] = @intCast(name_lengths[index]);
        offset += 1;
        @memcpy(bytes[offset..][0..name_lengths[index]], names[index][0..name_lengths[index]]);
        offset += name_lengths[index];

        var data: [64]u8 = undefined;
        const data_len = smith.slice(&data);
        std.mem.writeInt(u64, bytes[offset..][0..8], data_len, .little);
        offset += @sizeOf(u64);
        @memcpy(bytes[offset..][0..data_len], data[0..data_len]);
        offset += data_len;
    }

    var unknown_query: [query_bytes_max]u8 = undefined;
    const unknown_len = smith.slice(&unknown_query);
    const query = if (section_count > 0 and smith.value(bool)) q: {
        const index = smith.valueRangeAtMost(u8, 0, section_count - 1);
        break :q names[index][0..name_lengths[index]];
    } else unknown_query[0..unknown_len];
    try expectSection(bytes[0..offset], query);
}

fn checkContainer(_: void, smith: *testing.Smith) !void {
    var arbitrary_bytes: [input_bytes_max]u8 = undefined;
    const arbitrary_len = smith.slice(&arbitrary_bytes);
    try checkInit(arbitrary_bytes[0..arbitrary_len]);

    var valid_bytes: [header_bytes + input_bytes_max]u8 = undefined;
    @memcpy(valid_bytes[0..container.MAGIC.len], container.MAGIC);
    std.mem.writeInt(
        u32,
        valid_bytes[container.MAGIC.len..][0..4],
        container.VERSION,
        .little,
    );
    const body_len = smith.slice(valid_bytes[header_bytes..]);
    const bytes = valid_bytes[0 .. header_bytes + body_len];

    var query_bytes: [query_bytes_max]u8 = undefined;
    const query_len = smith.slice(&query_bytes);
    const query = query_bytes[0..query_len];
    try expectSection(bytes, query);
    try checkGeneratedContainer(smith);
}

const seed_zero: [64]u8 = @splat(0);
const seed_ones: [64]u8 = @splat(0xFF);

test "snapshot container parser properties" {
    return testing.fuzz({}, checkContainer, .{ .corpus = &.{ &seed_zero, &seed_ones } });
}
