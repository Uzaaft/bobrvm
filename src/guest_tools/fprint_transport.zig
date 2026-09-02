//! Blocking transport behind the libfprint ABI adapter.

const Self = @This();
const std = @import("std");
const builtin = @import("builtin");

const username_bytes_max = 64;
const unix_path_bytes_max = 108;
const timeout_ms = 60_000;
const state_idle: c_int = -1;
const state_starting: c_int = -2;
const state_cancelled: c_int = -3;

active_fd: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(state_idle),

const Operation = enum(u8) {
    enroll = 1,
    verify = 2,
};

const Result = enum(c_int) {
    success = 1,
    no_match = 2,
    cancelled = 3,
    unavailable = 4,
    locked = 5,
    failed = 6,
    invalid_argument = -1,
    busy = -2,
    socket_failed = -3,
    connect_failed = -4,
    write_failed = -5,
    timed_out = -6,
    connection_closed = -7,
    invalid_response = -8,
};

pub export fn bobrvm_fprint_transport_create() ?*Self {
    const self = std.heap.c_allocator.create(Self) catch return null;
    self.* = .{};
    return self;
}

pub export fn bobrvm_fprint_transport_destroy(self: ?*Self) void {
    const transport = self orelse return;
    transport.cancel();
    std.heap.c_allocator.destroy(transport);
}

pub export fn bobrvm_fprint_transport_request(
    self: *Self,
    operation_raw: u8,
    username_pointer: [*]const u8,
    username_length: usize,
    socket_path_pointer: [*:0]const u8,
) Result {
    if (comptime builtin.os.tag != .linux) return .unavailable;
    const operation = operationFromByte(operation_raw) orelse return .invalid_argument;
    const username = username_pointer[0..username_length];
    const socket_path = std.mem.span(socket_path_pointer);
    if (!validRequest(username, socket_path)) return .invalid_argument;
    if (self.begin()) |result| return result;

    const fd = std.c.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    if (fd < 0) {
        self.finish(state_starting);
        return .socket_failed;
    }
    defer _ = std.c.close(fd);

    if (self.active_fd.cmpxchgStrong(
        state_starting,
        fd,
        .acq_rel,
        .acquire,
    )) |state| {
        std.debug.assert(state == state_cancelled);
        self.active_fd.store(state_idle, .release);
        return .cancelled;
    }
    defer self.finish(fd);

    if (!connectSocket(fd, socket_path)) return self.failure(.connect_failed);
    var payload: [2 + username_bytes_max]u8 = undefined;
    payload[0] = @intFromEnum(operation);
    payload[1] = @intCast(username.len);
    @memcpy(payload[2..][0..username.len], username);
    writeAll(fd, payload[0 .. 2 + username.len]) catch return self.failure(.write_failed);
    return self.readResult(fd);
}

fn begin(self: *Self) ?Result {
    if (self.active_fd.cmpxchgStrong(
        state_idle,
        state_starting,
        .acq_rel,
        .acquire,
    )) |state| {
        if (state != state_cancelled) return .busy;
        self.active_fd.store(state_idle, .release);
        return .cancelled;
    }
    return null;
}

pub export fn bobrvm_fprint_transport_cancel(self: *Self) void {
    self.cancel();
}

fn cancel(self: *Self) void {
    while (true) {
        const state = self.active_fd.load(.acquire);
        if (state == state_cancelled) return;
        if (self.active_fd.cmpxchgWeak(
            state,
            state_cancelled,
            .acq_rel,
            .acquire,
        ) != null) continue;
        if (state >= 0) _ = std.c.shutdown(state, std.posix.SHUT.RDWR);
        return;
    }
}

fn finish(self: *Self, expected: c_int) void {
    _ = self.active_fd.cmpxchgStrong(expected, state_idle, .release, .acquire);
    if (self.active_fd.load(.acquire) == state_cancelled) {
        self.active_fd.store(state_idle, .release);
    }
}

