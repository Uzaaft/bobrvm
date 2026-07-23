//! Built-in NAT responder (slirp-style addressing, no root required).
//!
//! Answers the guest's ARP, DHCP, and ICMP-echo traffic and forwards
//! UDP/TCP to real hosts through host sockets — so `ip addr` shows a
//! lease, `ping 10.0.2.2` works, DNS resolves, and `curl` reaches the
//! internet, all without root. The vmnet.framework backend comes later.
//!
//!   guest:   10.0.2.15
//!   gateway: 10.0.2.2 (this responder)
//!   dns:     1.1.1.1 (advertised; UDP forwarded to the real resolver)
//!
//! TCP is a minimal user-mode proxy: guest SYN opens a host socket, we
//! track sequence numbers and relay bytes both ways with proper ACKs.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const net_compat = @import("../compat/net.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.mininat);

/// Wall-clock seconds since epoch, for flow idle-timeout bookkeeping.
/// zig 0.16 removed std.time.timestamp() in favor of the Io.Clock
/// abstraction; this is a thin wrapper since we just need coarse,
/// relative "how long has this flow been idle" comparisons.
fn nowSeconds() i64 {
    const ns = std.Io.Clock.real.now(global.io()).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_s));
}

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

const IcmpKey = struct {
    remote_ip: [4]u8,
    /// Guest-chosen ICMP echo identifier (ping's pid-derived id).
    id: u16,
};

/// A forwarded ICMP echo "flow": one unprivileged DGRAM ICMP socket per
/// (remote host, guest id). last_seq lets us stamp the guest's sequence
/// number back onto whatever the kernel/remote host actually returns.
const IcmpFlow = struct {
    socket: std.posix.socket_t,
    last_used: i64,
    last_seq: u16 = 0,
};

const TcpKey = struct {
    guest_port: u16,
    remote_ip: [4]u8,
    remote_port: u16,
};

const TcpState = enum { connecting, established, fin_wait, closed };

/// A forwarded TCP connection (guest ↔ host socket).
const TcpFlow = struct {
    socket: std.posix.socket_t,
    state: TcpState,
    /// Our (gateway-side) sequence number = bytes we've sent to the guest.
    snd_nxt: u32,
    /// Next sequence we expect from the guest = bytes acked to it.
    rcv_nxt: u32,
    last_used: i64,
};

