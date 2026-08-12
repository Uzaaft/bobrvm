//! QEMU-virt-compatible GPEX host bridge used by the UEFI boot path.
//!
//! ECAM addresses encode bus, device, function, and register in bits 27:20,
//! 19:15, 14:12, and 11:0 respectively.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const config_policy = @import("config.zig");

const log = std.log.scoped(.pci_ecam);

pub const ECAM_BASE: u64 = 0x3c00_0000;

/// 256 buses * 32 devices * 8 functions * 4 KiB.
pub const ECAM_SIZE: u64 = 64 * 1024 * 1024;

pub const PCI_MMIO_BASE: u64 = 0x1000_0000;

pub const PCI_MMIO_SIZE: u64 = 0x2c00_0000;

/// ARM64 does not use the I/O-port aperture, but firmware expects it in ACPI.
pub const PCI_IO_BASE: u64 = 0x0;

pub const PCI_IO_SIZE: u64 = 0x10000;

pub const MAX_DEVICES: usize = 32;

pub const MAX_FUNCTIONS: usize = 8;

pub const CONFIG_SPACE_SIZE: u64 = 4096;

/// PCI vendor/device IDs.
pub const VendorId = enum(u16) {
    invalid = 0xFFFF,
    virtio = 0x1AF4,
};

pub const DeviceId = enum(u16) {
    invalid = 0xFFFF,
    virtio_block = 0x1001,
    virtio_console = 0x1003,
    virtio_gpu = 0x1050,
};

/// PCI class codes.
pub const ClassCode = struct {
    pub const MASS_STORAGE: u8 = 0x01;
    pub const COMMUNICATION: u8 = 0x07;
    pub const DISPLAY: u8 = 0x03;
};

/// PCI configuration space header offsets.
pub const ConfigReg = enum(u12) {
    vendor_id = 0x00,
    device_id = 0x02,
    command = 0x04,
    status = 0x06,
    revision = 0x08,
    class_code = 0x09,
    cache_line = 0x0C,
    latency = 0x0D,
    header_type = 0x0E,
    bist = 0x0F,
    bar0 = 0x10,
    bar1 = 0x14,
    bar2 = 0x18,
    bar3 = 0x1C,
    bar4 = 0x20,
    bar5 = 0x24,
    subsys_vendor = 0x2C,
    subsys_id = 0x2E,
    cap_ptr = 0x34,
    interrupt_line = 0x3C,
    interrupt_pin = 0x3D,
    _,
};

/// Decoded ECAM address.
pub const EcamAddr = struct {
    bus: u8,
    device: u5,
    function: u3,
    reg: u12,

    pub fn decode(addr: u64) EcamAddr {
        assert(addr >= ECAM_BASE);
        assert(addr < ECAM_BASE + ECAM_SIZE);

        const offset = addr - ECAM_BASE;
        return .{
            .bus = @truncate(offset >> 20),
            .device = @truncate(offset >> 15),
            .function = @truncate(offset >> 12),
            .reg = @truncate(offset),
        };
    }

    pub fn format(self: EcamAddr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{x:0>2}:{x:0>2}.{d}", .{ self.bus, @as(u8, self.device), @as(u8, self.function) });
    }
};

