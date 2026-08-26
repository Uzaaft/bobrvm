//! Suspend the shared Docker VM only after Docker confirms that no container
//! is running. The next wrapped Docker command restores the saved state.

const std = @import("std");

const global = @import("../global.zig");
const net_compat = @import("../compat/net.zig");
const linux_vz = @import("../runtime/linux_vz.zig");

const idle_delay_ms: i64 = 30_000;
const response_timeout_ms: i32 = 2_000;
const response_bytes_max: usize = 16 * 1024;

pub const Action = enum {
    none,
    checkpoint,
};

pub const Controller = struct {
    machine: *linux_vz.Machine,
    probe: Probe,
    provision_done: *const std.atomic.Value(bool),
    phase: Phase = .waiting,
    deadline_ms: i64,

    const Phase = enum {
        waiting,
        probing,
    };

    pub fn init(
        machine: *linux_vz.Machine,
        socket_path: []const u8,
        provision_done: *const std.atomic.Value(bool),
    ) Controller {
        return .{
            .machine = machine,
            .probe = .{ .socket_path = socket_path },
            .provision_done = provision_done,
            .deadline_ms = nowMs() + idle_delay_ms,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.probe.deinit();
    }

    pub fn tick(self: *Controller) !Action {
        return switch (self.phase) {
            .waiting => try self.tickWaiting(),
            .probing => self.tickProbing(),
        };
    }

    pub fn retryLater(self: *Controller) void {
        self.reset();
    }

    fn tickWaiting(self: *Controller) !Action {
        if (!self.provision_done.load(.acquire)) {
            self.deadline_ms = nowMs() + idle_delay_ms;
            return .none;
        }
        if (self.machine.dockerConnectionCount() != 0) {
            self.deadline_ms = nowMs() + idle_delay_ms;
            return .none;
        }
        if (nowMs() < self.deadline_ms) return .none;
        try self.probe.start();
        self.phase = .probing;
        return .none;
    }

    fn tickProbing(self: *Controller) Action {
        const result = self.probe.poll() orelse return .none;
        const checkpoint = result == .empty and self.machine.dockerConnectionCount() == 0;
        self.reset();
        return if (checkpoint) .checkpoint else .none;
    }

    fn reset(self: *Controller) void {
        self.phase = .waiting;
        self.deadline_ms = nowMs() + idle_delay_ms;
    }
};

const Probe = struct {
    socket_path: []const u8,
    thread: ?std.Thread = null,
    result: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(Result.pending)),

    const Result = enum(u8) {
        pending,
        empty,
        busy,
        unavailable,
    };

    fn start(self: *Probe) !void {
        std.debug.assert(self.thread == null);
        self.result.store(@intFromEnum(Result.pending), .release);
        self.thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, run, .{self});
    }

    fn poll(self: *Probe) ?Result {
        const result: Result = @enumFromInt(self.result.load(.acquire));
        if (result == .pending) return null;
        self.thread.?.join();
        self.thread = null;
        return result;
    }

    fn deinit(self: *Probe) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn run(self: *Probe) void {
        const result = query(self.socket_path);
        self.result.store(@intFromEnum(result), .release);
    }
};

fn query(path: []const u8) Probe.Result {
    const fd = connectSocket(path) catch return .unavailable;
    defer net_compat.socketClose(fd);
    const request = "GET /containers/json?all=0 HTTP/1.0\r\n" ++
        "Host: docker\r\nConnection: close\r\n\r\n";
    if (!sendAll(fd, request)) return .unavailable;

    var response: [response_bytes_max]u8 = undefined;
    var used: usize = 0;
    while (used < response.len) {
        if (!waitReadable(fd)) return .unavailable;
        const count = std.c.read(fd, response[used..].ptr, response.len - used);
        if (count <= 0) return .unavailable;
        used += @intCast(count);
        if (classifyResponse(response[0..used])) |result| return result;
    }
    return .unavailable;
}

fn connectSocket(path: []const u8) !std.posix.socket_t {
    if (path.len >= @sizeOf(@FieldType(std.posix.sockaddr.un, "path"))) {
        return error.NameTooLong;
    }
    const fd = try net_compat.socketCreate(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer net_compat.socketClose(fd);
    var address: std.posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len = @offsetOf(std.posix.sockaddr.un, "path") + path.len + 1;
    if (@hasField(std.posix.sockaddr.un, "len")) address.len = @intCast(address_len);
    try net_compat.connect(fd, @ptrCast(&address), @intCast(address_len));
    return fd;
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
        if (count <= 0) return false;
        offset += @intCast(count);
    }
    return true;
}

fn waitReadable(fd: std.posix.socket_t) bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return (std.posix.poll(&poll_fds, response_timeout_ms) catch return false) > 0;
}

fn classifyResponse(response: []const u8) ?Probe.Result {
    if (std.mem.indexOf(u8, response, "HTTP/1.1 200") == null and
        std.mem.indexOf(u8, response, "HTTP/1.0 200") == null)
    {
        return null;
    }
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return null;
    const body = std.mem.trimStart(u8, response[header_end + 4 ..], " \t\r\n");
    if (body.len < 2) return null;
    if (std.mem.startsWith(u8, body, "[]")) return .empty;
    if (body[0] == '[') return .busy;
    return .unavailable;
}

fn nowMs() i64 {
    return @intCast(@divTrunc(
        std.Io.Clock.awake.now(global.io()).nanoseconds,
        std.time.ns_per_ms,
    ));
}

test "Docker idle probe classifies empty and active container arrays" {
    try std.testing.expectEqual(
        Probe.Result.empty,
        classifyResponse("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]").?,
    );
    try std.testing.expectEqual(
        Probe.Result.busy,
        classifyResponse("HTTP/1.0 200 OK\r\n\r\n[{\"Id\":\"1\"}]").?,
    );
    try std.testing.expect(classifyResponse("HTTP/1.1 200 OK\r\n\r\n[") == null);
}
