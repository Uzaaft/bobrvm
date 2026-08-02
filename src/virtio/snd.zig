//! Virtio Sound Device (virtio-snd).
//!
//! Implements virtio-snd per virtio 1.2 spec section 5.14, processing
//! descriptor chains directly from guest memory. Output-only for now: the
//! device enumerates one PCM output stream (plus a jack and a stereo channel
//! map) over the control queue, and consumes guest PCM period buffers on the
//! tx queue, forwarding the decoded bytes to a pluggable PlaybackSink.
//!
//! Queues:
//!   0: controlq (jack/pcm/chmap info + PCM stream lifecycle)
//!   1: eventq   (advertised, idle — no async events emitted)
//!   2: txq      (guest -> host PCM frames)
//!   3: rxq      (advertised, idle — capture not implemented)
//!
//! Audio output is deliberately decoupled from any real audio backend: the
//! device hands each period's PCM bytes to `sink.on_period`, if set. Unit
//! tests capture into a buffer; a host CoreAudio/AVAudioEngine backend can be
//! wired behind the same callback later (see CoreAudioSink stub below).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");

const log = std.log.scoped(.virtio_snd);

// Queue indices.
const CONTROLQ: u32 = 0;
const EVENTQ: u32 = 1;
const TXQ: u32 = 2;
const RXQ: u32 = 3;
const NUM_QUEUES: u8 = 4;

// Control request codes (virtio_snd_hdr.code).
pub const R_JACK_INFO: u32 = 1;
pub const R_JACK_REMAP: u32 = 2;
pub const R_PCM_INFO: u32 = 0x0100;
pub const R_PCM_SET_PARAMS: u32 = 0x0101;
pub const R_PCM_PREPARE: u32 = 0x0102;
pub const R_PCM_RELEASE: u32 = 0x0103;
pub const R_PCM_START: u32 = 0x0104;
pub const R_PCM_STOP: u32 = 0x0105;
pub const R_CHMAP_INFO: u32 = 0x0200;

// Status codes (virtio_snd_hdr.code in responses).
pub const S_OK: u32 = 0x8000;
pub const S_BAD_MSG: u32 = 0x8001;
pub const S_NOT_SUPP: u32 = 0x8002;
pub const S_IO_ERR: u32 = 0x8003;

// PCM stream directions.
pub const D_OUTPUT: u8 = 0;
pub const D_INPUT: u8 = 1;

// PCM sample formats (bit positions in virtio_snd_pcm_info.formats).
pub const FMT_S16: u8 = 5;

// PCM frame rates (bit positions in virtio_snd_pcm_info.rates).
pub const RATE_44100: u8 = 6;
pub const RATE_48000: u8 = 7;

// Channel map positions (virtio_snd_chmap_info.positions).
pub const CHMAP_NONE: u8 = 0;
pub const CHMAP_FL: u8 = 3;
pub const CHMAP_FR: u8 = 4;
pub const CHMAP_MAX_SIZE: usize = 18;

/// virtio_snd_config: device configuration space.
pub const Config = extern struct {
    jacks: u32 = 1,
    streams: u32 = 1,
    chmaps: u32 = 1,
};

/// virtio_snd_hdr: common request/response header.
pub const Hdr = extern struct {
    code: u32,
};

/// virtio_snd_query_info: the request body for every *_INFO command.
pub const QueryInfo = extern struct {
    hdr: Hdr,
    start_id: u32,
    count: u32,
    size: u32,
};

/// virtio_snd_info: common info-struct header.
pub const Info = extern struct {
    hda_fn_nid: u32 = 0,
};

/// virtio_snd_pcm_info: one PCM stream's capabilities (32 bytes).
pub const PcmInfo = extern struct {
    hdr: Info = .{},
    features: u32 = 0,
    formats: u64 = 0,
    rates: u64 = 0,
    direction: u8 = 0,
    channels_min: u8 = 0,
    channels_max: u8 = 0,
    padding: [5]u8 = .{ 0, 0, 0, 0, 0 },
};

/// virtio_snd_jack_info: one jack's capabilities (24 bytes).
pub const JackInfo = extern struct {
    hdr: Info = .{},
    features: u32 = 0,
    hda_reg_defconf: u32 = 0,
    hda_reg_caps: u32 = 0,
    connected: u8 = 0,
    padding: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
};

