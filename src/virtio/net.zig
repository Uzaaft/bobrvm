//! Virtio Network Device.
//!
//! Implements virtio-net per virtio 1.2 section 5.1 over guest-memory
//! virtqueues. Frames go to/come from a pluggable backend (built-in
//! NAT responder today, vmnet.framework later).
//!
//! Queues:
//!   0: receiveq (host → guest frames)
//!   1: transmitq (guest → host frames)
//!
//! No offload features are negotiated, so every buffer starts with the
//! 12-byte virtio_net_hdr followed by a raw Ethernet frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");

const log = std.log.scoped(.virtio_net);

/// Net feature bits.
pub const Features = struct {
    /// Device provides a MAC address in config space.
    pub const MAC: u64 = 1 << 5;
};

/// virtio_net_hdr with VIRTIO_F_VERSION_1 (12 bytes, no offloads).
pub const NetHeader = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    num_buffers: u16 = 1,
};

/// Net config space.
pub const Config = extern struct {
    mac: [6]u8,
    status: u16 = 0,
    max_virtqueue_pairs: u16 = 1,
    mtu: u16 = 1500,
};

/// Frame sink for guest → host traffic. The frame is borrowed only for the
/// callback duration. The callback may run on the vCPU thread; backends queue
/// replies via queueRxFrame.
pub const TxCallback = *const fn (frame: []const u8, userdata: ?*anyopaque) void;

const RxFrame = struct {
    storage_index: u16,
    len: u32,
};

const RxStorage = struct {
    ptr: ?[*]u8,
    capacity: u32,
    next_free: u16,

    fn bytes(self: RxStorage) []u8 {
        assert(self.ptr != null);
        assert(self.capacity > 0);
        return self.ptr.?[0..self.capacity];
    }
};

const rx_index_none: u16 = std.math.maxInt(u16);

