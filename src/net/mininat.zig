//! Built-in NAT responder (slirp-style addressing, no root required).
//!
//! Answers the guest's ARP, DHCP, and ICMP-echo traffic so `ip addr`
//! shows a lease and `ping 10.0.2.2` works out of the box. TCP/UDP
//! forwarding and the vmnet.framework backend come later.
//!
//!   guest:   10.0.2.15
//!   gateway: 10.0.2.2 (this responder)
//!
//! UDP datagrams to external addresses are forwarded through host
//! sockets (so DNS to real resolvers works); TCP forwarding is next.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.mininat);

pub const GUEST_IP = [4]u8{ 10, 0, 2, 15 };
pub const GATEWAY_IP = [4]u8{ 10, 0, 2, 2 };
pub const DNS_IP = [4]u8{ 1, 1, 1, 1 };
pub const NETMASK = [4]u8{ 255, 255, 255, 0 };
pub const GATEWAY_MAC = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 };

const ETH_HDR = 14;
const ETHERTYPE_IP: u16 = 0x0800;
const ETHERTYPE_ARP: u16 = 0x0806;

/// Reply sink: frames the responder wants delivered to the guest.
pub const ReplyFn = *const fn (frame: []const u8, userdata: ?*anyopaque) void;

const UdpKey = struct {
    guest_port: u16,
    remote_ip: [4]u8,
    remote_port: u16,
};

const UdpFlow = struct {
    socket: std.posix.socket_t,
    last_used: i64,
};

