//! macOS virtual keycode → Linux evdev keycode mapping.
//!
//! macOS virtual keycodes (kVK_*) identify physical keys on the ANSI
//! layout; evdev codes are what the guest's input stack expects.

/// Sentinel for unmapped keys.
pub const UNMAPPED: u16 = 0;

/// Map a macOS virtual keycode to an evdev keycode (0 if unmapped).
pub fn macosToEvdev(keycode: u32) u16 {
    if (keycode >= table.len) return UNMAPPED;
    return table[keycode];
}

const table = blk: {
    var t = [_]u16{UNMAPPED} ** 128;
    // Letters
    t[0x00] = 30; // A
    t[0x01] = 31; // S
    t[0x02] = 32; // D
    t[0x03] = 33; // F
    t[0x04] = 35; // H
    t[0x05] = 34; // G
    t[0x06] = 44; // Z
    t[0x07] = 45; // X
    t[0x08] = 46; // C
    t[0x09] = 47; // V
    t[0x0B] = 48; // B
    t[0x0C] = 16; // Q
    t[0x0D] = 17; // W
    t[0x0E] = 18; // E
    t[0x0F] = 19; // R
    t[0x10] = 21; // Y
    t[0x11] = 20; // T
    t[0x1F] = 24; // O
    t[0x20] = 22; // U
    t[0x22] = 23; // I
    t[0x23] = 25; // P
    t[0x25] = 38; // L
    t[0x26] = 36; // J
    t[0x28] = 37; // K
    t[0x2D] = 49; // N
    t[0x2E] = 50; // M
    // Digits
    t[0x12] = 2; // 1
    t[0x13] = 3; // 2
    t[0x14] = 4; // 3
    t[0x15] = 5; // 4
    t[0x17] = 6; // 5
    t[0x16] = 7; // 6
    t[0x1A] = 8; // 7
    t[0x1C] = 9; // 8
    t[0x19] = 10; // 9
    t[0x1D] = 11; // 0
    // Punctuation
    t[0x18] = 13; // =
    t[0x1B] = 12; // -
    t[0x1E] = 27; // ]
    t[0x21] = 26; // [
    t[0x27] = 40; // '
    t[0x29] = 39; // ;
    t[0x2A] = 43; // backslash
    t[0x2B] = 51; // ,
    t[0x2C] = 53; // /
    t[0x2F] = 52; // .
    t[0x32] = 41; // `
    // Control keys
    t[0x24] = 28; // Return -> ENTER
    t[0x30] = 15; // Tab
    t[0x31] = 57; // Space
    t[0x33] = 14; // Delete -> BACKSPACE
    t[0x35] = 1; // Escape
    t[0x37] = 125; // Command -> LEFTMETA
    t[0x36] = 126; // Right Command -> RIGHTMETA
    t[0x38] = 42; // Shift -> LEFTSHIFT
    t[0x39] = 58; // CapsLock
    t[0x3A] = 56; // Option -> LEFTALT
    t[0x3B] = 29; // Control -> LEFTCTRL
    t[0x3C] = 54; // RShift
    t[0x3D] = 100; // ROption -> RIGHTALT
    t[0x3E] = 97; // RControl
    // Navigation
    t[0x73] = 102; // Home
    t[0x74] = 104; // PageUp
    t[0x75] = 111; // ForwardDelete -> DELETE
    t[0x77] = 107; // End
    t[0x79] = 109; // PageDown
    t[0x7B] = 105; // Left
    t[0x7C] = 106; // Right
    t[0x7D] = 108; // Down
    t[0x7E] = 103; // Up
    // Function keys
    t[0x7A] = 59; // F1
    t[0x78] = 60; // F2
    t[0x63] = 61; // F3
    t[0x76] = 62; // F4
    t[0x60] = 63; // F5
    t[0x61] = 64; // F6
    t[0x62] = 65; // F7
    t[0x64] = 66; // F8
    t[0x65] = 67; // F9
    t[0x6D] = 68; // F10
    t[0x67] = 87; // F11
    t[0x6F] = 88; // F12
    break :blk t;
};

// =============================================================================
// Tests
// =============================================================================

const std = @import("std");

test "keymap basics" {
    try std.testing.expectEqual(@as(u16, 30), macosToEvdev(0x00)); // A
    try std.testing.expectEqual(@as(u16, 28), macosToEvdev(0x24)); // Return
    try std.testing.expectEqual(@as(u16, 1), macosToEvdev(0x35)); // Escape
    try std.testing.expectEqual(@as(u16, 103), macosToEvdev(0x7E)); // Up
    try std.testing.expectEqual(UNMAPPED, macosToEvdev(0x7F));
    try std.testing.expectEqual(UNMAPPED, macosToEvdev(9999));
}
