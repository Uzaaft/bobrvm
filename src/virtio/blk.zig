//! Virtio Block Device.
//!
//! Implements virtio-blk per virtio 1.2 spec section 5.2.
//! Provides block storage I/O for guest disk access.
//!
//! Queues:
//!   0: requestq (read/write/flush requests)
//!
//! Request format:
//!   [header][data buffers...][status]
//!   - header: 16 bytes (type, reserved, sector)
//!   - data: variable size read/write buffers
//!   - status: 1 byte result

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const mmio = @import("mmio.zig");

/// Block feature bits.
pub const Features = struct {
    /// Maximum size of any single segment is in size_max.
    pub const SIZE_MAX: u64 = 1 << 1;
    /// Maximum number of segments in a request is in seg_max.
    pub const SEG_MAX: u64 = 1 << 2;
    /// Disk-style geometry specified in geometry.
    pub const GEOMETRY: u64 = 1 << 4;
    /// Device is read-only.
    pub const RO: u64 = 1 << 5;
    /// Block size of disk is in blk_size.
    pub const BLK_SIZE: u64 = 1 << 6;
    /// Device exports flush command.
    pub const FLUSH: u64 = 1 << 9;
    /// Device exports topology info.
    pub const TOPOLOGY: u64 = 1 << 10;
    /// Device can toggle cache writeback.
    pub const CONFIG_WCE: u64 = 1 << 11;
    /// Device supports discard command.
    pub const DISCARD: u64 = 1 << 13;
    /// Device supports write zeroes command.
    pub const WRITE_ZEROES: u64 = 1 << 14;
};

/// Request types.
pub const RequestType = enum(u32) {
    in = 0, // Read
    out = 1, // Write
    flush = 4,
    get_id = 8,
    discard = 11,
    write_zeroes = 13,
    _,
};

/// Request status.
pub const Status = enum(u8) {
    ok = 0,
    io_err = 1,
    unsupp = 2,
};

/// Block geometry.
pub const Geometry = extern struct {
    cylinders: u16 = 0,
    heads: u8 = 0,
    sectors: u8 = 0,
};

/// Block topology.
pub const Topology = extern struct {
    physical_block_exp: u8 = 0,
    alignment_offset: u8 = 0,
    min_io_size: u16 = 1,
    opt_io_size: u32 = 1,
};

/// Block config space (virtio 1.2 section 5.2.4).
pub const Config = extern struct {
    /// Capacity in 512-byte sectors.
    capacity: u64 = 0,
    /// Maximum segment size (if SIZE_MAX).
    size_max: u32 = 0,
    /// Maximum number of segments (if SEG_MAX).
    seg_max: u32 = 0,
    /// Geometry (if GEOMETRY).
    geometry: Geometry = .{},
    /// Block size in bytes (if BLK_SIZE).
    blk_size: u32 = 512,
    /// Topology (if TOPOLOGY).
    topology: Topology = .{},
    /// Writeback mode (if CONFIG_WCE).
    writeback: u8 = 0,
    _unused0: u8 = 0,
    /// Number of queues (if MQ).
    num_queues: u16 = 1,
    /// Max discard sectors (if DISCARD).
    max_discard_sectors: u32 = 0,
    /// Max discard segments (if DISCARD).
    max_discard_seg: u32 = 0,
    /// Discard sector alignment (if DISCARD).
    discard_sector_alignment: u32 = 0,
    /// Max write zeroes sectors (if WRITE_ZEROES).
    max_write_zeroes_sectors: u32 = 0,
    /// Max write zeroes segments (if WRITE_ZEROES).
    max_write_zeroes_seg: u32 = 0,
    /// Write zeroes may unmap (if WRITE_ZEROES).
    write_zeroes_may_unmap: u8 = 0,
    _unused1: [3]u8 = .{ 0, 0, 0 },
};

/// Block request header (guest → host).
pub const RequestHeader = extern struct {
    type: u32, // RequestType
    reserved: u32 = 0,
    sector: u64,
};

