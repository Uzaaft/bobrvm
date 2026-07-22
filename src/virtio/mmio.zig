//! Virtio MMIO Transport.
//!
//! Implements virtio-mmio transport per virtio 1.2 spec section 4.2.
//! Each device maps a 0x200 byte region to guest physical memory.
//!
//! Register layout (all 32-bit little-endian):
//!   0x000: MagicValue (read-only) = 0x74726976 ("virt")
//!   0x004: Version (read-only) = 2
//!   0x008: DeviceID (read-only)
//!   0x00c: VendorID (read-only)
//!   0x010: DeviceFeatures (read-only, selected by DeviceFeaturesSel)
//!   0x014: DeviceFeaturesSel (write-only)
//!   0x020: DriverFeatures (write-only)
//!   0x024: DriverFeaturesSel (write-only)
//!   0x030: QueueSel (write-only)
//!   0x034: QueueNumMax (read-only)
//!   0x038: QueueNum (write-only)
//!   0x044: QueueReady (read-write)
//!   0x050: QueueNotify (write-only)
//!   0x060: InterruptStatus (read-only)
//!   0x064: InterruptACK (write-only)
//!   0x070: Status (read-write)
//!   0x080: QueueDescLow (write-only)
//!   0x084: QueueDescHigh (write-only)
//!   0x090: QueueDriverLow (write-only)
//!   0x094: QueueDriverHigh (write-only)
//!   0x0a0: QueueDeviceLow (write-only)
//!   0x0a4: QueueDeviceHigh (write-only)
//!   0x0fc: ConfigGeneration (read-only)
//!   0x100+: Config space (device-specific)

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

/// MMIO region size.
pub const REGION_SIZE: usize = 0x200;

/// Magic value "virt".
pub const MAGIC: u32 = 0x74726976;

/// Version 2 (virtio 1.0+).
pub const VERSION: u32 = 2;

/// MMIO register offsets.
pub const Reg = enum(u12) {
    magic = 0x000,
    version = 0x004,
    device_id = 0x008,
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_low = 0x080,
    queue_desc_high = 0x084,
    queue_driver_low = 0x090,
    queue_driver_high = 0x094,
    queue_device_low = 0x0a0,
    queue_device_high = 0x0a4,
    shm_sel = 0x0ac,
    shm_len_low = 0x0b0,
    shm_len_high = 0x0b4,
    shm_base_low = 0x0b8,
    shm_base_high = 0x0bc,
    config_generation = 0x0fc,
    config = 0x100,
    // Non-exhaustive: guests may touch registers we don't model;
    // reads return 0, writes are ignored.
    _,
};

/// Queue configuration.
pub const QueueConfig = struct {
    num: u16 = 0,
    ready: bool = false,
    desc_addr: u64 = 0,
    driver_addr: u64 = 0,
    device_addr: u64 = 0,
};

/// Interrupt status bits.
pub const InterruptStatus = packed struct(u32) {
    used_buffer: bool = false,
    config_change: bool = false,
    _padding: u30 = 0,
};

/// Device status bits.
pub const Status = packed struct(u8) {
    acknowledge: bool = false,
    driver: bool = false,
    driver_ok: bool = false,
    features_ok: bool = false,
    device_needs_reset: bool = false,
    failed: bool = false,
    _padding: u2 = 0,
};

