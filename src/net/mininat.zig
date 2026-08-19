//! Built-in NAT responder (slirp-style addressing, no root required).
//!
//! Answers ARP, DHCP, and ICMP echo locally, and forwards UDP/TCP through
//! unprivileged host sockets.
//!
//!   guest:   10.0.2.15
//!   gateway: 10.0.2.2 (this responder)
//!   dns:     1.1.1.1 (advertised; UDP forwarded to the real resolver)
//!
//! TCP is a minimal user-mode proxy: guest SYN opens a host socket, we
//! track sequence numbers and relay bytes both ways with proper ACKs.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const callback_binding = @import("../callback.zig");
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

/// Monotonic-ish nanoseconds for retransmit-timer bookkeeping. Only used
/// for relative deadline comparisons within a single flow.
fn nowNanos() i64 {
    return @intCast(std.Io.Clock.real.now(global.io()).nanoseconds);
}

pub const GUEST_IP = [4]u8{ 10, 0, 2, 15 };
pub const GATEWAY_IP = [4]u8{ 10, 0, 2, 2 };
pub const DNS_IP = [4]u8{ 1, 1, 1, 1 };
pub const NETMASK = [4]u8{ 255, 255, 255, 0 };
pub const GATEWAY_MAC = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 };

const ETH_HDR = 14;
const ETHERTYPE_IP: u16 = 0x0800;
const ETHERTYPE_ARP: u16 = 0x0806;

/// Exclusive frame storage borrowed from a reply sink until commit.
pub const ReplyLease = struct {
    frame: []u8,
    token: usize,
};

/// Reply sink: frames the responder wants delivered to the guest.
pub const Reply = callback_binding.Binding1([]const u8, void);
pub const ReplyReserve = callback_binding.Binding1(usize, ?ReplyLease);
pub const ReplyCommit = callback_binding.Binding1(ReplyLease, void);
pub const RxReady = callback_binding.Binding0(bool);

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

const TcpState = enum {
    /// Outbound: host connect() in flight; SYN-ACK goes to the guest when
    /// it completes.
    connecting,
    /// Inbound (port forward): our synthetic SYN was sent to the guest;
    /// waiting for its SYN-ACK.
    syn_to_guest,
    established,
    fin_wait,
    closed,
};

/// A host→guest port forward rule.
pub const Forward = struct {
    host_port: u16,
    guest_port: u16,
};

/// A listening host socket for one forward rule.
const Listener = struct {
    socket: std.posix.socket_t,
    guest_port: u16,
    host_port: u16,
};

/// Max host→guest bytes buffered unacked per flow — caps the sliding send
/// window. The guest can't advertise more than 65535 anyway (our SYN-ACK
/// carries no options, so no window scaling is negotiated).
const SND_BUF_MAX: usize = 65535;
/// Guest window assumed before its first ACK arrives (its true window never
/// exceeds this without scaling, so we can never overshoot).
const DEFAULT_SND_WND: u32 = 65535;
/// Initial host→guest retransmit timeout and its exponential-backoff ceiling.
const INITIAL_RTO_NS: i64 = 250 * std.time.ns_per_ms;
const MAX_RTO_NS: i64 = 4 * std.time.ns_per_s;
/// Poll work is iterative; its largest packet scratch buffers are under 4 KiB.
const stack_size_bytes: usize = 1024 * 1024;

const TcpSendBuffer = struct {
    storage: []u8 = &.{},
    head: usize = 0,
    len: usize = 0,
    pool_index: ?u16 = null,

    const Prefix = struct {
        first: []const u8,
        second: []const u8,
    };

    fn init(alloc: std.mem.Allocator) std.mem.Allocator.Error!TcpSendBuffer {
        const storage = try alloc.alloc(u8, SND_BUF_MAX);
        assert(storage.len == SND_BUF_MAX);
        assert(storage.len > 0);
        return .{ .storage = storage };
    }

    fn deinit(self: *TcpSendBuffer, alloc: std.mem.Allocator) void {
        assert(self.head < self.storage.len or self.storage.len == 0);
        assert(self.len <= self.storage.len);
        assert(self.pool_index == null);
        if (self.storage.len > 0) alloc.free(self.storage);
        self.* = .{};
    }

    fn initPooled(storage: []u8, pool_index: u16) TcpSendBuffer {
        assert(storage.len == SND_BUF_MAX);
        assert(pool_index < MiniNat.TCP_FLOW_MAX);
        return .{ .storage = storage, .pool_index = pool_index };
    }

    fn append(self: *TcpSendBuffer, data: []const u8) bool {
        assert(self.storage.len == SND_BUF_MAX);
        assert(self.len <= self.storage.len);
        if (data.len > self.storage.len - self.len) return false;
        const tail = (self.head + self.len) % self.storage.len;
        const first_len = @min(data.len, self.storage.len - tail);
        @memcpy(self.storage[tail..][0..first_len], data[0..first_len]);
        @memcpy(self.storage[0 .. data.len - first_len], data[first_len..]);
        self.len += data.len;
        return true;
    }

    fn consume(self: *TcpSendBuffer, count: usize) void {
        assert(count <= self.len);
        assert(self.storage.len == SND_BUF_MAX);
        self.len -= count;
        if (self.len == 0) {
            self.head = 0;
        } else {
            self.head = (self.head + count) % self.storage.len;
        }
    }

    fn prefixParts(self: *const TcpSendBuffer, max_len: usize) Prefix {
        assert(max_len > 0);
        assert(self.len <= self.storage.len);
        const prefix_len = @min(self.len, max_len);
        const first_len = @min(prefix_len, self.storage.len - self.head);
        return .{
            .first = self.storage[self.head..][0..first_len],
            .second = self.storage[0 .. prefix_len - first_len],
        };
    }
};

/// A forwarded TCP connection (guest ↔ host socket).
const TcpFlow = struct {
    socket: std.posix.socket_t,
    state: TcpState,
    /// Our (gateway-side) next sequence to send to the guest.
    snd_nxt: u32,
    /// Oldest unacknowledged byte we've sent to the guest. Bytes in
    /// [snd_una, snd_nxt) live in snd_buf awaiting the guest's ACK; this
    /// is what makes host→guest delivery reliable (retransmittable).
    snd_una: u32 = 0,
    /// Guest's advertised receive window (bytes). We never let the amount
    /// in flight exceed this — ignoring it is what silently overran the
    /// guest and stalled bulk downloads. No window scaling is negotiated
    /// (our SYN-ACK carries no options) so this is a plain 16-bit value.
    snd_wnd: u32 = DEFAULT_SND_WND,
    /// Unacked host→guest payload = the bytes [snd_una, snd_nxt). Kept so
    /// a lost segment can be retransmitted (the source bytes are already
    /// gone from the host socket by the time we send them).
    snd_buf: TcpSendBuffer = .{},
    /// Absolute nanosecond deadline for retransmitting the oldest unacked
    /// segment; 0 = no data outstanding / timer disarmed.
    rt_deadline_ns: i64 = 0,
    /// Current retransmit timeout (ns), doubled on each timeout, reset on
    /// forward progress.
    rto_ns: i64 = INITIAL_RTO_NS,
    /// Duplicate-ACK counter for fast retransmit.
    dup_acks: u8 = 0,
    /// The host socket hit EOF; drain snd_buf, then FIN. Deferring the FIN
    /// until everything is acked keeps the tail of a download from being
    /// dropped along with the flow.
    host_eof: bool = false,
    /// Next sequence we expect from the guest = bytes acked to it.
    rcv_nxt: u32,
    last_used: i64,

    fn deinit(self: *TcpFlow, alloc: std.mem.Allocator) void {
        self.snd_buf.deinit(alloc);
    }
};

