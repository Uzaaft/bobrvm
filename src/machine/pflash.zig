//! CFI parallel NOR flash with the Intel P30 command set, modelled on QEMU's
//! `pflash_cfi01` as the `virt` machine instantiates it: a 32-bit bank made
//! of two interleaved 16-bit devices with 256 KiB sectors. EDK2's
//! VirtNorFlashDxe programs the UEFI variable store with this protocol and
//! spins (interrupts masked) until the status register reports ready, so a
//! bank that is plain RAM hangs the firmware at its first variable write.
//!
//! The bank's memory is guest-readable while the device is in array mode, so
//! ordinary reads never trap. Writes always trap. Commands that leave array
//! mode (status, device ID, CFI query, in-progress program/erase) must also
//! trap reads; the owner watches `readsTrap()` after every write and adjusts
//! the guest mapping.
//!
//! Reference: https://gitlab.com/qemu-project/qemu/-/blob/master/hw/block/pflash_cfi01.c

const Pflash = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;

/// Guest-visible contents. Programs and erases modify it in place.
storage: []u8,
/// Erase granularity in bytes; the guest advertises the same in its CFI table.
sector_size: u32 = SECTOR_SIZE,
/// Command that decides what reads return (0 = array mode).
cmd: u8 = 0,
/// Write cycle within a multi-write command sequence.
wcycle: u8 = 0,
/// Status register (shared by both devices in the bank).
status: u8 = 0,
/// Remaining data writes of a buffered program.
counter: u32 = 0,
/// Set by every program or erase; owner clears after persisting.
dirty: bool = false,

pub const SECTOR_SIZE: u32 = 256 * 1024;
const BANK_WIDTH: u8 = 4;
const DEVICE_WIDTH: u8 = 2;
const IDENT0: u8 = 0x89; // Intel
const IDENT1: u8 = 0x18;

pub const Cmd = struct {
    pub const READ_ARRAY: u8 = 0xFF;
    pub const READ_STATUS: u8 = 0x70;
    pub const CLEAR_STATUS: u8 = 0x50;
    pub const READ_DEVICE_ID: u8 = 0x90;
    pub const CFI_QUERY: u8 = 0x98;
    pub const WORD_PROGRAM: u8 = 0x40;
    pub const WORD_PROGRAM_ALT: u8 = 0x10;
    pub const BUFFERED_PROGRAM: u8 = 0xE8;
    pub const BLOCK_ERASE: u8 = 0x20;
    pub const LOCK_SETUP: u8 = 0x60;
    pub const LOCK: u8 = 0x01;
    pub const LOCK_DOWN: u8 = 0x2F;
    pub const CONFIRM: u8 = 0xD0;
};

pub const STATUS_READY: u8 = 0x80;
const STATUS_ERASE_ERROR: u8 = 0x20;
const STATUS_PROGRAM_ERROR: u8 = 0x10;

pub fn init(storage: []u8) Pflash {
    assert(storage.len % SECTOR_SIZE == 0);
    assert(storage.len > 0);
    return .{ .storage = storage };
}

/// True when guest reads must trap because they do not return array data.
pub fn readsTrap(self: *const Pflash) bool {
    return self.cmd != 0;
}

/// Guest read of `size` bytes at `offset`. Only reached while `readsTrap()`
/// holds (or on a racing read right after a reset), so array data is served
/// as a fallback.
pub fn read(self: *Pflash, offset: u64, size: u8) u64 {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    if (offset >= self.storage.len) return 0;

    switch (self.cmd) {
        Cmd.WORD_PROGRAM,
        Cmd.WORD_PROGRAM_ALT,
        Cmd.LOCK_SETUP,
        Cmd.READ_STATUS,
        Cmd.BUFFERED_PROGRAM,
        Cmd.BLOCK_ERASE,
        => return replicate(self.status, size),
        Cmd.READ_DEVICE_ID => return self.queryRead(offset, size, deviceIdByte),
        Cmd.CFI_QUERY => return self.queryRead(offset, size, cfiByte),
        else => {
            // Unknown state: QEMU resets and serves array data.
            self.cmd = 0;
            self.wcycle = 0;
            return self.arrayRead(offset, size);
        },
    }
}

