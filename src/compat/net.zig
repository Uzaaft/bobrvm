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
    const rc = socket(@intCast(domain), @intCast(socket_type), @intCast(protocol));
    if (rc == -1) return errnoError();
    return rc;
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