pub const MiniNat = struct {
    reply: Reply,
    reply_reserve: ?ReplyReserve = null,
    reply_commit: ?ReplyCommit = null,

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
    rx_ready: ?RxReady = null,

    /// Host→guest port-forward listeners. Populated by addForward()
    /// BEFORE start(); immutable afterwards (pollLoop reads unlocked).
    listeners: std.ArrayListUnmanaged(Listener) = .empty,
    /// One startup allocation divided into fixed per-flow retransmit buffers.
    tcp_send_pool: []u8 = &.{},
    tcp_send_free: [TCP_FLOW_MAX]u16 = undefined,
    tcp_send_free_count: u16 = 0,
    /// Ephemeral "remote" port allocator for inbound flows (the guest
    /// sees forwarded connections as coming from GATEWAY_IP:ephemeral).
    next_inbound_port: u16 = 49152,

    pub const UDP_FLOW_MAX: usize = 256;
    pub const UDP_IDLE_TIMEOUT_S: i64 = 60;
    pub const TCP_FLOW_MAX: usize = 256;
    pub const TCP_IDLE_TIMEOUT_S: i64 = 300;
    pub const ICMP_FLOW_MAX: usize = 256;
    pub const ICMP_IDLE_TIMEOUT_S: i64 = 60;
    /// Our advertised window / max relayed segment payload.
    pub const TCP_MSS: usize = 1400;

    pub fn init(alloc: std.mem.Allocator, reply: Reply) MiniNat {
        return .{
            .reply = reply,
            .alloc = alloc,
            .udp_flows = std.AutoHashMap(UdpKey, UdpFlow).init(alloc),
            .tcp_flows = std.AutoHashMap(TcpKey, TcpFlow).init(alloc),
            .icmp_flows = std.AutoHashMap(IcmpKey, IcmpFlow).init(alloc),
        };
    }

    pub fn setReplyLease(
        self: *MiniNat,
        reserve: ReplyReserve,
        commit: ReplyCommit,
    ) void {
        assert(self.reply_reserve == null);
        assert(self.reply_commit == null);
        self.reply_reserve = reserve;
        self.reply_commit = commit;
    }

    const ReplyBuffer = struct {
        frame: []u8,
        token: ?usize,
    };

    fn acquireReply(self: *MiniNat, fallback: []u8, frame_len: usize) ?ReplyBuffer {
        assert(frame_len > 0);
        assert(fallback.len >= frame_len);
        if (self.reply_reserve) |reserve| {
            const lease = reserve.call(frame_len) orelse return null;
            assert(lease.frame.len == frame_len);
            return .{ .frame = lease.frame, .token = lease.token };
        }
        assert(self.reply_commit == null);
        return .{ .frame = fallback[0..frame_len], .token = null };
    }

    fn commitReply(self: *MiniNat, buffer: ReplyBuffer) void {
        assert(buffer.frame.len > 0);
        assert((buffer.token == null) == (self.reply_commit == null));
        if (buffer.token) |token| {
            self.reply_commit.?.call(.{ .frame = buffer.frame, .token = token });
            return;
        }
        self.reply.call(buffer.frame);
    }

    fn initTcpSendPool(self: *MiniNat) std.mem.Allocator.Error!void {
        assert(self.tcp_send_pool.len == 0);
        assert(self.tcp_send_free_count == 0);
        self.tcp_send_pool = try self.alloc.alloc(u8, TCP_FLOW_MAX * SND_BUF_MAX);
        errdefer self.tcp_send_pool = &.{};
        for (&self.tcp_send_free, 0..) |*slot, index| slot.* = @intCast(index);
        self.tcp_send_free_count = TCP_FLOW_MAX;
    }

    fn deinitTcpSendPool(self: *MiniNat) void {
        assert(self.tcp_send_free_count <= TCP_FLOW_MAX);
        assert(self.tcp_send_pool.len == 0 or
            self.tcp_send_pool.len == TCP_FLOW_MAX * SND_BUF_MAX);
        if (self.tcp_send_pool.len > 0) {
            assert(self.tcp_send_free_count == TCP_FLOW_MAX);
            self.alloc.free(self.tcp_send_pool);
        }
        self.tcp_send_pool = &.{};
        self.tcp_send_free_count = 0;
    }

    fn createTcpSendBuffer(self: *MiniNat) std.mem.Allocator.Error!TcpSendBuffer {
        assert(self.tcp_send_free_count <= TCP_FLOW_MAX);
        assert(self.tcp_send_pool.len == 0 or
            self.tcp_send_pool.len == TCP_FLOW_MAX * SND_BUF_MAX);
        if (self.tcp_send_pool.len == 0) return TcpSendBuffer.init(self.alloc);
        if (self.tcp_send_free_count == 0) return error.OutOfMemory;
        self.tcp_send_free_count -= 1;
        const index = self.tcp_send_free[self.tcp_send_free_count];
        const offset = @as(usize, index) * SND_BUF_MAX;
        return TcpSendBuffer.initPooled(
            self.tcp_send_pool[offset..][0..SND_BUF_MAX],
            index,
        );
    }

    fn releaseTcpSendBuffer(self: *MiniNat, buffer: *TcpSendBuffer) void {
        assert(self.tcp_send_free_count <= TCP_FLOW_MAX);
        assert(buffer.storage.len == SND_BUF_MAX);
        if (buffer.pool_index) |index| {
            assert(index < TCP_FLOW_MAX);
            const offset = @as(usize, index) * SND_BUF_MAX;
            assert(buffer.storage.ptr == self.tcp_send_pool[offset..].ptr);
            assert(self.tcp_send_free_count < TCP_FLOW_MAX);
            self.tcp_send_free[self.tcp_send_free_count] = index;
            self.tcp_send_free_count += 1;
            buffer.* = .{};
            return;
        }
        buffer.deinit(self.alloc);
    }

    fn reserveFlowTables(self: *MiniNat) std.mem.Allocator.Error!void {
        assert(self.udp_flows.count() == 0);
        assert(self.tcp_flows.count() == 0);
        assert(self.icmp_flows.count() == 0);
        try self.udp_flows.ensureTotalCapacity(UDP_FLOW_MAX);
        try self.tcp_flows.ensureTotalCapacity(TCP_FLOW_MAX);
        try self.icmp_flows.ensureTotalCapacity(ICMP_FLOW_MAX);
    }

    /// Set the RX back-pressure predicate (see rx_ready).
    pub fn setRxReady(self: *MiniNat, rx_ready: RxReady) void {
        self.rx_ready = rx_ready;
    }

    /// Add a host→guest port forward: connections accepted on the host's
    /// TCP host_port are proxied to the guest's guest_port. Must be called
    /// before start().
    pub fn addForward(self: *MiniNat, fwd: Forward) !void {
        const sock = try net_compat.socketCreate(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer net_compat.socketClose(sock);
        net_compat.setReuseAddr(sock);
        var addr = std.posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, fwd.host_port),
            .addr = 0, // INADDR_ANY
        };
        try net_compat.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
        try net_compat.listen(sock, 8);
        try self.listeners.append(self.alloc, .{
            .socket = sock,
            .guest_port = fwd.guest_port,
            .host_port = fwd.host_port,
        });
        log.info("forwarding host tcp/{} -> guest tcp/{}", .{ fwd.host_port, fwd.guest_port });
    }

    /// Start the reply-poll thread (forwards socket replies to the guest).
    pub fn start(self: *MiniNat) !void {
        try self.initTcpSendPool();
        errdefer self.deinitTcpSendPool();
        try self.reserveFlowTables();
        self.running.store(true, .release);
        errdefer self.running.store(false, .release);
        self.poll_thread = try std.Thread.spawn(.{ .stack_size = stack_size_bytes }, pollLoop, .{self});
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
        while (titer.next()) |flow| {
            net_compat.socketClose(flow.socket);
            self.releaseTcpSendBuffer(&flow.snd_buf);
        }
        self.tcp_flows.deinit();
        var iiter = self.icmp_flows.valueIterator();
        while (iiter.next()) |flow| net_compat.socketClose(flow.socket);
        self.icmp_flows.deinit();
        for (self.listeners.items) |l| net_compat.socketClose(l.socket);
        self.listeners.deinit(self.alloc);
        self.deinitTcpSendPool();
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

        var fallback: [ETH_HDR + 28]u8 = undefined;
        const reply_buffer = self.acquireReply(&fallback, fallback.len) orelse return;
        const out = reply_buffer.frame;
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

        self.commitReply(reply_buffer);
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

        if (self.udp_flows.count() >= UDP_FLOW_MAX and !self.udp_flows.contains(key)) return;
        const gop = self.udp_flows.getOrPut(key) catch return;
        if (!gop.found_existing) {
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

        if (self.icmp_flows.count() >= ICMP_FLOW_MAX and !self.icmp_flows.contains(key)) return;
        const gop = self.icmp_flows.getOrPut(key) catch return;
        if (!gop.found_existing) {
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
            if (self.pumpAccept()) delivered = true;
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
        const now_ns = nowNanos();
        var remove_key: ?TcpKey = null;

        // Back-pressure: if the guest RX queue is backed up, don't pull
        // more host data this pass (connect completion and close still
        // proceed). Leaves data in the host socket → real sender throttles.
        const rx_ok = if (self.rx_ready) |rx_ready| rx_ready.call() else true;

        var iter = self.tcp_flows.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const flow = entry.value_ptr;

            // Established inbound (forwarded) flows are exempt from idle
            // reaping: a quiet SSH session is legitimate idle, and reaping
            // it used to wedge the guest side silently. Their accepted
            // sockets carry SO_KEEPALIVE, so a vanished host peer still
            // surfaces as a socket error and is reaped through the recv
            // path below.
            const idle = now - flow.last_used > TCP_IDLE_TIMEOUT_S;
            const idle_exempt = flow.state == .established and isInbound(key);
            if (flow.state == .closed or (idle and !idle_exempt)) {
                // On idle expiry the guest still believes the connection
                // is alive — RST it so it learns immediately instead of
                // keeping a half-dead flow around.
                if (flow.state != .closed) self.tcpSendRst(key, flow.rcv_nxt);
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

            // Inbound handshake in flight: no data relay until the guest's
            // SYN-ACK arrives (handleTcp flips the state to established).
            if (flow.state == .syn_to_guest) continue;

            // (1) Retransmit the oldest unacked segment if its timer fired.
            // A single frame, well under the hard RX cap, so it goes even
            // when rx_ok is false — retransmission must always make progress.
            if (flow.snd_buf.len > 0 and flow.rt_deadline_ns != 0 and now_ns >= flow.rt_deadline_ns) {
                const payload = flow.snd_buf.prefixParts(TCP_MSS);
                self.tcpSendParts(
                    key,
                    flow.snd_una,
                    flow.rcv_nxt,
                    TCP_PSH | TCP_ACK,
                    payload.first,
                    payload.second,
                );
                flow.rto_ns = @min(flow.rto_ns * 2, MAX_RTO_NS);
                flow.rt_deadline_ns = now_ns + flow.rto_ns;
                flow.last_used = now;
                work = true;
            }

            // (2) Send new host data, bounded by the guest's advertised
            // receive window AND our send buffer — this is the flow control
            // whose absence let bulk downloads overrun the guest and stall.
            // Skip when the RX ring is backed up (no drop: the data stays in
            // the host socket, so the real sender is throttled).
            const in_flight = flow.snd_nxt -% flow.snd_una;
            const eff_wnd: u32 = @min(@max(flow.snd_wnd, @as(u32, 1)), @as(u32, SND_BUF_MAX));
            const buffered: u32 = @intCast(flow.snd_buf.len);
            if (rx_ok and !flow.host_eof and in_flight < eff_wnd and buffered < SND_BUF_MAX) {
                const window_room = eff_wnd - in_flight;
                const buf_room: u32 = @intCast(SND_BUF_MAX - flow.snd_buf.len);
                const want: usize = @min(@min(@as(u32, TCP_MSS), window_room), buf_room);
                const n = net_compat.recv(flow.socket, buf[0..want], 0) catch |e| {
                    if (e != error.WouldBlock) {
                        self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_RST | TCP_ACK, &.{});
                        remove_key = key;
                    }
                    continue;
                };
                if (n == 0) {
                    // Host EOF: stop reading, drain snd_buf, then FIN below.
                    flow.host_eof = true;
                } else {
                    if (!flow.snd_buf.append(buf[0..n])) continue;
                    self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_PSH | TCP_ACK, buf[0..n]);
                    flow.snd_nxt +%= @intCast(n);
                    if (flow.rt_deadline_ns == 0) flow.rt_deadline_ns = now_ns + flow.rto_ns;
                    flow.last_used = now;
                    work = true;
                }
            }

            // (3) Host closed and everything acked → FIN, then drop the flow.
            if (flow.host_eof and flow.snd_buf.len == 0 and flow.snd_una == flow.snd_nxt) {
                self.tcpSend(key, flow.snd_nxt, flow.rcv_nxt, TCP_FIN | TCP_ACK, &.{});
                flow.snd_nxt +%= 1;
                remove_key = key;
                continue;
            }
        }

        if (remove_key) |key| {
            if (self.tcp_flows.fetchRemove(key)) |entry| {
                var v = entry.value;
                net_compat.socketClose(v.socket);
                self.releaseTcpSendBuffer(&v.snd_buf);
            }
        }
        return work;
    }

    /// Accept pending connections on forward listeners and open the
    /// guest-side handshake: the guest sees a SYN from GATEWAY_IP with an
    /// ephemeral source port. Caller holds flows_mutex.
    fn pumpAccept(self: *MiniNat) bool {
        var work = false;
        for (self.listeners.items) |l| {
            while (true) {
                const sock = net_compat.accept(l.socket) catch break;
                if (self.tcp_flows.count() >= TCP_FLOW_MAX) {
                    net_compat.socketClose(sock);
                    break;
                }
                // Inbound flows never idle-reap once established (see
                // pumpTcp); kernel keepalive is what eventually detects a
                // peer that vanished without closing.
                net_compat.setKeepAlive(sock);
                const key = self.allocInboundKey(l.guest_port) orelse {
                    net_compat.socketClose(sock);
                    break;
                };
                var flow = TcpFlow{
                    .socket = sock,
                    .state = .syn_to_guest,
                    .snd_nxt = 0x2000,
                    .snd_una = 0x2000,
                    .rcv_nxt = 0, // learned from the guest's SYN-ACK
                    .last_used = nowSeconds(),
                };
                flow.snd_buf = self.createTcpSendBuffer() catch {
                    net_compat.socketClose(sock);
                    break;
                };
                self.tcp_flows.put(key, flow) catch {
                    self.releaseTcpSendBuffer(&flow.snd_buf);
                    net_compat.socketClose(sock);
                    break;
                };
                self.tcpSend(key, 0x2000, 0, TCP_SYN, &.{});
                self.tcp_flows.getPtr(key).?.snd_nxt +%= 1; // SYN consumes a seq
                work = true;
            }
        }
        return work;
    }

    /// Inbound (port-forward) flows are keyed to the gateway address:
    /// allocInboundKey() builds them that way, and guest-initiated SYNs
    /// to on-net addresses are never opened (handleTcp), so no outbound
    /// flow can ever carry it.
    fn isInbound(key: TcpKey) bool {
        return std.mem.eql(u8, &key.remote_ip, &GATEWAY_IP);
    }

    /// Pick an unused (guest_port, GATEWAY_IP, ephemeral) key for an
    /// inbound flow. Caller holds flows_mutex.
    fn allocInboundKey(self: *MiniNat, guest_port: u16) ?TcpKey {
        var attempts: u32 = 0;
        while (attempts < 16384) : (attempts += 1) {
            const port = self.next_inbound_port;
            self.next_inbound_port = if (port == 65535) 49152 else port + 1;
            const key = TcpKey{
                .guest_port = guest_port,
                .remote_ip = GATEWAY_IP,
                .remote_port = port,
            };
            if (!self.tcp_flows.contains(key)) return key;
        }
        return null;
    }

    /// Build remote → guest UDP frame.
    fn replyUdp(self: *MiniNat, key: UdpKey, payload: []const u8) void {
        const total = ETH_HDR + 20 + 8 + payload.len;
        var fallback: [2048 + 42]u8 = undefined;
        if (total > fallback.len) return;
        const reply_buffer = self.acquireReply(&fallback, total) orelse return;
        const out = reply_buffer.frame;

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

        self.commitReply(reply_buffer);
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

        const total = ETH_HDR + 20 + icmp_msg.len;
        var fallback: [2048 + 42]u8 = undefined;
        if (total > fallback.len) return;
        const reply_buffer = self.acquireReply(&fallback, total) orelse return;
        const out = reply_buffer.frame;

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

        self.commitReply(reply_buffer);
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
        // On-net destinations are never proxied outbound — but replies on
        // inbound (port-forwarded) flows are addressed to GATEWAY_IP, so
        // they must still reach the flow lookup below.
        const on_net = std.mem.eql(u8, dst_ip[0..3], GATEWAY_IP[0..3]);

        const tcp = frame[tcp_off..];
        const src_port = std.mem.readInt(u16, tcp[0..2], .big);
        const dst_port = std.mem.readInt(u16, tcp[2..4], .big);
        const seq = std.mem.readInt(u32, tcp[4..8], .big);
        const ack = std.mem.readInt(u32, tcp[8..12], .big);
        const data_off: usize = @as(usize, (tcp[12] >> 4)) * 4;
        const flags = tcp[13];
        const wnd: u32 = std.mem.readInt(u16, tcp[14..16], .big);
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
            if (!on_net) self.tcpOpen(key, seq);
            return;
        }

        const flow = self.tcp_flows.getPtr(key) orelse {
            // Unknown connection: RST it so the guest gives up quickly.
            // (Not for on-net packets — the gateway itself runs no
            // services; silence matches the old drop behavior.)
            if (!on_net and flags & TCP_RST == 0) {
                self.tcpSendRst(key, seq + @as(u32, @intCast(payload.len)));
            }
            return;
        };
        flow.last_used = nowSeconds();

        if (flags & TCP_RST != 0) {
            net_compat.socketClose(flow.socket);
            if (self.tcp_flows.fetchRemove(key)) |entry| {
                var v = entry.value;
                self.releaseTcpSendBuffer(&v.snd_buf);
            }
            return;
        }

        // Inbound flow: the guest's SYN-ACK completes the handshake.
        if (flow.state == .syn_to_guest) {
            if (flags & TCP_SYN != 0 and flags & TCP_ACK != 0) {
                flow.rcv_nxt = seq +% 1; // guest SYN consumes a seq
                flow.snd_wnd = @max(wnd, 1);
                flow.state = .established;
                self.tcpSendAck(key, flow);
            }
            return;
        }

        // Process the guest's acknowledgement of host→guest data: free
        // acked bytes from the retransmit buffer and track the guest's
        // advertised receive window (the flow control we must honor).
        if (flags & TCP_ACK != 0) self.processGuestAck(key, flow, ack, wnd);

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

    /// Apply a guest ACK to a flow's host→guest send state: retire acked
    /// bytes from the retransmit buffer, track the advertised window, and
    /// fast-retransmit on the third duplicate ACK. Caller holds flows_mutex.
    fn processGuestAck(self: *MiniNat, key: TcpKey, flow: *TcpFlow, ack: u32, wnd: u32) void {
        flow.snd_wnd = @max(wnd, 1);
        const outstanding = flow.snd_nxt -% flow.snd_una;
        const acked = ack -% flow.snd_una;

        if (acked == 0) {
            // Duplicate ACK: three in a row ⇒ retransmit immediately rather
            // than waiting for the RTO (fast retransmit).
            if (outstanding > 0) {
                flow.dup_acks +%= 1;
                if (flow.dup_acks >= 3 and flow.snd_buf.len > 0) {
                    const payload = flow.snd_buf.prefixParts(TCP_MSS);
                    self.tcpSendParts(
                        key,
                        flow.snd_una,
                        flow.rcv_nxt,
                        TCP_PSH | TCP_ACK,
                        payload.first,
                        payload.second,
                    );
                    flow.rt_deadline_ns = nowNanos() + flow.rto_ns;
                    flow.dup_acks = 0;
                }
            }
            return;
        }
        // Ignore acks for data we never sent (stale or wrapped).
        if (acked > outstanding) return;

        // New data acknowledged — drop it from the front of the buffer.
        const drop = @min(@as(usize, acked), flow.snd_buf.len);
        if (drop > 0) flow.snd_buf.consume(drop);
        flow.snd_una = ack;
        flow.dup_acks = 0;
        flow.rto_ns = INITIAL_RTO_NS; // forward progress resets the backoff
        flow.rt_deadline_ns = if (flow.snd_una == flow.snd_nxt) 0 else nowNanos() + flow.rto_ns;
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
        var flow = TcpFlow{
            .socket = sock,
            .state = .connecting,
            .snd_nxt = 0x1000,
            .snd_una = 0x1000,
            .rcv_nxt = guest_seq +% 1, // SYN consumes a sequence number
            .last_used = nowSeconds(),
        };
        flow.snd_buf = self.createTcpSendBuffer() catch {
            net_compat.socketClose(sock);
            return;
        };
        self.tcp_flows.put(key, flow) catch {
            self.releaseTcpSendBuffer(&flow.snd_buf);
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
    fn tcpSend(
        self: *MiniNat,
        key: TcpKey,
        seq: u32,
        ack: u32,
        flags: u8,
        payload: []const u8,
    ) void {
        assert(payload.len <= TCP_MSS);
        assert(payload.len <= std.math.maxInt(u16));
        self.tcpSendParts(key, seq, ack, flags, payload, &.{});
    }

    fn tcpSendParts(
        self: *MiniNat,
        key: TcpKey,
        seq: u32,
        ack: u32,
        flags: u8,
        payload_first: []const u8,
        payload_second: []const u8,
    ) void {
        assert(payload_first.len <= TCP_MSS);
        assert(payload_second.len <= TCP_MSS - payload_first.len);
        const payload_len = payload_first.len + payload_second.len;
        const total = ETH_HDR + 20 + 20 + payload_len;
        var fallback: [ETH_HDR + 20 + 20 + TCP_MSS]u8 = undefined;
        const reply_buffer = self.acquireReply(&fallback, total) orelse return;
        const out = reply_buffer.frame;

        @memcpy(out[0..6], &[_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 });
        @memcpy(out[6..12], &GATEWAY_MAC);
        std.mem.writeInt(u16, out[12..14], ETHERTYPE_IP, .big);

        const ip = out[ETH_HDR..];
        @memset(ip[0..20], 0);
        ip[0] = 0x45;
        std.mem.writeInt(u16, ip[2..4], @intCast(20 + 20 + payload_len), .big);
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
        @memcpy(tcp[20..][0..payload_first.len], payload_first);
        @memcpy(tcp[20 + payload_first.len ..][0..payload_second.len], payload_second);
        std.mem.writeInt(
            u16,
            tcp[16..18],
            tcpChecksum(key.remote_ip, GUEST_IP, tcp[0 .. 20 + payload_len]),
            .big,
        );

        self.commitReply(reply_buffer);
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
        sum += sumBE(segment);
        return fold(sum);
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
        var fallback: [1600]u8 = undefined;
        if (frame.len > fallback.len) return;
        const reply_buffer = self.acquireReply(&fallback, frame.len) orelse return;
        const out = reply_buffer.frame;
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

        self.commitReply(reply_buffer);
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

        const bootp_len: usize = 300;
        const total = ETH_HDR + 20 + 8 + bootp_len;
        assert(bootp_len >= 240);
        assert(total <= 590);
        var fallback: [590]u8 = undefined;
        const reply_buffer = self.acquireReply(&fallback, total) orelse return;
        const out = reply_buffer.frame;
        @memset(out, 0);

        const xid = bootp[4..8];
        const chaddr = bootp[28..44];

        // BOOTP reply
        const b = out[ETH_HDR + 28 .. total];
        b[0] = 2; // BOOTREPLY
        b[1] = 1; // ethernet
        b[2] = 6; // hlen
        @memcpy(b[4..8], xid);
        @memcpy(b[16..20], &GUEST_IP); // yiaddr
        @memcpy(b[20..24], &GATEWAY_IP); // siaddr
        @memcpy(b[28..44], chaddr);
        @memcpy(b[236..240], &[_]u8{ 0x63, 0x82, 0x53, 0x63 });
        var o: usize = 240;
        o = putOpt(b, o, 53, &.{reply_type});
        o = putOpt(b, o, 54, &GATEWAY_IP); // server id
        o = putOpt(b, o, 51, &.{ 0, 1, 0x51, 0x80 }); // lease 86400s
        o = putOpt(b, o, 1, &NETMASK);
        o = putOpt(b, o, 3, &GATEWAY_IP); // router
        o = putOpt(b, o, 6, &DNS_IP); // dns
        b[o] = 0xFF;
        o += 1;
        assert(o <= bootp_len);

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

        self.commitReply(reply_buffer);
    }

    fn putOpt(buf: []u8, offset: usize, opt: u8, data: []const u8) usize {
        buf[offset] = opt;
        buf[offset + 1] = @intCast(data.len);
        @memcpy(buf[offset + 2 ..][0..data.len], data);
        return offset + 2 + data.len;
    }

    /// RFC 1071 Internet checksum.
    fn checksum(data: []const u8) u16 {
        return fold(sumBE(data));
    }

    /// Ones-complement fold of an unfolded accumulator into the final 16-bit
    /// Internet checksum: wrap the carries back in, then invert.
    fn fold(acc: u32) u16 {
        var sum = acc;
        while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        return @truncate(~sum);
    }

    /// Sum of the big-endian 16-bit words in `data` (RFC 1071), returned
    /// *unfolded* so callers can add pseudo-header terms before folding.
    ///
    /// A big-endian word at an even offset weights its high byte by 256 and
    /// its low byte by 1, so the whole word sum is
    /// `256*Σ(even-offset bytes) + Σ(odd-offset bytes)`. That decomposition
    /// lets us widen and add a full vector of bytes each iteration, then split
    /// the even/odd lanes once at the end — the classic SIMD shape (broadcast,
    /// wide loop, reduce, scalar remainder). Bytes are ≤255 and real frames are
    /// ≤64 KiB, so the u32 lanes never overflow.
    fn sumBE(data: []const u8) u32 {
        // Byte-wide vector. The even/odd lane split and the scalar-remainder
        // parity argument both require an even lane count; real vector widths
        // are powers of two, but guard it so a future odd width fails loudly.
        const lanes = comptime std.simd.suggestVectorLength(u8) orelse 16;
        comptime if (lanes % 2 != 0) @compileError("sumBE requires an even vector width");
        const Bytes = @Vector(lanes, u8);
        const Wide = @Vector(lanes, u32);
        const even_mask: Wide = comptime blk: {
            var m: [lanes]u32 = undefined;
            for (&m, 0..) |*x, k| x.* = if (k % 2 == 0) 1 else 0;
            break :blk m;
        };

        var acc: Wide = @splat(0);
        var i: usize = 0;
        while (i + lanes <= data.len) : (i += lanes) {
            const chunk: Bytes = data[i..][0..lanes].*;
            acc += @as(Wide, chunk); // widen u8 -> u32, add every lane at once
        }

        // Reduce: total = Σ all bytes, even = Σ even-offset bytes.
        // 256*Σeven + Σodd == total + 255*Σeven.
        const total: u32 = @reduce(.Add, acc);
        const even: u32 = @reduce(.Add, acc * even_mask);
        var sum: u32 = total + 255 * even;

        // Scalar remainder. `i` is a multiple of `lanes` (even), so the tail
        // offsets keep the same even/odd parity as the whole buffer.
        while (i + 1 < data.len) : (i += 2) {
            sum += (@as(u32, data[i]) << 8) | data[i + 1];
        }
        if (i < data.len) sum += @as(u32, data[i]) << 8;
        return sum;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

var test_replies: std.ArrayListUnmanaged([]u8) = .empty;
var test_alloc: std.mem.Allocator = undefined;
var test_reply_lease: [2048 + 42]u8 = undefined;
var test_reply_lease_len: usize = 0;
var test_reply_lease_committed: bool = false;

fn testReply(frame: []const u8, _: ?*anyopaque) void {
    const copy = test_alloc.dupe(u8, frame) catch return;
    test_replies.append(test_alloc, copy) catch {};
}

fn testReplyReserve(frame_len: usize, userdata: ?*anyopaque) ?ReplyLease {
    assert(userdata == null);
    assert(frame_len > 0);
    if (frame_len > test_reply_lease.len) return null;
    return .{ .frame = test_reply_lease[0..frame_len], .token = 42 };
}

fn testReplyCommit(lease: ReplyLease, userdata: ?*anyopaque) void {
    assert(userdata == null);
    assert(lease.token == 42);
    assert(lease.frame.ptr == test_reply_lease[0..].ptr);
    test_reply_lease_len = lease.frame.len;
    test_reply_lease_committed = true;
}

fn clearReplies() void {
    for (test_replies.items) |r| test_alloc.free(r);
    test_replies.deinit(test_alloc);
    test_replies = .empty;
}

test "mininat: ARP request for gateway gets a reply" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    nat.setReplyLease(ReplyReserve.initRaw(testReplyReserve, null), ReplyCommit.initRaw(testReplyCommit, null));
    test_reply_lease_len = 0;
    test_reply_lease_committed = false;
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
    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
    try testing.expect(test_reply_lease_committed);
    try testing.expectEqual(@as(usize, ETH_HDR + 28), test_reply_lease_len);
    const rep = test_reply_lease[0..test_reply_lease_len];
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, rep[20..22], .big)); // ARP reply
    try testing.expect(std.mem.eql(u8, rep[22..28], &GATEWAY_MAC)); // sender hw
}

