//! Wait for the host listener and Docker HTTP response using kernel events.
//! The VZ bridge holds early requests until the guest announces its listener.

const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const net = @import("../compat/net.zig");

const request = "GET /_ping HTTP/1.0\r\nHost: docker\r\n\r\n";

pub const Error = error{
    DockerHostStartFailed,
    DockerHostReadyTimeout,
    DockerHostWatchFailed,
    DockerHostNotReady,
    UnsupportedPlatform,
};

/// One deadline covers socket publication, guest startup, and the HTTP reply.
/// Register before checking the socket so an early notification cannot be lost.
pub fn wait(path: []const u8, pid: std.c.pid_t, timeout_ns: u64) Error!void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const deadline = nowNs() + timeout_ns;
    const parent = std.fs.path.dirname(path) orelse return error.DockerHostWatchFailed;
    const directory = std.Io.Dir.openDirAbsolute(global.io(), parent, .{}) catch
        return error.DockerHostWatchFailed;
    defer directory.close(global.io());
    const queue = std.c.kqueue();
    if (queue < 0) return error.DockerHostWatchFailed;
    defer net.socketClose(queue);
    try register(
        queue,
        @intCast(directory.handle),
        std.c.EVFILT.VNODE,
        std.c.NOTE.WRITE | std.c.NOTE.RENAME | std.c.NOTE.DELETE,
    );
    try register(queue, @intCast(pid), std.c.EVFILT.PROC, std.c.NOTE.EXIT);

    const fd = while (true) {
        if (try connectSocket(path)) |fd| break fd;
        try waitEvent(queue, deadline);
    };
    defer net.socketClose(fd);
    try register(queue, @intCast(fd), std.c.EVFILT.WRITE, 0);
    try sendRequest(fd, queue, deadline);
    var removal = event(@intCast(fd), std.c.EVFILT.WRITE, 0);
    removal.flags = std.c.EV.DELETE;
    if (std.c.kevent(queue, @ptrCast(&removal), 1, undefined, 0, null) < 0) {
        return error.DockerHostWatchFailed;
    }
    try register(queue, @intCast(fd), std.c.EVFILT.READ, 0);
    try readResponse(fd, queue, deadline);
}

fn event(ident: usize, filter: i16, fflags: u32) std.c.Kevent {
    return .{
        .ident = ident,
        .filter = filter,
        .flags = std.c.EV.ADD | std.c.EV.CLEAR,
        .fflags = fflags,
        .data = 0,
        .udata = 0,
    };
}

fn register(queue: c_int, ident: usize, filter: i16, fflags: u32) Error!void {
    const change = event(ident, filter, fflags);
    if (std.c.kevent(queue, @ptrCast(&change), 1, undefined, 0, null) < 0) {
        if (std.c.errno(@as(c_int, -1)) == .SRCH) return error.DockerHostStartFailed;
        return error.DockerHostWatchFailed;
    }
}

fn waitEvent(queue: c_int, deadline: u64) Error!void {
    while (true) {
        const remaining = deadline -| nowNs();
        if (remaining == 0) return error.DockerHostReadyTimeout;
        const timeout = std.c.timespec{
            .sec = @intCast(remaining / std.time.ns_per_s),
            .nsec = @intCast(remaining % std.time.ns_per_s),
        };
        var events: [4]std.c.Kevent = undefined;
        const count = std.c.kevent(queue, undefined, 0, &events, events.len, &timeout);
        if (count < 0) {
            if (std.c.errno(@as(c_int, -1)) == .INTR) continue;
            return error.DockerHostWatchFailed;
        }
        if (count == 0) return error.DockerHostReadyTimeout;
        for (events[0..@intCast(count)]) |notification| {
            if (notification.filter == std.c.EVFILT.PROC) return error.DockerHostStartFailed;
            if (notification.flags & std.c.EV.ERROR != 0) return error.DockerHostWatchFailed;
        }
        return;
    }
}

fn connectSocket(path: []const u8) Error!?c_int {
    var address: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    if (path.len >= address.path.len) return error.DockerHostNotReady;
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const length = @offsetOf(std.posix.sockaddr.un, "path") + path.len + 1;
    address.len = @intCast(length);
    const fd = net.socketCreate(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        0,
    ) catch return error.DockerHostNotReady;
    if (std.c.connect(fd, @ptrCast(&address), @intCast(length)) != 0) {
        const failure = std.c.errno(@as(c_int, -1));
        net.socketClose(fd);
        return switch (failure) {
            .NOENT, .CONNREFUSED => null,
            else => error.DockerHostNotReady,
        };
    }
    return fd;
}

fn sendRequest(fd: c_int, queue: c_int, deadline: u64) Error!void {
    var offset: usize = 0;
    while (offset < request.len) {
        if (nowNs() >= deadline) return error.DockerHostReadyTimeout;
        const count = std.c.send(
            fd,
            request[offset..].ptr,
            request.len - offset,
            std.posix.MSG.NOSIGNAL,
        );
        if (count > 0) {
            offset += @intCast(count);
        } else if (count < 0) {
            switch (std.c.errno(@as(c_int, -1))) {
                .INTR => continue,
                .AGAIN => try waitEvent(queue, deadline),
                else => return error.DockerHostNotReady,
            }
        } else return error.DockerHostNotReady;
    }
}