/// Guest write of `size` bytes at `offset`: a command, a program count, or
/// program data depending on the current write cycle.
pub fn write(self: *Pflash, offset: u64, size: u8, value: u64) void {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    if (offset >= self.storage.len) return;

    // Commands repeat in every device lane; the low lane is authoritative.
    const cmd: u8 = @truncate(value);

    switch (self.wcycle) {
        0 => self.writeCommand(cmd),
        1 => self.writeSecondCycle(offset, size, value, cmd),
        2 => {
            if (self.cmd != Cmd.BUFFERED_PROGRAM) return self.reset();
            self.program(offset, size, value);
            if (self.counter == 0) {
                self.wcycle = 3;
            } else {
                self.counter -= 1;
            }
        },
        3 => {
            // Buffered program confirm; anything else aborts the sequence.
            if (self.cmd == Cmd.BUFFERED_PROGRAM and cmd == Cmd.CONFIRM) {
                self.status |= STATUS_READY;
                self.wcycle = 0;
            } else {
                self.reset();
            }
        },
        else => self.reset(),
    }
}

fn writeCommand(self: *Pflash, cmd: u8) void {
    switch (cmd) {
        0x00, Cmd.READ_ARRAY, 0xF0 => self.reset(),
        Cmd.CLEAR_STATUS => {
            self.status = 0;
            self.reset();
        },
        Cmd.READ_STATUS, Cmd.READ_DEVICE_ID, Cmd.CFI_QUERY => self.cmd = cmd,
        Cmd.WORD_PROGRAM, Cmd.WORD_PROGRAM_ALT, Cmd.BLOCK_ERASE, Cmd.LOCK_SETUP => {
            self.cmd = cmd;
            self.wcycle = 1;
        },
        Cmd.BUFFERED_PROGRAM => {
            self.status |= STATUS_READY;
            self.cmd = cmd;
            self.wcycle = 1;
        },
        else => self.reset(),
    }
}

fn writeSecondCycle(self: *Pflash, offset: u64, size: u8, value: u64, cmd: u8) void {
    switch (self.cmd) {
        Cmd.WORD_PROGRAM, Cmd.WORD_PROGRAM_ALT => {
            self.program(offset, size, value);
            self.status |= STATUS_READY;
            self.wcycle = 0;
        },
        Cmd.BLOCK_ERASE => switch (cmd) {
            Cmd.CONFIRM => {
                self.eraseSector(offset);
                self.status |= STATUS_READY;
                self.wcycle = 0;
            },
            Cmd.READ_ARRAY => self.reset(),
            else => self.reset(),
        },
        Cmd.BUFFERED_PROGRAM => {
            // Word count minus one, in bus words, repeated per lane.
            self.counter = @truncate(value & 0xFFFF);
            self.wcycle = 2;
        },
        Cmd.LOCK_SETUP => switch (cmd) {
            Cmd.CONFIRM, Cmd.LOCK, Cmd.LOCK_DOWN => {
                // Block locking is not modelled; report completion.
                self.status |= STATUS_READY;
                self.wcycle = 0;
            },
            else => self.reset(),
        },
        else => self.reset(),
    }
}

fn reset(self: *Pflash) void {
    self.cmd = 0;
    self.wcycle = 0;
}

fn program(self: *Pflash, offset: u64, size: u8, value: u64) void {
    if (offset + size > self.storage.len) {
        self.status |= STATUS_PROGRAM_ERROR;
        return;
    }
    const start: usize = @intCast(offset);
    const bytes = std.mem.asBytes(&std.mem.nativeToLittle(u64, value));
    @memcpy(self.storage[start .. start + size], bytes[0..size]);
    self.dirty = true;
}

fn eraseSector(self: *Pflash, offset: u64) void {
    const sector_start: usize = @intCast(offset - (offset % self.sector_size));
    assert(sector_start + self.sector_size <= self.storage.len);
    @memset(self.storage[sector_start .. sector_start + self.sector_size], 0xFF);
    self.dirty = true;
}

fn arrayRead(self: *const Pflash, offset: u64, size: u8) u64 {
    if (offset + size > self.storage.len) return 0;
    const start: usize = @intCast(offset);
    var value: u64 = 0;
    @memcpy(std.mem.asBytes(&value)[0..size], self.storage[start .. start + size]);
    return std.mem.littleToNative(u64, value);
}

/// Replicate a per-device byte into every 16-bit device lane of the access.
fn replicate(byte: u8, size: u8) u64 {
    var value: u64 = 0;
    var lane: u8 = 0;
    while (lane * DEVICE_WIDTH < size) : (lane += 1) {
        value |= @as(u64, byte) << @intCast(lane * DEVICE_WIDTH * 8);
    }
    return value;
}

/// Device ID / CFI reads: one response byte per bank word, replicated per lane.
fn queryRead(
    self: *const Pflash,
    offset: u64,
    size: u8,
    comptime byteAt: fn (*const Pflash, u64) u8,
) u64 {
    var value: u64 = 0;
    var word: u8 = 0;
    while (word * BANK_WIDTH < size) : (word += 1) {
        const byte = byteAt(self, offset + word * BANK_WIDTH);
        value |= replicate(byte, BANK_WIDTH) << @intCast(word * BANK_WIDTH * 8);
    }
    return value;
}