test "mininat: UDP reply is built directly in leased RX storage" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    nat.setReplyLease(ReplyReserve.initRaw(testReplyReserve, null), ReplyCommit.initRaw(testReplyCommit, null));
    test_reply_lease_len = 0;
    test_reply_lease_committed = false;
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }

    var payload: [1400]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index);
    const key = UdpKey{
        .guest_port = 49152,
        .remote_ip = .{ 1, 1, 1, 1 },
        .remote_port = 53,
    };
    nat.replyUdp(key, &payload);

    const total = ETH_HDR + 20 + 8 + payload.len;
    try testing.expect(test_reply_lease_committed);
    try testing.expectEqual(total, test_reply_lease_len);
    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
    try testing.expectEqualSlices(u8, &payload, test_reply_lease[ETH_HDR + 28 .. total]);
}

test "mininat: DHCP DISCOVER gets an OFFER with our lease" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    nat.setReplyLease(ReplyReserve.initRaw(testReplyReserve, null), ReplyCommit.initRaw(testReplyCommit, null));
    test_reply_lease_len = 0;
    test_reply_lease_committed = false;
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
    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
    try testing.expect(test_reply_lease_committed);
    try testing.expectEqual(@as(usize, ETH_HDR + 20 + 8 + 300), test_reply_lease_len);
    const rep = test_reply_lease[0..test_reply_lease_len];
    const rbootp = rep[ETH_HDR + 28 ..];
    try testing.expectEqual(@as(u8, 2), rbootp[0]); // BOOTREPLY
    try testing.expect(std.mem.eql(u8, rbootp[16..20], &GUEST_IP)); // yiaddr
    try testing.expectEqual(@as(u8, 2), rbootp[242]); // OFFER
    try testing.expectEqual(@as(u16, 0), MiniNat.checksum(rep[ETH_HDR .. ETH_HDR + 20]));
}

