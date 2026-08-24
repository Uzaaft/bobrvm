const KittyInput = @This();

const std = @import("std");
const builtin = @import("builtin");

buffer: [sequence_bytes_max]u8 = undefined,
length: usize = 0,

const sequence_bytes_max: usize = 64;
const csi_prefix = "\x1b[";
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
    key: KeyEvent,
    mouse: MouseEvent,
};

pub const KeyEvent = struct {
    evdev_code: u16,
    codepoint: u32,
    shifted_codepoint: ?u32,
    modifiers: u8,
    action: Action,

    pub const Action = enum {
        press,
        repeat,
        release,
    };

    pub const Modifier = struct {
        pub const shift: u8 = 1 << 0;
        pub const alt: u8 = 1 << 1;
        pub const control: u8 = 1 << 2;
        pub const super: u8 = 1 << 3;
    };

    pub fn commandByte(self: KeyEvent) ?u8 {
        const codepoint = if (self.modifiers & Modifier.shift != 0)
            self.shifted_codepoint orelse self.codepoint
        else
            self.codepoint;
        if (codepoint > std.math.maxInt(u8)) return null;
        return @intCast(codepoint);
    }
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

/// Decode one byte while preserving candidate CSI sequences across reads.
/// The keyboard forms follow https://sw.kovidgoyal.net/kitty/keyboard-protocol/.
pub fn feed(self: *KittyInput, byte: u8) FeedResult {
    if (self.length == 0 and byte != csi_prefix[0]) {
        self.buffer[0] = byte;
        self.length = 1;
        return .{ .forward = self.flush() };
    }

    self.buffer[self.length] = byte;
    self.length += 1;

    if (self.length <= csi_prefix.len) {
        if (!std.mem.eql(u8, self.buffer[0..self.length], csi_prefix[0..self.length])) {
            return .{ .forward = self.flush() };
        }
        return .pending;
    }

    if (isFinalByte(byte)) {
        const sequence = self.buffer[0..self.length];
        if (parseMouse(sequence)) |event| {
            self.length = 0;
            return .{ .mouse = event };
        }
        if (parseKey(sequence)) |event| {
            self.length = 0;
            return .{ .key = event };
        }
        return .{ .forward = self.flush() };
    }

    if (!isSequenceByte(byte) or self.length == self.buffer.len) {
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

fn isFinalByte(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

fn isSequenceByte(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x3f;
}

fn parseMouse(sequence: []const u8) ?MouseEvent {
    if (sequence.len <= mouse_prefix.len + 1) return null;
    if (!std.mem.startsWith(u8, sequence, mouse_prefix)) return null;
    const final = sequence[sequence.len - 1];
    if (final != 'M' and final != 'm') return null;

    var fields = std.mem.splitScalar(u8, sequence[mouse_prefix.len .. sequence.len - 1], ';');
    const code = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
    const x = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) return null;
    return .{
        .code = code,
        .x = x,
        .y = y,
        .released = final == 'm',
    };
}

const AlternateCodes = struct {
    primary: u32,
    shifted: ?u32,
    base: ?u32,
};

const Modifiers = struct {
    bits: u8,
    action: KeyEvent.Action,
};

fn parseKey(sequence: []const u8) ?KeyEvent {
    if (sequence.len <= csi_prefix.len) return null;
    if (!std.mem.startsWith(u8, sequence, csi_prefix)) return null;

    const final = sequence[sequence.len - 1];
    const parameters = sequence[csi_prefix.len .. sequence.len - 1];
    return switch (final) {
        'u' => parseCodepointKey(parameters),
        '~' => parseTildeKey(parameters),
        'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'S' => parseLetterKey(parameters, final),
        else => null,
    };
}

fn parseCodepointKey(parameters: []const u8) ?KeyEvent {
    var fields = std.mem.splitScalar(u8, parameters, ';');
    const codes = parseAlternateCodes(fields.next() orelse return null) orelse return null;
    const modifiers = parseModifiers(fields.next()) orelse return null;
    _ = fields.next(); // Associated text, if a terminal reports it.
    if (fields.next() != null) return null;

    const physical = codes.base orelse codes.primary;
    const evdev_code = if (codes.primary >= 57344)
        evdevForPrivateCode(codes.primary)
    else
        evdevForCodepoint(physical);
    return .{
        .evdev_code = evdev_code,
        .codepoint = physical,
        .shifted_codepoint = codes.shifted,
        .modifiers = modifiers.bits,
        .action = modifiers.action,
    };
}

fn parseAlternateCodes(field: []const u8) ?AlternateCodes {
    var fields = std.mem.splitScalar(u8, field, ':');
    const primary = parseCodepoint(fields.next() orelse return null) orelse return null;
    var shifted: ?u32 = null;
    var base: ?u32 = null;
    if (fields.next()) |value| {
        if (value.len != 0) shifted = parseCodepoint(value) orelse return null;
    }
    if (fields.next()) |value| {
        if (value.len != 0) base = parseCodepoint(value) orelse return null;
    }
    if (fields.next() != null) return null;
    return .{ .primary = primary, .shifted = shifted, .base = base };
}

fn parseCodepoint(field: []const u8) ?u32 {
    if (field.len == 0) return null;
    const value = std.fmt.parseInt(u32, field, 10) catch return null;
    if (value > 0x10ffff) return null;
    return value;
}

fn parseModifiers(field: ?[]const u8) ?Modifiers {
    const value = field orelse return .{ .bits = 0, .action = .press };
    if (value.len == 0) return .{ .bits = 0, .action = .press };

    var fields = std.mem.splitScalar(u8, value, ':');
    const encoded = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    if (encoded == 0 or encoded > 256) return null;
    const action: KeyEvent.Action = if (fields.next()) |event_type|
        switch (std.fmt.parseInt(u8, event_type, 10) catch return null) {
            1 => .press,
            2 => .repeat,
            3 => .release,
            else => return null,
        }
    else
        .press;
    if (fields.next() != null) return null;
    return .{ .bits = @intCast(encoded - 1), .action = action };
}

fn parseTildeKey(parameters: []const u8) ?KeyEvent {
    var fields = std.mem.splitScalar(u8, parameters, ';');
    const number = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    const modifiers = parseModifiers(fields.next()) orelse return null;
    if (fields.next() != null) return null;
    return functionalEvent(evdevForTilde(number), modifiers);
}

fn parseLetterKey(parameters: []const u8, final: u8) ?KeyEvent {
    var fields = std.mem.splitScalar(u8, parameters, ';');
    const first = fields.next() orelse return null;
    if (first.len != 0) {
        const number = std.fmt.parseInt(u8, first, 10) catch return null;
        if (number != 1) return null;
    }
    const modifiers = parseModifiers(fields.next()) orelse return null;
    if (fields.next() != null) return null;
    return functionalEvent(evdevForFinal(final), modifiers);
}

fn functionalEvent(evdev_code: u16, modifiers: Modifiers) KeyEvent {
    return .{
        .evdev_code = evdev_code,
        .codepoint = 0,
        .shifted_codepoint = null,
        .modifiers = modifiers.bits,
        .action = modifiers.action,
    };
}

pub fn evdevForCodepoint(codepoint: u32) u16 {
    return switch (codepoint) {
        27 => 1,
        '1'...'9' => @intCast(codepoint - '1' + 2),
        '0' => 11,
        '-' => 12,
        '=' => 13,
        127 => 14,
        9 => 15,
        'q' => 16,
        'w' => 17,
        'e' => 18,
        'r' => 19,
        't' => 20,
        'y' => 21,
        'u' => 22,
        'i' => 23,
        'o' => 24,
        'p' => 25,
        '[' => 26,
        ']' => 27,
        10, 13 => 28,
        'a' => 30,
        's' => 31,
        'd' => 32,
        'f' => 33,
        'g' => 34,
        'h' => 35,
        'j' => 36,
        'k' => 37,
        'l' => 38,
        ';' => 39,
        '\'' => 40,
        0x60 => 41,
        '\\' => 43,
        'z' => 44,
        'x' => 45,
        'c' => 46,
        'v' => 47,
        'b' => 48,
        'n' => 49,
        'm' => 50,
        ',' => 51,
        '.' => 52,
        '/' => 53,
        ' ' => 57,
        else => 0,
    };
}

fn evdevForPrivateCode(codepoint: u32) u16 {
    return switch (codepoint) {
        57358 => 58,
        57359 => 70,
        57360 => 69,
        57361 => 99,
        57362 => 119,
        57363 => 127,
        57399 => 82,
        57400 => 79,
        57401 => 80,
        57402 => 81,
        57403 => 75,
        57404 => 76,
        57405 => 77,
        57406 => 71,
        57407 => 72,
        57408 => 73,
        57409 => 83,
        57410 => 98,
        57411 => 55,
        57412 => 74,
        57413 => 78,
        57414 => 96,
        57415 => 117,
        57441 => 42,
        57442 => 29,
        57443 => 56,
        57444, 57446 => 125,
        57447 => 54,
        57448 => 97,
        57449, 57453 => 100,
        57450, 57452 => 126,
        else => 0,
    };
}

fn evdevForTilde(number: u32) u16 {
    return switch (number) {
        2 => 110,
        3 => 111,
        5 => 104,
        6 => 109,
        7 => 102,
        8 => 107,
        11...15 => @intCast(number + 48),
        17...21 => @intCast(number + 47),
        23 => 87,
        24 => 88,
        else => 0,
    };
}

fn evdevForFinal(final: u8) u16 {
    return switch (final) {
        'A' => 103,
        'B' => 108,
        'C' => 106,
        'D' => 105,
        'E' => 76,
        'F' => 107,
        'H' => 102,
        'P' => 59,
        'Q' => 60,
        'S' => 62,
        else => 0,
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
    try std.testing.expect(parseMouse("\x1b[<0;1;2u") == null);
}

test "unrecognized input is forwarded without loss" {
    var input: KittyInput = .{};
    try std.testing.expectEqualStrings("a", input.feed('a').forward);

    const unknown = "\x1b[?25h";
    for (unknown[0 .. unknown.len - 1]) |byte| {
        try std.testing.expect(input.feed(byte) == .pending);
    }
    try std.testing.expectEqualStrings(unknown, input.feed(unknown[unknown.len - 1]).forward);

    try std.testing.expect(input.feed('\x1b') == .pending);
    try std.testing.expect(input.hasPending());
    try std.testing.expectEqualStrings("\x1b", input.flushPending().?);
    try std.testing.expect(!input.hasPending());
}

test "keyboard reports retain press repeat and release" {
    var input: KittyInput = .{};
    const sequence = "\x1b[97;5:1u";
    for (sequence[0 .. sequence.len - 1]) |byte| {
        try std.testing.expect(input.feed(byte) == .pending);
    }
    const press = input.feed(sequence[sequence.len - 1]).key;
    try std.testing.expectEqual(@as(u16, 30), press.evdev_code);
    try std.testing.expectEqual(KeyEvent.Modifier.control, press.modifiers);
    try std.testing.expectEqual(KeyEvent.Action.press, press.action);

    const repeat = parseKey("\x1b[97;1:2u").?;
    try std.testing.expectEqual(KeyEvent.Action.repeat, repeat.action);
    const release = parseKey("\x1b[97;1:3u").?;
    try std.testing.expectEqual(KeyEvent.Action.release, release.action);
}

test "base layout and shifted codes preserve physical shortcuts" {
    const cyrillic_c = parseKey("\x1b[1089::99;5:1u").?;
    try std.testing.expectEqual(@as(u32, 'c'), cyrillic_c.codepoint);
    try std.testing.expectEqual(@as(u16, 46), cyrillic_c.evdev_code);

    const question = parseKey("\x1b[47:63:47;2:1u").?;
    try std.testing.expectEqual(@as(u16, 53), question.evdev_code);
    try std.testing.expectEqual(@as(u8, '?'), question.commandByte().?);
}

test "functional and modifier keys map to evdev" {
    const up = parseKey("\x1b[1;1:3A").?;
    try std.testing.expectEqual(@as(u16, 103), up.evdev_code);
    try std.testing.expectEqual(KeyEvent.Action.release, up.action);

    const f5 = parseKey("\x1b[15;1:1~").?;
    try std.testing.expectEqual(@as(u16, 63), f5.evdev_code);

    const control = parseKey("\x1b[57442;5:1u").?;
    try std.testing.expectEqual(@as(u16, 29), control.evdev_code);
    try std.testing.expectEqual(KeyEvent.Modifier.control, control.modifiers);
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
