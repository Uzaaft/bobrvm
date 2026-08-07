//! Virtio PCI Modern Transport.
//!
//! Implements virtio-pci modern transport per virtio 1.2 spec section 4.1.
//! This provides PCI-based device access for UEFI boot support.
//!
//! BAR layout (all in BAR0 for simplicity):
//! - 0x000-0x03F: Common configuration (64 bytes)
//! - 0x040-0x043: ISR status (4 bytes)
//! - 0x044-0x047: Notify region (4 bytes, multiplier=0)
//! - 0x048-0x0FF: Device-specific config (184 bytes)
//!
//! PCI capabilities point to these BAR regions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.virtio_pci);

/// PCI capability ID for vendor-specific.
pub const PCI_CAP_ID_VNDR: u8 = 0x09;

/// Virtio PCI capability types.
pub const CapType = enum(u8) {
    common_cfg = 1,
    notify_cfg = 2,
    isr_cfg = 3,
    device_cfg = 4,
    pci_cfg = 5,
};

/// Virtio PCI capability structure (16 bytes).
pub const VirtioPciCap = extern struct {
    cap_vndr: u8 = PCI_CAP_ID_VNDR,
    cap_next: u8 = 0,
    cap_len: u8 = 16,
    cfg_type: u8,
    bar: u8 = 0,
    id: u8 = 0,
    padding: [2]u8 = .{ 0, 0 },
    offset: u32,
    length: u32,
};

/// Virtio PCI notify capability (20 bytes).
pub const VirtioPciNotifyCap = extern struct {
    cap: VirtioPciCap,
    notify_off_multiplier: u32 = 0,
};

/// Common configuration structure offsets.
pub const CommonCfgReg = enum(u8) {
    device_feature_select = 0x00,
    device_feature = 0x04,
    driver_feature_select = 0x08,
    driver_feature = 0x0C,
    msix_config = 0x10,
    num_queues = 0x12,
    device_status = 0x14,
    config_generation = 0x15,
    queue_select = 0x16,
    queue_size = 0x18,
    queue_msix_vector = 0x1A,
    queue_enable = 0x1C,
    queue_notify_off = 0x1E,
    queue_desc_lo = 0x20,
    queue_desc_hi = 0x24,
    queue_driver_lo = 0x28,
    queue_driver_hi = 0x2C,
    queue_device_lo = 0x30,
    queue_device_hi = 0x34,
    queue_reset = 0x38,
    _,
};

/// BAR region offsets (all in BAR0).
pub const BAR_COMMON_CFG_OFFSET: u32 = 0x000;
pub const BAR_COMMON_CFG_SIZE: u32 = 0x40;
pub const BAR_ISR_OFFSET: u32 = 0x040;
pub const BAR_ISR_SIZE: u32 = 0x04;
pub const BAR_NOTIFY_OFFSET: u32 = 0x044;
pub const BAR_NOTIFY_SIZE: u32 = 0x04;
pub const BAR_DEVICE_CFG_OFFSET: u32 = 0x048;
pub const BAR_DEVICE_CFG_SIZE: u32 = 0x100; // 256 bytes for device config

/// Total BAR0 size (4KB minimum for PCI).
pub const BAR0_SIZE: u32 = 0x1000;

/// Queue configuration state.
pub const QueueConfig = struct {
    size: u16 = 0,
    enable: bool = false,
    notify_off: u16 = 0,
    desc_addr: u64 = 0,
    driver_addr: u64 = 0,
    device_addr: u64 = 0,
};

/// ISR status bits.
pub const IsrStatus = packed struct(u8) {
    queue_interrupt: bool = false,
    config_change: bool = false,
    _padding: u6 = 0,
};

/// Device status bits (same as MMIO).
pub const DeviceStatus = packed struct(u8) {
    acknowledge: bool = false,
    driver: bool = false,
    driver_ok: bool = false,
    features_ok: bool = false,
    _padding: u2 = 0,
    device_needs_reset: bool = false,
    failed: bool = false,
};