test "mininat: ICMP echo to gateway gets a reply" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    nat.setReplyLease(ReplyReserve.initRaw(testReplyReserve, null), ReplyCommit.initRaw(testReplyCommit, null));
    test_reply_lease_len = 0;
    test_reply_lease_committed = false;
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
    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
    try testing.expect(test_reply_lease_committed);
    try testing.expectEqual(req.len, test_reply_lease_len);
    const rep = test_reply_lease[0..test_reply_lease_len];
    try testing.expectEqual(@as(u8, 0), rep[ETH_HDR + 20]); // echo reply
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 12 ..][0..4], &GATEWAY_IP));
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 16 ..][0..4], &GUEST_IP));
    try testing.expectEqual(@as(u16, 0), MiniNat.checksum(rep[ETH_HDR .. ETH_HDR + 20]));
    try testing.expectEqual(@as(u16, 0), MiniNat.checksum(rep[ETH_HDR + 20 ..]));
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
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    nat.setReplyLease(ReplyReserve.initRaw(testReplyReserve, null), ReplyCommit.initRaw(testReplyCommit, null));
    test_reply_lease_len = 0;
    test_reply_lease_committed = false;
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

    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
    try testing.expect(test_reply_lease_committed);
    try testing.expectEqual(@as(usize, ETH_HDR + 20 + 13), test_reply_lease_len);
    const rep = test_reply_lease[0..test_reply_lease_len];
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 12 ..][0..4], &remote_ip));
    try testing.expect(std.mem.eql(u8, rep[ETH_HDR + 16 ..][0..4], &GUEST_IP));
    const rep_icmp = rep[ETH_HDR + 20 ..];
    try testing.expectEqual(@as(u8, 0), rep_icmp[0]); // echo reply
    // id/seq are stamped with the guest's originals, not the kernel's.
    try testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, rep_icmp[4..6], .big));
    try testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, rep_icmp[6..8], .big));
    try testing.expect(std.mem.eql(u8, rep_icmp[8..13], "hello"));
}

