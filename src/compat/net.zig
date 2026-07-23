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
const posix = std.posix;

// std.c doesn't publicly expose these two (they're private helpers in
// libc.zig), even though the extern symbols exist — declare our own.
extern "c" fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

pub const Error = error{ WouldBlock, ConnectionPending, Unexpected };

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
    if (want_nonblock) setNonBlocking(rc);
    return rc;
}

fn setNonBlocking(fd: posix.socket_t) void {
    const cur = std.c.fcntl(fd, std.c.F.GETFL);
    if (cur == -1) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(cur)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags)));
}

pub fn socketClose(fd: posix.socket_t) void {
    _ = close(fd);
}

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