/// One discard/write-zeroes segment (virtio 1.2 section 5.2.6): the data
/// descriptor of those requests carries an array of these.
pub const DiscardWriteZeroes = extern struct {
    sector: u64,
    num_sectors: u32,
    /// Bit 0: unmap (write-zeroes may deallocate). Reserved otherwise.
    flags: u32 = 0,
};

/// Darwin fcntl(F_PUNCHHOLE) argument (sys/fcntl.h); deallocates a
/// byte range of an APFS file, which then reads back as zeros.
const FPunchhole = extern struct {
    fp_flags: c_uint = 0,
    reserved: c_uint = 0,
    fp_offset: c_longlong,
    fp_length: c_longlong,
};

/// APFS punch-hole granularity: both offset and length must be
/// multiples of the filesystem block size.
const PUNCH_ALIGN: u64 = 4096;

/// Block device.
pub const Block = struct {
    alloc: Allocator,
    transport: mmio.Transport,
    transport_queues: [1]mmio.QueueConfig,
    config: Config,

    /// Shadow cursor for the guest-owned request queue.
    request_last_avail: u16,

    /// Backing file.
    file: ?std.Io.File,
    capacity_bytes: u64,
    read_only: bool,

    /// Guest memory accessor.
    guest_memory: ?*const fn (addr: u64, len: usize) ?[]u8,

    /// Interrupt callback.
    interrupt_callback: ?*const fn (userdata: ?*anyopaque) void,
    interrupt_userdata: ?*anyopaque,

    pub const Error = Allocator.Error || std.Io.File.OpenError;
    pub const QUEUE_SIZE: u16 = 256;
    pub const SECTOR_SIZE: u64 = 512;

    pub fn init(alloc: Allocator) Error!*Block {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        const features = Features.SIZE_MAX | Features.SEG_MAX | Features.BLK_SIZE |
            Features.FLUSH | Features.DISCARD | Features.WRITE_ZEROES | virtio_version_1;
        const blk = try alloc.create(Block);
        errdefer alloc.destroy(blk);
        blk.* = .{
            .alloc = alloc,
            .transport = undefined,
            .transport_queues = undefined,
            .config = .{
                .size_max = 4096,
                .seg_max = 128,
                .blk_size = 512,
                // Discard/write-zeroes limits: 2 GiB per request, one
                // segment per request, 4 KiB granularity (APFS punch-hole
                // alignment; 8 sectors).
                .max_discard_sectors = 4_194_304,
                .max_discard_seg = 1,
                .discard_sector_alignment = @intCast(PUNCH_ALIGN / SECTOR_SIZE),
                .max_write_zeroes_sectors = 4_194_304,
                .max_write_zeroes_seg = 1,
                .write_zeroes_may_unmap = 1,
            },
            .request_last_avail = 0,
            .file = null,
            .capacity_bytes = 0,
            .read_only = false,
            .guest_memory = null,
            .interrupt_callback = null,
            .interrupt_userdata = null,
        };

        // Set up notification callback
        blk.transport.initEmbedded(2, features, &blk.transport_queues);
        blk.transport.setNotifyCallback(handleNotify, blk);

        // Post-condition
        assert(blk.transport.device_id == 2); // block device ID

        return blk;
    }

    pub fn deinit(self: *Block) void {
        if (self.file) |f| f.close(global.io());
        self.alloc.destroy(self);
    }

    /// Attach a disk image file.
    pub fn attachDisk(self: *Block, path: []const u8, read_only: bool) !void {
        const flags: std.Io.Dir.OpenFileOptions = if (read_only)
            .{ .mode = .read_only }
        else
            .{ .mode = .read_write };

        const file = try std.Io.Dir.cwd().openFile(global.io(), path, flags);
        errdefer file.close(global.io());

        const stat = try file.stat(global.io());
        const size = stat.size;

        // Close any existing file
        if (self.file) |f| f.close(global.io());

        self.file = file;
        self.capacity_bytes = size;
        self.read_only = read_only;
        self.config.capacity = size / SECTOR_SIZE;

        // Update features if read-only
        if (read_only) {
            self.transport.device_features |= Features.RO;
        }
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(
        self: *Block,
        accessor: *const fn (u64, usize) ?[]u8,
    ) void {
        self.guest_memory = accessor;
    }

    /// Set interrupt callback.
    pub fn setInterruptCallback(
        self: *Block,
        callback: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.interrupt_callback = callback;
        self.interrupt_userdata = userdata;
    }

    /// Handle MMIO read.
    pub fn read(self: *Block, offset: u12) u32 {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    /// Handle MMIO write.
    pub fn write(self: *Block, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            self.writeConfig(offset - @intFromEnum(mmio.Reg.config), value);
            return;
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Block, offset: u12) u32 {
        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        return 0;
    }

    fn writeConfig(_: *Block, _: u12, _: u32) void {
        // Config is read-only for block device
    }

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Block = @ptrCast(@alignCast(userdata));
        if (queue_idx == 0) {
            self.processRequestQueue();
        }
    }

    /// Poll the request queue. Can be called from the vCPU loop.
    pub fn pollRequests(self: *Block) void {
        self.processRequestQueue();
    }

    /// A descriptor read out of guest memory.
    const GuestDesc = struct {
        addr: u64,
        len: u32,
        flags: u16,
        next: u16,

        const F_NEXT: u16 = 1;
        const F_WRITE: u16 = 2;
    };

    /// Longest descriptor chain we accept: header + seg_max data + status.
    const MAX_CHAIN: usize = 130;

    fn readDesc(
        qc: mmio.QueueConfig,
        idx: u16,
        get_mem: *const fn (addr: u64, len: usize) ?[]u8,
    ) ?GuestDesc {
        const mem = get_mem(qc.desc_addr + @as(u64, idx) * 16, 16) orelse return null;
        return .{
            .addr = std.mem.readInt(u64, mem[0..8], .little),
            .len = std.mem.readInt(u32, mem[8..12], .little),
            .flags = std.mem.readInt(u16, mem[12..14], .little),
            .next = std.mem.readInt(u16, mem[14..16], .little),
        };
    }

    fn processRequestQueue(self: *Block) void {
        const qc = self.transport.queues[0];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_ring = get_mem(qc.driver_addr, 6) orelse return;
        const avail_idx = std.mem.readInt(u16, avail_ring[2..4], .little);

        var last_avail_idx = self.request_last_avail;
        var processed: u32 = 0;

        while (last_avail_idx != avail_idx) : (processed += 1) {
            const ring_idx = last_avail_idx % qc.num;
            const ring_entry = get_mem(qc.driver_addr + 4 + @as(u64, ring_idx) * 2, 2) orelse break;
            const desc_idx = std.mem.readInt(u16, ring_entry[0..2], .little);

            const written = self.processRequestGuest(qc, desc_idx, get_mem);

            const used_ring = get_mem(qc.device_addr, 6) orelse break;
            var used_idx = std.mem.readInt(u16, used_ring[2..4], .little);
            const used_ring_idx = used_idx % qc.num;
            const used_entry = get_mem(qc.device_addr + 4 + @as(u64, used_ring_idx) * 8, 8) orelse break;
            std.mem.writeInt(u32, used_entry[0..4], desc_idx, .little);
            std.mem.writeInt(u32, used_entry[4..8], written, .little);
            used_idx +%= 1;
            std.mem.writeInt(u16, @ptrCast(used_ring[2..4]), used_idx, .little);

            last_avail_idx +%= 1;
        }

        self.request_last_avail = last_avail_idx;
        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Execute one request chain. Returns the number of bytes written to
    /// device-writable buffers (data for reads, plus the status byte).
    fn processRequestGuest(
        self: *Block,
        qc: mmio.QueueConfig,
        head: u16,
        get_mem: *const fn (addr: u64, len: usize) ?[]u8,
    ) u32 {
        // Collect the descriptor chain.
        var descs: [MAX_CHAIN]GuestDesc = undefined;
        var count: usize = 0;
        var idx = head;
        while (count < MAX_CHAIN) {
            const desc = readDesc(qc, idx, get_mem) orelse break;
            descs[count] = desc;
            count += 1;
            if ((desc.flags & GuestDesc.F_NEXT) == 0) break;
            idx = desc.next;
        }

        // Minimum viable request: header + status.
        if (count < 2) return 0;
        const header_desc = descs[0];
        const status_desc = descs[count - 1];
        if (status_desc.len < 1 or (status_desc.flags & GuestDesc.F_WRITE) == 0) return 0;

        var status: Status = .ok;
        var data_written: u32 = 0;

        if (header_desc.len < @sizeOf(RequestHeader)) {
            status = .io_err;
        } else if (get_mem(header_desc.addr, @sizeOf(RequestHeader))) |hdr_mem| {
            const header = std.mem.bytesToValue(RequestHeader, hdr_mem[0..@sizeOf(RequestHeader)]);
            const data = descs[1 .. count - 1];
            status = self.executeRequest(header, data, get_mem, &data_written);
        } else {
            status = .io_err;
        }

        // Status byte is always written.
        if (get_mem(status_desc.addr, 1)) |status_mem| {
            status_mem[0] = @intFromEnum(status);
        }

        return data_written + 1;
    }

    fn executeRequest(
        self: *Block,
        header: RequestHeader,
        data: []const GuestDesc,
        get_mem: *const fn (addr: u64, len: usize) ?[]u8,
        data_written: *u32,
    ) Status {
        const req_type: RequestType = @enumFromInt(header.type);
        switch (req_type) {
            .in => return self.executeRead(header.sector, data, get_mem, data_written),
            .out => return self.executeWrite(header.sector, data, get_mem),
            .flush => {
                if (self.file) |f| {
                    f.sync(global.io()) catch return .io_err;
                }
                return .ok;
            },
            .get_id => {
                // Serial ID: write into the first writable data buffer.
                for (data) |desc| {
                    if ((desc.flags & GuestDesc.F_WRITE) == 0) continue;
                    const buf = get_mem(desc.addr, desc.len) orelse return .io_err;
                    const id = "bobrvm";
                    const n = @min(buf.len, id.len);
                    @memcpy(buf[0..n], id[0..n]);
                    @memset(buf[n..], 0);
                    data_written.* += @intCast(buf.len);
                    return .ok;
                }
                return .io_err;
            },
            .discard, .write_zeroes => {
                if (self.read_only) return .io_err;
                if (self.file == null) return .io_err;
                // The readable data descriptors carry an array of segments.
                for (data) |desc| {
                    if ((desc.flags & GuestDesc.F_WRITE) != 0) continue;
                    if (desc.len % @sizeOf(DiscardWriteZeroes) != 0) return .unsupp;
                    const buf = get_mem(desc.addr, desc.len) orelse return .io_err;
                    var off: usize = 0;
                    while (off < buf.len) : (off += @sizeOf(DiscardWriteZeroes)) {
                        const seg = std.mem.bytesToValue(
                            DiscardWriteZeroes,
                            buf[off..][0..@sizeOf(DiscardWriteZeroes)],
                        );
                        const st = self.executeDiscardSegment(seg, req_type == .write_zeroes);
                        if (st != .ok) return st;
                    }
                }
                return .ok;
            },
            else => return .unsupp,
        }
    }

    fn executeRead(
        self: *Block,
        sector: u64,
        data: []const GuestDesc,
        get_mem: *const fn (addr: u64, len: usize) ?[]u8,
        data_written: *u32,
    ) Status {
        assert(data.len <= MAX_CHAIN - 2);
        assert(data_written.* == 0);
        const file = self.file orelse return .io_err;
        var buffers: [MAX_CHAIN][]u8 = undefined;
        var count: usize = 0;
        var total: usize = 0;
        for (data) |desc| {
            if ((desc.flags & GuestDesc.F_WRITE) == 0) continue;
            buffers[count] = get_mem(desc.addr, desc.len) orelse return .io_err;
            total += buffers[count].len;
            count += 1;
        }
        const offset = sector * SECTOR_SIZE;
        if (offset + total > self.capacity_bytes or offset + total < offset) return .io_err;

        var active = buffers[0..count];
        var completed: usize = 0;
        while (completed < total) {
            const n = file.readPositional(global.io(), active, offset + completed) catch return .io_err;
            if (n == 0) {
                for (active) |buffer| @memset(buffer, 0);
                break;
            }
            active = advanceBuffers(active, n);
            completed += n;
        }
        data_written.* = @intCast(total);
        return .ok;
    }

    fn executeWrite(
        self: *Block,
        sector: u64,
        data: []const GuestDesc,
        get_mem: *const fn (addr: u64, len: usize) ?[]u8,
    ) Status {
        assert(data.len <= MAX_CHAIN - 2);
        assert(SECTOR_SIZE > 0);
        if (self.read_only) return .io_err;
        const file = self.file orelse return .io_err;
        var buffers: [MAX_CHAIN][]const u8 = undefined;
        var count: usize = 0;
        var total: usize = 0;
        for (data) |desc| {
            if ((desc.flags & GuestDesc.F_WRITE) != 0) continue;
            buffers[count] = get_mem(desc.addr, desc.len) orelse return .io_err;
            total += buffers[count].len;
            count += 1;
        }
        const offset = sector * SECTOR_SIZE;
        if (offset + total > self.capacity_bytes or offset + total < offset) return .io_err;

        var active = buffers[0..count];
        var completed: usize = 0;
        while (completed < total) {
            const n = file.writePositional(global.io(), active, offset + completed) catch return .io_err;
            if (n == 0) return .io_err;
            active = advanceBuffersConst(active, n);
            completed += n;
        }
        return .ok;
    }

    fn advanceBuffers(buffers: [][]u8, consumed: usize) [][]u8 {
        assert(buffers.len > 0);
        assert(consumed > 0);
        var active = buffers;
        var remaining = consumed;
        while (remaining >= active[0].len) {
            remaining -= active[0].len;
            active = active[1..];
            if (active.len == 0) return active;
        }
        active[0] = active[0][remaining..];
        return active;
    }

    fn advanceBuffersConst(buffers: [][]const u8, consumed: usize) [][]const u8 {
        assert(buffers.len > 0);
        assert(consumed > 0);
        var active = buffers;
        var remaining = consumed;
        while (remaining >= active[0].len) {
            remaining -= active[0].len;
            active = active[1..];
            if (active.len == 0) return active;
        }
        active[0] = active[0][remaining..];
        return active;
    }

    /// Apply one discard/write-zeroes segment. Discard is advisory: the
    /// aligned interior is hole-punched (APFS reclaims the space and reads
    /// back zeros) and failures are ignored. Write-zeroes must be exact, so
    /// any remainder the punch couldn't cover is explicitly zeroed.
    fn executeDiscardSegment(self: *Block, seg: DiscardWriteZeroes, must_zero: bool) Status {
        const file = self.file orelse return .io_err;
        const start = seg.sector * SECTOR_SIZE;
        const len = @as(u64, seg.num_sectors) * SECTOR_SIZE;
        if (len == 0) return .ok;
        if (start + len > self.capacity_bytes or start + len < start) return .io_err;

        // Punch the aligned interior so sparse files actually shrink.
        const hole_start = std.mem.alignForward(u64, start, PUNCH_ALIGN);
        const hole_end = std.mem.alignBackward(u64, start + len, PUNCH_ALIGN);
        var punched = false;
        if (hole_end > hole_start) {
            var args = FPunchhole{
                .fp_offset = @intCast(hole_start),
                .fp_length = @intCast(hole_end - hole_start),
            };
            punched = std.c.fcntl(file.handle, std.c.F.PUNCHHOLE, &args) == 0;
        }

        if (!must_zero) return .ok; // discard: advisory, done either way

        // write_zeroes: explicitly zero whatever the punch didn't cover.
        var zeros: [65536]u8 = @splat(0);
        var ranges: [2][2]u64 = undefined;
        var n_ranges: usize = 0;
        if (punched) {
            if (start < hole_start) {
                ranges[n_ranges] = .{ start, hole_start };
                n_ranges += 1;
            }
            if (hole_end < start + len) {
                ranges[n_ranges] = .{ hole_end, start + len };
                n_ranges += 1;
            }
        } else {
            ranges[0] = .{ start, start + len };
            n_ranges = 1;
        }
        for (ranges[0..n_ranges]) |range| {
            var pos = range[0];
            while (pos < range[1]) {
                const chunk = @min(range[1] - pos, zeros.len);
                file.writePositionalAll(global.io(), zeros[0..chunk], pos) catch return .io_err;
                pos += chunk;
            }
        }
        return .ok;
    }

    /// Get MMIO region size.
    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Block init" {
    const blk = try Block.init(std.testing.allocator);
    defer blk.deinit();

    // Check magic value
    const magic = blk.read(@intFromEnum(mmio.Reg.magic));
    try std.testing.expectEqual(mmio.MAGIC, magic);

    // Check device ID
    const device_id = blk.read(@intFromEnum(mmio.Reg.device_id));
    try std.testing.expectEqual(@as(u32, 2), device_id);
}

test "Block config read" {
    const blk = try Block.init(std.testing.allocator);
    defer blk.deinit();

    // Set capacity
    blk.config.capacity = 2048; // 1MB in sectors

    // Read capacity low
    const cap_low = blk.read(@intFromEnum(mmio.Reg.config));
    try std.testing.expectEqual(@as(u32, 2048), cap_low);
}

test "RequestHeader size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RequestHeader));
}

test "Config size" {
    // Ensure config is properly aligned
    try std.testing.expect(@sizeOf(Config) >= 56);
}

test "discard and write_zeroes advertised" {
    const blk = try Block.init(std.testing.allocator);
    defer blk.deinit();

    try std.testing.expect(blk.transport.device_features & Features.DISCARD != 0);
    try std.testing.expect(blk.transport.device_features & Features.WRITE_ZEROES != 0);
    try std.testing.expect(blk.config.max_discard_sectors > 0);
    try std.testing.expectEqual(@as(u32, 8), blk.config.discard_sector_alignment);
}

test "write_zeroes zeroes exactly the requested range" {
    const io = global.io();
    const path = ".zig-cache/blk-wz-test.raw";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var pattern: [64 * 1024]u8 = @splat(0xAA);
        try f.writePositionalAll(io, &pattern, 0);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const blk = try Block.init(std.testing.allocator);
    defer blk.deinit();
    try blk.attachDisk(path, false);

    // Zero a deliberately unaligned range: sectors 3..9 (1536..4608).
    const seg = DiscardWriteZeroes{ .sector = 3, .num_sectors = 6 };
    try std.testing.expectEqual(Status.ok, blk.executeDiscardSegment(seg, true));

    var buf: [64 * 1024]u8 = undefined;
    const f = blk.file.?;
    _ = try f.readPositionalAll(io, &buf, 0);
    // Before, inside, after.
    for (buf[0..1536]) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
    for (buf[1536..4608]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (buf[4608 .. 8 * 1024]) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
}

test "discard punches aligned range and rejects out-of-bounds" {
    const io = global.io();
    const path = ".zig-cache/blk-discard-test.raw";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var pattern: [64 * 1024]u8 = @splat(0xBB);
        try f.writePositionalAll(io, &pattern, 0);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const blk = try Block.init(std.testing.allocator);
    defer blk.deinit();
    try blk.attachDisk(path, false);

    // 4K-aligned discard: sectors 8..24 (4096..12288). On APFS the punched
    // hole reads back as zeros.
    const seg = DiscardWriteZeroes{ .sector = 8, .num_sectors = 16 };
    try std.testing.expectEqual(Status.ok, blk.executeDiscardSegment(seg, false));

    var buf: [16 * 1024]u8 = undefined;
    _ = try blk.file.?.readPositionalAll(io, &buf, 0);
    for (buf[0..4096]) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);
    for (buf[4096..12288]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (buf[12288..]) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);

    // Out-of-bounds segment must fail, not corrupt.
    const oob = DiscardWriteZeroes{ .sector = 1 << 40, .num_sectors = 8 };
    try std.testing.expectEqual(Status.io_err, blk.executeDiscardSegment(oob, false));
}

test "discard request path via executeRequest" {
    const io = global.io();
    const path = ".zig-cache/blk-discard-req-test.raw";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var pattern: [32 * 1024]u8 = @splat(0xCC);
        try f.writePositionalAll(io, &pattern, 0);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const blk = try Block.init(std.testing.allocator);
    defer blk.deinit();
    try blk.attachDisk(path, false);

    // Fake guest memory holding the segment array at 0x1000.
    const Ctx = struct {
        var mem: [4096]u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr < 0x1000) return null;
            const off = addr - 0x1000;
            if (off + len > mem.len) return null;
            return mem[off..][0..len];
        }
    };
    const seg = DiscardWriteZeroes{ .sector = 8, .num_sectors = 8 };
    @memcpy(Ctx.mem[0..@sizeOf(DiscardWriteZeroes)], std.mem.asBytes(&seg));

    const header = RequestHeader{ .type = @intFromEnum(RequestType.discard), .sector = 0 };
    const data = [_]Block.GuestDesc{
        .{ .addr = 0x1000, .len = @sizeOf(DiscardWriteZeroes), .flags = 0, .next = 0 },
    };
    var written: u32 = 0;
    try std.testing.expectEqual(Status.ok, blk.executeRequest(header, &data, Ctx.get, &written));

    // Read-only disks refuse.
    blk.read_only = true;
    try std.testing.expectEqual(Status.io_err, blk.executeRequest(header, &data, Ctx.get, &written));
}