/// virtio_snd_chmap_info: one channel map (24 bytes).
pub const ChmapInfo = extern struct {
    hdr: Info = .{},
    direction: u8 = 0,
    channels: u8 = 0,
    positions: [CHMAP_MAX_SIZE]u8 = [_]u8{0} ** CHMAP_MAX_SIZE,
};

/// virtio_snd_pcm_hdr: request header referencing a specific stream.
pub const PcmHdr = extern struct {
    hdr: Hdr,
    stream_id: u32,
};

/// virtio_snd_pcm_set_params: PCM_SET_PARAMS request body (24 bytes).
pub const SetParams = extern struct {
    hdr: PcmHdr,
    buffer_bytes: u32,
    period_bytes: u32,
    features: u32,
    channels: u8,
    format: u8,
    rate: u8,
    padding: u8,
};

/// virtio_snd_pcm_xfer: leading header of a tx/rx period buffer.
pub const PcmXfer = extern struct {
    stream_id: u32,
};

/// virtio_snd_pcm_status: trailing status of a tx/rx period buffer.
pub const PcmStatus = extern struct {
    status: u32,
    latency_bytes: u32,
};

comptime {
    // Wire sizes must match the spec exactly (LE extern layout).
    assert(@sizeOf(PcmInfo) == 32);
    assert(@sizeOf(JackInfo) == 24);
    assert(@sizeOf(ChmapInfo) == 24);
    assert(@sizeOf(SetParams) == 24);
    assert(@sizeOf(PcmStatus) == 8);
}

/// Pluggable playback backend. The device forwards each PCM period's decoded
/// bytes to `on_period`; a null callback is a silent sink (the protocol still
/// completes correctly). This keeps the device unit-testable with no real
/// audio hardware dependency.
pub const PlaybackSink = struct {
    on_period: ?*const fn (data: []const u8, userdata: ?*anyopaque) void = null,
    userdata: ?*anyopaque = null,
};

/// TODO: a real host playback sink. Wire an AVAudioEngine/CoreAudio output
/// node here and feed `on_period` bytes into its ring buffer. Left as a stub
/// so the device compiles and tests run without any audio device present.
pub const CoreAudioSink = struct {
    pub fn sink(_: *CoreAudioSink) PlaybackSink {
        // Not yet implemented: acts as a silent sink.
        return .{};
    }
};

/// Per-stream negotiated parameters + lifecycle state.
const Stream = struct {
    const State = enum { unset, params_set, prepared, running, stopped, released };

    buffer_bytes: u32 = 0,
    period_bytes: u32 = 0,
    channels: u8 = 2,
    format: u8 = FMT_S16,
    rate: u8 = RATE_48000,
    state: State = .unset,
};

