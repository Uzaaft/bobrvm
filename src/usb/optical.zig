//! Read-only MMC optical media over USB Mass Storage Bulk-Only Transport.
//! CBW/data/CSW framing follows usb.org/sites/default/files/usbmassbulk_10.pdf.
const Optical = @This();
const std = @import("std");
const global = @import("../global.zig");

file: ?std.Io.File = null,
blocks: u32 = 0,
phase: enum { command, data, status, recovery } = .command,
tag: u32 = 0,
residue: u32 = 0,
status: u8 = 0,
sense_key: u8 = 0,
sense_asc: u8 = 0,
response: [512]u8 = @splat(0),
response_len: usize = 0,
position: u64 = 0,
remaining: u32 = 0,
reading: bool = false,

pub const block_size = 2048;
pub const Error = error{ Stall, Io };

pub const InitError = std.Io.File.OpenError || std.Io.File.StatError || error{InvalidOpticalImage};

pub fn init(path: []const u8) InitError!Optical {
    const file = try std.Io.Dir.cwd().openFile(global.io(), path, .{});
    errdefer file.close(global.io());
    const stat = try file.stat(global.io());
    if (stat.size == 0 or stat.size % block_size != 0 or
        stat.size / block_size > std.math.maxInt(u32)) return error.InvalidOpticalImage;
    return .{ .file = file, .blocks = @intCast(stat.size / block_size) };
}

pub fn deinit(self: *Optical) void {
    if (self.file) |file| file.close(global.io());
    self.file = null;
}

pub fn reset(self: *Optical) void {
    const file = self.file;
    const blocks = self.blocks;
    self.* = .{ .file = file, .blocks = blocks };
}

pub fn transfer(self: *Optical, input: bool, data: []u8) Error!usize {
    if (!input) return self.command(data);
    switch (self.phase) {
        .data => return self.read(data),
        .status => {
            if (data.len < 13) return error.Stall;
            @memset(data[0..13], 0);
            std.mem.writeInt(u32, data[0..4], 0x53425355, .little);
            std.mem.writeInt(u32, data[4..8], self.tag, .little);
            std.mem.writeInt(u32, data[8..12], self.residue, .little);
            data[12] = self.status;
            self.phase = if (self.status == 2) .recovery else .command;
            return 13;
        },
        else => return error.Stall,
    }
}

fn command(self: *Optical, data: []const u8) Error!usize {
    if (self.phase != .command or data.len != 31 or
        std.mem.readInt(u32, data[0..4], .little) != 0x43425355 or
        data[13] != 0 or data[14] == 0 or data[14] > 16 or data[12] & 0x7f != 0)
    {
        self.phase = .recovery;
        return error.Stall;
    }
    self.tag = std.mem.readInt(u32, data[4..8], .little);
    self.residue = std.mem.readInt(u32, data[8..12], .little);
    self.status = 0;
    self.position = 0;
    self.remaining = 0;
    self.response_len = 0;
    self.reading = false;
    @memset(&self.response, 0);
    self.scsi(data[15..31], data[14]);
    if (self.remaining > 0 and (data[12] & 0x80 == 0 or self.residue < self.remaining)) {
        self.status = 2;
        self.remaining = @min(self.remaining, self.residue);
    }
    // An unsupported data-out command must be recovered by the host, not
    // mistaken for a subsequent CBW or silently written to the backing file.
    if (self.residue > 0 and data[12] & 0x80 == 0) self.status = 2;
    self.phase = if (self.residue > 0 and data[12] & 0x80 != 0) .data else .status;
    if (trace()) std.log.debug("USB optical CDB=0x{x} bytes={} status={}", .{
        data[15], self.remaining, self.status,
    });
    return data.len;
}

fn fail(self: *Optical, key: u8, asc: u8) void {
    self.status = 1;
    self.sense_key = key;
    self.sense_asc = asc;
    self.remaining = 0;
}

fn responseLength(self: *Optical, size: usize, allocation: usize) void {
    self.response_len = @min(size, @min(allocation, self.residue));
    self.remaining = @intCast(self.response_len);
}

