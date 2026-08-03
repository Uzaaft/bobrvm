//! ARM PL031 real-time clock emulation.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");

pub const Reg = struct {
    pub const DR: u12 = 0x000;
    pub const MR: u12 = 0x004;
    pub const LR: u12 = 0x008;
    pub const CR: u12 = 0x00c;
    pub const IMSC: u12 = 0x010;
    pub const RIS: u12 = 0x014;
    pub const MIS: u12 = 0x018;
    pub const ICR: u12 = 0x01c;
    pub const PeriphID0: u12 = 0xfe0;
    pub const PeriphID1: u12 = 0xfe4;
    pub const PeriphID2: u12 = 0xfe8;
    pub const PeriphID3: u12 = 0xfec;
    pub const PCellID0: u12 = 0xff0;
    pub const PCellID1: u12 = 0xff4;
    pub const PCellID2: u12 = 0xff8;
    pub const PCellID3: u12 = 0xffc;
};

pub const Rtc = struct {
    pub fn init() Rtc {
        return .{};
    }

    pub fn read(self: *const Rtc, offset: u12) u32 {
        assert(offset <= Reg.PCellID3);
        assert(offset % 4 == 0);
        _ = self;

        return switch (offset) {
            Reg.DR => currentSeconds(),
            Reg.MR => 0,
            Reg.LR => 0,
            Reg.CR => 1,
            Reg.IMSC => 0,
            Reg.RIS, Reg.MIS, Reg.ICR => 0,
            Reg.PeriphID0 => 0x31,
            Reg.PeriphID1 => 0x10,
            Reg.PeriphID2 => 0x14,
            Reg.PeriphID3 => 0x00,
            Reg.PCellID0 => 0x0d,
            Reg.PCellID1 => 0xf0,
            Reg.PCellID2 => 0x05,
            Reg.PCellID3 => 0xb1,
            else => 0,
        };
    }

    pub fn write(self: *Rtc, offset: u12, value: u32) void {
        assert(offset <= Reg.PCellID3);
        assert(offset % 4 == 0);
        _ = self;
        _ = value;
    }

    fn currentSeconds() u32 {
        const seconds = hostSeconds();
        if (seconds <= 0) return 0;
        return @truncate(@as(u64, @intCast(seconds)));
    }

    fn hostSeconds() i64 {
        const nanoseconds = std.Io.Clock.real.now(global.io()).nanoseconds;
        return @intCast(@divFloor(nanoseconds, std.time.ns_per_s));
    }
};

pub fn mmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    assert(offset < 0x1000);
    const rtc: *Rtc = @ptrCast(@alignCast(context));
    return rtc.read(@truncate(offset));
}

pub fn mmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    assert(offset < 0x1000);
    const rtc: *Rtc = @ptrCast(@alignCast(context));
    rtc.write(@truncate(offset), @truncate(value));
}

test "PL031 reports host wall clock and PrimeCell identity" {
    var rtc = Rtc.init();
    const before = @divFloor(std.Io.Clock.real.now(global.io()).nanoseconds, std.time.ns_per_s);
    const actual = rtc.read(Reg.DR);
    const after = @divFloor(std.Io.Clock.real.now(global.io()).nanoseconds, std.time.ns_per_s);

    try std.testing.expect(actual >= before);
    try std.testing.expect(actual <= after);
    try std.testing.expectEqual(@as(u32, 0x31), rtc.read(Reg.PeriphID0));
    try std.testing.expectEqual(@as(u32, 0xb1), rtc.read(Reg.PCellID3));
}