pub const MiniNat = struct {
    reply: ReplyFn,
    reply_userdata: ?*anyopaque,

    alloc: std.mem.Allocator,
    udp_flows: std.AutoHashMap(UdpKey, UdpFlow),
    tcp_flows: std.AutoHashMap(TcpKey, TcpFlow),
    icmp_flows: std.AutoHashMap(IcmpKey, IcmpFlow),
    flows_mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_thread: ?std.Thread = null,

    /// Back-pressure: returns true while the guest RX side has headroom.
    /// The pump stops pulling from host sockets when this is false, so a
    /// bulk download can't overrun the guest queue and drop segments
    /// (which, with no retransmit, would stall the connection). Data
    /// waits in the host socket buffer; the host kernel's TCP window then
    /// throttles the real sender.
    rx_ready: ?*const fn (?*anyopaque) bool = null,
    rx_ready_userdata: ?*anyopaque = null,

    pub const UDP_FLOW_MAX: usize = 256;
    pub const UDP_IDLE_TIMEOUT_S: i64 = 60;
    pub const TCP_FLOW_MAX: usize = 256;
    pub const TCP_IDLE_TIMEOUT_S: i64 = 300;
    pub const ICMP_FLOW_MAX: usize = 256;
    pub const ICMP_IDLE_TIMEOUT_S: i64 = 60;
    /// Our advertised window / max relayed segment payload.
    pub const TCP_MSS: usize = 1400;

    pub fn init(alloc: std.mem.Allocator, reply: ReplyFn, userdata: ?*anyopaque) MiniNat {
        return .{
            .reply = reply,
            .reply_userdata = userdata,
            .alloc = alloc,
            .udp_flows = std.AutoHashMap(UdpKey, UdpFlow).init(alloc),
            .tcp_flows = std.AutoHashMap(TcpKey, TcpFlow).init(alloc),
            .icmp_flows = std.AutoHashMap(IcmpKey, IcmpFlow).init(alloc),
        };
    }

    /// Set the RX back-pressure predicate (see rx_ready).
    pub fn setRxReady(self: *MiniNat, cb: *const fn (?*anyopaque) bool, userdata: ?*anyopaque) void {
        self.rx_ready = cb;
        self.rx_ready_userdata = userdata;
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
        while (iter.next()) |flow| net_compat.socketClose(flow.socket);
        self.udp_flows.deinit();
        var titer = self.tcp_flows.valueIterator();
        while (titer.next()) |flow| net_compat.socketClose(flow.socket);
        self.tcp_flows.deinit();
        var iiter = self.icmp_flows.valueIterator();
        while (iiter.next()) |flow| net_compat.socketClose(flow.socket);
        self.icmp_flows.deinit();
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
            6 => self.handleTcp(frame, ihl),
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

        self.flows_mutex.lockUncancelable(global.io());
        defer self.flows_mutex.unlock(global.io());

        const gop = self.udp_flows.getOrPut(key) catch return;
        if (!gop.found_existing) {
            if (self.udp_flows.count() > UDP_FLOW_MAX) {
                _ = self.udp_flows.remove(key);
                return;
            }
            const sock = net_compat.socketCreate(
                std.posix.AF.INET,
                std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
                0,
            ) catch {
                _ = self.udp_flows.remove(key);
                return;
            };
            gop.value_ptr.* = .{ .socket = sock, .last_used = nowSeconds() };
        }
        gop.value_ptr.last_used = nowSeconds();

        var addr = std.posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, remote_port),
            .addr = @bitCast(remote_ip),
        };
        _ = net_compat.sendto(
            gop.value_ptr.socket,
            payload,
            0,
            @ptrCast(&addr),
            @sizeOf(std.posix.sockaddr.in),
        ) catch {};
    }

    /// Forward a guest ICMP echo request to a real remote host via an
    /// unprivileged DGRAM ICMP socket (no root required on macOS/Linux).
    fn forwardIcmp(
        self: *MiniNat,
        remote_ip: [4]u8,
        id: u16,
        seq: u16,
        payload: []const u8,
    ) void {
        const key = IcmpKey{ .remote_ip = remote_ip, .id = id };

        self.flows_mutex.lockUncancelable(global.io());
        defer self.flows_mutex.unlock(global.io());

        const gop = self.icmp_flows.getOrPut(key) catch return;
        if (!gop.found_existing) {
            if (self.icmp_flows.count() > ICMP_FLOW_MAX) {
                _ = self.icmp_flows.remove(key);
                return;
            }
            const sock = net_compat.socketCreate(
                std.posix.AF.INET,
                std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK,
                std.posix.IPPROTO.ICMP,
            ) catch {
                _ = self.icmp_flows.remove(key);
                return;
            };
            gop.value_ptr.* = .{ .socket = sock, .last_used = nowSeconds() };
        }
        gop.value_ptr.last_used = nowSeconds();
        gop.value_ptr.last_seq = seq;

        var req: [1500]u8 = undefined;
        const total = 8 + payload.len;
        if (total > req.len) return;
        req[0] = 8; // echo request
        req[1] = 0; // code
        std.mem.writeInt(u16, req[2..4], 0, .big);
        std.mem.writeInt(u16, req[4..6], id, .big);
        std.mem.writeInt(u16, req[6..8], seq, .big);
        @memcpy(req[8..total], payload);
        const icmp_csum = checksum(req[0..total]);
        std.mem.writeInt(u16, req[2..4], icmp_csum, .big);

        var addr = std.posix.sockaddr.in{
            .port = 0,
            .addr = @bitCast(remote_ip),
        };
        _ = net_compat.sendto(
            gop.value_ptr.socket,
            req[0..total],
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

            self.flows_mutex.lockUncancelable(global.io());
            const now = nowSeconds();
            var expired: ?UdpKey = null;
            var iter = self.udp_flows.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const flow = entry.value_ptr;

                if (now - flow.last_used > UDP_IDLE_TIMEOUT_S) {
                    expired = key; // one per pass keeps the iterator valid
                    continue;
                }

                const n = net_compat.recvfrom(flow.socket, &buf, 0, null, null) catch |err| {
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
                    net_compat.socketClose(entry.value.socket);
                }
            }

            var expired_icmp: ?IcmpKey = null;
            var iiter = self.icmp_flows.iterator();
            while (iiter.next()) |entry| {
                const key = entry.key_ptr.*;
                const flow = entry.value_ptr;

                if (now - flow.last_used > ICMP_IDLE_TIMEOUT_S) {
                    expired_icmp = key;
                    continue;
                }

                const n = net_compat.recvfrom(flow.socket, &buf, 0, null, null) catch |err| {
                    if (err != error.WouldBlock) expired_icmp = key;
                    continue;
                };
                if (n == 0) continue;
                flow.last_used = now;
                self.handleIcmpSocketReply(key, flow.last_seq, buf[0..n]);
                delivered = true;
            }
            if (expired_icmp) |key| {
                if (self.icmp_flows.fetchRemove(key)) |entry| {
                    net_compat.socketClose(entry.value.socket);
                }
            }

            if (self.pumpTcp(&buf)) delivered = true;
            self.flows_mutex.unlock(global.io());

            if (!delivered) {
                std.Io.Clock.Duration.sleep(.{
                    .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms },
                    .clock = .awake,
                }, global.io()) catch {};
            }
        }
    }

    /// Service TCP flows: complete connects (SYN-ACK), relay host data to
    /// the guest, propagate close. Caller holds flows_mutex. Returns true
    /// if any work happened. One expiry/removal per pass keeps the
    /// iterator valid.
    fn pumpTcp(self: *MiniNat, buf: []u8) bool {
        var work = false;
        const now = nowSeconds();
        var remove_key: ?TcpKey = null;

        // Back-pressure: if the guest RX queue is backed up, don't pull
        // more host data this pass (connect completion and close still
        // proceed). Leaves data in the host socket → real sender throttles.
        const rx_ok = if (self.rx_ready) |rr| rr(self.rx_ready_userdata) else true;

        var iter = self.tcp_flows.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const flow = entry.value_ptr;

            if (now - flow.last_used > TCP_IDLE_TIMEOUT_S or flow.state == .closed) {
                remove_key = key;
                continue;
            }

            if (flow.state == .connecting) {
                // A nonblocking connect completes when the socket becomes
                // writable; only then is SO_ERROR meaningful.
                var pfd = [_]std.posix.pollfd{.{
                    .fd = flow.socket,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&pfd, 0) catch 0;
                if (ready == 0 or (pfd[0].revents & std.posix.POLL.OUT) == 0) continue;

                net_compat.getsockoptError(flow.socket) catch {
                    self.tcpSendRst(key, flow.rcv_nxt);
                    remove_key = key;
                    continue;
                };
                // Connected: SYN-ACK, then our seq advances past the SYN.
                self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_SYN | TCP_ACK, &.{});
                flow.snd_nxt +%= 1;
                flow.state = .established;
                flow.last_used = now;
                work = true;
                continue;
            }

            // Relay available host data to the guest — unless the guest RX
            // side is backed up, in which case defer (no drop).
            if (!rx_ok) continue;
            const n = net_compat.recv(flow.socket, buf[0..TCP_MSS], 0) catch |e| {
                if (e == error.WouldBlock) continue;
                self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_RST | TCP_ACK, &.{});
                remove_key = key;
                continue;
            };
            if (n == 0) {
                // Host closed: send FIN.
                self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_FIN | TCP_ACK, &.{});
                flow.snd_nxt +%= 1;
                remove_key = key;
                continue;
            }
            self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_PSH | TCP_ACK, buf[0..n]);
            flow.snd_nxt +%= @intCast(n);
            flow.last_used = now;
            work = true;
        }

        if (remove_key) |key| {
            if (self.tcp_flows.fetchRemove(key)) |entry| {
                net_compat.socketClose(entry.value.socket);
            }
        }
        return work;
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

    /// Build remote → guest ICMP echo reply frame. `icmp_msg` is whatever
    /// the host's DGRAM ICMP socket handed back; the id/seq are stamped
    /// with the guest's original values since the kernel may have
    /// rewritten the id on the way out for its own demuxing.
    /// Handle bytes read from a DGRAM ICMP flow socket. macOS/BSD hand
    /// back the full IP packet (header + ICMP message) on recvfrom, not
    /// just the ICMP part like UDP recvfrom does — skip the IP header
    /// before reframing for the guest.
    fn handleIcmpSocketReply(self: *MiniNat, key: IcmpKey, seq: u16, raw: []const u8) void {
        if (raw.len < 20 or raw[0] >> 4 != 4) return;
        const rihl: usize = @as(usize, raw[0] & 0x0F) * 4;
        if (raw.len <= rihl) return;
        self.replyIcmp(key, seq, raw[rihl..]);
    }

    fn replyIcmp(self: *MiniNat, key: IcmpKey, seq: u16, icmp_msg: []const u8) void {
        if (icmp_msg.len < 8) return;
        if (icmp_msg[0] != 0) return; // only relay echo replies

        var out: [2048 + 42]u8 = undefined;
        const total = ETH_HDR + 20 + icmp_msg.len;
        if (total > out.len) return;

        @memcpy(out[0..6], &[_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 });
        @memcpy(out[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, out[12..14], ETHERTYPE_IP, .big);

        const ip = out[ETH_HDR..];
        @memset(ip[0..20], 0);
        ip[0] = 0x45;
        std.mem.writeInt(u16, ip[2..4], @intCast(20 + icmp_msg.len), .big);
        ip[8] = 64;
        ip[9] = 1; // icmp
        @memcpy(ip[12..16], &key.remote_ip);
        @memcpy(ip[16..20], &GUEST_IP);
        const ip_csum = checksum(ip[0..20]);
        std.mem.writeInt(u16, ip[10..12], ip_csum, .big);

        const icmp = out[ETH_HDR + 20 ..][0..icmp_msg.len];
        @memcpy(icmp, icmp_msg);
        std.mem.writeInt(u16, icmp[4..6], key.id, .big);
        std.mem.writeInt(u16, icmp[6..8], seq, .big);
        std.mem.writeInt(u16, icmp[2..4], 0, .big);
        const icmp_csum = checksum(icmp);
        std.mem.writeInt(u16, icmp[2..4], icmp_csum, .big);

        self.reply(out[0..total], self.reply_userdata);
    }

    // =========================================================================
    // TCP (user-mode proxy)
    // =========================================================================

    const TCP_FIN: u8 = 0x01;
    const TCP_SYN: u8 = 0x02;
    const TCP_RST: u8 = 0x04;
    const TCP_PSH: u8 = 0x08;
    const TCP_ACK: u8 = 0x10;

    fn handleTcp(self: *MiniNat, frame: []const u8, ihl: usize) void {
        const tcp_off = ETH_HDR + ihl;
        if (frame.len < tcp_off + 20) return;
        const ip = frame[ETH_HDR..];
        const dst_ip = ip[16..20];
        // Only forward off-net destinations.
        if (std.mem.eql(u8, dst_ip[0..3], GATEWAY_IP[0..3])) return;

        const tcp = frame[tcp_off..];
        const src_port = std.mem.readInt(u16, tcp[0..2], .big);
        const dst_port = std.mem.readInt(u16, tcp[2..4], .big);
        const seq = std.mem.readInt(u32, tcp[4..8], .big);
        const data_off: usize = @as(usize, (tcp[12] >> 4)) * 4;
        const flags = tcp[13];
        if (tcp_off + data_off > frame.len) return;
        const payload = frame[tcp_off + data_off ..];

        const key = TcpKey{
            .guest_port = src_port,
            .remote_ip = dst_ip[0..4].*,
            .remote_port = dst_port,
        };

        self.flows_mutex.lockUncancelable(global.io());
        defer self.flows_mutex.unlock(global.io());

        if (flags & TCP_SYN != 0 and flags & TCP_ACK == 0) {
            self.tcpOpen(key, seq);
            return;
        }

        const flow = self.tcp_flows.getPtr(key) orelse {
            // Unknown connection: RST it so the guest gives up quickly.
            if (flags & TCP_RST == 0) self.tcpSendRst(key, seq + @as(u32, @intCast(payload.len)));
            return;
        };
        flow.last_used = nowSeconds();

        if (flags & TCP_RST != 0) {
            net_compat.socketClose(flow.socket);
            _ = self.tcp_flows.remove(key);
            return;
        }

        // Relay any guest payload to the host socket (only new bytes, and
        // only once the host side is connected). One non-blocking send;
        // ACK only what actually went through and let the guest retransmit
        // the rest. Never spin here — this runs on the vCPU thread under
        // the machine lock, so a blocking send would freeze the guest.
        if (payload.len > 0 and seq == flow.rcv_nxt and flow.state == .established) {
            const sent = trySend(flow.socket, payload);
            if (sent > 0) {
                flow.rcv_nxt +%= @intCast(sent);
                self.tcpSendAck(key, flow);
            }
            // If sent < payload.len, we simply don't ACK the tail; the
            // guest's retransmit timer resends it.
        }

        // A FIN is only valid (and consumes its sequence number) once we
        // have acked all preceding data — i.e. the guest didn't retransmit
        // past our rcv_nxt.
        if (flags & TCP_FIN != 0 and seq +% @as(u32, @intCast(payload.len)) == flow.rcv_nxt) {
            flow.rcv_nxt +%= 1; // FIN consumes a sequence number
            net_compat.shutdown(flow.socket, .send) catch {};
            self.tcpSendAck(key, flow);
            flow.state = .fin_wait;
        }
    }

    /// One non-blocking send; returns bytes accepted by the socket (0 on
    /// EAGAIN or a dead peer). Uses the raw syscall because std.posix.send
    /// maps ENOTCONN/EPIPE to unreachable, which a NAT proxy must tolerate
    /// (races with connect completion and peer close). Must never block:
    /// the caller runs on the vCPU thread under the machine lock, and the
    /// TCP proxy relies on the guest to retransmit anything not acked.
    fn trySend(socket: std.posix.socket_t, data: []const u8) usize {
        const rc = std.posix.system.send(socket, data.ptr, data.len, 0);
        const signed: isize = @bitCast(rc);
        if (signed >= 0) return @intCast(signed);
        return 0; // EAGAIN / ENOTCONN / EPIPE / ECONNRESET
    }

    fn tcpOpen(self: *MiniNat, key: TcpKey, guest_seq: u32) void {
        if (self.tcp_flows.count() >= TCP_FLOW_MAX) return;

        const sock = net_compat.socketCreate(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        ) catch return;

        var addr = std.posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, key.remote_port),
            .addr = @bitCast(key.remote_ip),
        };
        net_compat.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) catch |err| {
            // EINPROGRESS is expected for a nonblocking connect.
            if (err != error.WouldBlock and err != error.ConnectionPending) {
                net_compat.socketClose(sock);
                return;
            }
        };

        // Our ISN is arbitrary; use a fixed base plus the guest seq for
        // variety (determinism is fine for a single-host proxy).
        const flow = TcpFlow{
            .socket = sock,
            .state = .connecting,
            .snd_nxt = 0x1000,
            .rcv_nxt = guest_seq +% 1, // SYN consumes a sequence number
            .last_used = nowSeconds(),
        };
        self.tcp_flows.put(key, flow) catch {
            net_compat.socketClose(sock);
            return;
        };
        // SYN-ACK is sent once the host connect completes (pollLoop).
    }

    /// Send a bare ACK for the current rcv_nxt/snd_nxt.
    fn tcpSendAck(self: *MiniNat, key: TcpKey, flow: *TcpFlow) void {
        self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_ACK, &.{});
    }

    fn tcpSendRst(self: *MiniNat, key: TcpKey, ack: u32) void {
        self.tcpSend(key, 0, ack, TCP_RST | TCP_ACK, &.{});
    }

    /// Build and deliver one remote → guest TCP segment.
    fn tcpSend(self: *MiniNat, key: TcpKey, seq: u32, ack: u32, flags: u8, payload: []const u8) void {
        var out: [ETH_HDR + 20 + 20 + TCP_MSS]u8 = undefined;
        if (payload.len > TCP_MSS) return;
        const total = ETH_HDR + 20 + 20 + payload.len;

        @memcpy(out[0..6], &[_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 });
        @memcpy(out[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, out[12..14], ETHERTYPE_IP, .big);

        const ip = out[ETH_HDR..];
        @memset(ip[0..20], 0);
        ip[0] = 0x45;
        std.mem.writeInt(u16, ip[2..4], @intCast(20 + 20 + payload.len), .big);
        ip[8] = 64;
        ip[9] = 6; // TCP
        @memcpy(ip[12..16], &key.remote_ip);
        @memcpy(ip[16..20], &GUEST_IP);
        std.mem.writeInt(u16, ip[10..12], checksum(ip[0..20]), .big);

        const tcp = out[ETH_HDR + 20 ..];
        @memset(tcp[0..20], 0);
        std.mem.writeInt(u16, tcp[0..2], key.remote_port, .big);
        std.mem.writeInt(u16, tcp[2..4], key.guest_port, .big);
        std.mem.writeInt(u32, tcp[4..8], seq, .big);
        std.mem.writeInt(u32, tcp[8..12], ack, .big);
        tcp[12] = 5 << 4; // data offset = 5 words
        tcp[13] = flags;
        std.mem.writeInt(u16, tcp[14..16], 0xFFFF, .big); // window
        @memcpy(tcp[20..][0..payload.len], payload);
        std.mem.writeInt(u16, tcp[16..18], tcpChecksum(key.remote_ip, GUEST_IP, tcp[0 .. 20 + payload.len]), .big);

        self.reply(out[0..total], self.reply_userdata);
    }

    /// TCP checksum over the pseudo-header + segment.
    fn tcpChecksum(src_ip: [4]u8, dst_ip: [4]u8, segment: []const u8) u16 {
        var sum: u32 = 0;
        sum += (@as(u32, src_ip[0]) << 8) | src_ip[1];
        sum += (@as(u32, src_ip[2]) << 8) | src_ip[3];
        sum += (@as(u32, dst_ip[0]) << 8) | dst_ip[1];
        sum += (@as(u32, dst_ip[2]) << 8) | dst_ip[3];
        sum += 6; // protocol
        sum += @intCast(segment.len);

        var i: usize = 0;
        while (i + 1 < segment.len) : (i += 2) {
            sum += (@as(u32, segment[i]) << 8) | segment[i + 1];
        }
        if (i < segment.len) sum += @as(u32, segment[i]) << 8;
        while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        return @truncate(~sum);
    }

    fn handleIcmp(self: *MiniNat, frame: []const u8, ihl: usize) void {
        const ip = frame[ETH_HDR..];
        const dst_ip = ip[16..20];

        const icmp_off = ETH_HDR + ihl;
        if (frame.len < icmp_off + 8) return;
        if (frame[icmp_off] != 8) return; // echo request only

        // Arbitrary remote host: forward the echo request via a real
        // (unprivileged) ICMP socket instead of faking a local reply.
        if (!std.mem.eql(u8, dst_ip, &GATEWAY_IP) and !std.mem.eql(u8, dst_ip, &DNS_IP)) {
            if (dst_ip[0] == 255) return; // broadcast
            const icmp = frame[icmp_off..];
            const id = std.mem.readInt(u16, icmp[4..6], .big);
            const seq = std.mem.readInt(u16, icmp[6..8], .big);
            self.forwardIcmp(dst_ip[0..4].*, id, seq, icmp[8..]);
            return;
        }

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

var test_replies: std.ArrayListUnmanaged([]u8) = .empty;
var test_alloc: std.mem.Allocator = undefined;

fn testReply(frame: []const u8, _: ?*anyopaque) void {
    const copy = test_alloc.dupe(u8, frame) catch return;
    test_replies.append(test_alloc, copy) catch {};
}

fn clearReplies() void {
    for (test_replies.items) |r| test_alloc.free(r);
    test_replies.deinit(test_alloc);
    test_replies = .empty;
}

test "mininat: ARP request for gateway gets a reply" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, testReply, null);
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }

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
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }

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
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }

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

