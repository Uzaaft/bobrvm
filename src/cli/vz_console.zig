//! Bidirectional project console for the Virtualization.framework engine.
//!
//! VZ consumes file descriptors rather than callbacks. A stream socket pair preserves an
//! interactive stdout/stdin console while teeing guest output into the shared
//! marker-based provisioning session.

pub const Console = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const console_exec = @import("console_exec.zig");

alloc: Allocator,
guest_fd: std.posix.fd_t,
host_fd: std.posix.fd_t,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
capture: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
output_thread: ?std.Thread = null,
session: console_exec.Session,

const output_stack_bytes: usize = 1024 * 1024;

pub fn create(alloc: Allocator) !*Console {
    const self = try alloc.create(Console);
    errdefer alloc.destroy(self);

    var sockets: [2]std.posix.socket_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    errdefer closePair(sockets);

    self.* = .{
        .alloc = alloc,
        .guest_fd = sockets[0],
        .host_fd = sockets[1],
        .session = undefined,
    };
    self.session = console_exec.Session.initTransport(alloc, .{
        .context = self,
        .write = writeTransport,
        .wait_ready = waitReady,
    });
    self.running.store(true, .release);
    errdefer self.running.store(false, .release);
    self.output_thread = try std.Thread.spawn(
        .{ .stack_size = output_stack_bytes },
        outputLoop,
        .{self},
    );
    return self;
}

pub fn destroy(self: *Console) void {
    self.cancelIO();
    closeFd(self.host_fd);
    closeFd(self.guest_fd);
    self.session.deinit();
    const alloc = self.alloc;
    self.* = undefined;
    alloc.destroy(self);
}

pub fn cancelIO(self: *Console) void {
    self.session.cancel();
    self.running.store(false, .release);
    _ = std.c.shutdown(self.host_fd, std.posix.SHUT.RDWR);
    if (self.output_thread) |thread| {
        thread.join();
        self.output_thread = null;
    }
}

pub fn markReady(self: *Console) void {
    self.ready.store(true, .release);
}

pub fn setCapture(self: *Console, enabled: bool) void {
    self.capture.store(enabled, .release);
}

/// Forward currently available stdin bytes without blocking VZ's main loop.
pub fn pumpInput(self: *Console) void {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const available = std.posix.poll(&poll_fds, 0) catch return;
    if (available == 0 or poll_fds[0].revents & std.posix.POLL.IN == 0) return;
    var bytes: [4096]u8 = undefined;
    const count = std.posix.read(std.posix.STDIN_FILENO, &bytes) catch return;
    if (count > 0) writeAll(self.host_fd, bytes[0..count]);
}

fn outputLoop(self: *Console) void {
    var bytes: [4096]u8 = undefined;
    var cursor_query_match: usize = 0;
    while (self.running.load(.acquire)) {
        const count = std.posix.read(self.host_fd, &bytes) catch return;
        if (count == 0) return;
        const output = bytes[0..count];
        writeAll(std.posix.STDOUT_FILENO, output);
        for (output) |byte| {
            if (cursorQueryComplete(&cursor_query_match, byte)) {
                writeAll(self.host_fd, "\x1b[1;1R");
            }
        }
        if (self.capture.load(.acquire)) console_exec.Session.sink(output, &self.session);
    }
}

fn cursorQueryComplete(matched: *usize, byte: u8) bool {
    const query = "\x1b[6n";
    if (byte == query[matched.*]) {
        matched.* += 1;
        if (matched.* == query.len) {
            matched.* = 0;
            return true;
        }
    } else {
        matched.* = @intFromBool(byte == query[0]);
    }
    return false;
}

fn writeTransport(context: *anyopaque, data: []const u8) void {
    const self: *Console = @ptrCast(@alignCast(context));
    writeAll(self.host_fd, data);
}

fn waitReady(context: *anyopaque, timeout_ns: u64) bool {
    _ = timeout_ns;
    const self: *Console = @ptrCast(@alignCast(context));
    return self.ready.load(.acquire);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const count = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (count <= 0) return;
        written += @intCast(count);
    }
}

fn closePair(fds: [2]std.posix.fd_t) void {
    closeFd(fds[0]);
    closeFd(fds[1]);
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

test "VZ console pipes start and stop" {
    if (@import("builtin").os.tag != .macos) return;
    const console = try Console.create(std.testing.allocator);
    console.destroy();
}

test "VZ console recognizes a split cursor-position query" {
    var matched: usize = 0;
    for ("noise\x1b[") |byte| try std.testing.expect(!cursorQueryComplete(&matched, byte));
    try std.testing.expect(!cursorQueryComplete(&matched, '6'));
    try std.testing.expect(cursorQueryComplete(&matched, 'n'));
    try std.testing.expectEqual(@as(usize, 0), matched);
}
