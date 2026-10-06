//! Built-in USB devices. Called only while the machine lock is held.
const Device = @This();
const std = @import("std");
pub const Optical = @import("optical.zig");

kind: Kind,
optical: Optical = .{},
configuration: u8 = 0,
protocol: u8 = 1,
idle: u8 = 0,
report: [8]u8 = @splat(0),
reports: [128][8]u8 = @splat(@splat(0)),
head: usize = 0,
count: usize = 0,

pub const Kind = enum { keyboard, tablet, optical };
pub const Error = error{ Stall, Io };
pub const Setup = struct {
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,

    pub fn parse(bytes: *const [8]u8) Setup {
        return .{
            .request_type = bytes[0],
            .request = bytes[1],
            .value = std.mem.readInt(u16, bytes[2..4], .little),
            .index = std.mem.readInt(u16, bytes[4..6], .little),
            .length = std.mem.readInt(u16, bytes[6..8], .little),
        };
    }
};

const keyboard_report = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07,
    0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01,
    0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
    0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
    0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
    0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07,
    0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xc0,
};
const tablet_report = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
    0x95, 0x03, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05,
    0x81, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00,
    0x26, 0xff, 0x7f, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0x09,
    0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81,
    0x06, 0xc0, 0xc0,
};

pub fn reset(self: *Device) void {
    self.configuration = 0;
    self.protocol = 1;
    self.idle = 0;
    self.head = 0;
    self.count = 0;
    self.report = @splat(0);
    self.optical.reset();
}

pub fn control(self: *Device, setup: Setup, output: []u8) Error!usize {
    var reply: [256]u8 = @splat(0);
    const length = try self.controlReply(setup, &reply);
    const count = @min(output.len, @min(length, setup.length));
    @memcpy(output[0..count], reply[0..count]);
    return count;
}

fn controlReply(self: *Device, s: Setup, reply: *[256]u8) Error!usize {
    if (s.request_type & 0x60 == 0) switch (s.request) {
        0 => return 2, // GET_STATUS
        1, 3, 5, 11 => return 0, // CLEAR/SET_FEATURE, SET_ADDRESS, SET_INTERFACE
        6 => return self.descriptor(s.value, reply),
        8 => {
            reply[0] = self.configuration;
            return 1;
        },
        9 => {
            if (s.value > 1) return error.Stall;
            self.configuration = @intCast(s.value);
            self.head = 0;
            self.count = 0;
            if (self.kind != .optical) self.enqueue();
            return 0;
        },
        10 => return 1, // GET_INTERFACE, alternate setting zero
        else => return error.Stall,
    };
    if (s.request_type & 0x60 != 0x20 or s.index != 0) return error.Stall;
    if (self.kind == .optical) switch (s.request) {
        0xfe => return 1, // GET_MAX_LUN, LUN 0
        0xff => {
            self.optical.reset();
            return 0;
        },
        else => return error.Stall,
    };
    switch (s.request) {
        1 => {
            @memcpy(reply[0..8], &self.report);
            return self.reportLength();
        },
        2 => {
            reply[0] = self.idle;
            return 1;
        },
        3 => {
            reply[0] = self.protocol;
            return 1;
        },
        9 => return 0, // SET_REPORT (keyboard LEDs)
        10 => {
            self.idle = @truncate(s.value >> 8);
            return 0;
        },
        11 => {
            self.protocol = @truncate(s.value);
            return 0;
        },
        else => return error.Stall,
    }
}

fn descriptor(self: *const Device, value: u16, out: *[256]u8) Error!usize {
    const descriptor_type = value >> 8;
    const index: u8 = @truncate(value);
    switch (descriptor_type) {
        1 => {
            const bytes = [_]u8{
                18, 1, 0, 2, 0, 0, 0, 64, 0xf4, 0x1a, 0x10, 0x10, 0, 1, 1, 2, 3, 1,
            };
            @memcpy(out[0..18], &bytes);
            out[10] += @intFromEnum(self.kind);
            return 18;
        },
        2 => return self.configurationDescriptor(out),
        3 => return self.stringDescriptor(index, out),
        0x21 => {
            if (self.kind == .optical) return error.Stall;
            self.hidDescriptor(out[0..9]);
            return 9;
        },
        0x22 => {
            if (self.kind == .optical) return error.Stall;
            const report = if (self.kind == .keyboard) &keyboard_report else &tablet_report;
            @memcpy(out[0..report.len], report);
            return report.len;
        },
        else => return error.Stall,
    }
}