/// MMIO transport state.
pub const Transport = struct {
    device_id: u32,
    vendor_id: u32,
    device_features: u64,
    driver_features: u64,
    device_features_sel: u32,
    driver_features_sel: u32,
    status: Status,
    queue_sel: u32,
    queues: []QueueConfig,
    interrupt_status: InterruptStatus,
    config_generation: u32,
    alloc: Allocator,

    /// Callback for queue notifications.
    notify_callback: ?*const fn (queue_idx: u32, userdata: ?*anyopaque) void,
    notify_userdata: ?*anyopaque,

    /// Callback for the interrupt line (level-triggered): true while
    /// InterruptStatus is non-zero, false once the driver ACKs it all.
    irq_callback: ?*const fn (level: bool, userdata: ?*anyopaque) void,
    irq_userdata: ?*anyopaque,

    pub const Error = Allocator.Error;
    pub const MAX_QUEUES = 8;

    pub fn init(
        alloc: Allocator,
        device_id: u32,
        device_features: u64,
        num_queues: u8,
    ) Error!*Transport {
        // Pre-conditions
        assert(num_queues > 0);
        assert(num_queues <= MAX_QUEUES);

        const transport = try alloc.create(Transport);
        errdefer alloc.destroy(transport);

        const queues = try alloc.alloc(QueueConfig, num_queues);
        errdefer alloc.free(queues);

        @memset(queues, QueueConfig{});

        transport.* = .{
            .device_id = device_id,
            .vendor_id = 0x554D4551, // "QEMU"
            .device_features = device_features,
            .driver_features = 0,
            .device_features_sel = 0,
            .driver_features_sel = 0,
            .status = .{},
            .queue_sel = 0,
            .queues = queues,
            .interrupt_status = .{},
            .config_generation = 0,
            .alloc = alloc,
            .notify_callback = null,
            .notify_userdata = null,
            .irq_callback = null,
            .irq_userdata = null,
        };

        // Post-condition
        assert(transport.queues.len == num_queues);

        return transport;
    }

    pub fn deinit(self: *Transport) void {
        self.alloc.free(self.queues);
        self.alloc.destroy(self);
    }

    /// Set notification callback.
    pub fn setNotifyCallback(
        self: *Transport,
        callback: *const fn (u32, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.notify_callback = callback;
        self.notify_userdata = userdata;
    }

    /// Set IRQ line callback (for injecting interrupts to guest).
    pub fn setIrqCallback(
        self: *Transport,
        callback: *const fn (bool, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.irq_callback = callback;
        self.irq_userdata = userdata;
    }

    /// Handle MMIO read.
    pub fn read(self: *Transport, offset: u12) u32 {
        return switch (@as(Reg, @enumFromInt(offset))) {
            .magic => MAGIC,
            .version => VERSION,
            .device_id => self.device_id,
            .vendor_id => self.vendor_id,
            .device_features => self.readDeviceFeatures(),
            .queue_num_max => 256, // Max queue size
            .queue_ready => if (self.currentQueue()) |q| @intFromBool(q.ready) else 0,
            .interrupt_status => @bitCast(self.interrupt_status),
            .status => @as(u32, @intFromBool(self.status.acknowledge)) |
                (@as(u32, @intFromBool(self.status.driver)) << 1) |
                (@as(u32, @intFromBool(self.status.driver_ok)) << 2) |
                (@as(u32, @intFromBool(self.status.features_ok)) << 3) |
                (@as(u32, @intFromBool(self.status.device_needs_reset)) << 4) |
                (@as(u32, @intFromBool(self.status.failed)) << 5),
            .config_generation => self.config_generation,
            // No shared-memory regions: length reads must be all-ones
            // (the spec's "region does not exist" marker).
            .shm_len_low, .shm_len_high => 0xFFFF_FFFF,
            else => 0, // Write-only registers return 0
        };
    }

    /// Handle MMIO write.
    pub fn write(self: *Transport, offset: u12, value: u32) void {
        switch (@as(Reg, @enumFromInt(offset))) {
            .device_features_sel => self.device_features_sel = value,
            .driver_features => self.writeDriverFeatures(value),
            .driver_features_sel => self.driver_features_sel = value,
            .queue_sel => {
                if (value < self.queues.len) {
                    self.queue_sel = value;
                }
            },
            .queue_num => {
                if (self.currentQueue()) |q| {
                    q.num = @truncate(value);
                }
            },
            .queue_ready => {
                if (self.currentQueue()) |q| {
                    q.ready = value != 0;
                }
            },
            .queue_notify => self.handleNotify(value),
            .interrupt_ack => {
                self.interrupt_status = @bitCast(@as(u32, @bitCast(self.interrupt_status)) & ~value);
                // Deassert the (level) interrupt line once fully ACKed
                if (@as(u32, @bitCast(self.interrupt_status)) == 0) {
                    if (self.irq_callback) |cb| {
                        cb(false, self.irq_userdata);
                    }
                }
            },
            .status => self.handleStatusWrite(@truncate(value)),
            .queue_desc_low => {
                if (self.currentQueue()) |q| {
                    q.desc_addr = (q.desc_addr & 0xFFFFFFFF00000000) | value;
                }
            },
            .queue_desc_high => {
                if (self.currentQueue()) |q| {
                    q.desc_addr = (q.desc_addr & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
                }
            },
            .queue_driver_low => {
                if (self.currentQueue()) |q| {
                    q.driver_addr = (q.driver_addr & 0xFFFFFFFF00000000) | value;
                }
            },
            .queue_driver_high => {
                if (self.currentQueue()) |q| {
                    q.driver_addr = (q.driver_addr & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
                }
            },
            .queue_device_low => {
                if (self.currentQueue()) |q| {
                    q.device_addr = (q.device_addr & 0xFFFFFFFF00000000) | value;
                }
            },
            .queue_device_high => {
                if (self.currentQueue()) |q| {
                    q.device_addr = (q.device_addr & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
                }
            },
            else => {}, // Read-only or config space
        }
    }

    /// Get current queue config.
    fn currentQueue(self: *Transport) ?*QueueConfig {
        if (self.queue_sel < self.queues.len) {
            return &self.queues[self.queue_sel];
        }
        return null;
    }

    fn readDeviceFeatures(self: *Transport) u32 {
        if (self.device_features_sel == 0) {
            return @truncate(self.device_features);
        } else {
            return @truncate(self.device_features >> 32);
        }
    }

    fn writeDriverFeatures(self: *Transport, value: u32) void {
        if (self.driver_features_sel == 0) {
            self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | value;
        } else {
            self.driver_features = (self.driver_features & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
        }
    }

    fn handleStatusWrite(self: *Transport, value: u8) void {
        const new_status: Status = @bitCast(value);

        // Writing 0 resets the device
        if (value == 0) {
            self.reset();
            return;
        }

        self.status = new_status;
    }

    fn handleNotify(self: *Transport, queue_idx: u32) void {
        if (self.notify_callback) |cb| {
            cb(queue_idx, self.notify_userdata);
        }
    }

    /// Reset device to initial state.
    pub fn reset(self: *Transport) void {
        self.status = .{};
        self.driver_features = 0;
        self.device_features_sel = 0;
        self.driver_features_sel = 0;
        self.queue_sel = 0;
        self.interrupt_status = .{};

        for (self.queues) |*q| {
            q.* = QueueConfig{};
        }
    }

    /// Signal used buffer interrupt.
    pub fn signalUsedBuffer(self: *Transport) void {
        self.interrupt_status.used_buffer = true;
        // Assert the (level) interrupt line
        if (self.irq_callback) |cb| {
            cb(true, self.irq_userdata);
        }
    }

    /// Signal config change interrupt.
    pub fn signalConfigChange(self: *Transport) void {
        self.interrupt_status.config_change = true;
        self.config_generation +%= 1;
    }

    /// Check if device is ready for I/O.
    pub fn isReady(self: *Transport) bool {
        return self.status.driver_ok and self.status.features_ok;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Transport init and magic" {
    const transport = try Transport.init(std.testing.allocator, 3, 0, 2);
    defer transport.deinit();

    try std.testing.expectEqual(MAGIC, transport.read(@intFromEnum(Reg.magic)));
    try std.testing.expectEqual(VERSION, transport.read(@intFromEnum(Reg.version)));
    try std.testing.expectEqual(@as(u32, 3), transport.read(@intFromEnum(Reg.device_id)));
}

test "Transport queue selection" {
    const transport = try Transport.init(std.testing.allocator, 3, 0, 4);
    defer transport.deinit();

    // Select queue 2
    transport.write(@intFromEnum(Reg.queue_sel), 2);
    try std.testing.expectEqual(@as(u32, 2), transport.queue_sel);

    // Set queue size
    transport.write(@intFromEnum(Reg.queue_num), 64);
    try std.testing.expectEqual(@as(u16, 64), transport.queues[2].num);
}

test "Transport status reset" {
    const transport = try Transport.init(std.testing.allocator, 3, 0, 2);
    defer transport.deinit();

    // Set some status
    transport.write(@intFromEnum(Reg.status), 0x0F);
    try std.testing.expect(transport.status.acknowledge);

    // Reset by writing 0
    transport.write(@intFromEnum(Reg.status), 0);
    try std.testing.expect(!transport.status.acknowledge);
}