fn scsi(self: *Optical, cdb: *const [16]u8, cdb_len: u8) void {
    const required: u8 = switch (cdb[0] >> 5) {
        0 => 6,
        1, 2 => 10,
        4 => 16,
        5 => 12,
        else => 6,
    };
    if (cdb_len < required) return self.fail(5, 0x24);
    switch (cdb[0]) {
        0x00 => if (self.file == null) {
            self.fail(2, 0x3a);
        }, // TEST UNIT READY
        0x03 => { // REQUEST SENSE, fixed format
            self.response[0] = 0x70;
            self.response[2] = self.sense_key;
            self.response[7] = 10;
            self.response[12] = self.sense_asc;
            self.responseLength(18, cdb[4]);
            self.sense_key = 0;
            self.sense_asc = 0;
        },
        0x12 => self.inquiry(cdb),
        0x1b, 0x1e, 0x35 => {}, // START STOP, PREVENT REMOVAL, SYNCHRONIZE CACHE
        0x25 => { // READ CAPACITY(10)
            if (self.blocks == 0) return self.fail(2, 0x3a);
            std.mem.writeInt(u32, self.response[0..4], self.blocks - 1, .big);
            std.mem.writeInt(u32, self.response[4..8], block_size, .big);
            self.responseLength(8, 8);
        },
        0x28, 0xa8 => self.beginRead(cdb),
        0x1a, 0x5a => self.modeSense(cdb),
        0x43 => self.readToc(cdb),
        0x46 => self.configuration(cdb),
        0x4a => { // GET EVENT STATUS NOTIFICATION: no event, media present.
            self.response[1] = 6;
            self.response[2] = 4;
            self.response[3] = 0x10;
            self.response[5] = if (self.file != null) 2 else 0;
            self.responseLength(8, std.mem.readInt(u16, cdb[7..9], .big));
        },
        0x51 => { // READ DISC INFORMATION: finalized single-session data disc.
            self.response[1] = 32;
            self.response[2] = 0x0e;
            self.response[3] = 1;
            self.response[4] = 1;
            self.response[5] = 1;
            self.response[6] = 1;
            self.responseLength(34, std.mem.readInt(u16, cdb[7..9], .big));
        },
        0x2a, 0xaa => self.fail(7, 0x27), // DATA PROTECT
        else => self.fail(5, 0x20), // invalid command operation code
    }
}

fn inquiry(self: *Optical, cdb: *const [16]u8) void {
    if (cdb[1] & 1 != 0) { // Supported VPD pages; no invented device identifiers.
        self.response[0] = 5;
        if (cdb[2] != 0) return self.fail(5, 0x24);
        self.response[3] = 1;
        self.responseLength(5, cdb[4]);
        return;
    }
    self.response[0] = 5; // optical, not a direct-access disk
    self.response[1] = 0x80;
    self.response[2] = 5;
    self.response[3] = 2;
    self.response[4] = 31;
    @memcpy(self.response[8..16], "BOBRVM  ");
    @memcpy(self.response[16..32], "Virtual DVD-ROM ");
    @memcpy(self.response[32..36], "1.00");
    self.responseLength(36, cdb[4]);
}

fn beginRead(self: *Optical, cdb: *const [16]u8) void {
    const lba = std.mem.readInt(u32, cdb[2..6], .big);
    const count: u32 = if (cdb[0] == 0x28)
        std.mem.readInt(u16, cdb[7..9], .big)
    else
        std.mem.readInt(u32, cdb[6..10], .big);
    if (lba > self.blocks or count > self.blocks - lba) return self.fail(5, 0x21);
    self.remaining = std.math.mul(u32, count, block_size) catch return self.fail(5, 0x24);
    self.position = @as(u64, lba) * block_size;
    self.reading = true;
}

fn modeSense(self: *Optical, cdb: *const [16]u8) void {
    const ten = cdb[0] == 0x5a;
    const header: usize = if (ten) 8 else 4;
    const page = cdb[2] & 0x3f;
    if (page != 0x2a and page != 0x3f and page != 0) return self.fail(5, 0x24);
    self.response[if (ten) @as(usize, 3) else 2] = 0x80; // write protected
    var length = header;
    if (page != 0) {
        self.response[header] = 0x2a;
        self.response[header + 1] = 0x12;
        self.response[header + 2] = 0x08; // DVD-ROM read
        self.response[header + 6] = 0x29; // tray, lock, eject
        length += 20;
    }
    if (ten) {
        std.mem.writeInt(u16, self.response[0..2], @intCast(length - 2), .big);
    } else {
        self.response[0] = @intCast(length - 1);
    }
    self.responseLength(length, if (ten) std.mem.readInt(u16, cdb[7..9], .big) else cdb[4]);
}