/// PCI device configuration space (4KB).
pub const PciDevice = struct {
    config: [CONFIG_SPACE_SIZE]u8,
    present: bool,

    pub fn init() PciDevice {
        return .{
            .config = [_]u8{0xFF} ** CONFIG_SPACE_SIZE,
            .present = false,
        };
    }

    pub fn initVirtioBlock(bar_addr: u32) PciDevice {
        var dev = PciDevice.init();
        dev.present = true;

        dev.setU16(@intFromEnum(ConfigReg.vendor_id), @intFromEnum(VendorId.virtio));
        dev.setU16(@intFromEnum(ConfigReg.device_id), @intFromEnum(DeviceId.virtio_block));
        dev.setU16(@intFromEnum(ConfigReg.command), 0x0000);
        dev.setU16(@intFromEnum(ConfigReg.status), 0x0010); // Capabilities list
        dev.setU8(@intFromEnum(ConfigReg.revision), 0x01);
        dev.setU8(@intFromEnum(ConfigReg.class_code), ClassCode.MASS_STORAGE);
        dev.setU8(@intFromEnum(ConfigReg.class_code) + 1, 0x00); // Subclass
        dev.setU8(@intFromEnum(ConfigReg.class_code) + 2, 0x00); // ProgIf
        dev.setU8(@intFromEnum(ConfigReg.header_type), 0x00);
        dev.setU32(@intFromEnum(ConfigReg.bar0), bar_addr);
        dev.setU16(@intFromEnum(ConfigReg.subsys_vendor), @intFromEnum(VendorId.virtio));
        dev.setU16(@intFromEnum(ConfigReg.subsys_id), 0x0002);
        dev.setU8(@intFromEnum(ConfigReg.interrupt_pin), 1); // INTA#

        return dev;
    }

    pub fn initVirtioConsole(bar_addr: u32) PciDevice {
        var dev = PciDevice.init();
        dev.present = true;

        dev.setU16(@intFromEnum(ConfigReg.vendor_id), @intFromEnum(VendorId.virtio));
        dev.setU16(@intFromEnum(ConfigReg.device_id), @intFromEnum(DeviceId.virtio_console));
        dev.setU16(@intFromEnum(ConfigReg.command), 0x0000);
        dev.setU16(@intFromEnum(ConfigReg.status), 0x0010);
        dev.setU8(@intFromEnum(ConfigReg.revision), 0x01);
        dev.setU8(@intFromEnum(ConfigReg.class_code), ClassCode.COMMUNICATION);
        dev.setU8(@intFromEnum(ConfigReg.class_code) + 1, 0x80); // Other
        dev.setU8(@intFromEnum(ConfigReg.class_code) + 2, 0x00);
        dev.setU8(@intFromEnum(ConfigReg.header_type), 0x00);
        dev.setU32(@intFromEnum(ConfigReg.bar0), bar_addr);
        dev.setU16(@intFromEnum(ConfigReg.subsys_vendor), @intFromEnum(VendorId.virtio));
        dev.setU16(@intFromEnum(ConfigReg.subsys_id), 0x0003);
        dev.setU8(@intFromEnum(ConfigReg.interrupt_pin), 1);

        return dev;
    }

    fn setU8(self: *PciDevice, offset: u12, value: u8) void {
        self.config[offset] = value;
    }

    fn setU16(self: *PciDevice, offset: u12, value: u16) void {
        self.config[offset] = @truncate(value);
        self.config[offset + 1] = @truncate(value >> 8);
    }

    fn setU32(self: *PciDevice, offset: u12, value: u32) void {
        self.config[offset] = @truncate(value);
        self.config[offset + 1] = @truncate(value >> 8);
        self.config[offset + 2] = @truncate(value >> 16);
        self.config[offset + 3] = @truncate(value >> 24);
    }

    pub fn read(self: *const PciDevice, offset: u12, size: u8) u64 {
        assert(size == 1 or size == 2 or size == 4);
        if (@as(u64, offset) + size > CONFIG_SPACE_SIZE) return 0xFFFFFFFF;

        if (!self.present) {
            return 0xFFFFFFFF;
        }

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

    pub fn write(self: *PciDevice, offset: u12, size: u8, value: u64) void {
        assert(size == 1 or size == 2 or size == 4);
        if (@as(u64, offset) + size > CONFIG_SPACE_SIZE) return;

        if (!self.present) return;

        _ = config_policy.writeType0(&self.config, offset, size, value);
    }
};

/// PCIe ECAM host bridge.
pub const EcamHost = struct {
    alloc: Allocator,
    devices: ?*DeviceNode,

    const DeviceNode = struct {
        next: ?*DeviceNode,
        index: u8,
        embedded: bool,
        occupied: bool,
        device: PciDevice,
    };

    pub fn init(alloc: Allocator, reserve_first_device: bool) !*EcamHost {
        comptime {
            assert(@alignOf(EcamHost) >= @alignOf(DeviceNode));
            const LegacyDeviceNode = struct {
                next: ?*DeviceNode,
                index: u8,
                device: PciDevice,
            };
            assert(@sizeOf(DeviceNode) == @sizeOf(LegacyDeviceNode));
        }
        const allocation_bytes = @sizeOf(EcamHost) +
            @as(usize, @intFromBool(reserve_first_device)) * @sizeOf(DeviceNode);
        const allocation = try alloc.alignedAlloc(u8, .of(EcamHost), allocation_bytes);
        errdefer alloc.free(allocation);
        const host: *EcamHost = @ptrCast(allocation.ptr);
        const embedded_node: ?*DeviceNode = if (reserve_first_device)
            @ptrCast(@alignCast(allocation.ptr + @sizeOf(EcamHost)))
        else
            null;
        if (embedded_node) |node| {
            node.* = .{
                .next = null,
                .index = 0,
                .embedded = true,
                .occupied = false,
                .device = undefined,
            };
        }

        host.* = .{
            .alloc = alloc,
            .devices = embedded_node,
        };

        log.info("initialized PCIe ECAM host at 0x{x}-0x{x}", .{ ECAM_BASE, ECAM_BASE + ECAM_SIZE });
        return host;
    }

    pub fn deinit(self: *EcamHost) void {
        var node = self.devices;
        var embedded = false;
        while (node) |current| {
            node = current.next;
            if (current.embedded) {
                assert(!embedded);
                embedded = true;
            } else {
                self.alloc.destroy(current);
            }
        }
        const allocation_bytes = @sizeOf(EcamHost) +
            @as(usize, @intFromBool(embedded)) * @sizeOf(DeviceNode);
        const allocation_ptr: [*]align(@alignOf(EcamHost)) u8 = @ptrCast(self);
        self.alloc.free(allocation_ptr[0..allocation_bytes]);
    }

    pub fn addDevice(self: *EcamHost, device: u5, function: u3, dev: PciDevice) Allocator.Error!void {
        assert(dev.present);
        const index: u8 = @intCast(@as(usize, device) * MAX_FUNCTIONS + function);
        assert(self.findDevice(index) == null);

        var available = self.devices;
        while (available) |node| : (available = node.next) {
            if (!node.occupied) {
                assert(node.embedded);
                node.index = index;
                node.device = dev;
                node.occupied = true;
                log.debug("added PCI device at 00:{x:0>2}.{}", .{ device, function });
                return;
            }
        }

        const node = try self.alloc.create(DeviceNode);
        node.* = .{
            .next = self.devices,
            .index = index,
            .embedded = false,
            .occupied = true,
            .device = dev,
        };
        self.devices = node;
        log.debug("added PCI device at 00:{x:0>2}.{}", .{ device, function });
    }

    pub fn updateConfig(
        self: *EcamHost,
        device: u5,
        function: u3,
        config: *const [CONFIG_SPACE_SIZE]u8,
    ) void {
        const index: u8 = @intCast(@as(usize, device) * MAX_FUNCTIONS + function);
        const dev = self.findDevice(index) orelse unreachable;
        assert(dev.present);
        assert(config.len == CONFIG_SPACE_SIZE);
        @memcpy(&dev.config, config);
    }

    fn findDevice(self: *const EcamHost, index: u8) ?*PciDevice {
        var node = self.devices;
        while (node) |current| : (node = current.next) {
            if (current.occupied and current.index == index) return &current.device;
        }
        return null;
    }

    pub fn read(self: *const EcamHost, addr: u64, size: u8) u64 {
        const ecam = EcamAddr.decode(addr);

        // Only bus 0 is populated
        if (ecam.bus != 0) {
            return 0xFFFFFFFF;
        }

        const index: u8 = @intCast(@as(usize, ecam.device) * MAX_FUNCTIONS + ecam.function);
        const device = self.findDevice(index) orelse return 0xFFFFFFFF;
        const value = device.read(ecam.reg, size);

        if (ecam.reg < 0x40) {
            log.debug("ECAM read {any} reg=0x{x} size={d} -> 0x{x}", .{ ecam, ecam.reg, size, value });
        }

        return value;
    }

    pub fn write(self: *EcamHost, addr: u64, size: u8, value: u64) void {
        const ecam = EcamAddr.decode(addr);

        if (ecam.bus != 0) return;

        const index: u8 = @intCast(@as(usize, ecam.device) * MAX_FUNCTIONS + ecam.function);
        const device = self.findDevice(index) orelse return;
        device.write(ecam.reg, size, value);

        log.debug("ECAM write {any} reg=0x{x} size={d} <- 0x{x}", .{ ecam, ecam.reg, size, value });
    }
};

/// MMIO read callback for hypervisor integration.
pub fn ecamMmioRead(ctx: *anyopaque, addr: u64, size: u8) u64 {
    const host: *const EcamHost = @ptrCast(@alignCast(ctx));
    return host.read(addr, size);
}

/// MMIO write callback for hypervisor integration.
pub fn ecamMmioWrite(ctx: *anyopaque, addr: u64, size: u8, value: u64) void {
    const host: *EcamHost = @ptrCast(@alignCast(ctx));
    host.write(addr, size, value);
}

test "EcamAddr decode" {
    // Bus 0, device 0, function 0, register 0
    const addr1 = EcamAddr.decode(ECAM_BASE);
    try std.testing.expectEqual(@as(u8, 0), addr1.bus);
    try std.testing.expectEqual(@as(u5, 0), addr1.device);
    try std.testing.expectEqual(@as(u3, 0), addr1.function);
    try std.testing.expectEqual(@as(u12, 0), addr1.reg);

    // Bus 0, device 1, function 0, register 0
    const addr2 = EcamAddr.decode(ECAM_BASE + (1 << 15));
    try std.testing.expectEqual(@as(u8, 0), addr2.bus);
    try std.testing.expectEqual(@as(u5, 1), addr2.device);
    try std.testing.expectEqual(@as(u3, 0), addr2.function);

    // Bus 1, device 0, function 0, register 0
    const addr3 = EcamAddr.decode(ECAM_BASE + (1 << 20));
    try std.testing.expectEqual(@as(u8, 1), addr3.bus);
}

test "PciDevice virtio block" {
    const dev = PciDevice.initVirtioBlock(0x10000000);
    try std.testing.expect(dev.present);

    // Read vendor ID
    const vendor = dev.read(@intFromEnum(ConfigReg.vendor_id), 2);
    try std.testing.expectEqual(@as(u64, 0x1AF4), vendor);

    // Read device ID
    const device_id = dev.read(@intFromEnum(ConfigReg.device_id), 2);
    try std.testing.expectEqual(@as(u64, 0x1001), device_id);
}

test "PciDevice preserves read-only identity and partial BAR bytes" {
    var dev = PciDevice.initVirtioBlock(PCI_MMIO_BASE);

    dev.write(@intFromEnum(ConfigReg.vendor_id), 2, 0);
    dev.write(@intFromEnum(ConfigReg.bar0) + 2, 1, 0xAB);

    try std.testing.expectEqual(
        @as(u64, @intFromEnum(VendorId.virtio)),
        dev.read(@intFromEnum(ConfigReg.vendor_id), 2),
    );
    try std.testing.expectEqual(@as(u64, 0x10AB_0000), dev.read(
        @intFromEnum(ConfigReg.bar0),
        4,
    ));

    dev.write(@intFromEnum(ConfigReg.bar0), 1, 0x50);
    try std.testing.expectEqual(@as(u64, 0x10AB_0000), dev.read(
        @intFromEnum(ConfigReg.bar0),
        4,
    ));
}

test "PciDevice rejects accesses crossing configuration space" {
    var dev = PciDevice.initVirtioBlock(PCI_MMIO_BASE);
    const end = std.math.maxInt(u12);

    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF), dev.read(end, 4));
    dev.write(end, 4, 0);
    try std.testing.expectEqual(@as(u64, 0xFF), dev.read(end, 1));
}