fn deviceIdByte(_: *const Pflash, offset: u64) u8 {
    return switch ((offset / BANK_WIDTH) & 0xFF) {
        0 => IDENT0,
        1 => IDENT1,
        else => 0,
    };
}

/// CFI query table indexed by bank word, matching QEMU's Intel table for a
/// bank of this geometry.
fn cfiByte(self: *const Pflash, offset: u64) u8 {
    const index = offset / BANK_WIDTH;
    const sectors: u32 = @intCast(self.storage.len / self.sector_size);
    return switch (index) {
        0x10 => 'Q',
        0x11 => 'R',
        0x12 => 'Y',
        0x13 => 0x01, // Intel command set
        0x15 => 0x31, // Primary extended table address
        0x1B => 0x45, // Vcc min
        0x1C => 0x55, // Vcc max
        0x1F => 0x07, // Word program timeout, 2^n µs
        0x20 => 0x07, // Buffer program timeout, 2^n µs
        0x21 => 0x0A, // Block erase timeout, 2^n ms
        0x23 => 0x04, // Maximum word program timeout multiplier
        0x24 => 0x04, // Maximum buffer program timeout multiplier
        0x25 => 0x04, // Maximum block erase timeout multiplier
        0x27 => @intCast(std.math.log2_int(usize, self.storage.len)),
        0x28 => 0x02, // x8/x16 device interface
        0x2A => 0x0B, // Maximum buffer write, 2^n bytes
        0x2C => 0x01, // One erase block region
        0x2D => @truncate(sectors - 1),
        0x2E => @truncate((sectors - 1) >> 8),
        0x2F => @truncate(self.sector_size >> 8),
        0x30 => @truncate(self.sector_size >> 16),
        0x31 => 'P',
        0x32 => 'R',
        0x33 => 'I',
        0x34 => '1',
        0x35 => '0',
        0x3F => 0x01, // Protection fields
        else => 0,
    };
}

/// Two-lane command word as EDK2's `SEND_NOR_COMMAND` emits it.
fn dual(cmd: u8) u64 {
    return (@as(u64, cmd) << 16) | cmd;
}

const testing = std.testing;

fn testBank() ![]u8 {
    const bank = try testing.allocator.alloc(u8, 2 * SECTOR_SIZE);
    @memset(bank, 0xFF);
    return bank;
}

test "status read reports ready in both lanes and returns to array mode" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    try testing.expect(!flash.readsTrap());
    flash.write(0, 4, dual(Cmd.READ_STATUS));
    try testing.expect(flash.readsTrap());
    try testing.expectEqual(@as(u64, 0), flash.read(0, 4));

    flash.write(SECTOR_SIZE, 4, dual(Cmd.LOCK_SETUP));
    flash.write(SECTOR_SIZE, 4, dual(Cmd.CONFIRM));
    flash.write(0, 4, dual(Cmd.READ_STATUS));
    try testing.expectEqual(@as(u64, 0x0080_0080), flash.read(0, 4));

    flash.write(0, 4, dual(Cmd.READ_ARRAY));
    try testing.expect(!flash.readsTrap());
}

test "block erase fills only the addressed sector and reports ready" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    @memset(bank, 0x00);
    var flash = Pflash.init(bank);

    const sector_offset: u64 = SECTOR_SIZE + 0x100;
    flash.write(sector_offset, 4, dual(Cmd.BLOCK_ERASE));
    try testing.expect(flash.readsTrap());
    flash.write(sector_offset, 4, dual(Cmd.CONFIRM));
    try testing.expectEqual(@as(u64, 0x0080_0080), flash.read(0, 4));
    try testing.expect(flash.dirty);

    try testing.expectEqual(@as(u8, 0x00), bank[SECTOR_SIZE - 1]);
    try testing.expectEqual(@as(u8, 0xFF), bank[SECTOR_SIZE]);
    try testing.expectEqual(@as(u8, 0xFF), bank[2 * SECTOR_SIZE - 1]);

    flash.write(0, 4, dual(Cmd.READ_ARRAY));
    try testing.expect(!flash.readsTrap());
}