test "mininat: SIMD checksum matches a scalar reference at every length/parity" {
    // Straight, unvectorized RFC 1071 sum — the oracle the SIMD path must equal.
    const ref = struct {
        fn sum(data: []const u8) u16 {
            var s: u32 = 0;
            var i: usize = 0;
            while (i + 1 < data.len) : (i += 2) {
                s += (@as(u32, data[i]) << 8) | data[i + 1];
            }
            if (i < data.len) s += @as(u32, data[i]) << 8;
            while (s >> 16 != 0) s = (s & 0xFFFF) + (s >> 16);
            return @truncate(~s);
        }
    }.sum;

    var buf: [600]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i * 131 + 7); // varied, non-trivial

    // Sweep lengths across the vector boundary and both parities, and vary the
    // start offset so lane alignment differs run to run.
    for (0..buf.len) |len| {
        for ([_]usize{ 0, 1, 3 }) |off| {
            if (off + len > buf.len) continue;
            const slice = buf[off .. off + len];
            try testing.expectEqual(ref(slice), MiniNat.checksum(slice));
        }
    }
}

test "mininat: checksum of a known IPv4 header is correct" {
    // Canonical RFC-1071 worked example (checksum field zeroed).
    var hdr = [_]u8{
        0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00,
        0x40, 0x11, 0x00, 0x00, 0xc0, 0xa8, 0x00, 0x01,
        0xc0, 0xa8, 0x00, 0xc7,
    };
    try testing.expectEqual(@as(u16, 0xb861), MiniNat.checksum(&hdr));
    // Writing the checksum back in makes the header sum to zero (checks to 0xffff).
    std.mem.writeInt(u16, hdr[10..12], 0xb861, .big);
    try testing.expectEqual(@as(u16, 0), MiniNat.checksum(&hdr));
}