fn readResponse(fd: c_int, queue: c_int, deadline: u64) Error!void {
    var response: [1024]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        if (nowNs() >= deadline) return error.DockerHostReadyTimeout;
        const count = std.c.read(fd, response[used..].ptr, response.len - used);
        if (count > 0) {
            used += @intCast(count);
            if (std.mem.indexOf(u8, response[0..used], "\r\n")) |end| {
                if (!successfulStatus(response[0..end])) return error.DockerHostNotReady;
                return;
            }
        } else if (count < 0) {
            switch (std.c.errno(@as(c_int, -1))) {
                .INTR => continue,
                .AGAIN => try waitEvent(queue, deadline),
                else => return error.DockerHostNotReady,
            }
        } else return error.DockerHostNotReady;
    }
    return error.DockerHostNotReady;
}

fn successfulStatus(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "HTTP/1.0 200 ") or
        std.mem.startsWith(u8, line, "HTTP/1.1 200 ");
}

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

extern "c" fn socketpair(c_int, c_int, c_int, *[2]c_int) c_int;

test "Docker readiness validates the HTTP status line" {
    try std.testing.expect(successfulStatus("HTTP/1.0 200 OK"));
    try std.testing.expect(successfulStatus("HTTP/1.1 200 OK"));
    try std.testing.expect(!successfulStatus("HTTP/1.1 500 200 OK"));
    try std.testing.expect(!successfulStatus("garbage 200 OK"));
}

test "Docker readiness waits for fragmented HTTP status without retrying" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair),
    );
    defer net.socketClose(pair[0]);
    defer net.socketClose(pair[1]);
    const flags: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(pair[0], std.c.F.SETFL, flags) >= 0);
    const queue = std.c.kqueue();
    try std.testing.expect(queue >= 0);
    defer net.socketClose(queue);
    try register(queue, @intCast(pair[0]), std.c.EVFILT.READ, 0);
    // Deliver the reply in separate writes, with the final part gated on
    // receiving the request. The client sends exactly one HTTP request.
    try std.testing.expectEqual(@as(isize, 9), std.c.write(pair[1], "HTTP/1.1 ", 9));
    const worker = try std.Thread.spawn(.{}, struct {
        fn run(fd: c_int) void {
            var received: [request.len]u8 = undefined;
            var used: usize = 0;
            while (used < received.len) {
                const count = std.c.read(fd, received[used..].ptr, received.len - used);
                if (count <= 0) return;
                used += @intCast(count);
            }
            _ = std.c.write(fd, "200 OK\r\n\r\nOK", 12);
        }
    }.run, .{pair[1]});
    defer worker.join();
    try sendRequest(pair[0], queue, nowNs() + std.time.ns_per_s);
    try readResponse(pair[0], queue, nowNs() + std.time.ns_per_s);
}

test "Docker readiness applies deadline to a silent response" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair),
    );
    defer net.socketClose(pair[0]);
    defer net.socketClose(pair[1]);
    const flags: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(pair[0], std.c.F.SETFL, flags) >= 0);
    const queue = std.c.kqueue();
    try std.testing.expect(queue >= 0);
    defer net.socketClose(queue);
    try register(queue, @intCast(pair[0]), std.c.EVFILT.READ, 0);
    try std.testing.expectError(
        error.DockerHostReadyTimeout,
        readResponse(pair[0], queue, nowNs() + std.time.ns_per_ms),
    );
    _ = std.c.shutdown(pair[1], 1);
    try std.testing.expectError(
        error.DockerHostNotReady,
        readResponse(pair[0], queue, nowNs() + std.time.ns_per_s),
    );
}

test "Docker readiness preserves socket publication before waiting" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const queue = std.c.kqueue();
    try std.testing.expect(queue >= 0);
    defer net.socketClose(queue);
    try register(queue, @intCast(temporary.dir.handle), std.c.EVFILT.VNODE, std.c.NOTE.WRITE);
    const file = try temporary.dir.createFile(global.io(), "published", .{});
    file.close(global.io());
    try waitEvent(queue, nowNs() + std.time.ns_per_s);
}

test "Docker readiness observes runner exit" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_state.deinit();
    const io = io_state.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{"/bin/cat"},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        if (child.stdin) |input| input.close(io);
        _ = child.wait(io) catch {};
    }
    const queue = std.c.kqueue();
    try std.testing.expect(queue >= 0);
    defer net.socketClose(queue);
    try register(queue, @intCast(child.id.?), std.c.EVFILT.PROC, std.c.NOTE.EXIT);
    child.stdin.?.close(io);
    child.stdin = null;
    try std.testing.expectError(
        error.DockerHostStartFailed,
        waitEvent(queue, nowNs() + std.time.ns_per_s),
    );
}
