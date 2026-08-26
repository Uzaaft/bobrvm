//! Minimal POSIX socket syscall wrappers.
//!
//! zig 0.16 removed std.posix.socket/close/sendto/recvfrom/recv/connect/
//! shutdown/getsockoptError entirely — that surface moved into the new
//! std.Io.net abstraction, which is a much bigger redesign than our
//! hand-rolled nonblocking-socket NAT/TCP-proxy (src/net/mininat.zig)
//! needs. These are thin direct-libc wrappers (macOS/POSIX only, no
//! Windows branch) reproducing just the old semantics our call sites
//! depend on: WouldBlock detection for nonblocking sockets, and
//! EINPROGRESS/EALREADY handling for nonblocking connect.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const unix_path_bytes_max = @sizeOf(@FieldType(posix.sockaddr.un, "path"));

// std.c doesn't publicly expose these two (they're private helpers in
// libc.zig), even though the extern symbols exist — declare our own.
extern "c" fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

pub const Error = error{ WouldBlock, ConnectionPending, Unexpected };
pub const UnixSocketPathError = error{ AddressInUse, NameTooLong, Unexpected };

fn errnoError() Error {
    return switch (std.c.errno(@as(c_int, -1))) {
        .AGAIN, .INPROGRESS => error.WouldBlock,
        .ALREADY => error.ConnectionPending,
        else => error.Unexpected,
    };
}

pub fn socketCreate(domain: u32, socket_type: u32, protocol: u32) Error!posix.socket_t {
    // SOCK_NONBLOCK/SOCK_CLOEXEC baked into the type argument is a Linux-only
    // extension — Darwin's socket() doesn't understand it (silently creates
    // a normal *blocking* socket instead of erroring), so every socket we
    // made ended up blocking despite callers asking for nonblocking. That
    // turned a stalled connect()/recv() to an unresponsive host into a hang
    // of the entire machine-lock-guarded vCPU loop. Strip the bits and apply
    // O_NONBLOCK via fcntl afterward instead, matching what zig 0.15's
    // std.posix.socket() used to do for us on Darwin.
    const want_nonblock = (socket_type & posix.SOCK.NONBLOCK) != 0;
    const filtered_type = socket_type & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);

    const rc = socket(@intCast(domain), @intCast(filtered_type), @intCast(protocol));
    if (rc == -1) return errnoError();
    if (want_nonblock and !setNonBlocking(rc)) {
        _ = close(rc);
        return error.Unexpected;
    }
    return rc;
}

fn setNonBlocking(fd: posix.fd_t) bool {
    const cur = std.c.fcntl(fd, std.c.F.GETFL);
    if (cur == -1) return false;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(cur)));
    flags.NONBLOCK = true;
    return std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags))) != -1;
}

fn setCloseOnExec(fd: posix.fd_t) bool {
    const flags = std.c.fcntl(fd, std.c.F.GETFD);
    if (flags == -1) return false;
    return std.c.fcntl(fd, std.c.F.SETFD, flags | std.c.FD_CLOEXEC) != -1;
}

pub fn socketClose(fd: posix.socket_t) void {
    _ = close(fd);
}

/// Remove an abandoned Unix socket without clobbering a live listener or an
/// unrelated filesystem entry at the same path.
pub fn removeStaleUnixSocket(path: []const u8) UnixSocketPathError!void {
    if (path.len == 0 or path.len >= unix_path_bytes_max) return error.NameTooLong;
    const probe = socketCreate(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
        0,
    ) catch return error.Unexpected;
    defer socketClose(probe);

    var address: posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    address.family = posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len = @offsetOf(posix.sockaddr.un, "path") + path.len + 1;
    if (@hasField(posix.sockaddr.un, "len")) address.len = @intCast(address_len);
    if (std.c.connect(probe, @ptrCast(&address), @intCast(address_len)) == 0) {
        return error.AddressInUse;
    }

    switch (std.c.errno(@as(c_int, -1))) {
        .NOENT => {},
        .CONNREFUSED => {
            if (std.c.unlink(@ptrCast(&address.path)) != 0 and
                std.c.errno(@as(c_int, -1)) != .NOENT)
            {
                return error.Unexpected;
            }
        },
        else => return error.AddressInUse,
    }
}