test "EcamHost basic" {
    const alloc = std.testing.allocator;
    const host = try EcamHost.init(alloc, true);
    defer host.deinit();

    // Nonexistent device returns 0xFFFFFFFF
    const empty = host.read(ECAM_BASE, 4);
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), empty);

    // Add a device
    try host.addDevice(0, 0, PciDevice.initVirtioBlock(0x10000000));

    // Now it should return vendor ID
    const vendor = host.read(ECAM_BASE, 2);
    try std.testing.expectEqual(@as(u64, 0x1AF4), vendor);
}

test "EcamHost first device allocation profile" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const host = try EcamHost.init(counted.allocator(), true);
    defer host.deinit();

    try host.addDevice(0, 0, PciDevice.initVirtioBlock(0x10000000));

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqual(
        @sizeOf(EcamHost) + @sizeOf(EcamHost.DeviceNode),
        counted.allocated_bytes,
    );
}

test "EcamHost without reserved devices stays compact" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const host = try EcamHost.init(counted.allocator(), false);
    defer host.deinit();

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqual(@sizeOf(EcamHost), counted.allocated_bytes);
}

test "EcamHost reserved node falls back for additional devices" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const host = try EcamHost.init(counted.allocator(), true);
    defer host.deinit();

    try host.addDevice(0, 0, PciDevice.initVirtioBlock(0x10000000));
    try host.addDevice(1, 0, PciDevice.initVirtioBlock(0x10001000));

    try std.testing.expectEqual(@as(usize, 2), counted.allocations);
    try std.testing.expectEqual(
        @sizeOf(EcamHost) + 2 * @sizeOf(EcamHost.DeviceNode),
        counted.allocated_bytes,
    );
    try std.testing.expectEqual(@as(u64, 0x1AF4), host.read(ECAM_BASE + (1 << 15), 2));
}