fn hidDescriptor(self: *const Device, out: *[9]u8) void {
    out.* = .{ 9, 0x21, 0x11, 1, 0, 1, 0x22, 0, 0 };
    out[7] = @intCast(if (self.kind == .keyboard) keyboard_report.len else tablet_report.len);
}

fn configurationDescriptor(self: *const Device, out: *[256]u8) usize {
    if (self.kind == .optical) {
        const bytes = [_]u8{
            9,    2, 32,   0, 1, 1, 0, 0x80, 50,
            9,    4, 0,    0, 2, 8, 6, 0x50, 0,
            7,    5, 0x81, 2, 0, 2, 0, 7,    5,
            0x02, 2, 0,    2, 0,
        };
        @memcpy(out[0..bytes.len], &bytes);
        return bytes.len;
    }
    const bytes = [_]u8{
        9, 2,    34,   0, 1, 1, 0,    0x80, 50,
        9, 4,    0,    0, 1, 3, 0,    0,    0,
        9, 0x21, 0x11, 1, 0, 1, 0x22, 0,    0,
        7, 5,    0x81, 3, 8, 0, 10,
    };
    @memcpy(out[0..bytes.len], &bytes);
    if (self.kind == .keyboard) {
        out[15] = 1;
        out[16] = 1;
    }
    self.hidDescriptor(out[18..27]);
    return bytes.len;
}

fn stringDescriptor(self: *const Device, index: u8, out: *[256]u8) Error!usize {
    if (index == 0) {
        @memcpy(out[0..4], &[_]u8{ 4, 3, 9, 4 });
        return 4;
    }
    const value = switch (index) {
        1 => "bobrvm",
        2 => switch (self.kind) {
            .keyboard => "USB Keyboard",
            .tablet => "USB Tablet",
            .optical => "USB DVD-ROM",
        },
        3 => switch (self.kind) {
            .keyboard => "BOBRVM-HID-1",
            .tablet => "BOBRVM-HID-2",
            .optical => "BOBRVM-DVD-1",
        },
        else => return error.Stall,
    };
    out[0] = @intCast(2 + 2 * value.len);
    out[1] = 3;
    for (value, 0..) |byte, i| out[2 + i * 2] = byte;
    return out[0];
}

/// null is a USB NAK: leave the transfer pending until input arrives.
pub fn transfer(self: *Device, endpoint: u8, input: bool, data: []u8) Error!?usize {
    if (self.configuration != 1) return error.Stall;
    if (self.kind == .optical) {
        if ((input and endpoint != 1) or (!input and endpoint != 2)) return error.Stall;
        return try self.optical.transfer(input, data);
    }
    if (endpoint != 1 or !input) return error.Stall;
    if (self.count == 0) return null;
    const length = @min(self.reportLength(), data.len);
    @memcpy(data[0..length], self.reports[self.head][0..length]);
    self.head = (self.head + 1) % self.reports.len;
    self.count -= 1;
    return length;
}

fn reportLength(self: *const Device) usize {
    return if (self.kind == .keyboard) 8 else 6;
}

fn enqueue(self: *Device) void {
    // On overflow retain the newest complete state, including releases.
    // This bounds host input and prevents a lost release leaving keys stuck.
    if (self.count == self.reports.len) {
        self.head = 0;
        self.count = 0;
    }
    self.reports[(self.head + self.count) % self.reports.len] = self.report;
    self.count += 1;
}

pub fn key(self: *Device, evdev: u16, pressed: bool) void {
    const usage = keyUsage(evdev) orelse return;
    if (usage >= 0xe0 and usage <= 0xe7) {
        const mask = @as(u8, 1) << @intCast(usage - 0xe0);
        if (pressed) self.report[0] |= mask else self.report[0] &= ~mask;
    } else {
        for (self.report[2..8]) |*entry| {
            if (entry.* == usage) {
                entry.* = 0;
                break;
            }
        }
        if (pressed) for (self.report[2..8]) |*entry| {
            if (entry.* == 0) {
                entry.* = usage;
                break;
            }
        };
    }
    self.enqueue();
}