test "vectored block reads and writes preserve descriptor order" {
    const io = global.io();
    const path = ".zig-cache/blk-vectored-test.raw";
    var disk: [4096]u8 = undefined;
    for (&disk, 0..) |*byte, i| byte.* = @truncate(i);
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, &disk, 0);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const blk = try Block.init(std.testing.allocator);
    defer blk.deinit();
    try blk.attachDisk(path, false);

    const Ctx = struct {
        var mem: [2048]u8 = @splat(0);
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr < 0x1000) return null;
            const off = addr - 0x1000;
            if (off + len > mem.len) return null;
            return mem[off..][0..len];
        }
    };
    const read_data = [_]Block.GuestDesc{
        .{ .addr = 0x1000, .len = 512, .flags = Block.GuestDesc.F_WRITE, .next = 0 },
        .{ .addr = 0x1400, .len = 512, .flags = Block.GuestDesc.F_WRITE, .next = 0 },
    };
    var written: u32 = 0;
    const read_header = RequestHeader{ .type = @intFromEnum(RequestType.in), .sector = 2 };
    try std.testing.expectEqual(Status.ok, blk.executeRequest(read_header, &read_data, Ctx.get, &written));
    try std.testing.expectEqual(@as(u32, 1024), written);
    try std.testing.expectEqualSlices(u8, disk[1024..1536], Ctx.mem[0..512]);
    try std.testing.expectEqualSlices(u8, disk[1536..2048], Ctx.mem[1024..1536]);

    @memset(Ctx.mem[0..512], 0xA5);
    @memset(Ctx.mem[1024..1536], 0x5A);
    const write_data = [_]Block.GuestDesc{
        .{ .addr = 0x1000, .len = 512, .flags = 0, .next = 0 },
        .{ .addr = 0x1400, .len = 512, .flags = 0, .next = 0 },
    };
    const write_header = RequestHeader{ .type = @intFromEnum(RequestType.out), .sector = 4 };
    try std.testing.expectEqual(Status.ok, blk.executeRequest(write_header, &write_data, Ctx.get, &written));
    _ = try blk.file.?.readPositionalAll(io, &disk, 0);
    try std.testing.expectEqualSlices(u8, Ctx.mem[0..512], disk[2048..2560]);
    try std.testing.expectEqualSlices(u8, Ctx.mem[1024..1536], disk[2560..3072]);
}

test "vectored block short I/O advancement crosses buffers" {
    var first: [4]u8 = undefined;
    var second: [6]u8 = undefined;
    var buffers = [_][]u8{ &first, &second };
    const active = Block.advanceBuffers(&buffers, 7);
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(@as(usize, 3), active[0].len);
    try std.testing.expectEqual(second[3..].ptr, active[0].ptr);
}
