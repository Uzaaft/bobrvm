//! Virtio MMIO transport from virtio 1.2 section 4.2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const callback_binding = @import("../callback.zig");

pub const REGION_SIZE: usize = 0x200;

pub const MAGIC: u32 = 0x74726976;

pub const VERSION: u32 = 2;

pub const Irq = callback_binding.Binding1(bool, void);
pub const Notify = callback_binding.Binding1(u32, void);

pub fn bindNotify(
    comptime Context: type,
    context: *Context,
    comptime handler: fn (*Context, u32) void,
) Notify {
    return callback_binding.Handler1(Context, u32, void, handler).bind(context);
}

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

    /// Callback for queue notifications.
    notify: ?Notify,

    /// Callback for the interrupt line (level-triggered): true while
    /// InterruptStatus is non-zero, false once the driver ACKs it all.
    irq: ?Irq,

    /// Shared-memory region (VIRTIO_MMIO_SHM_*), selected by shm_sel. Only
    /// region 0 is used (virtio-gpu host-visible window for Venus blobs). A
    /// zero-length region reads back as "does not exist" (all-ones length).
    shm_sel: u32 = 0,
    shm_region_id: u32 = 0xffff_ffff,
    shm_region_base: u64 = 0,
    shm_region_len: u64 = 0,

    pub const Error = Allocator.Error;
    pub const MAX_QUEUES = 16;

    fn allocationSize(num_queues: usize) usize {
        assert(num_queues > 0);
        assert(num_queues <= MAX_QUEUES);

        const queues_offset = std.mem.alignForward(
            usize,
            @sizeOf(Transport),
            @alignOf(QueueConfig),
        );
        return queues_offset + num_queues * @sizeOf(QueueConfig);
    }

    /// Advertise a shared-memory region to the guest. `index` is the shmid the
    /// guest selects via shm_sel (VIRTIO_GPU_SHM_ID_HOST_VISIBLE = 1).
    pub fn setShmRegion(self: *Transport, index: u32, base: u64, len: u64) void {
        self.shm_region_id = index;
        self.shm_region_base = base;
        self.shm_region_len = len;
    }

    pub fn init(
        alloc: Allocator,
        device_id: u32,
        device_features: u64,
        num_queues: u8,
    ) Error!*Transport {
        // Pre-conditions
        assert(num_queues > 0);
        assert(num_queues <= MAX_QUEUES);

        comptime assert(@alignOf(Transport) >= @alignOf(QueueConfig));
        const allocation = try alloc.alignedAlloc(
            u8,
            .of(Transport),
            allocationSize(num_queues),
        );
        errdefer alloc.free(allocation);

        const transport: *Transport = @ptrCast(allocation.ptr);
        const queues_offset = std.mem.alignForward(
            usize,
            @sizeOf(Transport),
            @alignOf(QueueConfig),
        );
        const queues_ptr: [*]QueueConfig = @ptrCast(@alignCast(allocation.ptr + queues_offset));
        const queues = queues_ptr[0..num_queues];

        transport.initEmbedded(device_id, device_features, queues);

        // Post-condition
        assert(transport.queues.len == num_queues);

        return transport;
    }

    /// Initialize transport state in caller-owned storage. The owner must not
    /// call deinit; it releases the enclosing allocation instead.
    pub fn initEmbedded(
        self: *Transport,
        device_id: u32,
        device_features: u64,
        queues: []QueueConfig,
    ) void {
        assert(queues.len > 0);
        assert(queues.len <= MAX_QUEUES);

        @memset(queues, QueueConfig{});
        self.* = .{
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
            .notify = null,
            .irq = null,
        };
    }

    pub fn deinit(self: *Transport, alloc: Allocator) void {
        assert(self.queues.len > 0);
        assert(self.queues.len <= MAX_QUEUES);

        const allocation_len = allocationSize(self.queues.len);
        const allocation_ptr: [*]align(@alignOf(Transport)) u8 = @ptrCast(self);
        alloc.free(allocation_ptr[0..allocation_len]);
    }

    /// Set notification callback.
    pub fn setNotifyCallback(self: *Transport, notify: Notify) void {
        self.notify = notify;
    }

    /// Set IRQ line callback (for injecting interrupts to guest).
    pub fn setIrqCallback(self: *Transport, irq: Irq) void {
        self.irq = irq;
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
            // Shared-memory region query (selected by shm_sel). Only region 0
            // exists; a length of all-ones means "region does not exist".
            .shm_len_low => if (self.shm_sel == self.shm_region_id and self.shm_region_len != 0) @truncate(self.shm_region_len) else 0xFFFF_FFFF,
            .shm_len_high => if (self.shm_sel == self.shm_region_id and self.shm_region_len != 0) @truncate(self.shm_region_len >> 32) else 0xFFFF_FFFF,
            .shm_base_low => if (self.shm_sel == self.shm_region_id and self.shm_region_len != 0) @truncate(self.shm_region_base) else 0,
            .shm_base_high => if (self.shm_sel == self.shm_region_id and self.shm_region_len != 0) @truncate(self.shm_region_base >> 32) else 0,
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
                    if (self.irq) |irq| {
                        irq.call(false);
                    }
                }
            },
            .status => self.handleStatusWrite(@truncate(value)),
            .shm_sel => self.shm_sel = value,
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
        if (self.notify) |notify| {
            notify.call(queue_idx);
        }
    }

    /// Reset device to initial state.
    pub fn reset(self: *Transport) void {
        // Firmware can reset a device without first acknowledging its interrupt.
        // Drop the level before clearing the status so the next driver receives
        // a fresh edge when the machine routes legacy PCI interrupts through a PIC.
        if (@as(u32, @bitCast(self.interrupt_status)) != 0) {
            if (self.irq) |irq| irq.call(false);
        }
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
        if (self.irq) |irq| {
            irq.call(true);
        }
    }

    /// Signal config change interrupt.
    pub fn signalConfigChange(self: *Transport) void {
        self.interrupt_status.config_change = true;
        self.config_generation +%= 1;
        // Assert the (level) interrupt line
        if (self.irq) |irq| {
            irq.call(true);
        }
    }

    /// Check if device is ready for I/O.
    pub fn isReady(self: *Transport) bool {
        return self.status.driver_ok and self.status.features_ok;
    }
};