fn failure(self: *Self, result: Result) Result {
    return if (self.active_fd.load(.acquire) == state_cancelled) .cancelled else result;
}

fn readResult(self: *Self, fd: c_int) Result {
    var descriptor = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&descriptor, timeout_ms) catch {
        return self.failure(.connection_closed);
    };
    if (ready == 0) return self.failure(.timed_out);
    if (descriptor[0].revents & std.posix.POLL.IN == 0) {
        return self.failure(.connection_closed);
    }
    var response: [1]u8 = undefined;
    const length = std.posix.read(fd, &response) catch {
        return self.failure(.connection_closed);
    };
    if (length != response.len) return self.failure(.connection_closed);
    return resultFromByte(response[0]) orelse .invalid_response;
}

fn connectSocket(fd: c_int, path: []const u8) bool {
    var address: std.posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len = @offsetOf(std.posix.sockaddr.un, "path") + path.len + 1;
    if (@hasField(std.posix.sockaddr.un, "len")) address.len = @intCast(address_len);
    return std.c.connect(fd, @ptrCast(&address), @intCast(address_len)) == 0;
}

fn writeAll(fd: c_int, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const written = std.c.write(fd, data[offset..].ptr, data.len - offset);
        if (written < 0) {
            if (std.c.errno(written) == .INTR) continue;
            return error.WriteFailed;
        }
        if (written == 0) return error.ConnectionClosed;
        offset += @intCast(written);
    }
}

fn validRequest(username: []const u8, socket_path: []const u8) bool {
    if (username.len == 0 or username.len > username_bytes_max) return false;
    if (!std.unicode.utf8ValidateSlice(username)) return false;
    return socket_path.len > 0 and socket_path.len < unix_path_bytes_max;
}

fn operationFromByte(value: u8) ?Operation {
    return switch (value) {
        @intFromEnum(Operation.enroll) => .enroll,
        @intFromEnum(Operation.verify) => .verify,
        else => null,
    };
}

fn resultFromByte(value: u8) ?Result {
    return switch (value) {
        @intFromEnum(Result.success) => .success,
        @intFromEnum(Result.no_match) => .no_match,
        @intFromEnum(Result.cancelled) => .cancelled,
        @intFromEnum(Result.unavailable) => .unavailable,
        @intFromEnum(Result.locked) => .locked,
        @intFromEnum(Result.failed) => .failed,
        else => null,
    };
}

test "request validation bounds usernames and Unix socket paths" {
    const testing = std.testing;
    try testing.expect(validRequest("alice", "/run/bobrvm/touch-id.sock"));
    try testing.expect(!validRequest("", "/run/bobrvm/touch-id.sock"));
    try testing.expect(!validRequest(&([_]u8{'a'} ** 65), "/run/bobrvm/touch-id.sock"));
    try testing.expect(!validRequest("\xff", "/run/bobrvm/touch-id.sock"));
    try testing.expect(!validRequest("alice", ""));
}

test "wire values reject unknown operations and results" {
    const testing = std.testing;
    try testing.expectEqual(Operation.verify, operationFromByte(2).?);
    try testing.expect(operationFromByte(0) == null);
    try testing.expectEqual(Result.locked, resultFromByte(5).?);
    try testing.expect(resultFromByte(0) == null);
}

test "cancellation during socket setup returns transport to idle" {
    const testing = std.testing;
    var transport = Self{};
    transport.active_fd.store(state_starting, .release);

    transport.cancel();
    try testing.expectEqual(state_cancelled, transport.active_fd.load(.acquire));
    transport.finish(state_starting);
    try testing.expectEqual(state_idle, transport.active_fd.load(.acquire));
}

test "cancellation before socket setup is retained for the worker" {
    const testing = std.testing;
    var transport = Self{};

    transport.cancel();
    try testing.expectEqual(state_cancelled, transport.active_fd.load(.acquire));
    try testing.expectEqual(Result.cancelled, transport.begin().?);
    try testing.expectEqual(state_idle, transport.active_fd.load(.acquire));
}