/// Non-blocking self-pipe used to wake a thread blocked in poll/select. Signals
/// coalesce when the pipe is full; one readable byte is enough to rebuild the
/// caller's poll set from authoritative state.
pub const WakePipe = struct {
    read_fd: posix.fd_t = -1,
    write_fd: posix.fd_t = -1,

    pub fn init() error{Unexpected}!WakePipe {
        var fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.Unexpected;
        errdefer {
            _ = close(fds[0]);
            _ = close(fds[1]);
        }
        if (!setNonBlocking(fds[0]) or
            !setNonBlocking(fds[1]) or
            !setCloseOnExec(fds[0]) or
            !setCloseOnExec(fds[1]) or
            fds[0] >= fd_set_size)
        {
            return error.Unexpected;
        }
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: *WakePipe) void {
        if (self.read_fd >= 0) _ = close(self.read_fd);
        if (self.write_fd >= 0) _ = close(self.write_fd);
        self.* = .{};
    }

    pub fn signal(self: WakePipe) void {
        if (self.write_fd < 0) return;
        const bytes = [_]u8{1};
        _ = std.c.write(self.write_fd, bytes[0..].ptr, bytes.len);
    }

    pub fn drain(self: WakePipe) void {
        if (self.read_fd < 0) return;
        var bytes: [64]u8 = undefined;
        while (std.c.read(self.read_fd, &bytes, bytes.len) > 0) {}
    }

    /// Wait for a signal or a nanosecond-resolution timeout. A null timeout
    /// blocks indefinitely. Pipe readability preserves wakeups that arrive
    /// immediately before the wait begins.
    pub fn wait(self: WakePipe, timeout_ns: ?u64) Error!void {
        if (self.read_fd < 0) return error.Unexpected;
        var read_fds = FdSet{};
        read_fds.set(self.read_fd);
        var timeout: std.c.timespec = undefined;
        const timeout_ptr = if (timeout_ns) |ns| blk: {
            timeout = .{
                .sec = @intCast(ns / std.time.ns_per_s),
                .nsec = @intCast(ns % std.time.ns_per_s),
            };
            break :blk &timeout;
        } else null;
        const result = pselect(self.read_fd + 1, &read_fds, null, null, timeout_ptr, null);
        if (result < 0 and std.c.errno(@as(c_int, -1)) != .INTR) {
            return error.Unexpected;
        }
        if (result > 0) self.drain();
    }
};

const fd_set_size: posix.fd_t = 1024;
const FdMask = if (builtin.os.tag == .macos) i32 else c_long;
const fd_mask_bits = @bitSizeOf(FdMask);
const FdMaskUnsigned = std.meta.Int(.unsigned, fd_mask_bits);

const FdSet = extern struct {
    bits: [fd_set_size / fd_mask_bits]FdMask = @splat(0),

    fn set(self: *FdSet, fd: posix.fd_t) void {
        const index: usize = @intCast(@divTrunc(fd, fd_mask_bits));
        const shift: std.math.Log2Int(FdMaskUnsigned) = @intCast(@mod(fd, fd_mask_bits));
        const mask: FdMaskUnsigned = @as(FdMaskUnsigned, 1) << shift;
        self.bits[index] = @bitCast(mask);
    }
};

extern "c" fn pselect(
    nfds: c_int,
    read_fds: ?*FdSet,
    write_fds: ?*FdSet,
    except_fds: ?*FdSet,
    timeout: ?*const std.c.timespec,
    signal_mask: ?*const anyopaque,
) c_int;

pub fn sendto(
    sockfd: posix.socket_t,
    buf: []const u8,
    flags: u32,
    dest_addr: ?*const posix.sockaddr,
    addrlen: posix.socklen_t,
) Error!usize {
    const rc = std.c.sendto(sockfd, buf.ptr, buf.len, flags, dest_addr, addrlen);
    if (rc == -1) return errnoError();
    return @intCast(rc);
}

pub fn recvfrom(
    sockfd: posix.socket_t,
    buf: []u8,
    flags: u32,
    src_addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
) Error!usize {
    const rc = std.c.recvfrom(sockfd, buf.ptr, buf.len, flags, src_addr, addrlen);
    if (rc == -1) return errnoError();
    return @intCast(rc);
}