/// Network device.
pub const Net = struct {
    alloc: Allocator,
    transport: *mmio.Transport,
    config: Config,

    /// Shadow avail-ring cursors.
    rx_last_avail: u16,
    tx_last_avail: u16,

    /// Frames waiting for guest RX buffers. Guarded by rx_mutex: backend
    /// threads append, the vCPU thread drains via pollRx.
    rx_frames: [MAX_RX_QUEUED]RxFrame,
    rx_storage: [MAX_RX_QUEUED]RxStorage,
    rx_head: usize,
    rx_count: usize,
    rx_free_head: u16,
    rx_mutex: std.Io.Mutex,

    /// Guest memory accessor.
    guest_memory: ?ring.GetMemFn,

    /// Guest → host frame sink.
    tx_callback: ?TxCallback,
    tx_userdata: ?*anyopaque,

    pub const Error = Allocator.Error;
    pub const QUEUE_SIZE: u16 = 256;
    pub const MAX_FRAME: usize = 65550;
    pub const MAX_RX_QUEUED: usize = 1024;
    pub const RX_BUFFER_SIZE: usize = 2048;
    /// Back-pressure threshold: a frame source (e.g. the NAT TCP relay)
    /// should stop producing while the queue is at/above this, so it never
    /// overflows and drops — dropping a TCP segment in a proxy with no
    /// retransmit stalls the connection permanently.
    pub const RX_BACKPRESSURE: usize = 768;

    /// Default guest MAC (locally administered).
    pub const GUEST_MAC = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

    pub fn init(alloc: Allocator) Error!*Net {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        const features = Features.MAC | virtio_version_1;
        const transport = try mmio.Transport.init(alloc, 1, features, 2); // 1 = net device ID
        errdefer transport.deinit(alloc);

        const net = try alloc.create(Net);
        net.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = .{ .mac = GUEST_MAC },
            .rx_last_avail = 0,
            .tx_last_avail = 0,
            .rx_frames = undefined,
            .rx_storage = undefined,
            .rx_head = 0,
            .rx_count = 0,
            .rx_free_head = 0,
            .rx_mutex = .init,
            .guest_memory = null,
            .tx_callback = null,
            .tx_userdata = null,
        };
        for (&net.rx_storage, 0..) |*storage, index| {
            storage.* = .{
                .ptr = null,
                .capacity = 0,
                .next_free = if (index + 1 < MAX_RX_QUEUED)
                    @intCast(index + 1)
                else
                    rx_index_none,
            };
        }

        transport.setNotifyCallback(handleNotify, net);

        assert(net.transport.device_id == 1);
        assert(@sizeOf(RxFrame) == 8);
        assert(@sizeOf(RxStorage) == 16);

        return net;
    }

    pub fn deinit(self: *Net) void {
        for (&self.rx_storage) |*storage| {
            if (storage.ptr != null) self.alloc.free(storage.bytes());
        }
        self.transport.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn setGuestMemory(self: *Net, accessor: ring.GetMemFn) void {
        self.guest_memory = accessor;
    }

    pub fn setTxCallback(self: *Net, callback: TxCallback, userdata: ?*anyopaque) void {
        self.tx_callback = callback;
        self.tx_userdata = userdata;
    }

    /// Queue a frame for delivery to the guest. Thread-safe; the frame
    /// is copied. Drops when the queue is full (like a real NIC).
    pub fn queueRxFrame(self: *Net, frame: []const u8) void {
        if (frame.len == 0 or frame.len > MAX_FRAME) return;

        self.rx_mutex.lockUncancelable(global.io());
        defer self.rx_mutex.unlock(global.io());
        if (self.rx_count >= self.rx_frames.len) return;

        const storage_index = self.takeRxStorage(frame.len) orelse return;
        const storage = self.rx_storage[storage_index].bytes();
        @memcpy(storage[0..frame.len], frame);
        const tail = (self.rx_head + self.rx_count) % self.rx_frames.len;
        self.rx_frames[tail] = .{
            .storage_index = storage_index,
            .len = @intCast(frame.len),
        };
        self.rx_count += 1;
    }

    /// True while the RX queue has headroom. Frame producers should stop
    /// (leaving data in their own buffers) when this is false, so the
    /// queue never overflows. Thread-safe.
    pub fn rxReady(self: *Net) bool {
        self.rx_mutex.lockUncancelable(global.io());
        defer self.rx_mutex.unlock(global.io());
        return self.rx_count < RX_BACKPRESSURE;
    }

    // =========================================================================
    // MMIO Interface
    // =========================================================================

    pub fn read(self: *Net, offset: u12) u32 {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    pub fn write(self: *Net, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return; // config is read-only
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Net, offset: u12) u32 {
        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        // MAC is read with byte/short granularity by some drivers; serve
        // partial tail reads as zero-extended.
        if (offset < config_bytes.len) {
            var value: u32 = 0;
            var i: u12 = 0;
            while (offset + i < config_bytes.len and i < 4) : (i += 1) {
                value |= @as(u32, config_bytes[offset + i]) << @intCast(8 * i);
            }
            return value;
        }
        return 0;
    }

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Net = @ptrCast(@alignCast(userdata));
        switch (queue_idx) {
            0 => self.processRx(),
            1 => self.processTx(),
            else => {},
        }
    }

    /// Poll both directions. Called from the vCPU loop.
    pub fn poll(self: *Net) void {
        self.processTx();
        self.processRx();
    }

    // =========================================================================
    // TX: guest → host
    // =========================================================================

    fn processTx(self: *Net) void {
        const qc = self.transport.queues[1];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        while (self.tx_last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.tx_last_avail, get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);

            self.transmitChain(&chain, get_mem);
            ring.pushUsed(qc, head, 0, get_mem);
            self.tx_last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Gather one TX chain (skipping the 12-byte header) and hand the
    /// frame to the backend.
    fn transmitChain(self: *Net, chain: *const ring.Chain, get_mem: ring.GetMemFn) void {
        if (chain.count == 1) {
            const desc = chain.descs[0];
            if (!desc.isWrite() and desc.len > @sizeOf(NetHeader) and
                desc.len <= @sizeOf(NetHeader) + MAX_FRAME)
            {
                const mem = get_mem(desc.addr, desc.len) orelse return;
                const frame = mem[@sizeOf(NetHeader)..];
                assert(frame.len > 0);
                assert(frame.len <= MAX_FRAME);
                if (self.tx_callback) |cb| cb(frame, self.tx_userdata);
                return;
            }
        }

        var frame_buf: [MAX_FRAME]u8 = undefined;
        var frame_len: usize = 0;
        var skip: usize = @sizeOf(NetHeader);

        for (chain.slice()) |desc| {
            if (desc.isWrite()) continue;
            const mem = get_mem(desc.addr, desc.len) orelse return;
            var data: []const u8 = mem;
            if (skip > 0) {
                const n = @min(skip, data.len);
                data = data[n..];
                skip -= n;
            }
            const room = frame_buf.len - frame_len;
            const n = @min(room, data.len);
            @memcpy(frame_buf[frame_len..][0..n], data[0..n]);
            frame_len += n;
        }

        if (frame_len == 0) return;
        if (self.tx_callback) |cb| {
            cb(frame_buf[0..frame_len], self.tx_userdata);
        }
    }

    // =========================================================================
    // RX: host → guest
    // =========================================================================

    fn processRx(self: *Net) void {
        const qc = self.transport.queues[0];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        self.rx_mutex.lockUncancelable(global.io());
        defer self.rx_mutex.unlock(global.io());
        if (self.rx_count == 0) return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var last_avail = self.rx_last_avail;
        var delivered: usize = 0;

        while (last_avail != avail_idx and delivered < self.rx_count) {
            const head = ring.availEntry(qc, last_avail, get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);
            const frame_index = (self.rx_head + delivered) % self.rx_frames.len;
            const queued = self.rx_frames[frame_index];
            const storage = self.rx_storage[queued.storage_index].bytes();
            const frame = storage[0..queued.len];

            const written = deliverFrame(&chain, frame, get_mem) orelse break;
            ring.pushUsed(qc, head, written, get_mem);

            delivered += 1;
            last_avail +%= 1;
        }

        self.rx_last_avail = last_avail;
        if (delivered > 0) {
            for (0..delivered) |_| self.releaseRxFrame();
            self.transport.signalUsedBuffer();
        }
    }

    fn takeRxStorage(self: *Net, frame_len: usize) ?u16 {
        assert(frame_len > 0);
        assert(frame_len <= MAX_FRAME);
        assert(self.rx_free_head != rx_index_none);

        var previous = rx_index_none;
        var index = self.rx_free_head;
        while (index != rx_index_none) {
            const storage = &self.rx_storage[index];
            if (storage.capacity >= frame_len) {
                self.removeFreeStorage(previous, index);
                return index;
            }
            previous = index;
            index = storage.next_free;
        }

        index = self.rx_free_head;
        const storage = &self.rx_storage[index];
        self.removeFreeStorage(rx_index_none, index);
        const replacement = self.alloc.alloc(u8, @max(frame_len, RX_BUFFER_SIZE)) catch {
            storage.next_free = self.rx_free_head;
            self.rx_free_head = index;
            return null;
        };
        if (storage.ptr != null) self.alloc.free(storage.bytes());
        storage.ptr = replacement.ptr;
        storage.capacity = @intCast(replacement.len);
        return index;
    }

    fn removeFreeStorage(self: *Net, previous: u16, index: u16) void {
        assert(index != rx_index_none);
        assert(index < self.rx_storage.len);
        if (previous == rx_index_none) {
            self.rx_free_head = self.rx_storage[index].next_free;
        } else {
            assert(previous < self.rx_storage.len);
            self.rx_storage[previous].next_free = self.rx_storage[index].next_free;
        }
        self.rx_storage[index].next_free = rx_index_none;
    }

    fn releaseRxFrame(self: *Net) void {
        assert(self.rx_count > 0);
        const storage_index = self.rx_frames[self.rx_head].storage_index;
        assert(storage_index < self.rx_storage.len);
        assert(self.rx_storage[storage_index].next_free == rx_index_none);
        self.rx_storage[storage_index].next_free = self.rx_free_head;
        self.rx_free_head = storage_index;
        self.rx_head = (self.rx_head + 1) % self.rx_frames.len;
        self.rx_count -= 1;
    }

    fn releaseQueuedFrames(self: *Net) void {
        assert(self.rx_count <= self.rx_frames.len);
        while (self.rx_count > 0) self.releaseRxFrame();
        self.rx_head = 0;
    }

    fn queuedFrame(self: *const Net, frame_index: usize) []const u8 {
        assert(frame_index < self.rx_frames.len);
        const frame = self.rx_frames[frame_index];
        const storage = self.rx_storage[frame.storage_index].bytes();
        assert(frame.len > 0);
        assert(frame.len <= storage.len);
        return storage[0..frame.len];
    }

    /// Scatter header + frame into a writable RX chain; returns bytes
    /// written or null when the chain is unusable.
    fn deliverFrame(chain: *const ring.Chain, frame: []const u8, get_mem: ring.GetMemFn) ?u32 {
        const header = NetHeader{};
        const header_bytes = std.mem.asBytes(&header);

        var written: u32 = 0;
        var src_stage: usize = 0; // bytes consumed across header+frame
        const total = header_bytes.len + frame.len;

        for (chain.slice()) |desc| {
            if (!desc.isWrite()) continue;
            const mem = get_mem(desc.addr, desc.len) orelse return null;
            var dst = mem;
            while (dst.len > 0 and src_stage < total) {
                if (src_stage < header_bytes.len) {
                    const n = @min(dst.len, header_bytes.len - src_stage);
                    @memcpy(dst[0..n], header_bytes[src_stage..][0..n]);
                    dst = dst[n..];
                    src_stage += n;
                    written += @intCast(n);
                } else {
                    const off = src_stage - header_bytes.len;
                    const n = @min(dst.len, frame.len - off);
                    @memcpy(dst[0..n], frame[off..][0..n]);
                    dst = dst[n..];
                    src_stage += n;
                    written += @intCast(n);
                }
            }
            if (src_stage >= total) break;
        }

        if (src_stage < total) return null; // frame didn't fit
        return written;
    }

    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Net init" {
    const net = try Net.init(testing.allocator);
    defer net.deinit();

    try testing.expectEqual(@as(u32, 1), net.read(@intFromEnum(mmio.Reg.device_id)));
    // MAC low bytes in config
    const mac0 = net.read(@intFromEnum(mmio.Reg.config));
    try testing.expectEqual(@as(u32, 0x00005452), mac0 & 0x00FFFFFF);
}

test "NetHeader size" {
    try testing.expectEqual(@as(usize, 12), @sizeOf(NetHeader));
}

test "Net queues and drops rx frames at capacity" {
    const net = try Net.init(testing.allocator);
    defer net.deinit();

    var i: usize = 0;
    while (i < Net.MAX_RX_QUEUED + 10) : (i += 1) {
        net.queueRxFrame(&[_]u8{ 1, 2, 3, 4 });
    }
    try testing.expectEqual(Net.MAX_RX_QUEUED, net.rx_count);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, net.queuedFrame(net.rx_head));
}

