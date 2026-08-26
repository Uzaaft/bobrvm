//! Connect Virtualization.framework's virtio-net device to MiniNat.
//!
//! VZ owns one end of a datagram socket pair and sends complete Ethernet
//! frames through it. MiniNat owns the other end, preserving bobrvm's
//! unprivileged outbound networking, TCP forwards, and private Docker Unix
//! socket while Apple owns the guest-facing virtio device.

pub const Bridge = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const callback_binding = @import("../callback.zig");
const mininat = @import("../net/mininat.zig");
const net_compat = @import("../compat/net.zig");
const vz_process_policy = @import("vz_process_policy.zig");

const log = std.log.scoped(.vz_net);

alloc: Allocator,
vz_fd: std.posix.socket_t,
nat_fd: std.posix.socket_t,
nat: mininat.MiniNat,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

pub const Config = struct {
    forwards: []const mininat.Forward = &.{},
    docker_socket_path: ?[]const u8 = null,
    performance_policy: ?*vz_process_policy.Controller = null,
};

const socket_send_bytes: c_int = 4 * 1024 * 1024;
const socket_receive_bytes: c_int = 16 * 1024 * 1024;

pub fn create(alloc: Allocator, config: Config) !*Bridge {
    const self = try alloc.create(Bridge);
    errdefer alloc.destroy(self);

    var sockets: [2]std.posix.socket_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    errdefer {
        net_compat.socketClose(sockets[0]);
        net_compat.socketClose(sockets[1]);
    }
    try configureSocket(sockets[0]);
    try configureSocket(sockets[1]);

    self.* = .{
        .alloc = alloc,
        .vz_fd = sockets[0],
        .nat_fd = sockets[1],
        .nat = undefined,
    };
    self.nat = mininat.MiniNat.init(
        alloc,
        callback_binding.Handler1(Bridge, []const u8, void, reply).bind(self),
    );
    self.nat.setIngressSocket(self.nat_fd);
    if (config.performance_policy) |policy| {
        self.nat.setInboundActivity(callback_binding.Handler0(
            vz_process_policy.Controller,
            void,
            vz_process_policy.Controller.activity,
        ).bind(policy));
    }
    for (config.forwards) |forward| try self.nat.addForward(forward);
    if (config.docker_socket_path) |path| try self.nat.addUnixForward(path, 2375);
    self.running.store(true, .release);
    errdefer self.running.store(false, .release);
    try self.nat.start();
    errdefer self.nat.stop();
    return self;
}

pub fn destroy(self: *Bridge) void {
    self.nat.stop();
    self.running.store(false, .release);
    net_compat.socketClose(self.nat_fd);
    net_compat.socketClose(self.vz_fd);
    const alloc = self.alloc;
    self.* = undefined;
    alloc.destroy(self);
}

fn configureSocket(socket: std.posix.socket_t) !void {
    if (std.c.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        &socket_send_bytes,
        @sizeOf(c_int),
    ) != 0) return error.SocketSetupFailed;
    if (std.c.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        &socket_receive_bytes,
        @sizeOf(c_int),
    ) != 0) return error.SocketSetupFailed;
}

fn reply(self: *Bridge, frame: []const u8) void {
    if (!self.running.load(.acquire)) return;
    const sent = std.c.send(self.nat_fd, frame.ptr, frame.len, 0);
    if (sent < 0 or sent != frame.len) {
        log.warn("dropping VZ network reply ({} bytes)", .{frame.len});
    }
}

test "VZ MiniNat bridge starts and stops" {
    if (@import("builtin").os.tag != .macos) return;
    const bridge = try Bridge.create(std.testing.allocator, .{});
    bridge.destroy();
}
