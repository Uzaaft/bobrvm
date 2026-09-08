//! Local vmnet helper protocol. A control connection owns one interface;
//! closing it releases the interface. Ethernet uses a passed datagram socket.
const std = @import("std");
const net = @import("../compat/net.zig");

pub const socket_path = "/var/run/bobrvm-network/control.sock";
pub const magic = "BOBRNET1";
pub const version_query = "BOBRVER1";
pub const helper_version = @import("../network_helper_version.zig").value;
pub const frame_bytes_max = 1518;
pub const Hello = extern struct {
    version: [8]u8 = magic.*,
    mac: [6]u8,
    reserved: [2]u8 = .{ 0, 0 },

    pub fn valid(self: Hello) bool {
        return std.mem.eql(u8, &self.version, magic) and
            self.mac[0] & 3 == 2 and std.mem.allEqual(u8, &self.reserved, 0);
    }
};
pub const Error = error{ HelperUnavailable, ProtocolError };
extern "c" fn getpeereid(c_int, *u32, *u32) c_int;

pub fn peerUid(fd: c_int) ?u32 {
    var uid: u32 = 0;
    var gid: u32 = 0;
    return if (getpeereid(fd, &uid, &gid) == 0) uid else null;
}

pub fn address() std.posix.sockaddr.un {
    var result = std.mem.zeroes(std.posix.sockaddr.un);
    result.family = std.posix.AF.UNIX;
    result.len = @sizeOf(@TypeOf(result));
    @memcpy(result.path[0..socket_path.len], socket_path);
    return result;
}

pub fn configure(fd: c_int) Error!void {
    const yes: c_int = 1;
    const timeout = std.posix.timeval{ .sec = 10, .usec = 0 };
    if (std.c.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.NOSIGPIPE,
        &yes,
        @sizeOf(c_int),
    ) != 0 or std.c.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        &timeout,
        @sizeOf(@TypeOf(timeout)),
    ) != 0 or std.c.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        &timeout,
        @sizeOf(@TypeOf(timeout)),
    ) != 0 or
        std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0)
        return error.ProtocolError;
}

pub fn readExact(fd: c_int, bytes: []u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and std.c.errno(@as(c_int, -1)) == .INTR) continue;
        if (count <= 0) return error.ProtocolError;
        offset += @intCast(count);
    }
}

// Darwin CMSG alignment is four bytes, including on arm64. Exactly one fd.
const Rights = extern struct {
    len: u32 = @sizeOf(Rights),
    level: c_int = std.posix.SOL.SOCKET,
    kind: c_int = 1, // SCM_RIGHTS
    fd: c_int,
};

pub fn sendDescriptor(control: c_int, fd: c_int) Error!void {
    const rights = Rights{ .fd = fd };
    const ack = [_]u8{1};
    const iov = [_]std.posix.iovec_const{.{ .base = &ack, .len = 1 }};
    const message = std.c.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &rights,
        .controllen = @sizeOf(Rights),
        .flags = 0,
    };
    if (std.c.sendmsg(control, &message, 0) != 1) return error.ProtocolError;
}

pub fn receiveDescriptor(control: c_int) Error!c_int {
    var rights = std.mem.zeroes(Rights);
    var ack: [1]u8 = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &ack, .len = 1 }};
    var message = std.c.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &rights,
        .controllen = @sizeOf(Rights),
        .flags = 0,
    };
    const count = std.c.recvmsg(control, &message, 0);
    if (count != 1 or message.controllen != @sizeOf(Rights) or
        rights.len != @sizeOf(Rights) or rights.level != std.posix.SOL.SOCKET or
        rights.kind != 1) return error.ProtocolError;
    errdefer net.socketClose(rights.fd);
    if (ack[0] != 1 or message.flags != 0) return error.ProtocolError;
    try configure(rights.fd);
    return rights.fd;
}

test "shared helper rejects incompatible or invalid requests" {
    var hello = Hello{ .mac = .{ 2, 1, 2, 3, 4, 5 } };
    try std.testing.expect(hello.valid());
    hello.mac[0] = 3;
    try std.testing.expect(!hello.valid());
    hello.mac[0] = 2;
    hello.version[7] = '2';
    try std.testing.expect(!hello.valid());
}

test "shared helper transfers a private datagram socket" {
    if (@import("builtin").os.tag != .macos) return;
    var control: [2]c_int = undefined;
    var packets: [2]c_int = undefined;
    try std.testing.expect(std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &control) == 0);
    defer for (control) |fd| net.socketClose(fd);
    try std.testing.expect(std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0, &packets) == 0);
    defer for (packets) |fd| net.socketClose(fd);
    try sendDescriptor(control[0], packets[0]);
    const received = try receiveDescriptor(control[1]);
    defer net.socketClose(received);
    try std.testing.expectEqual(@as(isize, 3), std.c.send(packets[1], "abc", 3, 0));
    var bytes: [8]u8 = undefined;
    const count = std.c.recv(received, &bytes, bytes.len, 0);
    try std.testing.expectEqual(@as(isize, 3), count);
    try std.testing.expectEqualStrings("abc", bytes[0..3]);
}
