const KittyInput = @This();

const std = @import("std");
const builtin = @import("builtin");

buffer: [sequence_bytes_max]u8 = undefined,
length: usize = 0,

const sequence_bytes_max: usize = 64;
const mouse_prefix = "\x1b[<";
const tablet_axis_max: i32 = 32767;

pub const MouseEvent = struct {
    code: u8,
    x: i32,
    y: i32,
    released: bool,
};

pub const FeedResult = union(enum) {
    pending,
    forward: []const u8,
    mouse: MouseEvent,
};

pub const PixelSize = struct {
    width: u16,
    height: u16,
};

pub const GuestEvent = struct {
    x: i32,
    y: i32,
    action: Action = .none,

    pub const Action = union(enum) {
        none,
        button: struct {
            code: u16,
            pressed: bool,
        },
        scroll: struct {
            dx: i32,
            dy: i32,
        },
    };
};

/// Decode one byte while preserving candidate sequences across host reads.
/// Unrecognized input is returned verbatim for the guest serial console.
pub fn feed(self: *KittyInput, byte: u8) FeedResult {
    if (self.length == 0 and byte != mouse_prefix[0]) {
        self.buffer[0] = byte;
        self.length = 1;
        return .{ .forward = self.flush() };
    }

    self.buffer[self.length] = byte;
    self.length += 1;

    if (self.length <= mouse_prefix.len) {
        if (!std.mem.eql(u8, self.buffer[0..self.length], mouse_prefix[0..self.length])) {
            return .{ .forward = self.flush() };
        }
        return .pending;
    }

    if (byte == 'M' or byte == 'm') {
        const event = parseMouse(self.buffer[0..self.length]) orelse {
            return .{ .forward = self.flush() };
        };
        self.length = 0;
        return .{ .mouse = event };
    }

    if (!isParameterByte(byte) or self.length == self.buffer.len) {
        return .{ .forward = self.flush() };
    }
    return .pending;
}

pub fn hasPending(self: *const KittyInput) bool {
    return self.length != 0;
}

/// Return a candidate that did not complete before its input boundary.
pub fn flushPending(self: *KittyInput) ?[]const u8 {
    if (self.length == 0) return null;
    return self.flush();
}

pub fn translate(event: MouseEvent, size: PixelSize) GuestEvent {
    const action: GuestEvent.Action = action: {
        const code = event.code & ~@as(u8, 4 | 8 | 16);
        if (code & 64 != 0) {
            break :action switch (code & 3) {
                0 => .{ .scroll = .{ .dx = 0, .dy = 1 } },
                1 => .{ .scroll = .{ .dx = 0, .dy = -1 } },
                2 => .{ .scroll = .{ .dx = -1, .dy = 0 } },
                3 => .{ .scroll = .{ .dx = 1, .dy = 0 } },
                else => unreachable,
            };
        }
        if (code & 32 != 0 or code & 128 != 0) break :action .none;

        const button: u16 = switch (code & 3) {
            0 => 0x110, // BTN_LEFT
            1 => 0x112, // BTN_MIDDLE
            2 => 0x111, // BTN_RIGHT
            else => break :action .none,
        };
        break :action .{ .button = .{
            .code = button,
            .pressed = !event.released,
        } };
    };

    return .{
        .x = pointerAxis(event.x, size.width),
        .y = pointerAxis(event.y, size.height),
        .action = action,
    };
}

pub fn terminalPixelSize(fd: std.posix.fd_t) ?PixelSize {
    const request: c_int = switch (builtin.os.tag) {
        .linux => 0x5413,
        .macos => 0x4008_7468,
        else => return null,
    };
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(fd, request, &size) != 0) return null;
    if (size.xpixel == 0 or size.ypixel == 0) return null;
    return .{ .width = size.xpixel, .height = size.ypixel };
}

fn flush(self: *KittyInput) []const u8 {
    const result = self.buffer[0..self.length];
    self.length = 0;
    return result;
}

fn isParameterByte(byte: u8) bool {
    return std.ascii.isDigit(byte) or byte == ';' or byte == '-';
}

fn parseMouse(sequence: []const u8) ?MouseEvent {
    if (sequence.len <= mouse_prefix.len + 1) return null;
    if (!std.mem.startsWith(u8, sequence, mouse_prefix)) return null;

    var fields = std.mem.splitScalar(u8, sequence[mouse_prefix.len .. sequence.len - 1], ';');
    const code = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
    const x = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) return null;
    return .{
        .code = code,
        .x = x,
        .y = y,
        .released = sequence[sequence.len - 1] == 'm',
    };
}

fn pointerAxis(value: i32, extent: u16) i32 {
    if (extent == 0) return 0;
    const clamped = std.math.clamp(value, 0, @as(i32, extent));
    return @intCast(@divTrunc(@as(i64, clamped) * tablet_axis_max, extent));
}

test "mouse report can span reads" {
    var input: KittyInput = .{};
    for ("\x1b[<0;640;"[0..]) |byte| {
        try std.testing.expect(input.feed(byte) == .pending);
    }
    for ("420M"[0..3]) |byte| {
        try std.testing.expect(input.feed(byte) == .pending);
    }
    const event = input.feed('M').mouse;
    try std.testing.expectEqual(@as(u8, 0), event.code);
    try std.testing.expectEqual(@as(i32, 640), event.x);
    try std.testing.expectEqual(@as(i32, 420), event.y);
    try std.testing.expect(!event.released);
}

test "non-mouse input is forwarded without loss" {
    var input: KittyInput = .{};
    try std.testing.expectEqualStrings("a", input.feed('a').forward);
    try std.testing.expect(input.feed('\x1b') == .pending);
    try std.testing.expect(input.feed('[') == .pending);
    try std.testing.expectEqualStrings("\x1b[A", input.feed('A').forward);

    try std.testing.expect(input.feed('\x1b') == .pending);
    try std.testing.expect(input.hasPending());
    try std.testing.expectEqualStrings("\x1b", input.flushPending().?);
    try std.testing.expect(!input.hasPending());
}

test "mouse events translate to absolute tablet input" {
    const size: PixelSize = .{ .width = 1000, .height = 500 };

    const press = translate(.{ .code = 0, .x = 500, .y = 250, .released = false }, size);
    try std.testing.expectEqual(@as(i32, 16383), press.x);
    try std.testing.expectEqual(@as(i32, 16383), press.y);
    try std.testing.expectEqual(@as(u16, 0x110), press.action.button.code);
    try std.testing.expect(press.action.button.pressed);

    const release = translate(.{ .code = 2, .x = 1000, .y = 500, .released = true }, size);
    try std.testing.expectEqual(tablet_axis_max, release.x);
    try std.testing.expectEqual(tablet_axis_max, release.y);
    try std.testing.expectEqual(@as(u16, 0x111), release.action.button.code);
    try std.testing.expect(!release.action.button.pressed);
}

test "motion, modifiers, and wheel reports translate" {
    const size: PixelSize = .{ .width = 100, .height = 100 };
    const motion = translate(.{ .code = 32 | 4, .x = -10, .y = 120, .released = false }, size);
    try std.testing.expectEqual(@as(i32, 0), motion.x);
    try std.testing.expectEqual(tablet_axis_max, motion.y);
    try std.testing.expect(motion.action == .none);

    const wheel = translate(.{ .code = 65 | 8, .x = 20, .y = 30, .released = false }, size);
    try std.testing.expectEqual(@as(i32, 0), wheel.action.scroll.dx);
    try std.testing.expectEqual(@as(i32, -1), wheel.action.scroll.dy);
}