pub const Snd = struct {
    alloc: Allocator,
    transport: *mmio.Transport,
    config: Config,

    /// Shadow avail-ring cursors for the queues we service.
    ctrl_last_avail: u16,
    tx_last_avail: u16,

    /// One PCM output stream (stream id 0).
    streams: [1]Stream,

    /// Playback backend (silent by default).
    sink: PlaybackSink,

    /// Guest memory accessor.
    guest_memory: ?ring.GetMemFn,

    pub const Error = Allocator.Error;

    pub fn init(alloc: Allocator) Error!*Snd {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio.
        const virtio_version_1: u64 = 1 << 32;
        const transport = try mmio.Transport.init(alloc, 25, virtio_version_1, NUM_QUEUES); // 25 = sound
        errdefer transport.deinit(alloc);

        const snd = try alloc.create(Snd);
        snd.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = .{ .jacks = 1, .streams = 1, .chmaps = 1 },
            .ctrl_last_avail = 0,
            .tx_last_avail = 0,
            .streams = .{.{}},
            .sink = .{},
            .guest_memory = null,
        };

        transport.setNotifyCallback(handleNotify, snd);

        assert(snd.transport.device_id == 25);
        return snd;
    }

    pub fn deinit(self: *Snd) void {
        self.transport.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(self: *Snd, accessor: ring.GetMemFn) void {
        self.guest_memory = accessor;
    }

    /// Set the playback backend (defaults to a silent sink).
    pub fn setSink(self: *Snd, sink: PlaybackSink) void {
        self.sink = sink;
    }

    // =========================================================================
    // MMIO Interface
    // =========================================================================

    pub fn read(self: *Snd, offset: u12) u32 {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    pub fn write(self: *Snd, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            // Config space is entirely read-only for virtio-snd.
            return;
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Snd, offset: u12) u32 {
        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        return 0;
    }

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Snd = @ptrCast(@alignCast(userdata));
        switch (queue_idx) {
            CONTROLQ => self.processControlQueue(),
            TXQ => self.processTxQueue(),
            // eventq/rxq are advertised but idle for an output-only device.
            else => {},
        }
    }

    // =========================================================================
    // Control queue
    // =========================================================================

    fn processControlQueue(self: *Snd) void {
        const qc = self.transport.queues[CONTROLQ];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        while (self.ctrl_last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.ctrl_last_avail, get_mem) orelse break;
            const written = self.processControlCommand(qc, head, get_mem);
            ring.pushUsed(qc, head, written, get_mem);
            self.ctrl_last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Execute one control command chain; returns bytes written to the
    /// response (device-writable) descriptor.
    fn processControlCommand(self: *Snd, qc: mmio.QueueConfig, head: u16, get_mem: ring.GetMemFn) u32 {
        const chain = ring.Chain.collect(qc, head, get_mem);
        const req = chain.request(get_mem) orelse return 0;
        const resp = chain.response(get_mem) orelse return 0;
        if (req.len < @sizeOf(Hdr) or resp.len < @sizeOf(Hdr)) return 0;

        const code = std.mem.readInt(u32, req[0..4], .little);
        return switch (code) {
            R_JACK_INFO => self.cmdQueryInfo(req, resp, self.config.jacks, JackInfo, makeJackInfo),
            R_PCM_INFO => self.cmdQueryInfo(req, resp, self.config.streams, PcmInfo, makePcmInfo),
            R_CHMAP_INFO => self.cmdQueryInfo(req, resp, self.config.chmaps, ChmapInfo, makeChmapInfo),
            R_PCM_SET_PARAMS => self.cmdSetParams(req, resp),
            R_PCM_PREPARE => self.cmdPcmLifecycle(req, resp, .prepared),
            R_PCM_START => self.cmdPcmLifecycle(req, resp, .running),
            R_PCM_STOP => self.cmdPcmLifecycle(req, resp, .stopped),
            R_PCM_RELEASE => self.cmdPcmLifecycle(req, resp, .released),
            else => {
                log.warn("unhandled control request: 0x{x}", .{code});
                return writeStatus(resp, S_NOT_SUPP);
            },
        };
    }

    fn cmdQueryInfo(
        self: *Snd,
        req: []const u8,
        resp: []u8,
        total: u32,
        comptime InfoT: type,
        comptime make: fn (id: u32) InfoT,
    ) u32 {
        _ = self;
        if (req.len < @sizeOf(QueryInfo)) return writeStatus(resp, S_BAD_MSG);
        const q = std.mem.bytesToValue(QueryInfo, req[0..@sizeOf(QueryInfo)]);

        // Range must be within the advertised count.
        if (q.count == 0 or @as(u64, q.start_id) + q.count > total) {
            return writeStatus(resp, S_BAD_MSG);
        }

        const info_size = @sizeOf(InfoT);
        var off: usize = @sizeOf(Hdr);
        var i: u32 = 0;
        while (i < q.count) : (i += 1) {
            if (off + info_size > resp.len) break;
            const info = make(q.start_id + i);
            @memcpy(resp[off..][0..info_size], std.mem.asBytes(&info));
            off += info_size;
        }
        _ = writeStatus(resp, S_OK);
        return @intCast(off);
    }

    fn cmdSetParams(self: *Snd, req: []const u8, resp: []u8) u32 {
        if (req.len < @sizeOf(SetParams)) return writeStatus(resp, S_BAD_MSG);
        const p = std.mem.bytesToValue(SetParams, req[0..@sizeOf(SetParams)]);
        const sid = p.hdr.stream_id;
        if (sid >= self.streams.len) return writeStatus(resp, S_BAD_MSG);

        self.streams[sid] = .{
            .buffer_bytes = p.buffer_bytes,
            .period_bytes = p.period_bytes,
            .channels = p.channels,
            .format = p.format,
            .rate = p.rate,
            .state = .params_set,
        };
        return writeStatus(resp, S_OK);
    }

    fn cmdPcmLifecycle(self: *Snd, req: []const u8, resp: []u8, new_state: Stream.State) u32 {
        if (req.len < @sizeOf(PcmHdr)) return writeStatus(resp, S_BAD_MSG);
        const h = std.mem.bytesToValue(PcmHdr, req[0..@sizeOf(PcmHdr)]);
        const sid = h.stream_id;
        if (sid >= self.streams.len) return writeStatus(resp, S_BAD_MSG);

        self.streams[sid].state = new_state;
        return writeStatus(resp, S_OK);
    }

    // =========================================================================
    // TX queue (guest -> host PCM frames)
    // =========================================================================

    fn processTxQueue(self: *Snd) void {
        const qc = self.transport.queues[TXQ];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        while (self.tx_last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.tx_last_avail, get_mem) orelse break;
            const written = self.processTxBuffer(qc, head, get_mem);
            ring.pushUsed(qc, head, written, get_mem);
            self.tx_last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Consume one tx period buffer: skip the virtio_snd_pcm_xfer header in the
    /// readable descriptors, forward the PCM bytes to the sink, and write the
    /// virtio_snd_pcm_status into the writable descriptor.
    fn processTxBuffer(self: *Snd, qc: mmio.QueueConfig, head: u16, get_mem: ring.GetMemFn) u32 {
        const chain = ring.Chain.collect(qc, head, get_mem);

        var status_mem: ?[]u8 = null;
        // The xfer header (stream_id) leads the readable region; skip it, then
        // everything after is PCM sample data.
        var hdr_remaining: usize = @sizeOf(PcmXfer);

        for (chain.slice()) |d| {
            if (d.isWrite()) {
                if (status_mem == null) status_mem = get_mem(d.addr, d.len);
                continue;
            }
            var slice = get_mem(d.addr, d.len) orelse continue;
            if (hdr_remaining > 0) {
                const take = @min(slice.len, hdr_remaining);
                hdr_remaining -= take;
                slice = slice[take..];
            }
            if (slice.len > 0) {
                if (self.sink.on_period) |cb| cb(slice, self.sink.userdata);
            }
        }

        if (status_mem) |sm| {
            if (sm.len >= @sizeOf(PcmStatus)) {
                const st = PcmStatus{ .status = S_OK, .latency_bytes = 0 };
                @memcpy(sm[0..@sizeOf(PcmStatus)], std.mem.asBytes(&st));
                return @sizeOf(PcmStatus);
            }
        }
        return 0;
    }

    /// Get MMIO region size.
    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

/// Write a bare status header into a response buffer; returns bytes written.
fn writeStatus(resp: []u8, status: u32) u32 {
    const hdr = Hdr{ .code = status };
    @memcpy(resp[0..@sizeOf(Hdr)], std.mem.asBytes(&hdr));
    return @sizeOf(Hdr);
}

fn makePcmInfo(id: u32) PcmInfo {
    _ = id;
    return .{
        .features = 0,
        .formats = @as(u64, 1) << FMT_S16,
        .rates = (@as(u64, 1) << RATE_44100) | (@as(u64, 1) << RATE_48000),
        .direction = D_OUTPUT,
        .channels_min = 2,
        .channels_max = 2,
    };
}

fn makeJackInfo(id: u32) JackInfo {
    _ = id;
    return .{ .connected = 1 };
}

fn makeChmapInfo(id: u32) ChmapInfo {
    _ = id;
    var info = ChmapInfo{ .direction = D_OUTPUT, .channels = 2 };
    info.positions[0] = CHMAP_FL;
    info.positions[1] = CHMAP_FR;
    return info;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Synthetic guest memory shared by the device tests. Layout:
///   0x100: descriptor table   0x400: avail ring   0x600: used ring
///   0x800: request buffer      0xA00: response buffer   0xC00: PCM data
const TestMem = struct {
    var mem: [8192]u8 = undefined;
    fn get(addr: u64, len: usize) ?[]u8 {
        if (addr + len > mem.len) return null;
        return mem[@intCast(addr)..][0..len];
    }
    fn reset() void {
        @memset(&mem, 0);
    }
};

/// Build a 2-descriptor chain (readable request -> writable response) at the
/// standard addresses, mark the queue ready, and post one avail entry.
fn setupCtrlChain(snd: *Snd, req_len: u32, resp_len: u32) void {
    // desc0: readable request at 0x800.
    std.mem.writeInt(u64, TestMem.mem[0x100..][0..8], 0x800, .little);
    std.mem.writeInt(u32, TestMem.mem[0x100..][8..12], req_len, .little);
    std.mem.writeInt(u16, TestMem.mem[0x100..][12..14], ring.Desc.F_NEXT, .little);
    std.mem.writeInt(u16, TestMem.mem[0x100..][14..16], 1, .little);
    // desc1: writable response at 0xA00.
    std.mem.writeInt(u64, TestMem.mem[0x110..][0..8], 0xA00, .little);
    std.mem.writeInt(u32, TestMem.mem[0x110..][8..12], resp_len, .little);
    std.mem.writeInt(u16, TestMem.mem[0x110..][12..14], ring.Desc.F_WRITE, .little);

    snd.transport.queues[CONTROLQ] = .{
        .num = 8,
        .ready = true,
        .desc_addr = 0x100,
        .driver_addr = 0x400,
        .device_addr = 0x600,
    };
}

/// Post avail entry for descriptor head 0 at position `pos` and bump the
/// avail idx to pos+1 (drives one more control request into the device).
fn postAvail(pos: u16) void {
    std.mem.writeInt(u16, TestMem.mem[0x400..][4 + @as(usize, pos) * 2 ..][0..2], 0, .little);
    std.mem.writeInt(u16, TestMem.mem[0x400..][2..4], pos + 1, .little);
}

test "Snd init and identity" {
    const snd = try Snd.init(testing.allocator);
    defer snd.deinit();

    try testing.expectEqual(mmio.MAGIC, snd.read(@intFromEnum(mmio.Reg.magic)));
    try testing.expectEqual(@as(u32, 25), snd.read(@intFromEnum(mmio.Reg.device_id)));
    try testing.expectEqual(mmio.VERSION, snd.read(@intFromEnum(mmio.Reg.version)));

    // Config space: jacks/streams/chmaps all read back as 1.
    const cfg = @intFromEnum(mmio.Reg.config);
    try testing.expectEqual(@as(u32, 1), snd.read(cfg + 0)); // jacks
    try testing.expectEqual(@as(u32, 1), snd.read(cfg + 4)); // streams
    try testing.expectEqual(@as(u32, 1), snd.read(cfg + 8)); // chmaps
}

test "Snd PCM_INFO query returns one OUTPUT stream" {
    const snd = try Snd.init(testing.allocator);
    defer snd.deinit();

    TestMem.reset();
    snd.setGuestMemory(TestMem.get);
    setupCtrlChain(snd, @sizeOf(QueryInfo), 64);

    // Request: PCM_INFO for stream 0, count 1, size 32.
    const q = QueryInfo{
        .hdr = .{ .code = R_PCM_INFO },
        .start_id = 0,
        .count = 1,
        .size = @sizeOf(PcmInfo),
    };
    @memcpy(TestMem.mem[0x800..][0..@sizeOf(QueryInfo)], std.mem.asBytes(&q));

    postAvail(0);
    snd.write(@intFromEnum(mmio.Reg.queue_notify), CONTROLQ);

    // Response header: status OK.
    const status = std.mem.readInt(u32, TestMem.mem[0xA00..][0..4], .little);
    try testing.expectEqual(S_OK, status);

    // Followed by one pcm_info: direction OUTPUT, channels_max 2, S16 format.
    const info_base = 0xA00 + @sizeOf(Hdr);
    const formats = std.mem.readInt(u64, TestMem.mem[info_base + 8 ..][0..8], .little);
    const rates = std.mem.readInt(u64, TestMem.mem[info_base + 16 ..][0..8], .little);
    const direction = TestMem.mem[info_base + 24];
    const channels_max = TestMem.mem[info_base + 26];
    try testing.expectEqual(D_OUTPUT, direction);
    try testing.expectEqual(@as(u8, 2), channels_max);
    try testing.expect((formats & (@as(u64, 1) << FMT_S16)) != 0);
    try testing.expect((rates & (@as(u64, 1) << RATE_48000)) != 0);

    // Used ring reports hdr + one pcm_info.
    const used_len = std.mem.readInt(u32, TestMem.mem[0x600..][8..12], .little);
    try testing.expectEqual(@as(u32, @sizeOf(Hdr) + @sizeOf(PcmInfo)), used_len);
}

test "Snd JACK_INFO and CHMAP_INFO queries" {
    const snd = try Snd.init(testing.allocator);
    defer snd.deinit();

    TestMem.reset();
    snd.setGuestMemory(TestMem.get);
    setupCtrlChain(snd, @sizeOf(QueryInfo), 64);

    // JACK_INFO.
    var q = QueryInfo{ .hdr = .{ .code = R_JACK_INFO }, .start_id = 0, .count = 1, .size = @sizeOf(JackInfo) };
    @memcpy(TestMem.mem[0x800..][0..@sizeOf(QueryInfo)], std.mem.asBytes(&q));
    postAvail(0);
    snd.write(@intFromEnum(mmio.Reg.queue_notify), CONTROLQ);
    try testing.expectEqual(S_OK, std.mem.readInt(u32, TestMem.mem[0xA00..][0..4], .little));
    // jack_info.connected == 1 (Info hdr is 4 bytes, +features 4, +defconf 4,
    // +caps 4 => connected at offset 16).
    try testing.expectEqual(@as(u8, 1), TestMem.mem[0xA00 + @sizeOf(Hdr) + 16]);

    // CHMAP_INFO.
    q = QueryInfo{ .hdr = .{ .code = R_CHMAP_INFO }, .start_id = 0, .count = 1, .size = @sizeOf(ChmapInfo) };
    @memcpy(TestMem.mem[0x800..][0..@sizeOf(QueryInfo)], std.mem.asBytes(&q));
    postAvail(1);
    snd.write(@intFromEnum(mmio.Reg.queue_notify), CONTROLQ);
    try testing.expectEqual(S_OK, std.mem.readInt(u32, TestMem.mem[0xA00..][0..4], .little));
    // chmap_info: direction (offset 4), channels (5), positions[0..2] (6,7).
    const chmap_base = 0xA00 + @sizeOf(Hdr);
    try testing.expectEqual(D_OUTPUT, TestMem.mem[chmap_base + 4]);
    try testing.expectEqual(@as(u8, 2), TestMem.mem[chmap_base + 5]);
    try testing.expectEqual(CHMAP_FL, TestMem.mem[chmap_base + 6]);
    try testing.expectEqual(CHMAP_FR, TestMem.mem[chmap_base + 7]);
}

test "Snd SET_PARAMS then PREPARE/START stores params and returns OK" {
    const snd = try Snd.init(testing.allocator);
    defer snd.deinit();

    TestMem.reset();
    snd.setGuestMemory(TestMem.get);
    setupCtrlChain(snd, @sizeOf(SetParams), 64);

    // SET_PARAMS.
    const p = SetParams{
        .hdr = .{ .hdr = .{ .code = R_PCM_SET_PARAMS }, .stream_id = 0 },
        .buffer_bytes = 8192,
        .period_bytes = 4096,
        .features = 0,
        .channels = 2,
        .format = FMT_S16,
        .rate = RATE_48000,
        .padding = 0,
    };
    @memcpy(TestMem.mem[0x800..][0..@sizeOf(SetParams)], std.mem.asBytes(&p));
    postAvail(0);
    snd.write(@intFromEnum(mmio.Reg.queue_notify), CONTROLQ);
    try testing.expectEqual(S_OK, std.mem.readInt(u32, TestMem.mem[0xA00..][0..4], .little));
    try testing.expectEqual(@as(u32, 4096), snd.streams[0].period_bytes);
    try testing.expectEqual(@as(u32, 8192), snd.streams[0].buffer_bytes);
    try testing.expectEqual(Stream.State.params_set, snd.streams[0].state);

    // PREPARE.
    const prep = PcmHdr{ .hdr = .{ .code = R_PCM_PREPARE }, .stream_id = 0 };
    @memcpy(TestMem.mem[0x800..][0..@sizeOf(PcmHdr)], std.mem.asBytes(&prep));
    postAvail(1);
    snd.write(@intFromEnum(mmio.Reg.queue_notify), CONTROLQ);
    try testing.expectEqual(S_OK, std.mem.readInt(u32, TestMem.mem[0xA00..][0..4], .little));
    try testing.expectEqual(Stream.State.prepared, snd.streams[0].state);

    // START.
    const start = PcmHdr{ .hdr = .{ .code = R_PCM_START }, .stream_id = 0 };
    @memcpy(TestMem.mem[0x800..][0..@sizeOf(PcmHdr)], std.mem.asBytes(&start));
    postAvail(2);
    snd.write(@intFromEnum(mmio.Reg.queue_notify), CONTROLQ);
    try testing.expectEqual(S_OK, std.mem.readInt(u32, TestMem.mem[0xA00..][0..4], .little));
    try testing.expectEqual(Stream.State.running, snd.streams[0].state);
}

test "Snd txq forwards PCM period to the sink and returns OK status" {
    const snd = try Snd.init(testing.allocator);
    defer snd.deinit();

    TestMem.reset();
    snd.setGuestMemory(TestMem.get);

    const Cap = struct {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        fn cb(data: []const u8, ud: ?*anyopaque) void {
            _ = ud;
            @memcpy(buf[len..][0..data.len], data);
            len += data.len;
        }
    };
    Cap.len = 0;
    snd.setSink(.{ .on_period = Cap.cb });

    // Readable buffer at 0xC00: xfer header (stream_id 0) + 8 PCM bytes.
    const pcm = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    std.mem.writeInt(u32, TestMem.mem[0xC00..][0..4], 0, .little); // stream_id
    @memcpy(TestMem.mem[0xC00 + 4 ..][0..pcm.len], &pcm);

    // desc0: readable data (4 header + 8 pcm) -> desc1: writable status.
    std.mem.writeInt(u64, TestMem.mem[0x100..][0..8], 0xC00, .little);
    std.mem.writeInt(u32, TestMem.mem[0x100..][8..12], 4 + pcm.len, .little);
    std.mem.writeInt(u16, TestMem.mem[0x100..][12..14], ring.Desc.F_NEXT, .little);
    std.mem.writeInt(u16, TestMem.mem[0x100..][14..16], 1, .little);
    std.mem.writeInt(u64, TestMem.mem[0x110..][0..8], 0xA00, .little);
    std.mem.writeInt(u32, TestMem.mem[0x110..][8..12], @sizeOf(PcmStatus), .little);
    std.mem.writeInt(u16, TestMem.mem[0x110..][12..14], ring.Desc.F_WRITE, .little);

    snd.transport.queues[TXQ] = .{
        .num = 8,
        .ready = true,
        .desc_addr = 0x100,
        .driver_addr = 0x400,
        .device_addr = 0x600,
    };
    // Avail: idx 1, ring[0] = head 0.
    std.mem.writeInt(u16, TestMem.mem[0x400..][2..4], 1, .little);
    std.mem.writeInt(u16, TestMem.mem[0x400..][4..6], 0, .little);

    snd.write(@intFromEnum(mmio.Reg.queue_notify), TXQ);

    // The PCM bytes (header stripped) reached the sink.
    try testing.expectEqual(pcm.len, Cap.len);
    try testing.expectEqualSlices(u8, &pcm, Cap.buf[0..pcm.len]);

    // Status response: S_OK, latency 0.
    try testing.expectEqual(S_OK, std.mem.readInt(u32, TestMem.mem[0xA00..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, TestMem.mem[0xA00..][4..8], .little));

    // Used ring advanced, reporting the status length.
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, TestMem.mem[0x600..][2..4], .little));
    try testing.expectEqual(@as(u32, @sizeOf(PcmStatus)), std.mem.readInt(u32, TestMem.mem[0x600..][8..12], .little));
    try testing.expect(snd.transport.interrupt_status.used_buffer);
}