/// Coordinates use the same 0..32767 absolute range as virtio-input.
pub fn pointer(self: *Device, x: i32, y: i32) void {
    std.mem.writeInt(u16, self.report[1..3], @intCast(std.math.clamp(x, 0, 32767)), .little);
    std.mem.writeInt(u16, self.report[3..5], @intCast(std.math.clamp(y, 0, 32767)), .little);
    self.enqueue();
}

pub fn button(self: *Device, code: u16, pressed: bool) void {
    if (code < 272 or code > 274) return;
    const mask = @as(u8, 1) << @intCast(code - 272);
    if (pressed) self.report[0] |= mask else self.report[0] &= ~mask;
    self.enqueue();
}

pub fn scroll(self: *Device, delta: i32) void {
    self.report[5] = @bitCast(@as(i8, @intCast(std.math.clamp(delta, -127, 127))));
    self.enqueue();
    self.report[5] = 0;
}

fn keyUsage(code: u16) ?u8 {
    const keys = [_]u8{
        0,    0x29, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
        0x2d, 0x2e, 0x2a, 0x2b, 0x14, 0x1a, 0x08, 0x15, 0x17, 0x1c, 0x18, 0x0c,
        0x12, 0x13, 0x2f, 0x30, 0x28, 0xe0, 0x04, 0x16, 0x07, 0x09, 0x0a, 0x0b,
        0x0d, 0x0e, 0x0f, 0x33, 0x34, 0x35, 0xe1, 0x31, 0x1d, 0x1b, 0x06, 0x19,
        0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xe5, 0x55, 0xe2, 0x2c, 0x39, 0x3a,
        0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x53, 0x47, 0x5f,
        0x60, 0x61, 0x56, 0x5c, 0x5d, 0x5e, 0x57, 0x59, 0x5a, 0x5b, 0x62, 0x63,
        0,    0,    0x64, 0x44, 0x45,
    };
    if (code < keys.len) return if (keys[code] != 0) keys[code] else null;
    return switch (code) {
        96 => 0x58,
        97 => 0xe4,
        98 => 0x54,
        99 => 0x46,
        100 => 0xe6,
        102 => 0x4a,
        103 => 0x52,
        104 => 0x4b,
        105 => 0x50,
        106 => 0x4f,
        107 => 0x4d,
        108 => 0x51,
        109 => 0x4e,
        110 => 0x49,
        111 => 0x4c,
        119 => 0x48,
        125 => 0xe3,
        126 => 0xe7,
        127 => 0x65,
        else => null,
    };
}

test "USB HID preserves press and release reports while transfer is pending" {
    var keyboard: Device = .{ .kind = .keyboard, .configuration = 1 };
    var report: [8]u8 = undefined;
    try std.testing.expectEqual(null, try keyboard.transfer(1, true, &report));
    keyboard.key(28, true);
    keyboard.key(28, false);
    try std.testing.expectEqual(8, (try keyboard.transfer(1, true, &report)).?);
    try std.testing.expectEqual(0x28, report[2]);
    _ = try keyboard.transfer(1, true, &report);
    try std.testing.expectEqual(0, report[2]);
}

test "USB tablet preserves normalized coordinates and buttons" {
    var tablet: Device = .{ .kind = .tablet, .configuration = 1 };
    var report: [6]u8 = undefined;
    tablet.pointer(16383, 8191);
    tablet.button(272, true);
    try std.testing.expectEqual(6, (try tablet.transfer(1, true, &report)).?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0x3f, 0xff, 0x1f, 0 }, &report);
    _ = try tablet.transfer(1, true, &report);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0xff, 0x3f, 0xff, 0x1f, 0 }, &report);
    tablet.pointer(std.math.minInt(i32), std.math.maxInt(i32));
    _ = try tablet.transfer(1, true, &report);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0xff, 0x7f, 0 }, &report);
}

test {
    _ = Optical;
}
