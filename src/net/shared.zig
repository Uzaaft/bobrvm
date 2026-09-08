//! Unprivileged vmnet client. Packet sockets never block the vCPU thread.
pub const Client = @This();
const std = @import("std");
const protocol = @import("shared_protocol.zig");
const net = @import("../compat/net.zig");
const callback = @import("../callback.zig");

control: c_int,
packets: c_int,
mac: [6]u8,
sink: ReceiveSink,
thread: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(true),
ipv4: std.atomic.Value(u32) = .init(0),

/// Each reservation must be committed once or cancelled once before shutdown.
pub const ReceiveLease = struct { frame: []u8, token: usize };
/// Callbacks run on the receiver thread; reserve returns the requested capacity.
pub const ReceiveSink = struct {
    reserve: callback.Binding1(usize, ?ReceiveLease),
    commit: callback.Binding1(ReceiveLease, void),
    cancel: callback.Binding1(ReceiveLease, void),
};

pub const Error = protocol.Error || std.mem.Allocator.Error || std.Thread.SpawnError;

/// Stable local MAC for CLI project/disk identities. GUI persists random MACs.
pub fn macForIdentity(identity: []const u8) [6]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, std.hash.Wyhash.hash(0x626f6272766d, identity), .big);
    var mac: [6]u8 = bytes[0..6].*;
    mac[0] = (mac[0] & 0xfc) | 2;
    return mac;
}