test "word program stores the data and status polling sees ready" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    flash.write(0x40, 4, dual(Cmd.WORD_PROGRAM));
    flash.write(0x40, 4, 0x1122_3344);
    try testing.expectEqual(@as(u64, 0x0080_0080), flash.read(0, 4));
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11 }, bank[0x40..0x44]);

    // EDK2 re-sends READ_STATUS while polling, then READ_ARRAY.
    flash.write(0, 4, dual(Cmd.READ_STATUS));
    try testing.expectEqual(@as(u64, 0x0080_0080), flash.read(0, 4));
    flash.write(0, 4, dual(Cmd.READ_ARRAY));
    try testing.expect(!flash.readsTrap());
    try testing.expectEqual(@as(u64, 0x1122_3344), flash.read(0x40, 4));
}

test "buffered program writes every word and completes on confirm" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    const base: u64 = 0x1000;
    flash.write(base, 4, dual(Cmd.BUFFERED_PROGRAM));
    try testing.expectEqual(@as(u64, 0x0080_0080), flash.read(base, 4));
    flash.write(base, 4, dual(3 - 1));
    flash.write(base + 0, 4, 0x0000_0001);
    flash.write(base + 4, 4, 0x0000_0002);
    flash.write(base + 8, 4, 0x0000_0003);
    try testing.expectEqual(@as(u8, 3), flash.wcycle);
    flash.write(base, 4, dual(Cmd.CONFIRM));
    try testing.expectEqual(@as(u8, 0), flash.wcycle);
    try testing.expectEqual(@as(u64, 0x0080_0080), flash.read(0, 4));

    flash.write(0, 4, dual(Cmd.READ_ARRAY));
    try testing.expectEqual(@as(u64, 1), flash.read(base, 4));
    try testing.expectEqual(@as(u64, 2), flash.read(base + 4, 4));
    try testing.expectEqual(@as(u64, 3), flash.read(base + 8, 4));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), flash.read(base + 12, 4));
}

test "clear status resets the register and returns to array mode" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    flash.write(SECTOR_SIZE, 4, dual(Cmd.LOCK_SETUP));
    flash.write(SECTOR_SIZE, 4, dual(Cmd.CONFIRM));
    try testing.expectEqual(@as(u8, STATUS_READY), flash.status);
    flash.write(0, 4, dual(Cmd.CLEAR_STATUS));
    try testing.expect(!flash.readsTrap());
    try testing.expectEqual(@as(u8, 0), flash.status);
}

test "lock setup accepts unlock and completes" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    flash.write(SECTOR_SIZE, 4, dual(Cmd.LOCK_SETUP));
    flash.write(SECTOR_SIZE, 4, dual(Cmd.CONFIRM));
    try testing.expectEqual(@as(u8, 0), flash.wcycle);
    try testing.expectEqual(@as(u64, 0x0080_0080), flash.read(0, 4));
    try testing.expect(!flash.dirty);
}

test "CFI query exposes the QRY signature and geometry" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    flash.write(0, 4, dual(Cmd.CFI_QUERY));
    try testing.expectEqual(@as(u64, ('Q' << 16) | 'Q'), flash.read(0x10 * 4, 4));
    try testing.expectEqual(@as(u64, ('R' << 16) | 'R'), flash.read(0x11 * 4, 4));
    try testing.expectEqual(@as(u64, ('Y' << 16) | 'Y'), flash.read(0x12 * 4, 4));
    // Two sectors: region descriptor counts sectors - 1.
    try testing.expectEqual(@as(u64, 0x0001_0001), flash.read(0x2D * 4, 4));
    try testing.expectEqual(@as(u64, 0x0004_0004), flash.read(0x30 * 4, 4));
    try testing.expectEqual(@as(u64, 0x0013_0013), flash.read(0x27 * 4, 4));

    flash.write(0, 4, dual(Cmd.READ_DEVICE_ID));
    try testing.expectEqual(@as(u64, 0x0089_0089), flash.read(0, 4));
    try testing.expectEqual(@as(u64, 0x0018_0018), flash.read(4, 4));
}

test "unknown command sequences fall back to array mode" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    flash.write(0, 4, dual(0xAB));
    try testing.expect(!flash.readsTrap());
    flash.write(0, 4, dual(Cmd.BLOCK_ERASE));
    flash.write(0, 4, dual(0x12));
    try testing.expect(!flash.readsTrap());
    try testing.expectEqual(@as(u8, 0xFF), bank[0]);
}

test "writes beyond the bank are ignored" {
    const bank = try testBank();
    defer testing.allocator.free(bank);
    var flash = Pflash.init(bank);

    flash.write(bank.len, 4, dual(Cmd.WORD_PROGRAM));
    try testing.expectEqual(@as(u8, 0), flash.wcycle);
    try testing.expectEqual(@as(u64, 0), flash.read(bank.len, 4));
}