/// Virtio PCI modern transport.
pub const VirtioPciTransport = struct {
    alloc: Allocator,

    /// Device type (block=2, etc).
    device_id: u32,

    /// Device features.
    device_features: u64,

    /// Driver-acknowledged features.
    driver_features: u64,

    /// Feature selection registers.
    device_feature_select: u32,
    driver_feature_select: u32,

    /// Device status.
    status: DeviceStatus,

    /// Configuration generation counter.
    config_generation: u8,

    /// Selected queue index.
    queue_select: u16,

    /// Number of queues.
    num_queues: u16,

    /// Queue configurations.
    queues: []QueueConfig,

    /// ISR status.
    isr_status: IsrStatus,

    /// Device-specific configuration (e.g., virtio-blk config).
    device_config: []u8,

    /// Notification callback.
    notify_callback: ?*const fn (queue_idx: u32, userdata: ?*anyopaque) void,
    notify_userdata: ?*anyopaque,

    /// IRQ callback.
    irq_callback: ?*const fn (userdata: ?*anyopaque) void,
    irq_userdata: ?*anyopaque,

    pub const MAX_QUEUES = 8;
    pub const MAX_QUEUE_SIZE: u16 = 256;

    const AllocationLayout = struct {
        queues_offset: usize,
        device_config_offset: usize,
        size: usize,
    };

    fn allocationLayout(num_queues: u16, device_config_size: usize) Allocator.Error!AllocationLayout {
        assert(num_queues > 0);
        assert(num_queues <= MAX_QUEUES);
        comptime assert(@alignOf(VirtioPciTransport) >= @alignOf(QueueConfig));
        const queues_offset = std.mem.alignForward(
            usize,
            @sizeOf(VirtioPciTransport),
            @alignOf(QueueConfig),
        );
        const queues_bytes = std.math.mul(usize, num_queues, @sizeOf(QueueConfig)) catch
            return error.OutOfMemory;
        const device_config_offset = std.math.add(usize, queues_offset, queues_bytes) catch
            return error.OutOfMemory;
        const size = std.math.add(usize, device_config_offset, device_config_size) catch
            return error.OutOfMemory;
        return .{
            .queues_offset = queues_offset,
            .device_config_offset = device_config_offset,
            .size = size,
        };
    }

    pub fn init(
        alloc: Allocator,
        device_id: u32,
        device_features: u64,
        num_queues: u16,
        device_config_size: usize,
    ) !*VirtioPciTransport {
        assert(num_queues > 0);
        assert(num_queues <= MAX_QUEUES);

        const layout = try allocationLayout(num_queues, device_config_size);
        const allocation = try alloc.alignedAlloc(u8, .of(VirtioPciTransport), layout.size);
        errdefer alloc.free(allocation);
        const transport: *VirtioPciTransport = @ptrCast(allocation.ptr);
        const queues_ptr: [*]QueueConfig = @ptrCast(@alignCast(
            allocation.ptr + layout.queues_offset,
        ));
        const queues = queues_ptr[0..num_queues];
        const device_config = allocation[layout.device_config_offset..];
        transport.initEmbedded(alloc, device_id, device_features, queues, device_config);

        assert(transport.queues.len == num_queues);
        return transport;
    }

    fn initEmbedded(
        self: *VirtioPciTransport,
        alloc: Allocator,
        device_id: u32,
        device_features: u64,
        queues: []QueueConfig,
        device_config: []u8,
    ) void {
        assert(queues.len > 0);
        assert(queues.len <= MAX_QUEUES);
        @memset(queues, QueueConfig{ .size = MAX_QUEUE_SIZE });
        @memset(device_config, 0);

        self.* = .{
            .alloc = alloc,
            .device_id = device_id,
            .device_features = device_features | (1 << 32), // VIRTIO_F_VERSION_1
            .driver_features = 0,
            .device_feature_select = 0,
            .driver_feature_select = 0,
            .status = .{},
            .config_generation = 0,
            .queue_select = 0,
            .num_queues = @intCast(queues.len),
            .queues = queues,
            .isr_status = .{},
            .device_config = device_config,
            .notify_callback = null,
            .notify_userdata = null,
            .irq_callback = null,
            .irq_userdata = null,
        };

        assert(self.queues.len == queues.len);
        assert(self.device_config.len == device_config.len);
    }

    pub fn deinit(self: *VirtioPciTransport) void {
        const layout = allocationLayout(self.num_queues, self.device_config.len) catch unreachable;
        self.queues = &.{};
        self.device_config = &.{};
        const allocation_ptr: [*]align(@alignOf(VirtioPciTransport)) u8 = @ptrCast(self);
        self.alloc.free(allocation_ptr[0..layout.size]);
    }

    pub fn setNotifyCallback(
        self: *VirtioPciTransport,
        callback: *const fn (u32, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.notify_callback = callback;
        self.notify_userdata = userdata;
    }

    pub fn setIrqCallback(
        self: *VirtioPciTransport,
        callback: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.irq_callback = callback;
        self.irq_userdata = userdata;
    }

    /// Read from BAR0 region.
    pub fn readBar(self: *VirtioPciTransport, offset: u32, size: u8) u32 {
        assert(size == 1 or size == 2 or size == 4);

        if (offset < BAR_COMMON_CFG_OFFSET + BAR_COMMON_CFG_SIZE) {
            return self.readCommonCfg(@truncate(offset - BAR_COMMON_CFG_OFFSET), size);
        } else if (offset >= BAR_ISR_OFFSET and offset < BAR_ISR_OFFSET + BAR_ISR_SIZE) {
            return self.readIsr();
        } else if (offset >= BAR_NOTIFY_OFFSET and offset < BAR_NOTIFY_OFFSET + BAR_NOTIFY_SIZE) {
            return 0;
        } else if (offset >= BAR_DEVICE_CFG_OFFSET and offset < BAR_DEVICE_CFG_OFFSET + BAR_DEVICE_CFG_SIZE) {
            return self.readDeviceConfig(@truncate(offset - BAR_DEVICE_CFG_OFFSET), size);
        }
        return 0xFFFFFFFF;
    }

    /// Write to BAR0 region.
    pub fn writeBar(self: *VirtioPciTransport, offset: u32, size: u8, value: u32) void {
        assert(size == 1 or size == 2 or size == 4);

        if (offset < BAR_COMMON_CFG_OFFSET + BAR_COMMON_CFG_SIZE) {
            self.writeCommonCfg(@truncate(offset - BAR_COMMON_CFG_OFFSET), size, value);
        } else if (offset >= BAR_ISR_OFFSET and offset < BAR_ISR_OFFSET + BAR_ISR_SIZE) {
            self.isr_status = .{};
        } else if (offset >= BAR_NOTIFY_OFFSET and offset < BAR_NOTIFY_OFFSET + BAR_NOTIFY_SIZE) {
            self.handleNotify(value);
        } else if (offset >= BAR_DEVICE_CFG_OFFSET and offset < BAR_DEVICE_CFG_OFFSET + BAR_DEVICE_CFG_SIZE) {
            self.writeDeviceConfig(@truncate(offset - BAR_DEVICE_CFG_OFFSET), size, value);
        }
    }

    fn readCommonCfg(self: *VirtioPciTransport, offset: u8, size: u8) u32 {
        _ = size;
        return switch (@as(CommonCfgReg, @enumFromInt(offset))) {
            .device_feature_select => self.device_feature_select,
            .device_feature => self.readDeviceFeatures(),
            .driver_feature_select => self.driver_feature_select,
            .driver_feature => self.readDriverFeatures(),
            .msix_config => 0xFFFF, // No MSI-X
            .num_queues => self.num_queues,
            .device_status => @intFromBool(self.status.acknowledge) |
                (@as(u32, @intFromBool(self.status.driver)) << 1) |
                (@as(u32, @intFromBool(self.status.driver_ok)) << 2) |
                (@as(u32, @intFromBool(self.status.features_ok)) << 3) |
                (@as(u32, @intFromBool(self.status.device_needs_reset)) << 6) |
                (@as(u32, @intFromBool(self.status.failed)) << 7),
            .config_generation => self.config_generation,
            .queue_select => self.queue_select,
            .queue_size => if (self.currentQueue()) |q| q.size else MAX_QUEUE_SIZE,
            .queue_msix_vector => 0xFFFF,
            .queue_enable => if (self.currentQueue()) |q| @intFromBool(q.enable) else 0,
            .queue_notify_off => if (self.currentQueue()) |q| q.notify_off else 0,
            .queue_desc_lo => if (self.currentQueue()) |q| @truncate(q.desc_addr) else 0,
            .queue_desc_hi => if (self.currentQueue()) |q| @truncate(q.desc_addr >> 32) else 0,
            .queue_driver_lo => if (self.currentQueue()) |q| @truncate(q.driver_addr) else 0,
            .queue_driver_hi => if (self.currentQueue()) |q| @truncate(q.driver_addr >> 32) else 0,
            .queue_device_lo => if (self.currentQueue()) |q| @truncate(q.device_addr) else 0,
            .queue_device_hi => if (self.currentQueue()) |q| @truncate(q.device_addr >> 32) else 0,
            .queue_reset => 0,
            else => 0,
        };
    }

    fn writeCommonCfg(self: *VirtioPciTransport, offset: u8, size: u8, value: u32) void {
        _ = size;
        switch (@as(CommonCfgReg, @enumFromInt(offset))) {
            .device_feature_select => self.device_feature_select = value,
            .driver_feature_select => self.driver_feature_select = value,
            .driver_feature => self.writeDriverFeatures(value),
            .device_status => self.handleStatusWrite(@truncate(value)),
            .queue_select => {
                if (value < self.num_queues) {
                    self.queue_select = @truncate(value);
                }
            },
            .queue_size => {
                if (self.currentQueue()) |q| {
                    q.size = @truncate(value);
                }
            },
            .queue_enable => {
                if (self.currentQueue()) |q| {
                    q.enable = value != 0;
                }
            },
            .queue_desc_lo => {
                if (self.currentQueue()) |q| {
                    q.desc_addr = (q.desc_addr & 0xFFFFFFFF00000000) | value;
                }
            },
            .queue_desc_hi => {
                if (self.currentQueue()) |q| {
                    q.desc_addr = (q.desc_addr & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
                }
            },
            .queue_driver_lo => {
                if (self.currentQueue()) |q| {
                    q.driver_addr = (q.driver_addr & 0xFFFFFFFF00000000) | value;
                }
            },
            .queue_driver_hi => {
                if (self.currentQueue()) |q| {
                    q.driver_addr = (q.driver_addr & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
                }
            },
            .queue_device_lo => {
                if (self.currentQueue()) |q| {
                    q.device_addr = (q.device_addr & 0xFFFFFFFF00000000) | value;
                }
            },
            .queue_device_hi => {
                if (self.currentQueue()) |q| {
                    q.device_addr = (q.device_addr & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
                }
            },
            .queue_reset => {
                if (value != 0) {
                    if (self.currentQueue()) |q| {
                        q.* = QueueConfig{ .size = MAX_QUEUE_SIZE };
                    }
                }
            },
            else => {},
        }
    }

    fn readIsr(self: *VirtioPciTransport) u32 {
        const status: u8 = @bitCast(self.isr_status);
        self.isr_status = .{};
        return status;
    }

    fn readDeviceConfig(self: *VirtioPciTransport, offset: u8, size: u8) u32 {
        if (@as(usize, offset) + size > self.device_config.len) return 0;

        return switch (size) {
            1 => self.device_config[offset],
            2 => @as(u32, self.device_config[offset]) |
                (@as(u32, self.device_config[offset + 1]) << 8),
            4 => @as(u32, self.device_config[offset]) |
                (@as(u32, self.device_config[offset + 1]) << 8) |
                (@as(u32, self.device_config[offset + 2]) << 16) |
                (@as(u32, self.device_config[offset + 3]) << 24),
            else => 0,
        };
    }

    fn writeDeviceConfig(self: *VirtioPciTransport, offset: u8, size: u8, value: u32) void {
        if (@as(usize, offset) + size > self.device_config.len) return;

        switch (size) {
            1 => self.device_config[offset] = @truncate(value),
            2 => {
                self.device_config[offset] = @truncate(value);
                self.device_config[offset + 1] = @truncate(value >> 8);
            },
            4 => {
                self.device_config[offset] = @truncate(value);
                self.device_config[offset + 1] = @truncate(value >> 8);
                self.device_config[offset + 2] = @truncate(value >> 16);
                self.device_config[offset + 3] = @truncate(value >> 24);
            },
            else => {},
        }
    }

    fn currentQueue(self: *VirtioPciTransport) ?*QueueConfig {
        if (self.queue_select < self.queues.len) {
            return &self.queues[self.queue_select];
        }
        return null;
    }

    fn readDeviceFeatures(self: *VirtioPciTransport) u32 {
        return switch (self.device_feature_select) {
            0 => @truncate(self.device_features),
            1 => @truncate(self.device_features >> 32),
            else => 0,
        };
    }

    fn readDriverFeatures(self: *VirtioPciTransport) u32 {
        return switch (self.driver_feature_select) {
            0 => @truncate(self.driver_features),
            1 => @truncate(self.driver_features >> 32),
            else => 0,
        };
    }

    fn writeDriverFeatures(self: *VirtioPciTransport, value: u32) void {
        switch (self.driver_feature_select) {
            0 => self.driver_features = (self.driver_features & 0xFFFFFFFF00000000) | value,
            1 => self.driver_features =
                (self.driver_features & 0x00000000FFFFFFFF) | (@as(u64, value) << 32),
            else => {},
        }
    }

    fn handleStatusWrite(self: *VirtioPciTransport, value: u8) void {
        if (value == 0) {
            self.reset();
            return;
        }
        self.status = @bitCast(value);
    }

    fn handleNotify(self: *VirtioPciTransport, queue_idx: u32) void {
        if (!self.isReady()) return;
        if (self.notify_callback) |cb| {
            cb(queue_idx, self.notify_userdata);
        }
    }

    pub fn reset(self: *VirtioPciTransport) void {
        self.status = .{};
        self.driver_features = 0;
        self.device_feature_select = 0;
        self.driver_feature_select = 0;
        self.queue_select = 0;
        self.isr_status = .{};

        for (self.queues) |*q| {
            q.* = QueueConfig{ .size = MAX_QUEUE_SIZE };
        }
    }

    pub fn signalUsedBuffer(self: *VirtioPciTransport) void {
        self.isr_status.queue_interrupt = true;
        if (self.irq_callback) |cb| {
            cb(self.irq_userdata);
        }
    }

    pub fn signalConfigChange(self: *VirtioPciTransport) void {
        self.isr_status.config_change = true;
        self.config_generation +%= 1;
        if (self.irq_callback) |cb| {
            cb(self.irq_userdata);
        }
    }

    pub fn isReady(self: *VirtioPciTransport) bool {
        return self.status.driver_ok and self.status.features_ok;
    }

    /// Update device config (e.g., for virtio-blk capacity).
    pub fn setDeviceConfig(self: *VirtioPciTransport, data: []const u8) void {
        const len = @min(data.len, self.device_config.len);
        @memcpy(self.device_config[0..len], data[0..len]);
    }
};

/// Virtio PCI device with full PCI config space.
pub const VirtioPciDevice = struct {
    alloc: Allocator,
    transport: *VirtioPciTransport,

    /// PCI configuration space (4KB).
    config: [4096]u8,

    /// BAR0 address (assigned by OS/firmware).
    bar0_addr: u32,

    /// Device-specific info.
    subsystem_id: u16,

    const AllocationLayout = struct {
        transport_offset: usize,
        transport: VirtioPciTransport.AllocationLayout,
        size: usize,
    };

    fn allocationLayout(num_queues: u16, device_config_size: usize) Allocator.Error!AllocationLayout {
        comptime assert(@alignOf(VirtioPciDevice) >= @alignOf(VirtioPciTransport));
        const transport_offset = std.mem.alignForward(
            usize,
            @sizeOf(VirtioPciDevice),
            @alignOf(VirtioPciTransport),
        );
        const transport = try VirtioPciTransport.allocationLayout(
            num_queues,
            device_config_size,
        );
        const size = std.math.add(usize, transport_offset, transport.size) catch
            return error.OutOfMemory;
        assert(transport_offset >= @sizeOf(VirtioPciDevice));
        return .{ .transport_offset = transport_offset, .transport = transport, .size = size };
    }

    pub fn init(
        alloc: Allocator,
        device_id: u32,
        subsystem_id: u16,
        device_features: u64,
        num_queues: u16,
        device_config_size: usize,
    ) !*VirtioPciDevice {
        const layout = try allocationLayout(num_queues, device_config_size);
        const allocation = try alloc.alignedAlloc(u8, .of(VirtioPciDevice), layout.size);
        errdefer alloc.free(allocation);
        const dev: *VirtioPciDevice = @ptrCast(allocation.ptr);
        const transport: *VirtioPciTransport = @ptrCast(@alignCast(
            allocation.ptr + layout.transport_offset,
        ));
        const queues_ptr: [*]QueueConfig = @ptrCast(@alignCast(
            allocation.ptr + layout.transport_offset + layout.transport.queues_offset,
        ));
        const queues = queues_ptr[0..num_queues];
        const device_config_offset = layout.transport_offset + layout.transport.device_config_offset;
        const device_config = allocation[device_config_offset..];
        transport.initEmbedded(alloc, device_id, device_features, queues, device_config);

        dev.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = [_]u8{0} ** 4096,
            .bar0_addr = 0,
            .subsystem_id = subsystem_id,
        };

        dev.initConfigSpace();

        assert(dev.transport.device_id == device_id);
        return dev;
    }

    pub fn deinit(self: *VirtioPciDevice) void {
        const layout = allocationLayout(
            self.transport.num_queues,
            self.transport.device_config.len,
        ) catch unreachable;
        self.transport.queues = &.{};
        self.transport.device_config = &.{};
        const allocation_ptr: [*]align(@alignOf(VirtioPciDevice)) u8 = @ptrCast(self);
        self.alloc.free(allocation_ptr[0..layout.size]);
    }

    fn initConfigSpace(self: *VirtioPciDevice) void {
        // Vendor ID: Virtio (0x1AF4)
        self.setConfigU16(0x00, 0x1AF4);
        // Device ID: Use transitional IDs for UEFI compatibility
        // Block = 0x1001, Console = 0x1003, etc. (not modern-only 0x1040+)
        const device_id: u16 = switch (self.transport.device_id) {
            2 => 0x1001, // virtio-blk transitional
            3 => 0x1003, // virtio-console transitional
            else => 0x1040 + @as(u16, @truncate(self.transport.device_id)),
        };
        self.setConfigU16(0x02, device_id);
        // Command: All disabled initially (UEFI enables after BAR assignment)
        self.setConfigU16(0x04, 0x0000);
        // Status: Capabilities list present
        self.setConfigU16(0x06, 0x0010);
        // Revision ID
        self.config[0x08] = 0x01;
        // PCI class code helps firmware and the guest choose the right driver.
        self.config[0x09] = 0x00; // Prog IF
        self.config[0x0A] = 0x00; // Subclass
        self.config[0x0B] = switch (self.transport.device_id) {
            2 => 0x01, // Mass storage
            16 => 0x03, // Display controller
            else => 0x00,
        };
        // Header type
        self.config[0x0E] = 0x00;
        // BAR0: Memory, 32-bit, non-prefetchable (size set during BAR sizing)
        self.setConfigU32(0x10, 0x00000000);
        // Subsystem Vendor ID
        self.setConfigU16(0x2C, 0x1AF4);
        // Subsystem ID
        self.setConfigU16(0x2E, self.subsystem_id);
        // Capabilities pointer
        self.config[0x34] = 0x40;
        // Interrupt pin: INTA#
        self.config[0x3D] = 0x01;

        log.info("PCI config: vendor=0x{x} device=0x{x} class=0x{x:0>2}{x:0>2}{x:0>2}", .{
            @as(u16, 0x1AF4),
            device_id,
            self.config[0x0B],
            self.config[0x0A],
            self.config[0x09],
        });

        self.buildCapabilities();
    }

    fn buildCapabilities(self: *VirtioPciDevice) void {
        var cap_offset: u8 = 0x40;

        // Common configuration capability
        cap_offset = self.addCapability(cap_offset, .common_cfg, BAR_COMMON_CFG_OFFSET, BAR_COMMON_CFG_SIZE, false);

        // Notification capability (with multiplier)
        const notify_cap_offset = cap_offset;
        cap_offset = self.addCapability(cap_offset, .notify_cfg, BAR_NOTIFY_OFFSET, BAR_NOTIFY_SIZE, false);
        // Add notify_off_multiplier (0 = same address for all queues)
        self.setConfigU32(notify_cap_offset + 16, 0);

        // ISR status capability
        cap_offset = self.addCapability(cap_offset, .isr_cfg, BAR_ISR_OFFSET, BAR_ISR_SIZE, false);

        // Device-specific configuration capability (last in chain, next=0)
        _ = self.addCapability(cap_offset, .device_cfg, BAR_DEVICE_CFG_OFFSET, @intCast(self.transport.device_config.len), true);
    }

    fn addCapability(self: *VirtioPciDevice, offset: u8, cap_type: CapType, bar_offset: u32, length: u32, is_last: bool) u8 {
        const cap_len: u8 = if (cap_type == .notify_cfg) 20 else 16;
        const next_offset = offset + cap_len;

        self.config[offset + 0] = PCI_CAP_ID_VNDR;
        self.config[offset + 1] = if (is_last) 0 else next_offset; // next capability or 0 for end
        self.config[offset + 2] = cap_len;
        self.config[offset + 3] = @intFromEnum(cap_type);
        self.config[offset + 4] = 0; // BAR0
        self.config[offset + 5] = 0; // id
        self.config[offset + 6] = 0; // padding
        self.config[offset + 7] = 0; // padding
        self.setConfigU32At(offset + 8, bar_offset);
        self.setConfigU32At(offset + 12, length);

        return next_offset;
    }

    fn setConfigU16(self: *VirtioPciDevice, offset: u8, value: u16) void {
        self.config[offset] = @truncate(value);
        self.config[offset + 1] = @truncate(value >> 8);
    }

    fn setConfigU32(self: *VirtioPciDevice, offset: u8, value: u32) void {
        self.config[offset] = @truncate(value);
        self.config[offset + 1] = @truncate(value >> 8);
        self.config[offset + 2] = @truncate(value >> 16);
        self.config[offset + 3] = @truncate(value >> 24);
    }

    fn setConfigU32At(self: *VirtioPciDevice, offset: u8, value: u32) void {
        self.config[offset] = @truncate(value);
        self.config[offset + 1] = @truncate(value >> 8);
        self.config[offset + 2] = @truncate(value >> 16);
        self.config[offset + 3] = @truncate(value >> 24);
    }

    /// Read PCI configuration space.
    pub fn readConfig(self: *VirtioPciDevice, offset: u12, size: u8) u64 {
        assert(size == 1 or size == 2 or size == 4);
        if (@as(usize, offset) + size > self.config.len) return 0xFFFFFFFF;

        return switch (size) {
            1 => self.config[offset],
            2 => @as(u16, self.config[offset]) | (@as(u16, self.config[offset + 1]) << 8),
            4 => @as(u32, self.config[offset]) |
                (@as(u32, self.config[offset + 1]) << 8) |
                (@as(u32, self.config[offset + 2]) << 16) |
                (@as(u32, self.config[offset + 3]) << 24),
            else => 0xFFFFFFFF,
        };
    }

    /// Write PCI configuration space.
    pub fn writeConfig(self: *VirtioPciDevice, offset: u12, size: u8, value: u64) void {
        assert(size == 1 or size == 2 or size == 4);
        if (@as(usize, offset) + size > self.config.len) return;

        switch (offset) {
            0x04 => {
                // Command register - allow setting bus master, memory enable
                const cmd: u16 = @truncate(value);
                self.setConfigU16(0x04, cmd & 0x0007); // Only bits 0-2
            },
            0x10 => {
                // BAR0 sizing or address write
                if (value == 0xFFFFFFFF) {
                    // BAR sizing: return size mask (~(size-1) | type bits)
                    // BAR0_SIZE is 4KB, so mask is 0xFFFFF000
                    self.setConfigU32(0x10, 0xFFFFF000);
                    log.debug("BAR0 sizing: returning 0xFFFFF000 (4KB)", .{});
                } else {
                    // Store BAR address (preserve low 4 bits as 0 for memory BAR)
                    self.bar0_addr = @truncate(value & 0xFFFFF000);
                    self.setConfigU32(0x10, self.bar0_addr);
                    log.info("BAR0 assigned to 0x{x}", .{self.bar0_addr});
                }
            },
            else => {
                // Generic write for writable regions
                if (offset < 0x40) {
                    switch (size) {
                        1 => self.config[offset] = @truncate(value),
                        2 => {
                            self.config[offset] = @truncate(value);
                            self.config[offset + 1] = @truncate(value >> 8);
                        },
                        4 => {
                            self.config[offset] = @truncate(value);
                            self.config[offset + 1] = @truncate(value >> 8);
                            self.config[offset + 2] = @truncate(value >> 16);
                            self.config[offset + 3] = @truncate(value >> 24);
                        },
                        else => {},
                    }
                }
            },
        }
    }

    /// Read from BAR0 MMIO region.
    pub fn readBar0(self: *VirtioPciDevice, offset: u32, size: u8) u32 {
        return self.transport.readBar(offset, size);
    }

    /// Write to BAR0 MMIO region.
    pub fn writeBar0(self: *VirtioPciDevice, offset: u32, size: u8, value: u32) void {
        self.transport.writeBar(offset, size, value);
    }

    /// Get the assigned BAR0 address.
    pub fn getBar0Addr(self: *VirtioPciDevice) u32 {
        return self.bar0_addr;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "VirtioPciTransport init" {
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, 0, 1, 64);
    defer transport.deinit();

    try std.testing.expectEqual(@as(u32, 2), transport.device_id);
    try std.testing.expectEqual(@as(u16, 1), transport.num_queues);
}

test "virtio GPU uses the modern device id and display class" {
    const device = try VirtioPciDevice.init(std.testing.allocator, 16, 16, 0, 2, 16);
    defer device.deinit();

    try std.testing.expectEqual(@as(u8, 0x50), device.config[0x02]);
    try std.testing.expectEqual(@as(u8, 0x10), device.config[0x03]);
    try std.testing.expectEqual(@as(u8, 0x03), device.config[0x0B]);
}

test "VirtioPciTransport allocation profile" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const num_queues: u16 = 2;
    const device_config_size: usize = 64;
    const transport = try VirtioPciTransport.init(
        counted.allocator(),
        2,
        0,
        num_queues,
        device_config_size,
    );
    defer transport.deinit();

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqual(
        @sizeOf(VirtioPciTransport) + @as(usize, num_queues) * @sizeOf(QueueConfig) +
            device_config_size,
        counted.allocated_bytes,
    );
}

test "VirtioPciTransport common config read" {
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, 0x100, 2, 64);
    defer transport.deinit();

    // Read num_queues
    const num_queues = transport.readBar(BAR_COMMON_CFG_OFFSET + @intFromEnum(CommonCfgReg.num_queues), 2);
    try std.testing.expectEqual(@as(u32, 2), num_queues);

    // Read device_feature (low 32 bits)
    transport.device_feature_select = 0;
    const features_lo = transport.readBar(BAR_COMMON_CFG_OFFSET + @intFromEnum(CommonCfgReg.device_feature), 4);
    try std.testing.expectEqual(@as(u32, 0x100), features_lo);
}

test "VirtioPciTransport preserves standard high device status bits" {
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, 0, 1, 64);
    defer transport.deinit();

    const status_offset = @intFromEnum(CommonCfgReg.device_status);
    transport.writeBar(status_offset, 1, 0xC3);

    try std.testing.expectEqual(@as(u32, 0xC3), transport.readBar(status_offset, 1));
}

test "VirtioPciTransport ignores feature selector pages above one" {
    const features: u64 = 0x1122_3344_5566_7788;
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, features, 1, 64);
    defer transport.deinit();

    transport.writeBar(@intFromEnum(CommonCfgReg.device_feature_select), 4, 2);
    try std.testing.expectEqual(
        @as(u32, 0),
        transport.readBar(@intFromEnum(CommonCfgReg.device_feature), 4),
    );

    transport.writeBar(@intFromEnum(CommonCfgReg.driver_feature_select), 4, 2);
    transport.writeBar(@intFromEnum(CommonCfgReg.driver_feature), 4, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u64, 0), transport.driver_features);
}

