//! PCI configuration mechanism 1 for x86 I/O ports 0xcf8-0xcff.

const std = @import("std");

pub const ConfigAddress = struct {
    bus: u8,
    device: u5,
    function: u3,
    register: u8,
};

pub const LegacyConfig = struct {
    address: u32 = 0,

    pub const address_port: u16 = 0xcf8;
    pub const data_port: u16 = 0xcfc;

    pub fn writeAddress(self: *LegacyConfig, port: u16, size: u8, value: u32) bool {
        const lane = portLane(address_port, port, size) orelse return false;
        const shift: u5 = @as(u5, lane) * 8;
        const mask = sizeMask(size) << shift;
        self.address = (self.address & ~mask) | ((value << shift) & mask);
        return true;
    }

    pub fn readAddress(self: LegacyConfig, port: u16, size: u8) ?u32 {
        const lane = portLane(address_port, port, size) orelse return null;
        const shift: u5 = @as(u5, lane) * 8;
        return (self.address >> shift) & sizeMask(size);
    }

    pub fn dataAddress(self: LegacyConfig, port: u16, size: u8) ?ConfigAddress {
        const lane = portLane(data_port, port, size) orelse return null;
        if (self.address & (1 << 31) == 0) return null;
        return .{
            .bus = @truncate(self.address >> 16),
            .device = @truncate(self.address >> 11),
            .function = @truncate(self.address >> 8),
            .register = @intCast((self.address & 0xfc) + lane),
        };
    }

    fn portLane(base: u16, port: u16, size: u8) ?u3 {
        if (size != 1 and size != 2 and size != 4) return null;
        if (port < base or port >= base + 4) return null;
        const lane: u3 = @intCast(port - base);
        if (@as(u8, lane) + size > 4) return null;
        return lane;
    }

    fn sizeMask(size: u8) u32 {
        return switch (size) {
            1 => 0xff,
            2 => 0xffff,
            4 => 0xffff_ffff,
            else => unreachable,
        };
    }
};

test "enabled x86 PCI configuration address decodes data-port lanes" {
    var config = LegacyConfig{};
    try std.testing.expect(config.dataAddress(0xcfc, 4) == null);

    try std.testing.expect(config.writeAddress(0xcf8, 4, 0x8000_0800));
    const vendor = config.dataAddress(0xcfc, 2).?;
    try std.testing.expectEqual(@as(u8, 0), vendor.bus);
    try std.testing.expectEqual(@as(u5, 1), vendor.device);
    try std.testing.expectEqual(@as(u3, 0), vendor.function);
    try std.testing.expectEqual(@as(u8, 0), vendor.register);

    const device_id = config.dataAddress(0xcfe, 2).?;
    try std.testing.expectEqual(@as(u8, 2), device_id.register);
}

test "x86 PCI address port supports bounded little-endian accesses" {
    var config = LegacyConfig{};
    try std.testing.expect(config.writeAddress(0xcf8, 2, 0x0800));
    try std.testing.expect(config.writeAddress(0xcfa, 2, 0x8000));
    try std.testing.expectEqual(@as(?u32, 0x8000_0800), config.readAddress(0xcf8, 4));
    try std.testing.expect(!config.writeAddress(0xcfb, 2, 0xffff));
    try std.testing.expect(config.dataAddress(0xcff, 2) == null);
}