fn buildGuestTcpFrame(
    buf: *[54 + 64]u8,
    guest_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    payload: []const u8,
) []const u8 {
    const total = 54 + payload.len;
    @memset(buf[0..total], 0);
    @memcpy(buf[0..6], &GATEWAY_MAC);
    @memcpy(buf[6..12], &[_]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 });
    std.mem.writeInt(u16, buf[12..14], ETHERTYPE_IP, .big);
    const ip = buf[14..];
    ip[0] = 0x45;
    std.mem.writeInt(u16, ip[2..4], @intCast(40 + payload.len), .big);
    ip[9] = 6; // TCP
    @memcpy(ip[12..16], &GUEST_IP);
    @memcpy(ip[16..20], &GATEWAY_IP);
    const tcp = buf[34..];
    std.mem.writeInt(u16, tcp[0..2], guest_port, .big);
    std.mem.writeInt(u16, tcp[2..4], dst_port, .big);
    std.mem.writeInt(u32, tcp[4..8], seq, .big);
    std.mem.writeInt(u32, tcp[8..12], ack, .big);
    tcp[12] = 5 << 4;
    tcp[13] = flags;
    @memcpy(tcp[20..][0..payload.len], payload);
    return buf[0..total];
}

test "mininat: port forward — accept, handshake, and guest->host relay" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    defer {
        var titer = nat.tcp_flows.valueIterator();
        while (titer.next()) |flow| {
            net_compat.socketClose(flow.socket);
            flow.deinit(testing.allocator);
        }
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
        for (nat.listeners.items) |l| net_compat.socketClose(l.socket);
        nat.listeners.deinit(testing.allocator);
    }

    // Listener on an ephemeral host port (0 = kernel-assigned).
    try nat.addForward(.{ .host_port = 0, .guest_port = 22 });
    var sa: std.posix.sockaddr.in = undefined;
    var sa_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    try testing.expect(std.c.getsockname(nat.listeners.items[0].socket, @ptrCast(&sa), &sa_len) == 0);

    // A blocking loopback client connects (lands in the backlog).
    const client = try net_compat.socketCreate(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer net_compat.socketClose(client);
    var dst = std.posix.sockaddr.in{
        .port = sa.port,
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };
    try net_compat.connect(client, @ptrCast(&dst), @sizeOf(std.posix.sockaddr.in));

    // Accept: a SYN to the guest's port 22 from the gateway must go out.
    // Retry briefly — on Darwin the client's connect() can return a moment
    // before the connection lands in the listener's accept queue.
    var accepted = false;
    var tries: u32 = 0;
    while (!accepted and tries < 200) : (tries += 1) {
        nat.flows_mutex.lockUncancelable(global.io());
        accepted = nat.pumpAccept();
        nat.flows_mutex.unlock(global.io());
        if (!accepted) {
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = 5 * std.time.ns_per_ms },
                .clock = .awake,
            }, global.io()) catch {};
        }
    }
    try testing.expect(accepted);
    try testing.expectEqual(@as(usize, 1), nat.tcp_flows.count());
    try testing.expectEqual(@as(usize, 1), test_replies.items.len);
    const syn = test_replies.items[0];
    try testing.expectEqual(@as(u16, 22), std.mem.readInt(u16, syn[36..38], .big)); // dst = guest port
    try testing.expectEqual(MiniNat.TCP_SYN, syn[47]); // flags: SYN only
    const eph_port = std.mem.readInt(u16, syn[34..36], .big);

    // Guest answers SYN-ACK: flow must establish and we must ACK.
    var fbuf: [54 + 64]u8 = undefined;
    const synack = buildGuestTcpFrame(&fbuf, 22, eph_port, 777, 0x2001, MiniNat.TCP_SYN | MiniNat.TCP_ACK, &.{});
    nat.handleFrame(synack);
    const key = TcpKey{ .guest_port = 22, .remote_ip = GATEWAY_IP, .remote_port = eph_port };
    const flow = nat.tcp_flows.getPtr(key).?;
    try testing.expectEqual(TcpState.established, flow.state);
    try testing.expectEqual(@as(u32, 778), flow.rcv_nxt);
    try testing.expectEqual(@as(usize, 2), test_replies.items.len);
    const ackf = test_replies.items[1];
    try testing.expectEqual(MiniNat.TCP_ACK, ackf[47]);
    try testing.expectEqual(@as(u32, 778), std.mem.readInt(u32, ackf[42..46], .big));

    // Guest payload is relayed to the host client socket.
    const data = buildGuestTcpFrame(&fbuf, 22, eph_port, 778, 0x2001, MiniNat.TCP_PSH | MiniNat.TCP_ACK, "hello");
    nat.handleFrame(data);
    var rx: [16]u8 = undefined;
    const n = try net_compat.recv(client, &rx, 0);
    try testing.expectEqualStrings("hello", rx[0..n]);
}