/// Queries the helper's active session without opening a second interface.
pub fn lookup(mac: [6]u8) protocol.Error!u32 {
    if (@import("builtin").os.tag != .macos) return error.HelperUnavailable;
    const control = net.socketCreate(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch
        return error.HelperUnavailable;
    defer net.socketClose(control);
    try protocol.configure(control);
    var address = protocol.address();
    if (std.c.connect(control, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or
        protocol.peerUid(control) != 0) return error.HelperUnavailable;
    const hello = protocol.Hello{ .mac = mac, .version = "BOBRIP01".* };
    if (std.c.send(control, &hello, @sizeOf(@TypeOf(hello)), 0) != @sizeOf(@TypeOf(hello)))
        return error.ProtocolError;
    var bytes: [4]u8 = undefined;
    try protocol.readExact(control, &bytes);
    return std.mem.readInt(u32, &bytes, .big);
}

/// A failed version exchange is distinct from an absent daemon. In particular,
/// helpers predating the query close the socket without replying.
pub const HelperStatus = enum(c_int) { current = 0, mismatch = 1, unavailable = 2, unverified = 3 };

pub fn helperStatus() HelperStatus {
    const version = queryVersion() catch |err| return switch (err) {
        error.HelperUnavailable => .unavailable,
        else => .unverified,
    };
    return classifyVersion(version);
}

fn classifyVersion(version: [64]u8) HelperStatus {
    for (version) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return .unverified;
    }
    return if (std.mem.eql(u8, &version, &protocol.helper_version)) .current else .mismatch;
}

fn queryVersion() protocol.Error![64]u8 {
    if (@import("builtin").os.tag != .macos) return error.HelperUnavailable;
    const control = net.socketCreate(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch
        return error.HelperUnavailable;
    defer net.socketClose(control);
    try protocol.configure(control);
    var address = protocol.address();
    if (std.c.connect(control, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or
        protocol.peerUid(control) != 0) return error.HelperUnavailable;
    return exchangeVersion(control);
}

fn exchangeVersion(control: c_int) protocol.Error![64]u8 {
    const hello = protocol.Hello{ .mac = @splat(0), .version = protocol.version_query.* };
    if (std.c.send(control, &hello, @sizeOf(@TypeOf(hello)), 0) != @sizeOf(@TypeOf(hello)))
        return error.ProtocolError;
    var version: [64]u8 = undefined;
    try protocol.readExact(control, &version);
    return version;
}

pub const Connection = struct { control: c_int, packets: c_int };

/// Returns two owned descriptors. The caller must retain control until the
/// guest-facing packet attachment has stopped using packets.
pub fn connect(mac: [6]u8) protocol.Error!Connection {
    if (@import("builtin").os.tag != .macos) return error.HelperUnavailable;
    switch (helperStatus()) {
        .current, .unavailable => {},
        .mismatch => std.log.warn(
            "network helper version differs from this build; update networking",
            .{},
        ),
        .unverified => std.log.warn(
            "network helper version could not be verified; update networking",
            .{},
        ),
    }
    const hello = protocol.Hello{ .mac = mac };
    if (!hello.valid()) return error.ProtocolError;
    const control = net.socketCreate(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch
        return error.HelperUnavailable;
    errdefer net.socketClose(control);
    try protocol.configure(control);
    var address = protocol.address();
    if (std.c.connect(control, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or
        protocol.peerUid(control) != 0) return error.HelperUnavailable;
    if (std.c.send(control, &hello, @sizeOf(@TypeOf(hello)), 0) != @sizeOf(@TypeOf(hello)))
        return error.ProtocolError;
    const packets = try protocol.receiveDescriptor(control);
    errdefer net.socketClose(packets);
    return .{ .control = control, .packets = packets };
}

pub fn create(
    alloc: std.mem.Allocator,
    mac: [6]u8,
    sink: ReceiveSink,
) Error!*Client {
    const connection = try connect(mac);
    const control = connection.control;
    const packets = connection.packets;
    errdefer net.socketClose(control);
    errdefer net.socketClose(packets);
    const self = try alloc.create(Client);
    errdefer alloc.destroy(self);
    self.* = .{ .control = control, .packets = packets, .mac = mac, .sink = sink };
    self.thread = try std.Thread.spawn(.{}, receive, .{self});
    return self;
}

pub fn destroy(self: *Client, alloc: std.mem.Allocator) void {
    self.running.store(false, .release);
    _ = std.c.shutdown(self.control, 2);
    if (self.thread) |thread| thread.join();
    net.socketClose(self.packets);
    net.socketClose(self.control);
    alloc.destroy(self);
}

pub fn send(self: *Client, frame: []const u8) void {
    if (!self.running.load(.acquire) or frame.len < 14 or
        frame.len > protocol.frame_bytes_max) return;
    if (sourceAddress(frame, self.mac)) |ip| self.ipv4.store(ip, .release);
    _ = std.c.send(self.packets, frame.ptr, frame.len, std.posix.MSG.DONTWAIT);
}

fn receive(self: *Client) void {
    defer {
        self.running.store(false, .release);
        self.ipv4.store(0, .release);
    }
    while (self.running.load(.acquire)) {
        var fds = [_]std.c.pollfd{
            .{ .fd = self.control, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = self.packets, .events = std.c.POLL.IN, .revents = 0 },
        };
        if (std.c.poll(&fds, fds.len, -1) < 0) {
            if (std.c.errno(@as(c_int, -1)) == .INTR) continue;
            return;
        }
        if (fds[0].revents != 0) return;
        if (fds[1].revents & std.c.POLL.IN == 0) return;
        self.receivePacket();
    }
}

/// Receive directly into producer-owned storage, including one byte for oversize detection.
fn receivePacket(self: *Client) void {
    var lease = self.sink.reserve.call(protocol.frame_bytes_max + 1) orelse {
        var discard: [1]u8 = undefined;
        _ = std.c.recv(self.packets, &discard, discard.len, std.posix.MSG.DONTWAIT);
        return;
    };
    std.debug.assert(lease.frame.len == protocol.frame_bytes_max + 1);
    const count = std.c.recv(self.packets, lease.frame.ptr, lease.frame.len, std.posix.MSG.DONTWAIT);
    if (count < 14 or count > protocol.frame_bytes_max) {
        self.sink.cancel.call(lease);
        return;
    }
    lease.frame = lease.frame[0..@intCast(count)];
    self.sink.commit.call(lease);
}

/// Observe only this NIC's unicast IPv4/ARP source; never trust lengths from a guest.
pub fn sourceAddress(frame: []const u8, mac: [6]u8) ?u32 {
    if (frame.len < 14 or !std.mem.eql(u8, frame[6..12], &mac)) return null;
    const kind = std.mem.readInt(u16, frame[12..14], .big);
    const bytes = switch (kind) {
        0x0800 => blk: {
            if (frame.len < 34 or frame[14] >> 4 != 4 or frame[14] & 15 < 5) return null;
            const header_bytes = @as(usize, frame[14] & 15) * 4;
            const packet_bytes = std.mem.readInt(u16, frame[16..18], .big);
            if (packet_bytes < header_bytes or packet_bytes > frame.len - 14) return null;
            break :blk frame[26..30];
        },
        0x0806 => blk: {
            if (frame.len < 42 or !std.mem.eql(u8, frame[14..20], &.{ 0, 1, 8, 0, 6, 4 }) or
                !std.mem.eql(u8, frame[22..28], &mac)) return null;
            break :blk frame[28..32];
        },
        else => return null,
    };
    if (bytes[0] == 0 or bytes[0] == 127 or bytes[0] >= 224 or
        (bytes[0] == 169 and bytes[1] == 254)) return null;
    return std.mem.readInt(u32, bytes, .big);
}

test "shared address discovery bounds frames and matches the guest MAC" {
    const mac = [6]u8{ 2, 1, 2, 3, 4, 5 };
    var frame = [_]u8{0} ** 42;
    @memcpy(frame[6..12], &mac);
    @memcpy(frame[12..20], &[_]u8{ 8, 6, 0, 1, 8, 0, 6, 4 });
    @memcpy(frame[22..28], &mac);
    @memcpy(frame[28..32], &[_]u8{ 192, 168, 64, 2 });
    try std.testing.expectEqual(@as(?u32, 0xc0a84002), sourceAddress(&frame, mac));
    for (0..42) |length| {
        try std.testing.expectEqual(@as(?u32, null), sourceAddress(frame[0..length], mac));
    }
    frame[6] = 4;
    try std.testing.expectEqual(@as(?u32, null), sourceAddress(&frame, mac));
}

test "shared identities are stable, local, and distinct" {
    const first = macForIdentity("/projects/first");
    try std.testing.expectEqual(first, macForIdentity("/projects/first"));
    try std.testing.expectEqual(@as(u8, 2), first[0] & 3);
    try std.testing.expect(!std.mem.eql(u8, &first, &macForIdentity("/projects/second")));
}

test "shared IPv4 discovery rejects unspecified and truncated datagrams" {
    const mac = [6]u8{ 2, 1, 2, 3, 4, 5 };
    var frame = [_]u8{0} ** 34;
    @memcpy(frame[6..12], &mac);
    frame[12] = 8;
    frame[14] = 0x45;
    std.mem.writeInt(u16, frame[16..18], 20, .big);
    try std.testing.expectEqual(@as(?u32, null), sourceAddress(&frame, mac));
    @memcpy(frame[26..30], &[_]u8{ 192, 168, 64, 2 });
    try std.testing.expectEqual(@as(?u32, 0xc0a84002), sourceAddress(&frame, mac));
    frame[14] = 0x46;
    try std.testing.expectEqual(@as(?u32, null), sourceAddress(&frame, mac));
    frame[14] = 0x45;
    std.mem.writeInt(u16, frame[16..18], 21, .big);
    try std.testing.expectEqual(@as(?u32, null), sourceAddress(&frame, mac));
}

test "shared receive fills RX pool and recycles rejected datagrams without allocations" {
    const Net = @import("../virtio/net.zig").Net;
    const Harness = struct {
        device: *Net,
        published: usize = 0,

        fn reserve(self: *@This(), length: usize) ?ReceiveLease {
            const r = self.device.reserveRxFrame(length) orelse return null;
            return .{ .frame = r.bytes, .token = r.storage_index };
        }
        fn commit(self: *@This(), lease: ReceiveLease) void {
            self.device.commitRxFrame(.{ .bytes = lease.frame, .storage_index = @intCast(lease.token) });
            self.published += 1;
        }
        fn cancel(self: *@This(), lease: ReceiveLease) void {
            self.device.cancelRxFrame(.{ .bytes = lease.frame, .storage_index = @intCast(lease.token) });
        }
    };
    const device = try Net.init(std.testing.allocator);
    defer device.deinit();
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    device.alloc = counted.allocator();
    var harness = Harness{ .device = device };
    var sockets: [2]c_int = undefined;
    try std.testing.expect(std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0, &sockets) == 0);
    defer for (sockets) |fd| net.socketClose(fd);
    var client = Client{
        .control = -1,
        .packets = sockets[0],
        .mac = .{ 2, 0, 0, 0, 0, 1 },
        .sink = .{
            .reserve = callback.Handler1(Harness, usize, ?ReceiveLease, Harness.reserve).bind(&harness),
            .commit = callback.Handler1(Harness, ReceiveLease, void, Harness.commit).bind(&harness),
            .cancel = callback.Handler1(Harness, ReceiveLease, void, Harness.cancel).bind(&harness),
        },
    };
    var frame = [_]u8{0xA5} ** (protocol.frame_bytes_max + 2);
    for ([_]usize{ 0, 13, protocol.frame_bytes_max + 1, frame.len }) |length| {
        const sent = std.c.send(sockets[1], &frame, length, 0);
        try std.testing.expectEqual(@as(isize, @intCast(length)), sent);
        client.receivePacket();
        try std.testing.expectEqual(0, device.rx_reserved_count);
        try std.testing.expectEqual(0, device.rx_count);
    }
    client.receivePacket(); // EAGAIN must also return its reservation.
    try std.testing.expectEqual(0, device.rx_reserved_count);
    for (0..device.rx_frames.len) |_| {
        try std.testing.expectEqual(42, std.c.send(sockets[1], &frame, 42, 0));
        client.receivePacket();
    }
    try std.testing.expectEqual(device.rx_frames.len, harness.published);
    try std.testing.expectEqual(42, std.c.send(sockets[1], &frame, 42, 0));
    client.receivePacket(); // Full pool consumes and drops the datagram.
    try std.testing.expectEqual(device.rx_frames.len, harness.published);
    try std.testing.expect(std.c.recv(sockets[0], &frame, frame.len, std.posix.MSG.DONTWAIT) < 0);
    try std.testing.expectEqual(0, counted.allocations);
    try std.testing.expect(!counted.has_induced_failure);
}

test "helper version distinguishes matching, different and malformed replies" {
    try std.testing.expectEqual(HelperStatus.current, classifyVersion(protocol.helper_version));
    var different = protocol.helper_version;
    different[0] = if (different[0] == '0') '1' else '0';
    try std.testing.expectEqual(HelperStatus.mismatch, classifyVersion(different));
    different[0] = 0;
    try std.testing.expectEqual(HelperStatus.unverified, classifyVersion(different));
}

test "helper version exchange uses a query without creating an interface" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets),
    );
    defer net.socketClose(sockets[0]);
    defer net.socketClose(sockets[1]);
    try protocol.configure(sockets[0]);
    try protocol.configure(sockets[1]);
    try std.testing.expectEqual(@as(isize, 64), std.c.send(sockets[1], &protocol.helper_version, 64, 0));
    try std.testing.expectEqualSlices(u8, &protocol.helper_version, &try exchangeVersion(sockets[0]));
    var hello: protocol.Hello = undefined;
    try protocol.readExact(sockets[1], std.mem.asBytes(&hello));
    try std.testing.expectEqualSlices(u8, protocol.version_query, &hello.version);
    try std.testing.expect(std.mem.allEqual(u8, &hello.mac, 0));
    try std.testing.expect(std.mem.allEqual(u8, &hello.reserved, 0));
}

test "helper version exchange rejects legacy and truncated replies" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    for ([_]usize{ 0, 12 }) |length| {
        var sockets: [2]c_int = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets),
        );
        defer net.socketClose(sockets[0]);
        defer net.socketClose(sockets[1]);
        try protocol.configure(sockets[0]);
        try std.testing.expectEqual(
            @as(isize, @intCast(length)),
            std.c.send(sockets[1], &protocol.helper_version, length, 0),
        );
        try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(sockets[1], std.posix.SHUT.WR));
        try std.testing.expectError(error.ProtocolError, exchangeVersion(sockets[0]));
    }
}
