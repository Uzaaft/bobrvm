//! Virtio Console Device.
//!
//! Implements virtio-console per virtio 1.2 spec section 5.3.
//! Provides serial console I/O between guest and host.
//!
//! Queues:
//!   0: receiveq (host → guest, input to guest)
//!   1: transmitq (guest → host, output from guest)
//!   2: control receiveq (optional, multiport)
//!   3: control transmitq (optional, multiport)

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const mmio = @import("mmio.zig");
const Queue = @import("queue.zig");

const log = std.log.scoped(.virtio_console);

/// Console feature bits.
pub const Features = struct {
    pub const SIZE: u64 = 1 << 0; // Console size in config
    pub const MULTIPORT: u64 = 1 << 1; // Multiple ports
    pub const EMERG_WRITE: u64 = 1 << 2; // Emergency write
};

/// Console config space.
pub const Config = extern struct {
    cols: u16 = 80,
    rows: u16 = 25,
    max_nr_ports: u32 = 1,
    emerg_wr: u32 = 0,
};

/// Console queue indices.
pub const QueueIdx = enum(u32) {
    receive = 0,
    transmit = 1,
    control_receive = 2,
    control_transmit = 3,
};

/// Console device.
pub const Console = struct {
    alloc: Allocator,
    transport: *mmio.Transport,
    config: Config,

    /// Ring buffers for each queue.
    receive_queue: Queue.VirtQueue,
    transmit_queue: Queue.VirtQueue,

    /// Output buffer (guest → host).
    output_buffer: std.ArrayListUnmanaged(u8),

    /// Input buffer (host → guest). Guarded by input_mutex: the host
    /// input thread appends, the vCPU thread drains.
    input_buffer: std.ArrayListUnmanaged(u8),
    input_mutex: std.Io.Mutex,

    /// Callback for output data.
    output_callback: ?*const fn (data: []const u8, userdata: ?*anyopaque) void,
    output_userdata: ?*anyopaque,

    /// Guest memory accessor.
    guest_memory: ?*const fn (addr: u64, len: usize) ?[]u8,

    pub const Error = Allocator.Error;
    pub const QUEUE_SIZE: u16 = 128;
    pub const INPUT_BUFFER_MAX: usize = 64 * 1024;

    pub fn init(alloc: Allocator) Error!*Console {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        const features = Features.SIZE | Features.EMERG_WRITE | virtio_version_1;
        const transport = try mmio.Transport.init(alloc, 3, features, 2); // 3 = console device ID
        errdefer transport.deinit();

        var receive_queue = try Queue.VirtQueue.init(alloc, QUEUE_SIZE);
        errdefer receive_queue.deinit();

        var transmit_queue = try Queue.VirtQueue.init(alloc, QUEUE_SIZE);
        errdefer transmit_queue.deinit();

        const console = try alloc.create(Console);
        console.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = .{},
            .receive_queue = receive_queue,
            .transmit_queue = transmit_queue,
            .output_buffer = .empty,
            .input_buffer = .empty,
            .input_mutex = .init,
            .output_callback = null,
            .output_userdata = null,
            .guest_memory = null,
        };

        // Set up notification callback
        transport.setNotifyCallback(handleNotify, console);

        // Post-condition
        assert(console.transport.device_id == 3); // console device ID

        return console;
    }

    pub fn deinit(self: *Console) void {
        self.output_buffer.deinit(self.alloc);
        self.input_buffer.deinit(self.alloc);
        self.transmit_queue.deinit();
        self.receive_queue.deinit();
        self.transport.deinit();
        self.alloc.destroy(self);
    }

    /// Set output callback (called when guest writes to console).
    pub fn setOutputCallback(
        self: *Console,
        callback: *const fn ([]const u8, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.output_callback = callback;
        self.output_userdata = userdata;
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(
        self: *Console,
        accessor: *const fn (u64, usize) ?[]u8,
    ) void {
        self.guest_memory = accessor;
    }

    /// Queue input data to send to guest. Called from the host input
    /// thread; delivery happens on the vCPU thread via pollReceive.
    pub fn queueInput(self: *Console, data: []const u8) Error!void {
        self.input_mutex.lockUncancelable(global.io());
        defer self.input_mutex.unlock(global.io());
        // Bound the buffer so a wedged guest can't grow it forever.
        if (self.input_buffer.items.len + data.len > INPUT_BUFFER_MAX) return;
        try self.input_buffer.appendSlice(self.alloc, data);
    }

    /// Handle MMIO read.
    pub fn read(self: *Console, offset: u12) u32 {
        // Config space starts at 0x100
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    /// Handle MMIO write.
    pub fn write(self: *Console, offset: u12, value: u32) void {
        // Config space starts at 0x100
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            self.writeConfig(offset - @intFromEnum(mmio.Reg.config), value);
            return;
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Console, offset: u12) u32 {
        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        return 0;
    }

    fn writeConfig(self: *Console, offset: u12, value: u32) void {
        // Emergency write (single character output)
        if (offset == @offsetOf(Config, "emerg_wr")) {
            const char: u8 = @truncate(value);
            if (self.output_callback) |cb| {
                cb(&[_]u8{char}, self.output_userdata);
            }
        }
    }

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Console = @ptrCast(@alignCast(userdata));
        switch (@as(QueueIdx, @enumFromInt(queue_idx))) {
            .receive => {
                self.processReceiveQueue();
                // Also check TX queue on any notification (some drivers don't notify TX)
                self.processTransmitQueue();
            },
            .transmit => {
                self.processTransmitQueue();
            },
            else => {},
        }
    }

    fn processReceiveQueue(self: *Console) void {
        const qc = self.transport.queues[@intFromEnum(QueueIdx.receive)];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        self.input_mutex.lockUncancelable(global.io());
        defer self.input_mutex.unlock(global.io());
        if (self.input_buffer.items.len == 0) return;

        const avail_ring = get_mem(qc.driver_addr, 6) orelse return;
        const avail_idx = std.mem.readInt(u16, avail_ring[2..4], .little);

        var last_avail_idx = self.receive_queue.last_avail_idx;
        var consumed: usize = 0;
        var delivered: u32 = 0;

        while (last_avail_idx != avail_idx and consumed < self.input_buffer.items.len) {
            const ring_idx = last_avail_idx % qc.num;
            const ring_entry = get_mem(qc.driver_addr + 4 + @as(u64, ring_idx) * 2, 2) orelse break;
            const desc_idx = std.mem.readInt(u16, ring_entry[0..2], .little);

            // Fill this (device-writable) descriptor chain with input.
            var written: u32 = 0;
            var idx = desc_idx;
            var iterations: u16 = 0;
            while (iterations < qc.num and consumed < self.input_buffer.items.len) : (iterations += 1) {
                const desc_mem = get_mem(qc.desc_addr + @as(u64, idx) * 16, 16) orelse break;
                const buf_addr = std.mem.readInt(u64, desc_mem[0..8], .little);
                const buf_len = std.mem.readInt(u32, desc_mem[8..12], .little);
                const flags = std.mem.readInt(u16, desc_mem[12..14], .little);
                const next = std.mem.readInt(u16, desc_mem[14..16], .little);

                // Only fill device-writable descriptors (VIRTQ_DESC_F_WRITE).
                if ((flags & 2) != 0) {
                    if (get_mem(buf_addr, buf_len)) |buf| {
                        const remaining = self.input_buffer.items[consumed..];
                        const n: usize = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        consumed += n;
                        written += @intCast(n);
                    }
                }

                if ((flags & 1) == 0) break; // No VIRTQ_DESC_F_NEXT
                idx = next;
            }

            // Report the buffer used, even if written == 0, to keep the
            // ring consistent with the driver's expectations.
            const used_ring = get_mem(qc.device_addr, 6) orelse break;
            var used_idx = std.mem.readInt(u16, used_ring[2..4], .little);
            const used_ring_idx = used_idx % qc.num;
            const used_entry = get_mem(qc.device_addr + 4 + @as(u64, used_ring_idx) * 8, 8) orelse break;
            std.mem.writeInt(u32, used_entry[0..4], desc_idx, .little);
            std.mem.writeInt(u32, used_entry[4..8], written, .little);
            used_idx +%= 1;
            std.mem.writeInt(u16, @ptrCast(used_ring[2..4]), used_idx, .little);

            delivered += written;
            last_avail_idx +%= 1;
        }

        self.receive_queue.last_avail_idx = last_avail_idx;

        if (consumed > 0) {
            self.input_buffer.replaceRangeAssumeCapacity(0, consumed, &.{});
        }
        if (delivered > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Poll the transmit queue. Can be called from vCPU loop.
    pub fn pollTransmit(self: *Console) void {
        self.processTransmitQueue();
    }

    /// Poll the receive queue for pending host input. Called from the
    /// vCPU loop so all guest-memory access stays on one thread.
    pub fn pollReceive(self: *Console) void {
        self.processReceiveQueue();
    }

    /// Debug: dump queue state for diagnostics.
    pub fn debugState(self: *Console) void {
        const get_mem = self.guest_memory orelse return;
        for ([_]QueueIdx{ .receive, .transmit }) |qi| {
            const qc = self.transport.queues[@intFromEnum(qi)];
            var avail_idx: u16 = 0;
            var used_idx: u16 = 0;
            if (qc.ready) {
                if (get_mem(qc.driver_addr, 6)) |a| avail_idx = std.mem.readInt(u16, a[2..4], .little);
                if (get_mem(qc.device_addr, 6)) |u| used_idx = std.mem.readInt(u16, u[2..4], .little);
            }
            log.debug("q{}: ready={} num={} avail_idx={} used_idx={} last_avail={} desc=0x{x}", .{
                @intFromEnum(qi),                                                                               qc.ready,     qc.num, avail_idx, used_idx,
                if (qi == .transmit) self.transmit_queue.last_avail_idx else self.receive_queue.last_avail_idx, qc.desc_addr,
            });
        }
    }

    /// Debug: check if TX queue has pending data.
    pub fn hasPendingTx(self: *Console) bool {
        const qc = self.transport.queues[@intFromEnum(QueueIdx.transmit)];
        if (!qc.ready or qc.num == 0) return false;
        const get_mem = self.guest_memory orelse return false;
        const avail_ring = get_mem(qc.driver_addr, 6) orelse return false;
        const avail_idx = std.mem.readInt(u16, avail_ring[2..4], .little);
        return avail_idx != self.transmit_queue.last_avail_idx;
    }

    fn processTransmitQueue(self: *Console) void {
        // Get queue config from transport
        const qc = self.transport.queues[@intFromEnum(QueueIdx.transmit)];
        if (!qc.ready or qc.num == 0) {
            return;
        }

        const get_mem = self.guest_memory orelse return;

        // Read available ring from guest memory
        const avail_ring = get_mem(qc.driver_addr, 6) orelse {
            log.warn("TX: can't read avail ring at 0x{x}", .{qc.driver_addr});
            return;
        };
        const avail_idx = std.mem.readInt(u16, avail_ring[2..4], .little);

        // Process all available descriptors
        var last_avail_idx = self.transmit_queue.last_avail_idx;
        var processed: u32 = 0;
        while (last_avail_idx != avail_idx) : (processed += 1) {
            const ring_idx = last_avail_idx % qc.num;
            const ring_entry = get_mem(qc.driver_addr + 4 + @as(u64, ring_idx) * 2, 2) orelse break;
            const desc_idx = std.mem.readInt(u16, ring_entry[0..2], .little);

            // Process this descriptor chain
            const total_len = self.processDescriptorChainGuest(qc, desc_idx, get_mem);

            // Add to used ring
            const used_ring = get_mem(qc.device_addr, 6) orelse break;
            var used_idx = std.mem.readInt(u16, used_ring[2..4], .little);
            const used_ring_idx = used_idx % qc.num;
            const used_entry = get_mem(qc.device_addr + 4 + @as(u64, used_ring_idx) * 8, 8) orelse break;
            std.mem.writeInt(u32, used_entry[0..4], desc_idx, .little);
            std.mem.writeInt(u32, used_entry[4..8], total_len, .little);
            used_idx +%= 1;
            std.mem.writeInt(u16, @ptrCast(used_ring[2..4]), used_idx, .little);

            last_avail_idx +%= 1;
        }

        self.transmit_queue.last_avail_idx = last_avail_idx;
        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    fn processDescriptorChainGuest(
        self: *Console,
        qc: mmio.QueueConfig,
        head: u16,
        get_mem: *const fn (addr: u64, len: usize) ?[]u8,
    ) u32 {
        var idx = head;
        var total_len: u32 = 0;
        var iterations: u16 = 0;

        // Walk the descriptor chain
        while (iterations < qc.num) : (iterations += 1) {
            // Read descriptor from guest memory (16 bytes each)
            const desc_mem = get_mem(qc.desc_addr + @as(u64, idx) * 16, 16) orelse break;
            const buf_addr = std.mem.readInt(u64, desc_mem[0..8], .little);
            const buf_len = std.mem.readInt(u32, desc_mem[8..12], .little);
            const flags = std.mem.readInt(u16, desc_mem[12..14], .little);
            const next = std.mem.readInt(u16, desc_mem[14..16], .little);

            // Read data buffer from guest memory
            if (get_mem(buf_addr, buf_len)) |data| {
                if (self.output_callback) |cb| {
                    cb(data, self.output_userdata);
                }
                total_len += buf_len;
            }

            // Check for next descriptor (NEXT flag is bit 0)
            if ((flags & 1) == 0) break;
            idx = next;
        }

        return total_len;
    }

    /// Get MMIO base address requirement.
    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

/// Device ID for console.
const DeviceId = enum(u32) {
    console = 3,
};

// Ensure mmio module has the DeviceId
const mmioDeviceId = struct {
    pub const console: u32 = 3;
};

// =============================================================================
// Tests
// =============================================================================

test "Console init" {
    const console = try Console.init(std.testing.allocator);
    defer console.deinit();

    // Check magic value
    const magic = console.read(@intFromEnum(mmio.Reg.magic));
    try std.testing.expectEqual(mmio.MAGIC, magic);

    // Check device ID
    const device_id = console.read(@intFromEnum(mmio.Reg.device_id));
    try std.testing.expectEqual(@as(u32, 3), device_id);
}

test "Console config read" {
    const console = try Console.init(std.testing.allocator);
    defer console.deinit();

    // Read cols (offset 0x100)
    const cols = console.read(@intFromEnum(mmio.Reg.config));
    // cols=80, rows=25 → 0x00190050 in little-endian as u32
    try std.testing.expectEqual(@as(u32, 80 | (25 << 16)), cols);
}

test "Console queue input" {
    const console = try Console.init(std.testing.allocator);
    defer console.deinit();

    try console.queueInput("Hello, guest!");
    try std.testing.expectEqual(@as(usize, 13), console.input_buffer.items.len);
}