test "VirtioPciTransport notifications require a ready driver" {
    const State = struct {
        notifications: usize = 0,
        queue: u32 = 0,

        fn notify(queue: u32, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            self.notifications += 1;
            self.queue = queue;
        }
    };
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, 0, 1, 64);
    defer transport.deinit();
    var state = State{};
    transport.setNotifyCallback(State.notify, &state);

    transport.writeBar(BAR_NOTIFY_OFFSET, 4, 7);
    try std.testing.expectEqual(@as(usize, 0), state.notifications);

    transport.writeBar(@intFromEnum(CommonCfgReg.device_status), 1, 0x0C);
    transport.writeBar(BAR_NOTIFY_OFFSET, 4, 7);
    try std.testing.expectEqual(@as(usize, 1), state.notifications);
    try std.testing.expectEqual(@as(u32, 7), state.queue);
}

test "VirtioPciTransport config changes raise an interrupt" {
    const State = struct {
        irqs: usize = 0,

        fn irq(userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            self.irqs += 1;
        }
    };
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, 0, 1, 64);
    defer transport.deinit();
    var state = State{};
    transport.setIrqCallback(State.irq, &state);

    transport.signalConfigChange();

    try std.testing.expectEqual(@as(usize, 1), state.irqs);
    try std.testing.expect(transport.isr_status.config_change);
    try std.testing.expectEqual(@as(u8, 1), transport.config_generation);
}