test "Net recycles normal RX buffers" {
    const net = try Net.init(testing.allocator);
    defer net.deinit();

    var frame: [1514]u8 = @splat(0xA5);
    net.queueRxFrame(&frame);
    const storage_index = net.rx_frames[net.rx_head].storage_index;
    const storage = net.rx_storage[storage_index].ptr;
    net.releaseQueuedFrames();
    net.queueRxFrame(&frame);
    const recycled_index = net.rx_frames[net.rx_head].storage_index;
    try testing.expectEqual(storage, net.rx_storage[recycled_index].ptr);
}

var test_tx_memory: [1514]u8 = @splat(0xA5);
var test_tx_frame: ?[]const u8 = null;

fn testTxGetMem(addr: u64, len: usize) ?[]u8 {
    if (addr != 0x1000 or len > test_tx_memory.len) return null;
    return test_tx_memory[0..len];
}

fn testTxCallback(frame: []const u8, _: ?*anyopaque) void {
    test_tx_frame = frame;
}

test "Net sends a contiguous TX payload without copying" {
    const net = try Net.init(testing.allocator);
    defer net.deinit();
    net.setTxCallback(testTxCallback, null);

    var chain: ring.Chain = .{};
    chain.descs[0] = .{ .addr = 0x1000, .len = test_tx_memory.len, .flags = 0, .next = 0 };
    chain.count = 1;

    test_tx_frame = null;
    net.transmitChain(&chain, testTxGetMem);
    const frame = test_tx_frame.?;
    try testing.expectEqual(test_tx_memory.len - @sizeOf(NetHeader), frame.len);
    try testing.expectEqual(@intFromPtr(&test_tx_memory) + @sizeOf(NetHeader), @intFromPtr(frame.ptr));
}