test "mininat: ICMP echo to a remote host is reframed for the guest" {
    // Regression test: macOS/BSD DGRAM ICMP sockets hand recvfrom() the
    // full IP packet (header + ICMP message), not just the ICMP message
    // like UDP recvfrom does. handleIcmpSocketReply must skip that IP
    // header — otherwise every remote ping reply is silently dropped
    // (the IP header's first byte, 0x45, fails the "is this an echo
    // reply" type==0 check).
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, testReply, null);
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }

    const remote_ip = [4]u8{ 8, 8, 8, 8 };
    const key = IcmpKey{ .remote_ip = remote_ip, .id = 0x1234 };

    // Simulate exactly what recvfrom() on the DGRAM ICMP socket returns:
    // a 20-byte IPv4 header followed by an ICMP echo reply.
    var raw: [20 + 8 + 5]u8 = undefined;
    @memset(&raw, 0);
    raw[0] = 0x45; // version 4, IHL 5 (20-byte header)
    @memcpy(raw[12..16], &remote_ip);
    const icmp = raw[20..];
    icmp[0] = 0; // echo reply
    icmp[1] = 0; // code
    std.mem.writeInt(u16, icmp[4..6], 0x9999, .big); // kernel-rewritten id
    std.mem.writeInt(u16, icmp[6..8], 7, .big); // kernel/remote seq
    @memcpy(icmp[8..13], "hello");

    nat.handleIcmpSocketReply(key, 42, &raw);

    try testing.expectEqual(@as(usize, 1), test_replies.items.len);
    const rep = test_replies.items[0];
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 12 ..][0..4], &remote_ip));
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 16 ..][0..4], &GUEST_IP));
    const rep_icmp = rep[ETH_HDR + 20 ..];
    try testing.expectEqual(@as(u8, 0), rep_icmp[0]); // echo reply
    // id/seq are stamped with the guest's originals, not the kernel's.
    try testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, rep_icmp[4..6], .big));
    try testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, rep_icmp[6..8], .big));
    try testing.expect(std.mem.eql(u8, rep_icmp[8..13], "hello"));
}