test "VirtioPciTransport ignores unnamed common configuration offsets" {
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, 0, 1, 64);
    defer transport.deinit();

    try std.testing.expectEqual(@as(u32, 0), transport.readBar(0x03, 1));
    transport.writeBar(0x03, 1, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 0), transport.readBar(0x03, 1));
}

test "VirtioPciTransport rejects device config accesses crossing the BAR window" {
    const transport = try VirtioPciTransport.init(std.testing.allocator, 2, 0, 1, 256);
    defer transport.deinit();

    const last = BAR_DEVICE_CFG_OFFSET + BAR_DEVICE_CFG_SIZE - 1;
    transport.writeBar(last, 1, 0xA5);
    try std.testing.expectEqual(@as(u32, 0), transport.readBar(last, 4));
    transport.writeBar(last, 4, 0);
    try std.testing.expectEqual(@as(u32, 0xA5), transport.readBar(last, 1));
}

test "VirtioPciDevice init and config" {
    const dev = try VirtioPciDevice.init(std.testing.allocator, 2, 0x0002, 0, 1, 64);
    defer dev.deinit();

    // Check vendor ID
    const vendor = dev.readConfig(0x00, 2);
    try std.testing.expectEqual(@as(u64, 0x1AF4), vendor);

    // Check device ID (0x1001 for transitional block device)
    const device_id = dev.readConfig(0x02, 2);
    try std.testing.expectEqual(@as(u64, 0x1001), device_id);

    // Check capabilities pointer
    const cap_ptr = dev.readConfig(0x34, 1);
    try std.testing.expectEqual(@as(u64, 0x40), cap_ptr);
}

