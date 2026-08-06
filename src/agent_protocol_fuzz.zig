const std = @import("std");
const testing = std.testing;
const protocol = @import("agent/protocol.zig");

fn checkFrameRoundTrip(smith: *testing.Smith) !void {
    var payload_buffer: [1024]u8 = undefined;
    const payload_len = smith.slice(&payload_buffer);
    const payload = payload_buffer[0..payload_len];
    const expected = protocol.Frame{
        .kind = @enumFromInt(smith.value(u16)),
        .request_id = smith.value(u64),
        .payload = payload,
    };
    var encoded_buffer: [protocol.Header.bytes + payload_buffer.len]u8 = undefined;
    const encoded = try protocol.encode(&encoded_buffer, expected);
    const fragment_len = smith.valueRangeAtMost(u16, 1, 64);

    var decoder = protocol.Decoder.init(testing.allocator);
    defer decoder.deinit();
    var offset: usize = 0;
    var decoded = false;
    while (offset < encoded.len) {
        const end = @min(encoded.len, offset + fragment_len);
        if (try decoder.feed(encoded[offset..end])) |frame| {
            try testing.expect(!decoded);
            try testing.expectEqual(expected.kind, frame.kind);
            try testing.expectEqual(expected.request_id, frame.request_id);
            try testing.expectEqualSlices(u8, expected.payload, frame.payload);
            decoded = true;
        }
        offset = end;
    }
    try testing.expect(decoded);
}

fn checkFileOffer(payload: []const u8) !void {
    const offer = protocol.FileOffer.decode(payload) catch return;
    var encoded_buffer: [
        protocol.FileOffer.header_bytes +
            protocol.FileOffer.name_bytes_max
    ]u8 = undefined;
    const encoded = try protocol.FileOffer.encode(&encoded_buffer, offer.size, offer.name);
    const decoded = try protocol.FileOffer.decode(encoded);
    try testing.expectEqual(offer.size, decoded.size);
    try testing.expectEqualSlices(u8, offer.name, decoded.name);
}

fn checkFileChunk(payload: []const u8) !void {
    const chunk = protocol.FileChunk.decode(payload) catch return;
    var encoded_buffer: [protocol.FileChunk.header_bytes + 512]u8 = undefined;
    const encoded = try protocol.FileChunk.encode(&encoded_buffer, chunk.offset, chunk.data);
    const decoded = try protocol.FileChunk.decode(encoded);
    try testing.expectEqual(chunk.offset, decoded.offset);
    try testing.expectEqualSlices(u8, chunk.data, decoded.data);
}

fn checkPayloadCodecs(smith: *testing.Smith) !void {
    var payload_buffer: [512]u8 = undefined;
    const payload_len = smith.slice(&payload_buffer);
    const payload = payload_buffer[0..payload_len];

    try checkFileOffer(payload);
    try checkFileChunk(payload);
    if (protocol.Clipboard.decode(payload)) |text| {
        try testing.expect(text.len <= protocol.clipboard_text_bytes_max);
        try testing.expect(std.unicode.utf8ValidateSlice(text));
    } else |_| {}
}

fn checkProtocol(_: void, smith: *testing.Smith) !void {
    try checkFrameRoundTrip(smith);
    try checkPayloadCodecs(smith);
}

const seed_zero: [64]u8 = @splat(0);
const seed_ones: [64]u8 = @splat(0xFF);

test "agent protocol codec properties" {
    return testing.fuzz({}, checkProtocol, .{ .corpus = &.{ &seed_zero, &seed_ones } });
}