pub const MiniNat = struct {
    reply: ReplyFn,
    reply_userdata: ?*anyopaque,

    alloc: std.mem.Allocator,
    udp_flows: std.AutoHashMap(UdpKey, UdpFlow),
    flows_mutex: std.Thread.Mutex = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_thread: ?std.Thread = null,

    pub const UDP_FLOW_MAX: usize = 256;
    pub const UDP_IDLE_TIMEOUT_S: i64 = 60;

    pub fn init(alloc: std.mem.Allocator, reply: ReplyFn, userdata: ?*anyopaque) MiniNat {
        return .{
            .reply = reply,
            .reply_userdata = userdata,
            .alloc = alloc,
            .udp_flows = std.AutoHashMap(UdpKey, UdpFlow).init(alloc),
        };
    }

    /// Start the reply-poll thread (forwards socket replies to the guest).
    pub fn start(self: *MiniNat) !void {
        self.running.store(true, .release);
        self.poll_thread = try std.Thread.spawn(.{}, pollLoop, .{self});
    }

    pub fn stop(self: *MiniNat) void {
        self.running.store(false, .release);
        if (self.poll_thread) |thread| {
            thread.join();
            self.poll_thread = null;
        }
        var iter = self.udp_flows.valueIterator();
        while (iter.next()) |flow| std.posix.close(flow.socket);
        self.udp_flows.deinit();
    }

    /// Handle one guest → host Ethernet frame.
    pub fn handleFrame(self: *MiniNat, frame: []const u8) void {
        if (frame.len < ETH_HDR) return;
        const ethertype = std.mem.readInt(u16, frame[12..14], .big);

        switch (ethertype) {
            ETHERTYPE_ARP => self.handleArp(frame),
            ETHERTYPE_IP => self.handleIp(frame),
            else => {},
        }
    }

    // =========================================================================
    // ARP
    // =========================================================================

    fn handleArp(self: *MiniNat, frame: []const u8) void {
        // Ethernet + ARP for IPv4 over Ethernet = 14 + 28
        if (frame.len < ETH_HDR + 28) return;
        const arp = frame[ETH_HDR..];
        const oper = std.mem.readInt(u16, arp[6..8], .big);
        if (oper != 1) return; // requests only

        const target_ip = arp[24..28];
        const ours = std.mem.eql(u8, target_ip, &GATEWAY_IP) or
            std.mem.eql(u8, target_ip, &DNS_IP);
        if (!ours) return;

        var out: [ETH_HDR + 28]u8 = undefined;
        // Ethernet: dst = requester, src = us
        @memcpy(out[0..6], frame[6..12]);
        @memcpy(out[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, out[12..14], ETHERTYPE_ARP, .big);
        // ARP reply
        const rep = out[ETH_HDR..];
        std.mem.writeInt(u16, rep[0..2], 1, .big); // htype ethernet
        std.mem.writeInt(u16, rep[2..4], ETHERTYPE_IP, .big); // ptype ipv4
        rep[4] = 6; // hlen
        rep[5] = 4; // plen
        std.mem.writeInt(u16, rep[6..8], 2, .big); // oper reply
        @memcpy(rep[8..14], &GATEWAY_MAC); // sender hw
        @memcpy(rep[14..18], target_ip); // sender ip (the asked-for one)
        @memcpy(rep[18..24], arp[8..14]); // target hw = requester
        @memcpy(rep[24..28], arp[14..18]); // target ip = requester

        self.reply(&out, self.reply_userdata);
    }

    // =========================================================================
    // IPv4
    // =========================================================================

    fn handleIp(self: *MiniNat, frame: []const u8) void {
        if (frame.len < ETH_HDR + 20) return;
        const ip = frame[ETH_HDR..];
        const ihl: usize = @as(usize, ip[0] & 0xF) * 4;
        if (ihl < 20 or frame.len < ETH_HDR + ihl) return;
        const proto = ip[9];

        switch (proto) {
            17 => self.handleUdp(frame, ihl),
            1 => self.handleIcmp(frame, ihl),
            else => {},
        }
    }

    fn handleUdp(self: *MiniNat, frame: []const u8, ihl: usize) void {
        const udp_off = ETH_HDR + ihl;
        if (frame.len < udp_off + 8) return;
        const udp = frame[udp_off..];
        const dst_port = std.mem.readInt(u16, udp[2..4], .big);

        // DHCP client → server
        if (dst_port == 67) {
            self.handleDhcp(frame, frame[udp_off + 8 ..]);
            return;
        }

        // Forward datagrams for non-local destinations via host sockets.
        const ip = frame[ETH_HDR..];
        const dst_ip = ip[16..20];
        if (std.mem.eql(u8, dst_ip[0..3], GATEWAY_IP[0..3])) return; // local net
        if (dst_ip[0] == 255) return; // broadcast

        const src_port = std.mem.readInt(u16, udp[0..2], .big);
        const udp_len = std.mem.readInt(u16, udp[4..6], .big);
        if (udp_len < 8 or udp_off + udp_len > frame.len) return;
        const payload = frame[udp_off + 8 .. udp_off + udp_len];

        self.forwardUdp(src_port, dst_ip[0..4].*, dst_port, payload);
    }

    fn forwardUdp(
        self: *MiniNat,
        guest_port: u16,
        remote_ip: [4]u8,
        remote_port: u16,
        payload: []const u8,
    ) void {
        const key = UdpKey{
            .guest_port = guest_port,
            .remote_ip = remote_ip,
            .remote_port = remote_port,
        };

        self.flows_mutex.lock();
        defer self.flows_mutex.unlock();

        const gop = self.udp_flows.getOrPut(key) catch return;
        if (!gop.found_existing) {
            if (self.udp_flows.count() > UDP_FLOW_MAX) {
                _ = self.udp_flows.remove(key);
                return;
            }
            const sock = std.posix.socket(
                std.posix.AF.INET,
                std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
                0,
            ) catch {
                _ = self.udp_flows.remove(key);
                return;
            };
            gop.value_ptr.* = .{ .socket = sock, .last_used = std.time.timestamp() };
        }
        gop.value_ptr.last_used = std.time.timestamp();

        var addr = std.posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, remote_port),
            .addr = @bitCast(remote_ip),
        };
        _ = std.posix.sendto(
            gop.value_ptr.socket,
            payload,
            0,
            @ptrCast(&addr),
            @sizeOf(std.posix.sockaddr.in),
        ) catch {};
    }

    /// Poll host sockets for replies and frame them back to the guest.
    fn pollLoop(self: *MiniNat) void {
        var buf: [2048]u8 = undefined;
        while (self.running.load(.acquire)) {
            var delivered = false;

            self.flows_mutex.lock();
            const now = std.time.timestamp();
            var expired: ?UdpKey = null;
            var iter = self.udp_flows.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const flow = entry.value_ptr;

                if (now - flow.last_used > UDP_IDLE_TIMEOUT_S) {
                    expired = key; // one per pass keeps the iterator valid
                    continue;
                }

                const n = std.posix.recvfrom(flow.socket, &buf, 0, null, null) catch |err| {
                    if (err != error.WouldBlock) expired = key;
                    continue;
                };
                if (n == 0) continue;
                flow.last_used = now;
                self.replyUdp(key, buf[0..n]);
                delivered = true;
            }
            if (expired) |key| {
                if (self.udp_flows.fetchRemove(key)) |entry| {
                    std.posix.close(entry.value.socket);
                }
            }
            self.flows_mutex.unlock();

            if (!delivered) {
                std.Thread.sleep(2 * std.time.ns_per_ms);
            }
        }
    }

    /// Build remote → guest UDP frame.
    fn replyUdp(self: *MiniNat, key: UdpKey, payload: []const u8) void {
        var out: [2048 + 42]u8 = undefined;
        const total = ETH_HDR + 20 + 8 + payload.len;
        if (total > out.len) return;

        // Ethernet: to guest
        @memcpy(out[0..6], &[_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 });
        @memcpy(out[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, out[12..14], ETHERTYPE_IP, .big);

        const ip = out[ETH_HDR..];
        @memset(ip[0..20], 0);
        ip[0] = 0x45;
        std.mem.writeInt(u16, ip[2..4], @intCast(20 + 8 + payload.len), .big);
        ip[8] = 64;
        ip[9] = 17;
        @memcpy(ip[12..16], &key.remote_ip);
        @memcpy(ip[16..20], &GUEST_IP);
        const ip_csum = checksum(ip[0..20]);
        std.mem.writeInt(u16, ip[10..12], ip_csum, .big);

        const udp = out[ETH_HDR + 20 ..];
        std.mem.writeInt(u16, udp[0..2], key.remote_port, .big);
        std.mem.writeInt(u16, udp[2..4], key.guest_port, .big);
        std.mem.writeInt(u16, udp[4..6], @intCast(8 + payload.len), .big);
        std.mem.writeInt(u16, udp[6..8], 0, .big); // checksum disabled

        @memcpy(out[ETH_HDR + 28 ..][0..payload.len], payload);

        self.reply(out[0..total], self.reply_userdata);
    }

    fn handleIcmp(self: *MiniNat, frame: []const u8, ihl: usize) void {
        const ip = frame[ETH_HDR..];
        const dst_ip = ip[16..20];
        if (!std.mem.eql(u8, dst_ip, &GATEWAY_IP) and !std.mem.eql(u8, dst_ip, &DNS_IP)) {
            return;
        }

        const icmp_off = ETH_HDR + ihl;
        if (frame.len < icmp_off + 8) return;
        if (frame[icmp_off] != 8) return; // echo request only

        // Echo reply: swap MACs and IPs, flip type, fix checksums.
        var out: [1600]u8 = undefined;
        if (frame.len > out.len) return;
        @memcpy(out[0..frame.len], frame);

        @memcpy(out[0..6], frame[6..12]);
        @memcpy(out[6..12], &GATEWAY_MAC);
        const oip = out[ETH_HDR..frame.len];
        @memcpy(oip[12..16], dst_ip); // src = who was pinged
        @memcpy(oip[16..20], ip[12..16]); // dst = guest
        oip[8] = 64; // ttl
        std.mem.writeInt(u16, oip[10..12], 0, .big);
        const ip_csum = checksum(oip[0..ihl]);
        std.mem.writeInt(u16, oip[10..12], ip_csum, .big);

        const oicmp = out[icmp_off..frame.len];
        oicmp[0] = 0; // echo reply
        std.mem.writeInt(u16, oicmp[2..4], 0, .big);
        const icmp_csum = checksum(oicmp);
        std.mem.writeInt(u16, oicmp[2..4], icmp_csum, .big);

        self.reply(out[0..frame.len], self.reply_userdata);
    }

    // =========================================================================
    // DHCP
    // =========================================================================

    fn handleDhcp(self: *MiniNat, frame: []const u8, bootp: []const u8) void {
        if (bootp.len < 240) return;
        if (bootp[0] != 1) return; // BOOTREQUEST
        if (!std.mem.eql(u8, bootp[236..240], &[_]u8{ 0x63, 0x82, 0x53, 0x63 })) return;

        // Find DHCP message type option (53)
        var msg_type: u8 = 0;
        var i: usize = 240;
        while (i + 2 <= bootp.len) {
            const opt = bootp[i];
            if (opt == 0xFF) break;
            if (opt == 0) {
                i += 1;
                continue;
            }
            const olen = bootp[i + 1];
            if (i + 2 + olen > bootp.len) break;
            if (opt == 53 and olen >= 1) msg_type = bootp[i + 2];
            i += 2 + olen;
        }

        const reply_type: u8 = switch (msg_type) {
            1 => 2, // DISCOVER -> OFFER
            3 => 5, // REQUEST -> ACK
            else => return,
        };

        var out: [590]u8 = undefined;
        @memset(&out, 0);

        const xid = bootp[4..8];
        const chaddr = bootp[28..44];

        // BOOTP reply
        var b: [300]u8 = undefined;
        @memset(&b, 0);
        b[0] = 2; // BOOTREPLY
        b[1] = 1; // ethernet
        b[2] = 6; // hlen
        @memcpy(b[4..8], xid);
        @memcpy(b[16..20], &GUEST_IP); // yiaddr
        @memcpy(b[20..24], &GATEWAY_IP); // siaddr
        @memcpy(b[28..44], chaddr);
        @memcpy(b[236..240], &[_]u8{ 0x63, 0x82, 0x53, 0x63 });
        var o: usize = 240;
        o = putOpt(&b, o, 53, &.{reply_type});
        o = putOpt(&b, o, 54, &GATEWAY_IP); // server id
        o = putOpt(&b, o, 51, &.{ 0, 1, 0x51, 0x80 }); // lease 86400s
        o = putOpt(&b, o, 1, &NETMASK);
        o = putOpt(&b, o, 3, &GATEWAY_IP); // router
        o = putOpt(&b, o, 6, &DNS_IP); // dns
        b[o] = 0xFF;
        o += 1;
        const bootp_len = @max(o, 300);

        const total = ETH_HDR + 20 + 8 + bootp_len;

        // Ethernet: broadcast reply (guest may not have its IP yet)
        @memcpy(out[0..6], frame[6..12]);
        @memcpy(out[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, out[12..14], ETHERTYPE_IP, .big);

        // IPv4
        const ip = out[ETH_HDR..];
        ip[0] = 0x45;
        std.mem.writeInt(u16, ip[2..4], @intCast(20 + 8 + bootp_len), .big);
        ip[8] = 64; // ttl
        ip[9] = 17; // udp
        @memcpy(ip[12..16], &GATEWAY_IP);
        @memcpy(ip[16..20], &[_]u8{ 255, 255, 255, 255 });
        const ip_csum = checksum(ip[0..20]);
        std.mem.writeInt(u16, ip[10..12], ip_csum, .big);

        // UDP (checksum 0 = disabled)
        const udp = out[ETH_HDR + 20 ..];
        std.mem.writeInt(u16, udp[0..2], 67, .big);
        std.mem.writeInt(u16, udp[2..4], 68, .big);
        std.mem.writeInt(u16, udp[4..6], @intCast(8 + bootp_len), .big);

        @memcpy(out[ETH_HDR + 28 ..][0..bootp_len], b[0..bootp_len]);

        self.reply(out[0..total], self.reply_userdata);
    }

    fn putOpt(buf: []u8, offset: usize, opt: u8, data: []const u8) usize {
        buf[offset] = opt;
        buf[offset + 1] = @intCast(data.len);
        @memcpy(buf[offset + 2 ..][0..data.len], data);
        return offset + 2 + data.len;
    }

    /// RFC 1071 Internet checksum.
    fn checksum(data: []const u8) u16 {
        var sum: u32 = 0;
        var i: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            sum += std.mem.readInt(u16, data[i..][0..2], .big);
        }
        if (i < data.len) {
            sum += @as(u32, data[i]) << 8;
        }
        while (sum >> 16 != 0) {
            sum = (sum & 0xFFFF) + (sum >> 16);
        }
        return @truncate(~sum);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

var test_replies: std.ArrayListUnmanaged([]u8) = .{};
var test_alloc: std.mem.Allocator = undefined;

fn testReply(frame: []const u8, _: ?*anyopaque) void {
    const copy = test_alloc.dupe(u8, frame) catch return;
    test_replies.append(test_alloc, copy) catch {};
}

fn clearReplies() void {
    for (test_replies.items) |r| test_alloc.free(r);
    test_replies.deinit(test_alloc);
    test_replies = .{};
}

test "mininat: ARP request for gateway gets a reply" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, testReply, null);
    defer nat.udp_flows.deinit();

    var req: [42]u8 = undefined;
    @memset(&req, 0);
    @memset(req[0..6], 0xFF); // broadcast
    @memcpy(req[6..12], &[_]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 });
    std.mem.writeInt(u16, req[12..14], ETHERTYPE_ARP, .big);
    const arp = req[14..];
    std.mem.writeInt(u16, arp[0..2], 1, .big);
    std.mem.writeInt(u16, arp[2..4], ETHERTYPE_IP, .big);
    arp[4] = 6;
    arp[5] = 4;
    std.mem.writeInt(u16, arp[6..8], 1, .big); // request
    @memcpy(arp[8..14], req[6..12]);
    @memcpy(arp[14..18], &GUEST_IP);
    @memcpy(arp[24..28], &GATEWAY_IP);

    nat.handleFrame(&req);
    try testing.expectEqual(@as(usize, 1), test_replies.items.len);
    const rep = test_replies.items[0];
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, rep[20..22], .big)); // ARP reply
    try testing.expect(std.mem.eql(u8, rep[22..28], &GATEWAY_MAC)); // sender hw
}

