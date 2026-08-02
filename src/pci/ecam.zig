//! PCIe ECAM (Enhanced Configuration Access Mechanism) host bridge.
//!
//! Implements a GPEX-compatible PCIe host bridge for UEFI boot support.
//! ECAM provides memory-mapped access to PCI configuration space.
//!
//! Memory layout (QEMU virt compatible):
//! - ECAM config space: 0x3c000000-0x40000000 (64MB)
//! - PCI MMIO: 0x10000000-0x3c000000 (768MB)
//!
//! ECAM address decoding:
//! - bits[27:20]: bus number (0-255)
//! - bits[19:15]: device number (0-31)
//! - bits[14:12]: function number (0-7)
//! - bits[11:0]: register offset (0-4095)

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.pci_ecam);

/// ECAM base address (QEMU virt compatible).
pub const ECAM_BASE: u64 = 0x3c00_0000;

/// ECAM size: 256 buses * 32 devices * 8 functions * 4KB = 64MB
pub const ECAM_SIZE: u64 = 64 * 1024 * 1024;

/// PCI MMIO base for BAR allocations.
pub const PCI_MMIO_BASE: u64 = 0x1000_0000;

/// PCI MMIO size (768MB).
pub const PCI_MMIO_SIZE: u64 = 0x2c00_0000;

/// PCI I/O port base (not used on ARM64, but defined for completeness).
pub const PCI_IO_BASE: u64 = 0x0;

/// PCI I/O size.
pub const PCI_IO_SIZE: u64 = 0x10000;

/// Maximum devices per bus.
pub const MAX_DEVICES: usize = 32;

/// Maximum functions per device.
pub const MAX_FUNCTIONS: usize = 8;

/// PCI configuration space size per function.
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
    /// Configuration space data.
    config: [CONFIG_SPACE_SIZE]u8,

    /// Whether device exists.
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
        assert(offset + size <= CONFIG_SPACE_SIZE);

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
        assert(offset + size <= CONFIG_SPACE_SIZE);

        if (!self.present) return;

        // Handle writes to specific registers
        switch (@as(ConfigReg, @enumFromInt(offset))) {
            .command => {
                // Allow command register writes
                const cmd: u16 = @truncate(value);
                self.setU16(offset, cmd);
                log.debug("PCI command write: 0x{x}", .{cmd});
            },
            .bar0, .bar1, .bar2, .bar3, .bar4, .bar5 => {
                // BAR sizing: writing all 1s reads back size
                if (value == 0xFFFFFFFF) {
                    // Return BAR size (e.g., 4KB = ~0xFFF)
                    self.setU32(offset, 0xFFFFF000);
                } else {
                    self.setU32(offset, @truncate(value));
                }
            },
            else => {
                // Generic write
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
            },
        }
    }
};

/// PCIe ECAM host bridge.
pub const EcamHost = struct {
    alloc: Allocator,
    devices: ?*DeviceNode,

    const DeviceNode = struct {
        next: ?*DeviceNode,
        index: u8,
        device: PciDevice,
    };

    pub fn init(alloc: Allocator) !*EcamHost {
        const host = try alloc.create(EcamHost);
        errdefer alloc.destroy(host);

        host.* = .{
            .alloc = alloc,
            .devices = null,
        };

        log.info("initialized PCIe ECAM host at 0x{x}-0x{x}", .{ ECAM_BASE, ECAM_BASE + ECAM_SIZE });
        return host;
    }

    pub fn deinit(self: *EcamHost) void {
        var node = self.devices;
        while (node) |current| {
            node = current.next;
            self.alloc.destroy(current);
        }
        self.alloc.destroy(self);
    }

    pub fn addDevice(self: *EcamHost, device: u5, function: u3, dev: PciDevice) Allocator.Error!void {
        assert(dev.present);
        const index: u8 = @intCast(@as(usize, device) * MAX_FUNCTIONS + function);
        assert(self.findDevice(index) == null);

        const node = try self.alloc.create(DeviceNode);
        node.* = .{
            .next = self.devices,
            .index = index,
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
            if (current.index == index) return &current.device;
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

// =============================================================================
// Tests
// =============================================================================

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

test "EcamHost basic" {
    const alloc = std.testing.allocator;
    const host = try EcamHost.init(alloc);
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
