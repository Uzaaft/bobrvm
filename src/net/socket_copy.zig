//! Blocking socket relay shared by host and guest bridges.

const std = @import("std");

const copy_buffer_bytes: usize = 64 * 1024;

pub const Direction = struct {
    source_fd: std.posix.socket_t,
    destination_fd: std.posix.socket_t,
};

/// Borrows both blocking sockets. EOF shuts down only the destination's send
/// half so the reverse relay can finish; an I/O failure shuts down both sockets.
pub fn copyDirection(direction: Direction) void {
    var buffer: [copy_buffer_bytes]u8 = undefined;
    while (true) {
        const count = readRetry(direction.source_fd, &buffer) orelse {
            shutdownBoth(direction.source_fd, direction.destination_fd);
            return;
        };
        if (count == 0) {
            _ = std.c.shutdown(direction.destination_fd, 1);
            return;
        }
        if (!sendAll(direction.destination_fd, buffer[0..count])) {
            shutdownBoth(direction.source_fd, direction.destination_fd);
            return;
        }
    }
}

fn readRetry(fd: std.posix.socket_t, buffer: []u8) ?usize {
    while (true) {
        const count = std.c.read(fd, buffer.ptr, buffer.len);
        if (count >= 0) return @intCast(count);
        if (std.c.errno(@as(c_int, -1)) != .INTR) return null;
    }
}

fn sendAll(fd: std.posix.socket_t, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.send(
            fd,
            bytes[offset..].ptr,
            bytes.len - offset,
            std.posix.MSG.NOSIGNAL,
        );
        if (count > 0) {
            offset += @intCast(count);
        } else if (count == 0 or std.c.errno(@as(c_int, -1)) != .INTR) {
            return false;
        }
    }
    return true;
}

/// Interrupt both relay directions without closing the caller-owned sockets.
pub fn shutdownBoth(first: std.posix.socket_t, second: std.posix.socket_t) void {
    _ = std.c.shutdown(first, 2);
    _ = std.c.shutdown(second, 2);
}

fn testSocketPair() ![2]std.posix.socket_t {
    var sockets: [2]std.posix.socket_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketFailed;
    }
    errdefer for (sockets) |fd| {
        _ = std.c.close(fd);
    };
    const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
    for (sockets) |fd| {
        if (std.c.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            &timeout,
            @sizeOf(@TypeOf(timeout)),
        ) != 0) return error.SocketFailed;
    }
    return sockets;
}

test "socket relay preserves responses after request half-close" {
    const request = try testSocketPair();
    defer for (request) |fd| {
        _ = std.c.close(fd);
    };
    const response = try testSocketPair();
    defer for (response) |fd| {
        _ = std.c.close(fd);
    };
    const upload = try std.Thread.spawn(.{}, copyDirection, .{Direction{
        .source_fd = request[1],
        .destination_fd = response[1],
    }});
    defer {
        shutdownBoth(request[1], response[1]);
        upload.join();
    }
    const download = try std.Thread.spawn(.{}, copyDirection, .{Direction{
        .source_fd = response[1],
        .destination_fd = request[1],
    }});
    defer {
        shutdownBoth(request[1], response[1]);
        download.join();
    }

    try std.testing.expect(sendAll(request[0], "request"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(request[0], 1));
    var buffer: [32]u8 = undefined;
    try expectStream(response[0], "request", &buffer);
    try std.testing.expectEqual(@as(?usize, 0), readRetry(response[0], &buffer));

    try std.testing.expect(sendAll(response[0], "response after EOF"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(response[0], 1));
    try expectStream(request[0], "response after EOF", &buffer);
    try std.testing.expectEqual(@as(?usize, 0), readRetry(request[0], &buffer));
}

fn expectStream(fd: std.posix.socket_t, expected: []const u8, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < expected.len) {
        const count = readRetry(fd, buffer[0..@min(buffer.len, expected.len - offset)]) orelse
            return error.ReadFailed;
        if (count == 0) return error.EndOfStream;
        try std.testing.expectEqualSlices(u8, expected[offset..][0..count], buffer[0..count]);
        offset += count;
    }
}