pub fn recv(sockfd: posix.socket_t, buf: []u8, flags: u32) Error!usize {
    const rc = std.c.recv(sockfd, buf.ptr, buf.len, @intCast(flags));
    if (rc == -1) return errnoError();
    return @intCast(rc);
}

pub fn connect(sockfd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) Error!void {
    const rc = std.c.connect(sockfd, addr, len);
    if (rc == -1) return errnoError();
}

pub fn bind(sockfd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) Error!void {
    if (std.c.bind(sockfd, addr, len) != 0) return errnoError();
}

pub fn listen(sockfd: posix.socket_t, backlog: c_uint) Error!void {
    if (std.c.listen(sockfd, backlog) != 0) return errnoError();
}

/// Accept one pending connection; the returned fd is made non-blocking
/// (Darwin does not inherit O_NONBLOCK from the listener).
pub fn accept(sockfd: posix.socket_t) Error!posix.socket_t {
    const rc = std.c.accept(sockfd, null, null);
    if (rc == -1) return errnoError();
    if (!setNonBlocking(rc)) {
        _ = close(rc);
        return error.Unexpected;
    }
    return rc;
}

pub fn setReuseAddr(sockfd: posix.socket_t) void {
    const one: c_int = 1;
    _ = std.c.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one, @sizeOf(c_int));
}

/// Arm kernel TCP keepalive probes. Used on sockets whose flows are
/// exempt from application-level idle reaping, so a peer that vanished
/// without a FIN/RST still surfaces as a socket error eventually
/// (default kernel probe timing applies).
pub fn setKeepAlive(sockfd: posix.socket_t) void {
    const one: c_int = 1;
    _ = std.c.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &one, @sizeOf(c_int));
}

pub const ShutdownHow = enum { recv, send, both };

pub fn shutdown(sockfd: posix.socket_t, how: ShutdownHow) Error!void {
    const c_how: c_int = switch (how) {
        .recv => 0, // SHUT_RD
        .send => 1, // SHUT_WR
        .both => 2, // SHUT_RDWR
    };
    const rc = std.c.shutdown(sockfd, c_how);
    if (rc == -1) return errnoError();
}

pub fn getsockoptError(sockfd: posix.socket_t) Error!void {
    var err_code: i32 = undefined;
    var size: posix.socklen_t = @sizeOf(i32);
    const rc = std.c.getsockopt(sockfd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err_code), &size);
    if (rc == -1) return errnoError();
    if (err_code != 0) return error.Unexpected;
}

const testing = std.testing;

test "socketCreate with SOCK.NONBLOCK actually produces a non-blocking fd" {
    // Regression test: Darwin's socket() silently ignores SOCK_NONBLOCK
    // baked into the type argument (a Linux-only trick) instead of
    // erroring, so it's easy to end up with an accidentally-blocking
    // socket that then hangs connect()/recv() forever under the
    // machine-lock-guarded vCPU loop.
    const sock = try socketCreate(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK, 0);
    defer socketClose(sock);

    const flags = std.c.fcntl(sock, std.c.F.GETFL);
    try testing.expect(flags != -1);
    const o: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    try testing.expect(o.NONBLOCK);
}

test "socketCreate without SOCK.NONBLOCK leaves a blocking fd" {
    const sock = try socketCreate(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer socketClose(sock);

    const flags = std.c.fcntl(sock, std.c.F.GETFL);
    try testing.expect(flags != -1);
    const o: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    try testing.expect(!o.NONBLOCK);
}

test "WakePipe interrupts poll and drains coalesced signals" {
    var wake = try WakePipe.init();
    defer wake.deinit();

    wake.signal();
    wake.signal();
    var poll_fds = [_]posix.pollfd{.{
        .fd = wake.read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try testing.expectEqual(@as(usize, 1), try posix.poll(&poll_fds, 0));
    wake.drain();
    poll_fds[0].revents = 0;
    try testing.expectEqual(@as(usize, 0), try posix.poll(&poll_fds, 0));
}

test "WakePipe preserves a signal sent before an indefinite wait" {
    var wake = try WakePipe.init();
    defer wake.deinit();

    wake.signal();
    try wake.wait(null);
    var poll_fds = [_]posix.pollfd{.{
        .fd = wake.read_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try testing.expectEqual(@as(usize, 0), try posix.poll(&poll_fds, 0));
}