fn readToc(self: *Optical, cdb: *const [16]u8) void {
    const format = cdb[2] & 0x0f;
    if (format > 1) return self.fail(5, 0x24);
    const lead_only = cdb[6] == 0xaa;
    const length: usize = if (format == 1 or lead_only) 12 else 20;
    std.mem.writeInt(u16, self.response[0..2], @intCast(length - 2), .big);
    self.response[2] = 1;
    self.response[3] = 1;
    self.response[5] = 0x14;
    self.response[6] = if (lead_only) 0xaa else 1;
    self.tocAddress(8, if (lead_only) self.blocks else 0, cdb[1] & 2 != 0);
    if (length == 20) {
        self.response[13] = 0x14;
        self.response[14] = 0xaa;
        self.tocAddress(16, self.blocks, cdb[1] & 2 != 0);
    }
    self.responseLength(length, std.mem.readInt(u16, cdb[7..9], .big));
}

fn tocAddress(self: *Optical, offset: usize, lba: u32, msf: bool) void {
    if (!msf) {
        std.mem.writeInt(u32, self.response[offset..][0..4], lba, .big);
    } else {
        const frames = @as(u64, lba) + 150;
        self.response[offset + 1] = @truncate(frames / 4500);
        self.response[offset + 2] = @intCast((frames / 75) % 60);
        self.response[offset + 3] = @intCast(frames % 75);
    }
}

fn configuration(self: *Optical, cdb: *const [16]u8) void {
    // Current DVD-ROM profile plus the mandatory profile-list feature.
    std.mem.writeInt(u32, self.response[0..4], 12, .big);
    self.response[7] = 0x10;
    self.response[10] = 3;
    self.response[11] = 4;
    self.response[13] = 0x10;
    self.response[14] = 1;
    self.responseLength(16, std.mem.readInt(u16, cdb[7..9], .big));
}

fn read(self: *Optical, output: []u8) Error!usize {
    const count = @min(output.len, self.remaining);
    if (self.reading and count > 0) {
        const file = self.file orelse return error.Io;
        const n = file.readPositionalAll(global.io(), output[0..count], self.position) catch
            return error.Io;
        if (n != count) return error.Io;
    } else if (count > 0) {
        const offset: usize = @intCast(self.position);
        @memcpy(output[0..count], self.response[offset..][0..count]);
    }
    self.position += count;
    self.remaining -= @intCast(count);
    self.residue -= @intCast(count);
    if (self.remaining == 0) self.phase = .status;
    return count;
}

fn trace() bool {
    return std.c.getenv("BOBRVM_TRACE_USB") != null;
}

test "USB optical rejects malformed CBW until reset" {
    var device: Optical = .{};
    var invalid = [_]u8{0} ** 31;
    try std.testing.expectError(error.Stall, device.transfer(false, &invalid));
    try std.testing.expectEqual(.recovery, device.phase);
    device.reset();
    try std.testing.expectEqual(.command, device.phase);
}

test "USB optical inquiry reports read-only optical media and bounded residue" {
    var device: Optical = .{};
    var cbw = [_]u8{0} ** 31;
    std.mem.writeInt(u32, cbw[0..4], 0x43425355, .little);
    std.mem.writeInt(u32, cbw[8..12], 64, .little);
    cbw[12] = 0x80;
    cbw[14] = 6;
    cbw[15] = 0x12;
    cbw[19] = 64;
    _ = try device.transfer(false, &cbw);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(36, try device.transfer(true, &buffer));
    try std.testing.expectEqual(5, buffer[0]);
    try std.testing.expectEqual(13, try device.transfer(true, &buffer));
    try std.testing.expectEqual(28, std.mem.readInt(u32, buffer[8..12], .little));
    try std.testing.expectEqual(0, buffer[12]);
}
