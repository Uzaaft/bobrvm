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
const mmio = @import("mmio.zig");
const Queue = @import("queue.zig");

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

/// Block device.
pub const Block = struct {
    alloc: Allocator,
    transport: *mmio.Transport,
    config: Config,

    /// Request queue.
    request_queue: Queue.VirtQueue,

    /// Backing file.
    file: ?std.fs.File,
    capacity_bytes: u64,
    read_only: bool,

    /// Guest memory accessor.
    guest_memory: ?*const fn (addr: u64, len: usize) ?[]u8,

    /// Interrupt callback.
    interrupt_callback: ?*const fn (userdata: ?*anyopaque) void,
    interrupt_userdata: ?*anyopaque,

    pub const Error = Allocator.Error || std.fs.File.OpenError;
    pub const QUEUE_SIZE: u16 = 256;
    pub const SECTOR_SIZE: u64 = 512;

    pub fn init(alloc: Allocator) Error!*Block {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        const features = Features.SIZE_MAX | Features.SEG_MAX | Features.BLK_SIZE |
            Features.FLUSH | virtio_version_1;
        const transport = try mmio.Transport.init(alloc, 2, features, 1); // 2 = block device ID
        errdefer transport.deinit();

        var request_queue = try Queue.VirtQueue.init(alloc, QUEUE_SIZE);
        errdefer request_queue.deinit();

        const blk = try alloc.create(Block);
        blk.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = .{
                .size_max = 4096,
                .seg_max = 128,
                .blk_size = 512,
            },
            .request_queue = request_queue,
            .file = null,
            .capacity_bytes = 0,
            .read_only = false,
            .guest_memory = null,
            .interrupt_callback = null,
            .interrupt_userdata = null,
        };

        // Set up notification callback
        transport.setNotifyCallback(handleNotify, blk);

        // Post-condition
        assert(blk.transport.device_id == 2); // block device ID

        return blk;
    }

    pub fn deinit(self: *Block) void {
        if (self.file) |f| f.close();
        self.request_queue.deinit();
        self.transport.deinit();
        self.alloc.destroy(self);
    }

    /// Attach a disk image file.
    pub fn attachDisk(self: *Block, path: []const u8, read_only: bool) !void {
        const flags: std.fs.File.OpenFlags = if (read_only)
            .{ .mode = .read_only }
        else
            .{ .mode = .read_write };

        const file = try std.fs.cwd().openFile(path, flags);
        errdefer file.close();

        const stat = try file.stat();
        const size = stat.size;

        // Close any existing file
        if (self.file) |f| f.close();

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

        var last_avail_idx = self.request_queue.last_avail_idx;
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

        self.request_queue.last_avail_idx = last_avail_idx;
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
            .in => {
                // Per-descriptor reads: preadAll loops internally, so it is
                // robust to the short readv/preadv behavior macOS exhibits
                // for multi-iovec vectored reads (which corrupts blocks).
                const file = self.file orelse return .io_err;
                var offset = header.sector * SECTOR_SIZE;
                for (data) |desc| {
                    if ((desc.flags & GuestDesc.F_WRITE) == 0) continue;
                    const buf = get_mem(desc.addr, desc.len) orelse return .io_err;
                    if (offset + buf.len > self.capacity_bytes) return .io_err;
                    const n = file.preadAll(buf, offset) catch return .io_err;
                    // Short read within capacity: zero-fill (sparse tail).
                    @memset(buf[n..], 0);
                    offset += buf.len;
                    data_written.* += @intCast(buf.len);
                }
                return .ok;
            },
            .out => {
                if (self.read_only) return .io_err;
                const file = self.file orelse return .io_err;
                var offset = header.sector * SECTOR_SIZE;
                for (data) |desc| {
                    if ((desc.flags & GuestDesc.F_WRITE) != 0) continue;
                    const buf = get_mem(desc.addr, desc.len) orelse return .io_err;
                    if (offset + buf.len > self.capacity_bytes) return .io_err;
                    file.pwriteAll(buf, offset) catch return .io_err;
                    offset += buf.len;
                }
                return .ok;
            },
            .flush => {
                if (self.file) |f| {
                    f.sync() catch return .io_err;
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
            else => return .unsupp,
        }
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