test "Transport init and magic" {
    const transport = try Transport.init(std.testing.allocator, 3, 0, 2);
    defer transport.deinit(std.testing.allocator);

    try std.testing.expectEqual(MAGIC, transport.read(@intFromEnum(Reg.magic)));
    try std.testing.expectEqual(VERSION, transport.read(@intFromEnum(Reg.version)));
    try std.testing.expectEqual(@as(u32, 3), transport.read(@intFromEnum(Reg.device_id)));
}

test "Transport queue selection" {
    const transport = try Transport.init(std.testing.allocator, 3, 0, 4);
    defer transport.deinit(std.testing.allocator);

    // Select queue 2
    transport.write(@intFromEnum(Reg.queue_sel), 2);
    try std.testing.expectEqual(@as(u32, 2), transport.queue_sel);

    // Set queue size
    transport.write(@intFromEnum(Reg.queue_num), 64);
    try std.testing.expectEqual(@as(u16, 64), transport.queues[2].num);
}

test "Transport status reset" {
    const transport = try Transport.init(std.testing.allocator, 3, 0, 2);
    defer transport.deinit(std.testing.allocator);

    // Set some status
    transport.write(@intFromEnum(Reg.status), 0x0F);
    try std.testing.expect(transport.status.acknowledge);

    // Reset by writing 0
    transport.write(@intFromEnum(Reg.status), 0);
    try std.testing.expect(!transport.status.acknowledge);
}

test "Transport reset deasserts a pending interrupt" {
    const transport = try Transport.init(std.testing.allocator, 3, 0, 2);
    defer transport.deinit(std.testing.allocator);

    const Line = struct {
        level: bool = false,

        fn cb(level: bool, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.level = level;
        }
    };
    var line = Line{};
    transport.setIrqCallback(Irq.initRaw(Line.cb, &line));
    transport.signalUsedBuffer();
    try std.testing.expect(line.level);

    transport.write(@intFromEnum(Reg.status), 0);

    try std.testing.expect(!line.level);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(transport.interrupt_status)));
}

test "Transport config change raises and ack clears the interrupt line" {
    const transport = try Transport.init(std.testing.allocator, 16, 0, 2);
    defer transport.deinit(std.testing.allocator);

    const Line = struct {
        level: bool = false,
        fn cb(level: bool, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.level = level;
        }
    };
    var line = Line{};
    transport.setIrqCallback(Irq.initRaw(Line.cb, &line));

    const gen_before = transport.config_generation;
    transport.signalConfigChange();

    try std.testing.expect(line.level);
    try std.testing.expect(transport.interrupt_status.config_change);
    try std.testing.expectEqual(gen_before +% 1, transport.read(@intFromEnum(Reg.config_generation)));

    // ACK the config-change bit: line must deassert
    transport.write(@intFromEnum(Reg.interrupt_ack), 0x2);
    try std.testing.expect(!line.level);
    try std.testing.expect(!transport.interrupt_status.config_change);
}