test "VirtioPciDevice rejects config reads crossing its address space" {
    const dev = try VirtioPciDevice.init(std.testing.allocator, 2, 0, 0, 1, 64);
    defer dev.deinit();

    try std.testing.expectEqual(
        @as(u64, 0xFFFF_FFFF),
        dev.readConfig(std.math.maxInt(u12), 4),
    );
}

test "VirtioPciDevice allocation profile" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const num_queues: u16 = 2;
    const device_config_size: usize = 64;
    const dev = try VirtioPciDevice.init(
        counted.allocator(),
        2,
        0x0002,
        0,
        num_queues,
        device_config_size,
    );
    defer dev.deinit();

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqual(
        @sizeOf(VirtioPciDevice) + @sizeOf(VirtioPciTransport) +
            @as(usize, num_queues) * @sizeOf(QueueConfig) + device_config_size,
        counted.allocated_bytes,
    );
}

test "VirtioPciDevice BAR sizing" {
    const dev = try VirtioPciDevice.init(std.testing.allocator, 2, 0x0002, 0, 1, 64);
    defer dev.deinit();

    // Write all 1s to BAR0
    dev.writeConfig(0x10, 4, 0xFFFFFFFF);

    // Read back should show size mask
    const bar0 = dev.readConfig(0x10, 4);
    try std.testing.expectEqual(@as(u64, 0xFFFFF000), bar0);
}
