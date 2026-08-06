const std = @import("std");
const testing = std.testing;
const decoder_module = @import("gpu/virgl/decoder.zig");
const protocol = @import("gpu/virgl/protocol.zig");

fn decodeCommand(
    decoder: *decoder_module.Decoder,
    header: protocol.CommandHeader,
) !void {
    switch (header.opcode) {
        .clear => _ = try decoder_module.Clear.decode(decoder, header.length),
        .draw_vbo => _ = try decoder_module.DrawVbo.decode(decoder, header.length),
        .set_viewport_state => _ = try decoder_module.Viewport.decode(decoder, header.length),
        .set_framebuffer_state => _ = try decoder_module.Framebuffer.decode(decoder, header.length),
        else => _ = try decoder.payload(header.length),
    }
}

fn checkCommandStream(_: void, smith: *testing.Smith) !void {
    const alignment_offset = smith.valueRangeAtMost(u8, 0, 3);
    var storage: [1027]u8 align(@alignOf(u32)) = undefined;
    const input_len = smith.slice(storage[alignment_offset..]);
    const input = storage[alignment_offset..][0..input_len];
    const word_len = input.len / @sizeOf(u32);

    var decoder = decoder_module.Decoder.init(input);
    var word_pos: usize = 0;
    while (decoder.hasMore()) {
        try testing.expect(word_pos < word_len);
        const header_word = std.mem.readInt(u32, input[word_pos * 4 ..][0..4], .little);
        const payload_len: u16 = @truncate(header_word >> 16);
        const remaining_words = word_len - word_pos - 1;

        const header = decoder.nextHeader() catch |err| {
            try testing.expectEqual(error.InvalidLength, err);
            try testing.expect(payload_len > remaining_words);
            return;
        };
        try testing.expectEqual(payload_len, header.length);
        try testing.expect(payload_len <= remaining_words);

        decodeCommand(&decoder, header) catch |err| switch (err) {
            error.InvalidLength, error.UnexpectedEnd => return,
            error.InvalidCommand => return error.InvalidCommand,
        };
        word_pos += 1 + payload_len;
    }

    try testing.expectEqual(word_len, word_pos);
}

const seed_nop = "\x00\x00\x00\x00";
const seed_trailing_bytes = "\x00\x00\x00";
const seed_oversized_clear = "\x07\x00\xff\xff";
const seed_clear = "\x07\x00\x08\x00" ++ ("\x00" ** 32);

test "virgl decoder command stream properties" {
    return testing.fuzz({}, checkCommandStream, .{ .corpus = &.{
        seed_nop,
        seed_trailing_bytes,
        seed_oversized_clear,
        seed_clear,
    } });
}
