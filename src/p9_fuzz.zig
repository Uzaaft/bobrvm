const std = @import("std");
const testing = std.testing;
const p9 = @import("fs/p9.zig");

const request_bytes_max = 1024;
const requests_max = 16;
const safe_message_types = [_]u8{
    p9.Tversion,
    p9.Tattach,
    p9.Twalk,
    p9.Tgetattr,
    p9.Tstatfs,
    p9.Tfsync,
    p9.Tclunk,
    p9.Tflush,
    16,
    0xFF,
};

fn setDeclaredSize(request: []u8, smith: *testing.Smith) void {
    if (request.len < @sizeOf(u32)) return;
    const mode = smith.valueRangeAtMost(u8, 0, 3);
    const size: u32 = switch (mode) {
        0 => @intCast(request.len),
        1 => smith.value(u32),
        2 => @intCast(@min(request.len + 1, std.math.maxInt(u32))),
        3 => smith.valueRangeAtMost(u32, 0, @intCast(request.len)),
        else => unreachable,
    };
    std.mem.writeInt(u32, request[0..4], size, .little);
}

fn checkResponse(server: *p9.P9Server, request: []u8, response: []u8) !void {
    var request_copy: [request_bytes_max]u8 = undefined;
    @memcpy(request_copy[0..request.len], request);

    const response_len = server.handle(request, response);
    try testing.expect(response_len >= 7);
    try testing.expect(response_len <= response.len);
    try testing.expectEqual(
        @as(u32, @intCast(response_len)),
        std.mem.readInt(u32, response[0..4], .little),
    );
    const expected_tag = if (request.len >= 7)
        std.mem.readInt(u16, request[5..7], .little)
    else
        0;
    try testing.expectEqual(expected_tag, std.mem.readInt(u16, response[5..7], .little));
    if (response[4] == p9.Tlerror + 1) try testing.expectEqual(@as(usize, 11), response_len);
    try testing.expectEqualSlices(u8, request_copy[0..request.len], request);
    try testing.expect(server.msize <= p9.MSIZE_MAX);
}

fn checkServer(_: void, smith: *testing.Smith) !void {
    var root = [_]u8{'.'};
    var server = p9.P9Server.initEmbedded(testing.allocator, &root);
    defer server.deinitEmbedded();
    var response: [p9.MSIZE_MAX]u8 = undefined;
    var request: [request_bytes_max]u8 = undefined;

    const request_count = smith.valueRangeAtMost(u8, 1, requests_max);
    for (0..request_count) |_| {
        const request_len = smith.slice(&request);
        const bytes = request[0..request_len];
        if (bytes.len >= 5) {
            const type_index = smith.valueRangeAtMost(
                u8,
                0,
                safe_message_types.len - 1,
            );
            bytes[4] = safe_message_types[type_index];
        }
        setDeclaredSize(bytes, smith);
        try checkResponse(&server, bytes, &response);
    }
}

const seed_zero: [64]u8 = @splat(0);
const seed_ones: [64]u8 = @splat(0xFF);

test "9P request decoder properties" {
    return testing.fuzz({}, checkServer, .{ .corpus = &.{ &seed_zero, &seed_ones } });
}
