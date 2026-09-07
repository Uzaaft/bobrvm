//! Bounded, allocation-free guest datagram collection for vmnet writes.
const Batch = @This();
const std = @import("std");
const protocol = @import("shared_protocol.zig");

storage: [capacity][protocol.frame_bytes_max + 1]u8 = undefined,
frames: [capacity][]u8 = undefined,

pub const capacity = 32;

/// Returned slices borrow this batch until the next receive. Invalid datagrams
/// also consume the budget so a guest cannot starve control and incoming traffic.
pub fn receive(self: *Batch, socket: c_int, mac: [6]u8) [][]u8 {
    var count: usize = 0;
    for (0..capacity) |_| {
        const buffer = &self.storage[count];
        const length = std.c.recv(socket, buffer, buffer.len, std.posix.MSG.DONTWAIT);
        if (length < 0) break;
        if (length < 14 or length > protocol.frame_bytes_max or
            !std.mem.eql(u8, buffer[6..12], &mac)) continue;
        self.frames[count] = buffer[0..@intCast(length)];
        count += 1;
    }
    return self.frames[0..count];
}

test "shared packet batches preserve order and bound malformed traffic" {
    var sockets: [2]c_int = undefined;
    try std.testing.expect(std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0, &sockets) == 0);
    defer for (sockets) |fd| {
        _ = std.c.close(fd);
    };
    const buffer_bytes: c_int = 256 * 1024;
    const configured = std.c.setsockopt(
        sockets[0],
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        &buffer_bytes,
        @sizeOf(c_int),
    );
    try std.testing.expect(configured == 0);
    const mac = [6]u8{ 2, 1, 2, 3, 4, 5 };
    var frame = [_]u8{0} ** (protocol.frame_bytes_max + 2);
    @memcpy(frame[6..12], &mac);
    for (0..capacity + 1) |index| {
        frame[0] = @intCast(index);
        try std.testing.expectEqual(14, std.c.send(sockets[1], &frame, 14, 0));
    }
    var batch: Batch = .{};
    const frames = batch.receive(sockets[0], mac);
    try std.testing.expectEqual(capacity, frames.len);
    for (frames, 0..) |packet, index| try std.testing.expectEqual(index, packet[0]);
    const remainder = batch.receive(sockets[0], mac);
    try std.testing.expectEqual(1, remainder.len);
    try std.testing.expectEqual(capacity, remainder[0][0]);
    for (0..capacity) |index| {
        const length: usize = if (index % 2 == 0) 13 else frame.len;
        const sent = std.c.send(sockets[1], &frame, length, 0);
        try std.testing.expectEqual(@as(isize, @intCast(length)), sent);
    }
    try std.testing.expectEqual(14, std.c.send(sockets[1], &frame, 14, 0));
    try std.testing.expectEqual(0, batch.receive(sockets[0], mac).len);
    try std.testing.expectEqual(1, batch.receive(sockets[0], mac).len);
    frame[6] = 4;
    try std.testing.expectEqual(14, std.c.send(sockets[1], &frame, 14, 0));
    try std.testing.expectEqual(0, batch.receive(sockets[0], mac).len);
}
