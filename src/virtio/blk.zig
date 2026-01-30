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
        const features = Features.SIZE_MAX | Features.SEG_MAX | Features.BLK_SIZE | Features.FLUSH;
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

    fn processRequestQueue(self: *Block) void {
        const queue = &self.request_queue;

        while (queue.pop()) |head| {
            self.processRequest(head);
        }

        // Signal interrupt if requests completed
        if (self.interrupt_callback) |cb| {
            cb(self.interrupt_userdata);
        }
    }

    fn processRequest(self: *Block, head: u16) void {
        const queue = &self.request_queue;
        var idx = head;
        var status: Status = .ok;
        var total_len: u32 = 0;

        // First descriptor: request header
        const header_desc = &queue.desc[idx];
        const header = self.readHeader(header_desc) orelse {
            self.completeRequest(head, 0, .io_err);
            return;
        };

        // Advance to data descriptors
        if (!header_desc.flags.next) {
            self.completeRequest(head, 0, .io_err);
            return;
        }
        idx = header_desc.next;

        // Process based on request type
        const req_type: RequestType = @enumFromInt(header.type);
        switch (req_type) {
            .in => {
                // Read from disk to guest memory
                status = self.handleRead(queue, &idx, header.sector, &total_len);
            },
            .out => {
                // Write from guest memory to disk
                status = self.handleWrite(queue, &idx, header.sector, &total_len);
            },
            .flush => {
                if (self.file) |f| {
                    f.sync() catch {
                        status = .io_err;
                    };
                }
            },
            .get_id => {
                // Return device ID (not implemented)
                status = .unsupp;
            },
            else => {
                status = .unsupp;
            },
        }

        // Write status to last descriptor
        self.writeStatus(queue, idx, status);
        self.completeRequest(head, total_len, status);
    }

    fn readHeader(self: *Block, desc: *const Queue.Desc) ?RequestHeader {
        if (desc.len < @sizeOf(RequestHeader)) return null;

        const get_mem = self.guest_memory orelse return null;
        const mem = get_mem(desc.addr, @sizeOf(RequestHeader)) orelse return null;

        return std.mem.bytesToValue(RequestHeader, mem[0..@sizeOf(RequestHeader)]);
    }

    fn handleRead(
        self: *Block,
        queue: *Queue.VirtQueue,
        idx: *u16,
        sector: u64,
        total_len: *u32,
    ) Status {
        const file = self.file orelse return .io_err;
        const get_mem = self.guest_memory orelse return .io_err;

        var offset = sector * SECTOR_SIZE;

        // Process data descriptors
        while (true) {
            const desc = &queue.desc[idx.*];

            if (desc.flags.write) {
                // This is a device-writable buffer (for read data)
                const mem = get_mem(desc.addr, desc.len) orelse return .io_err;

                file.seekTo(offset) catch return .io_err;
                const bytes_read = file.read(mem) catch return .io_err;

                total_len.* += @intCast(bytes_read);
                offset += bytes_read;
            }

            if (!desc.flags.next) break;
            idx.* = desc.next;
            if (idx.* >= queue.size) break;
        }

        return .ok;
    }

    fn handleWrite(
        self: *Block,
        queue: *Queue.VirtQueue,
        idx: *u16,
        sector: u64,
        total_len: *u32,
    ) Status {
        if (self.read_only) return .io_err;

        const file = self.file orelse return .io_err;
        const get_mem = self.guest_memory orelse return .io_err;

        var offset = sector * SECTOR_SIZE;

        // Process data descriptors
        while (true) {
            const desc = &queue.desc[idx.*];

            if (!desc.flags.write) {
                // Device-readable buffer (write data from guest)
                const mem = get_mem(desc.addr, desc.len) orelse return .io_err;

                file.seekTo(offset) catch return .io_err;
                const bytes_written = file.write(mem) catch return .io_err;

                total_len.* += @intCast(bytes_written);
                offset += bytes_written;
            }

            if (!desc.flags.next) break;
            idx.* = desc.next;
            if (idx.* >= queue.size) break;
        }

        return .ok;
    }

    fn writeStatus(self: *Block, queue: *Queue.VirtQueue, idx: u16, status: Status) void {
        const desc = &queue.desc[idx];
        const get_mem = self.guest_memory orelse return;

        // Last descriptor should be status (1 byte, device-writable)
        if (desc.flags.write and desc.len >= 1) {
            const mem = get_mem(desc.addr, 1) orelse return;
            mem[0] = @intFromEnum(status);
        }
    }

    fn completeRequest(self: *Block, head: u16, len: u32, status: Status) void {
        _ = status;
        self.request_queue.pushUsed(head, len);
        self.transport.signalUsedBuffer();
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