test "mininat: idle outbound flow is reaped with an RST to the guest" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
        nat.listeners.deinit(testing.allocator);
    }

    const key = TcpKey{ .guest_port = 1234, .remote_ip = .{ 93, 184, 216, 34 }, .remote_port = 80 };
    var flow = TcpFlow{
        .socket = @as(std.posix.socket_t, -1), // reap closes it; EBADF is ignored
        .state = .established,
        .snd_nxt = 1000,
        .snd_una = 1000,
        .rcv_nxt = 5000,
        .last_used = 0, // long past TCP_IDLE_TIMEOUT_S
    };
    flow.snd_buf = try TcpSendBuffer.init(testing.allocator);
    try nat.tcp_flows.put(key, flow);

    var scratch: [2048]u8 = undefined;
    nat.flows_mutex.lockUncancelable(global.io());
    _ = nat.pumpTcp(&scratch);
    nat.flows_mutex.unlock(global.io());

    // Flow gone, and the guest was told: the reap used to be silent,
    // leaving the guest with a wedged half-dead connection.
    try testing.expectEqual(@as(usize, 0), nat.tcp_flows.count());
    try testing.expectEqual(@as(usize, 1), test_replies.items.len);
    const rst = test_replies.items[0];
    try testing.expectEqual(MiniNat.TCP_RST | MiniNat.TCP_ACK, rst[47]);
    try testing.expectEqual(@as(u32, 5000), std.mem.readInt(u32, rst[42..46], .big));
}

test "mininat: established inbound flow is exempt from idle reaping" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    defer {
        var titer = nat.tcp_flows.valueIterator();
        while (titer.next()) |f| f.deinit(testing.allocator);
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
        nat.listeners.deinit(testing.allocator);
    }

    // Inbound = keyed to the gateway (how allocInboundKey builds them).
    // The send window is exactly full so the pump's relay stage doesn't
    // touch the placeholder socket; only the reap logic is under test.
    const key = TcpKey{ .guest_port = 22, .remote_ip = GATEWAY_IP, .remote_port = 49200 };
    var flow = TcpFlow{
        .socket = @as(std.posix.socket_t, -1),
        .state = .established,
        .snd_nxt = 0x2000 +% 65535,
        .snd_una = 0x2000,
        .rcv_nxt = 900,
        .last_used = 0, // long past TCP_IDLE_TIMEOUT_S
    };
    flow.snd_buf = try TcpSendBuffer.init(testing.allocator);
    try nat.tcp_flows.put(key, flow);

    var scratch: [2048]u8 = undefined;
    nat.flows_mutex.lockUncancelable(global.io());
    _ = nat.pumpTcp(&scratch);
    nat.flows_mutex.unlock(global.io());

    // Still alive, nothing sent: an idle forwarded SSH session survives.
    try testing.expectEqual(@as(usize, 1), nat.tcp_flows.count());
    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
}

test "mininat: inbound flow stuck in handshake still idle-reaps" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
        nat.listeners.deinit(testing.allocator);
    }

    // A guest that never answers the synthetic SYN must not leak flows;
    // only *established* inbound flows are exempt.
    const key = TcpKey{ .guest_port = 22, .remote_ip = GATEWAY_IP, .remote_port = 49201 };
    var flow = TcpFlow{
        .socket = @as(std.posix.socket_t, -1),
        .state = .syn_to_guest,
        .snd_nxt = 0x2001,
        .snd_una = 0x2000,
        .rcv_nxt = 0,
        .last_used = 0, // long past TCP_IDLE_TIMEOUT_S
    };
    flow.snd_buf = try TcpSendBuffer.init(testing.allocator);
    try nat.tcp_flows.put(key, flow);

    var scratch: [2048]u8 = undefined;
    nat.flows_mutex.lockUncancelable(global.io());
    _ = nat.pumpTcp(&scratch);
    nat.flows_mutex.unlock(global.io());

    try testing.expectEqual(@as(usize, 0), nat.tcp_flows.count());
    try testing.expectEqual(@as(usize, 1), test_replies.items.len);
    try testing.expectEqual(MiniNat.TCP_RST | MiniNat.TCP_ACK, test_replies.items[0][47]);
}

test "mininat: guest ACK retires the send buffer, tracks window, fast-retransmits" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    nat.setReplyLease(ReplyReserve.initRaw(testReplyReserve, null), ReplyCommit.initRaw(testReplyCommit, null));
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
        nat.listeners.deinit(testing.allocator);
    }

    const key = TcpKey{ .guest_port = 1234, .remote_ip = .{ 93, 184, 216, 34 }, .remote_port = 80 };
    var flow = TcpFlow{
        .socket = @as(std.posix.socket_t, -1), // never touched: we don't recv here
        .state = .established,
        .snd_nxt = 1000,
        .snd_una = 1000,
        .rcv_nxt = 5000,
        .last_used = 0,
    };
    flow.snd_buf = try TcpSendBuffer.init(testing.allocator);
    defer flow.deinit(testing.allocator);

    // Pretend we've sent 3000 unacked bytes to the guest.
    var initial_payload: [3000]u8 = @splat(0xAB);
    try testing.expect(flow.snd_buf.append(&initial_payload));
    flow.snd_nxt = 1000 + 3000;
    flow.rt_deadline_ns = 1;

    // Partial ACK of 1000 bytes: buffer trims, snd_una advances, window tracked,
    // timer stays armed (data still outstanding).
    nat.processGuestAck(key, &flow, 2000, 32768);
    try testing.expectEqual(@as(u32, 2000), flow.snd_una);
    try testing.expectEqual(@as(usize, 2000), flow.snd_buf.len);
    try testing.expectEqual(@as(u32, 32768), flow.snd_wnd);
    try testing.expect(flow.rt_deadline_ns != 0);

    // Full ACK: buffer empties and the retransmit timer disarms.
    nat.processGuestAck(key, &flow, 4000, 65535);
    try testing.expectEqual(@as(u32, 4000), flow.snd_una);
    try testing.expectEqual(@as(usize, 0), flow.snd_buf.len);
    try testing.expectEqual(@as(i64, 0), flow.rt_deadline_ns);

    // Send a fresh segment, then three duplicate ACKs ⇒ one fast retransmit
    // of the oldest unacked byte (seq == snd_una), without waiting for the RTO.
    var fresh_payload: [1400]u8 = @splat(0xCD);
    try testing.expect(flow.snd_buf.append(&fresh_payload));
    flow.snd_nxt = 4000 + 1400;
    flow.rt_deadline_ns = std.math.maxInt(i64); // far future: only a dup-ack can trigger
    clearReplies();
    test_reply_lease_len = 0;
    test_reply_lease_committed = false;
    nat.processGuestAck(key, &flow, 4000, 65535); // dup 1
    nat.processGuestAck(key, &flow, 4000, 65535); // dup 2
    try testing.expectEqual(@as(usize, 0), test_replies.items.len); // not yet
    nat.processGuestAck(key, &flow, 4000, 65535); // dup 3 ⇒ retransmit
    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
    try testing.expect(test_reply_lease_committed);
    try testing.expectEqual(@as(usize, 54 + fresh_payload.len), test_reply_lease_len);
    const seg = test_reply_lease[0..test_reply_lease_len];
    try testing.expectEqual(@as(u32, 4000), std.mem.readInt(u32, seg[38..42], .big)); // seq
    try testing.expectEqual(MiniNat.TCP_PSH | MiniNat.TCP_ACK, seg[47]); // flags
    try testing.expectEqualSlices(u8, &fresh_payload, seg[54..]);
    try testing.expectEqual(@as(u16, 0), MiniNat.checksum(seg[14..34]));
    try testing.expectEqual(@as(u16, 0), MiniNat.tcpChecksum(key.remote_ip, GUEST_IP, seg[34..]));
    try testing.expectEqual(@as(u8, 0), flow.dup_acks); // counter reset after retransmit
}