test "mininat: DHCP DISCOVER gets an OFFER with our lease" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, testReply, null);
    defer nat.udp_flows.deinit();

    var req: [ETH_HDR + 20 + 8 + 244]u8 = undefined;
    @memset(&req, 0);
    @memset(req[0..6], 0xFF);
    @memcpy(req[6..12], &[_]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 });
    std.mem.writeInt(u16, req[12..14], ETHERTYPE_IP, .big);
    const ip = req[ETH_HDR..];
    ip[0] = 0x45;
    ip[9] = 17;
    const udp = req[ETH_HDR + 20 ..];
    std.mem.writeInt(u16, udp[0..2], 68, .big);
    std.mem.writeInt(u16, udp[2..4], 67, .big);
    const bootp = req[ETH_HDR + 28 ..];
    bootp[0] = 1; // BOOTREQUEST
    @memcpy(bootp[236..240], &[_]u8{ 0x63, 0x82, 0x53, 0x63 });
    bootp[240] = 53;
    bootp[241] = 1;
    bootp[242] = 1; // DISCOVER
    bootp[243] = 0xFF;

    nat.handleFrame(&req);
    try testing.expectEqual(@as(usize, 1), test_replies.items.len);
    const rep = test_replies.items[0];
    const rbootp = rep[ETH_HDR + 28 ..];
    try testing.expectEqual(@as(u8, 2), rbootp[0]); // BOOTREPLY
    try testing.expect(std.mem.eql(u8, rbootp[16..20], &GUEST_IP)); // yiaddr
    try testing.expectEqual(@as(u8, 2), rbootp[242]); // OFFER
}

test "mininat: ICMP echo to gateway gets a reply" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, testReply, null);
    defer nat.udp_flows.deinit();

    var req: [ETH_HDR + 20 + 12]u8 = undefined;
    @memset(&req, 0);
    @memcpy(req[0..6], &GATEWAY_MAC);
    @memcpy(req[6..12], &[_]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 });
    std.mem.writeInt(u16, req[12..14], ETHERTYPE_IP, .big);
    const ip = req[ETH_HDR..];
    ip[0] = 0x45;
    std.mem.writeInt(u16, ip[2..4], 20 + 12, .big);
    ip[9] = 1; // icmp
    @memcpy(ip[12..16], &GUEST_IP);
    @memcpy(ip[16..20], &GATEWAY_IP);
    const icmp = req[ETH_HDR + 20 ..];
    icmp[0] = 8; // echo request

    nat.handleFrame(&req);
    try testing.expectEqual(@as(usize, 1), test_replies.items.len);
    const rep = test_replies.items[0];
    try testing.expectEqual(@as(u8, 0), rep[ETH_HDR + 20]); // echo reply
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 12 ..][0..4], &GATEWAY_IP));
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 16 ..][0..4], &GUEST_IP));
}