test "TcpSendBuffer sends wrapped retransmit without scratch copy" {
    test_alloc = testing.allocator;
    defer clearReplies();
    var nat = MiniNat.init(testing.allocator, Reply.initRaw(testReply, null));
    nat.setReplyLease(ReplyReserve.initRaw(testReplyReserve, null), ReplyCommit.initRaw(testReplyCommit, null));
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }

    var buffer = try TcpSendBuffer.init(testing.allocator);
    defer buffer.deinit(testing.allocator);

    var initial: [SND_BUF_MAX]u8 = undefined;
    for (&initial, 0..) |*byte, i| byte.* = @truncate(i);
    try testing.expect(buffer.append(&initial));
    buffer.consume(65_000);

    var appended: [1000]u8 = undefined;
    for (&appended, 0..) |*byte, i| byte.* = @truncate(i + 17);
    try testing.expect(buffer.append(&appended));

    const prefix = buffer.prefixParts(MiniNat.TCP_MSS);
    try testing.expectEqual(@as(usize, 1535), buffer.len);
    try testing.expectEqual(@as(usize, 535), prefix.first.len);
    try testing.expectEqual(@as(usize, 865), prefix.second.len);
    try testing.expectEqual(buffer.storage[65_000..].ptr, prefix.first.ptr);
    try testing.expectEqual(buffer.storage.ptr, prefix.second.ptr);

    test_reply_lease_len = 0;
    test_reply_lease_committed = false;
    const key = TcpKey{
        .guest_port = 1234,
        .remote_ip = .{ 93, 184, 216, 34 },
        .remote_port = 80,
    };
    nat.tcpSendParts(
        key,
        4000,
        5000,
        MiniNat.TCP_PSH | MiniNat.TCP_ACK,
        prefix.first,
        prefix.second,
    );

    try testing.expectEqual(@as(usize, 0), test_replies.items.len);
    try testing.expect(test_reply_lease_committed);
    try testing.expectEqual(@as(usize, 54 + MiniNat.TCP_MSS), test_reply_lease_len);
    const payload = test_reply_lease[54..test_reply_lease_len];
    try testing.expectEqualSlices(u8, initial[65_000..], payload[0..535]);
    try testing.expectEqualSlices(u8, appended[0..865], payload[535..]);
    try testing.expectEqual(
        @as(u16, 0),
        MiniNat.tcpChecksum(key.remote_ip, GUEST_IP, test_reply_lease[34..test_reply_lease_len]),
    );
}

test "TcpSendBuffer allocation profile" {
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    var buffer = try TcpSendBuffer.init(counted.allocator());
    defer buffer.deinit(counted.allocator());

    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(SND_BUF_MAX, counted.allocated_bytes);
}

test "MiniNat TCP send slab checks out and recycles without allocation" {
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    var nat = MiniNat.init(counted.allocator(), Reply.initRaw(testReply, null));
    defer {
        nat.deinitTcpSendPool();
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }
    try nat.initTcpSendPool();

    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(MiniNat.TCP_FLOW_MAX * SND_BUF_MAX, counted.allocated_bytes);
    var first = try nat.createTcpSendBuffer();
    var second = try nat.createTcpSendBuffer();
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expect(first.pool_index != second.pool_index);

    const recycled_index = first.pool_index.?;
    nat.releaseTcpSendBuffer(&first);
    var recycled = try nat.createTcpSendBuffer();
    try testing.expectEqual(recycled_index, recycled.pool_index.?);
    nat.releaseTcpSendBuffer(&recycled);
    nat.releaseTcpSendBuffer(&second);
    try testing.expectEqual(@as(u16, MiniNat.TCP_FLOW_MAX), nat.tcp_send_free_count);

    var all: [MiniNat.TCP_FLOW_MAX]TcpSendBuffer = undefined;
    for (&all) |*buffer| buffer.* = try nat.createTcpSendBuffer();
    try testing.expectEqual(@as(u16, 0), nat.tcp_send_free_count);
    try testing.expectError(error.OutOfMemory, nat.createTcpSendBuffer());
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    for (&all) |*buffer| nat.releaseTcpSendBuffer(buffer);
    try testing.expectEqual(@as(u16, MiniNat.TCP_FLOW_MAX), nat.tcp_send_free_count);
}

test "MiniNat first flow-table inserts allocation profile" {
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    var nat = MiniNat.init(counted.allocator(), Reply.initRaw(testReply, null));
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }

    try nat.udp_flows.put(.{ .guest_port = 1, .remote_ip = .{ 1, 1, 1, 1 }, .remote_port = 2 }, .{
        .socket = -1,
        .last_used = 0,
    });
    try nat.tcp_flows.put(.{ .guest_port = 3, .remote_ip = .{ 2, 2, 2, 2 }, .remote_port = 4 }, .{
        .socket = -1,
        .state = .established,
        .snd_nxt = 0,
        .rcv_nxt = 0,
        .last_used = 0,
    });
    try nat.icmp_flows.put(.{ .remote_ip = .{ 3, 3, 3, 3 }, .id = 5 }, .{
        .socket = -1,
        .last_used = 0,
    });

    try testing.expectEqual(@as(usize, 3), counted.allocations);
    try testing.expectEqual(@as(usize, 1232), counted.allocated_bytes);
}

test "MiniNat reserved flow tables fill without allocation" {
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    var nat = MiniNat.init(counted.allocator(), Reply.initRaw(testReply, null));
    defer {
        nat.udp_flows.deinit();
        nat.tcp_flows.deinit();
        nat.icmp_flows.deinit();
    }
    try nat.reserveFlowTables();
    const allocations = counted.allocations;
    const allocated_bytes = counted.allocated_bytes;

    for (0..MiniNat.UDP_FLOW_MAX) |index| {
        const port: u16 = @intCast(index);
        const udp_key = UdpKey{
            .guest_port = port,
            .remote_ip = .{ 1, 1, 1, 1 },
            .remote_port = 1,
        };
        try nat.udp_flows.put(udp_key, .{
            .socket = -1,
            .last_used = 0,
        });
        const tcp_key = TcpKey{
            .guest_port = port,
            .remote_ip = .{ 2, 2, 2, 2 },
            .remote_port = 2,
        };
        try nat.tcp_flows.put(tcp_key, .{
            .socket = -1,
            .state = .established,
            .snd_nxt = 0,
            .rcv_nxt = 0,
            .last_used = 0,
        });
        try nat.icmp_flows.put(.{ .remote_ip = .{ 3, 3, 3, 3 }, .id = port }, .{
            .socket = -1,
            .last_used = 0,
        });
    }

    try testing.expectEqual(@as(usize, 3), allocations);
    try testing.expectEqual(@as(usize, 74_312), allocated_bytes);
    try testing.expectEqual(allocations, counted.allocations);
    try testing.expectEqual(allocated_bytes, counted.allocated_bytes);
    try testing.expectEqual(MiniNat.UDP_FLOW_MAX, nat.udp_flows.count());
    try testing.expectEqual(MiniNat.TCP_FLOW_MAX, nat.tcp_flows.count());
    try testing.expectEqual(MiniNat.ICMP_FLOW_MAX, nat.icmp_flows.count());

    nat.forwardUdp(60_000, .{ 4, 4, 4, 4 }, 53, "full");
    nat.forwardIcmp(.{ 5, 5, 5, 5 }, 60_000, 1, "full");
    try testing.expectEqual(allocations, counted.allocations);
    try testing.expectEqual(MiniNat.UDP_FLOW_MAX, nat.udp_flows.count());
    try testing.expectEqual(MiniNat.ICMP_FLOW_MAX, nat.icmp_flows.count());
}
