//! QEMU firmware configuration (fw_cfg) device, MMIO flavour with DMA.
//!
//! The guest firmware fetches named blobs through it: ACPI tables and their
//! loader script, the ramfb configuration, boot order hints. EDK2's
//! ArmVirtQemu locates the device through the `qemu,fw-cfg-mmio` DTB node
//! and uses DMA whenever the ID item advertises it.
//!
//! Register layout (QEMU docs/specs/fw_cfg.rst):
//!   0x00  data, 1/2/4/8-byte reads stream the selected item's bytes in
//!         memory order (byte 0 lands in the least significant lane)
//!   0x08  selector, 16-bit big-endian write
//!   0x10  DMA control address, 64-bit big-endian; may arrive as two 32-bit
//!         halves (high at 0x10, low at 0x14), the low half triggers.
//!
//! Item data is borrowed: the owner keeps every blob alive for the device's
//! lifetime. Files are fixed-capacity; the firmware needs a handful.

const FwCfg = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const GuestMemory = @import("../guest_memory.zig").GuestMemory;

const log = std.log.scoped(.fw_cfg);

selector: u16 = 0,
offset: u32 = 0,
/// Upper half of a DMA address written as two 32-bit halves.
dma_addr_high: u32 = 0,
files: [FILES_MAX]File = undefined,
files_len: u8 = 0,
/// Serialized FW_CFG_FILE_DIR: count followed by one 64-byte entry per file.
dir: [4 + FILES_MAX * 64]u8 = @splat(0),
dir_len: u32 = 4,
id_bytes: [4]u8 = .{ ID_TRADITIONAL | ID_DMA, 0, 0, 0 },

pub const FILES_MAX: u16 = 16;
pub const NAME_MAX: u8 = 55;

pub const REG_SIZE: u64 = 0x18;
const REG_DATA: u64 = 0x00;
const REG_SELECTOR: u64 = 0x08;
const REG_DMA_HIGH: u64 = 0x10;
const REG_DMA_LOW: u64 = 0x14;

pub const Selector = struct {
    pub const SIGNATURE: u16 = 0x0000;
    pub const ID: u16 = 0x0001;
    pub const FILE_DIR: u16 = 0x0019;
    pub const FILE_FIRST: u16 = 0x0020;
};

const ID_TRADITIONAL: u8 = 1 << 0;
const ID_DMA: u8 = 1 << 1;

const DMA_ERROR: u32 = 1 << 0;
const DMA_READ: u32 = 1 << 1;
const DMA_SKIP: u32 = 1 << 2;
const DMA_SELECT: u32 = 1 << 3;
const DMA_WRITE: u32 = 1 << 4;

const SIGNATURE = "QEMU";

/// Guest write into a writable item. `offset` is within the item.
pub const WriteCallback = *const fn (userdata: ?*anyopaque, offset: u32, bytes: []const u8) void;

pub const File = struct {
    name: [NAME_MAX + 1]u8,
    data: []u8,
    write_callback: ?WriteCallback = null,
    write_userdata: ?*anyopaque = null,
};

pub const AddError = error{ TooManyFiles, NameTooLong };

pub fn init() FwCfg {
    return .{};
}

/// Publish a blob under `name` (e.g. "etc/acpi/tables"). Writable files
/// receive guest DMA writes into `data` and notify `write_callback`.
pub fn addFile(
    self: *FwCfg,
    name: []const u8,
    data: []u8,
    write_callback: ?WriteCallback,
    write_userdata: ?*anyopaque,
) AddError!u16 {
    if (self.files_len >= FILES_MAX) return error.TooManyFiles;
    if (name.len == 0 or name.len > NAME_MAX) return error.NameTooLong;

    const index = self.files_len;
    const selector = Selector.FILE_FIRST + @as(u16, index);
    var file = File{
        .name = @splat(0),
        .data = data,
        .write_callback = write_callback,
        .write_userdata = write_userdata,
    };
    @memcpy(file.name[0..name.len], name);
    self.files[index] = file;
    self.files_len += 1;

    // Directory entry: size, select, reserved, name (all big-endian).
    const entry = self.dir[4 + @as(usize, index) * 64 ..][0..64];
    std.mem.writeInt(u32, entry[0..4], @intCast(data.len), .big);
    std.mem.writeInt(u16, entry[4..6], selector, .big);
    std.mem.writeInt(u16, entry[6..8], 0, .big);
    @memcpy(entry[8..64], &file.name);
    std.mem.writeInt(u32, self.dir[0..4], self.files_len, .big);
    self.dir_len = 4 + @as(u32, self.files_len) * 64;
    return selector;
}

/// Look a published file up by name.
pub fn findFile(self: *FwCfg, name: []const u8) ?*File {
    for (self.files[0..self.files_len]) |*file| {
        const stored = std.mem.sliceTo(&file.name, 0);
        if (std.mem.eql(u8, stored, name)) return file;
    }
    return null;
}

fn selectedData(self: *FwCfg) ?[]const u8 {
    return switch (self.selector) {
        Selector.SIGNATURE => SIGNATURE,
        Selector.ID => &self.id_bytes,
        Selector.FILE_DIR => self.dir[0..self.dir_len],
        else => blk: {
            if (self.selector < Selector.FILE_FIRST) break :blk null;
            const index = self.selector - Selector.FILE_FIRST;
            if (index >= self.files_len) break :blk null;
            break :blk self.files[index].data;
        },
    };
}

fn selectedFile(self: *FwCfg) ?*File {
    if (self.selector < Selector.FILE_FIRST) return null;
    const index = self.selector - Selector.FILE_FIRST;
    if (index >= self.files_len) return null;
    return &self.files[index];
}

fn selectItem(self: *FwCfg, selector: u16) void {
    self.selector = selector;
    self.offset = 0;
}

/// MMIO read of `size` bytes at register `offset`.
pub fn read(self: *FwCfg, offset: u64, size: u8) u64 {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    if (offset != REG_DATA) return 0;

    var value: u64 = 0;
    const data = self.selectedData() orelse return 0;
    var lane: u8 = 0;
    while (lane < size) : (lane += 1) {
        if (self.offset < data.len) {
            value |= @as(u64, data[self.offset]) << @intCast(lane * 8);
            self.offset += 1;
        }
    }
    return value;
}

/// MMIO write of `size` bytes at register `offset`. DMA transfers complete
/// synchronously before the guest's write instruction retires.
pub fn write(self: *FwCfg, offset: u64, size: u8, value: u64, memory: GuestMemory) void {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    switch (offset) {
        REG_SELECTOR => self.selectItem(@byteSwap(@as(u16, @truncate(value)))),
        REG_DMA_HIGH => {
            if (size == 8) {
                self.runDma(@byteSwap(value), memory);
            } else {
                self.dma_addr_high = @byteSwap(@as(u32, @truncate(value)));
            }
        },
        REG_DMA_LOW => {
            const low = @byteSwap(@as(u32, @truncate(value)));
            const address = (@as(u64, self.dma_addr_high) << 32) | low;
            self.dma_addr_high = 0;
            self.runDma(address, memory);
        },
        else => {},
    }
}

/// Execute one FwCfgDmaAccess {control, length, address} (all big-endian).
fn runDma(self: *FwCfg, access_addr: u64, memory: GuestMemory) void {
    var access: [16]u8 = undefined;
    memory.read(access_addr, &access) catch {
        log.warn("DMA descriptor at 0x{x} is outside guest memory", .{access_addr});
        return;
    };
    var control = std.mem.readInt(u32, access[0..4], .big);
    var length = std.mem.readInt(u32, access[4..8], .big);
    var address = std.mem.readInt(u64, access[8..16], .big);

    if (control & DMA_SELECT != 0) self.selectItem(@truncate(control >> 16));

    const is_read = control & DMA_READ != 0;
    const is_write = control & DMA_WRITE != 0;
    const is_skip = control & DMA_SKIP != 0;
    if (!is_read and !is_write and !is_skip) length = 0;

    const data = self.selectedData();
    var status: u32 = 0;
    while (length > 0) {
        const remaining: u32 = if (data) |bytes|
            @intCast(bytes.len -| self.offset)
        else
            0;
        if (remaining == 0) {
            // Past the end: reads zero-fill, writes fail, skips complete.
            if (is_read and !zeroFill(memory, address, length)) status = DMA_ERROR;
            if (is_write) status = DMA_ERROR;
            break;
        }
        const chunk = @min(length, remaining);
        if (is_read) {
            memory.write(address, data.?[self.offset..][0..chunk]) catch {
                status = DMA_ERROR;
                break;
            };
        } else if (is_write) {
            if (!self.writeIntoSelected(memory, address, chunk)) {
                status = DMA_ERROR;
                break;
            }
        }
        self.offset += chunk;
        address += chunk;
        length -= chunk;
    }

    control = status;
    std.mem.writeInt(u32, access[0..4], control, .big);
    memory.write(access_addr, access[0..4]) catch {};
}

fn writeIntoSelected(self: *FwCfg, memory: GuestMemory, address: u64, chunk: u32) bool {
    const file = self.selectedFile() orelse return false;
    if (file.write_callback == null) return false;
    const destination = file.data[self.offset..][0..chunk];
    memory.read(address, destination) catch return false;
    file.write_callback.?(file.write_userdata, self.offset, destination);
    return true;
}

fn zeroFill(memory: GuestMemory, address: u64, length: u32) bool {
    const destination = memory.get(address, length) orelse return false;
    @memset(destination, 0);
    return true;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TestMemory = struct {
    base: u64,
    bytes: []u8,

    fn get(self: *TestMemory, address: u64, length: usize) ?[]u8 {
        if (address < self.base) return null;
        const offset_u64 = address - self.base;
        if (offset_u64 > self.bytes.len) return null;
        const offset: usize = @intCast(offset_u64);
        if (length > self.bytes.len - offset) return null;
        return self.bytes[offset..][0..length];
    }
};

fn selectViaMmio(cfg: *FwCfg, selector: u16, memory: GuestMemory) void {
    cfg.write(REG_SELECTOR, 2, @byteSwap(selector), memory);
}

fn dmaDescriptor(ram: []u8, at: usize, control: u32, length: u32, address: u64) void {
    std.mem.writeInt(u32, ram[at..][0..4], control, .big);
    std.mem.writeInt(u32, ram[at + 4 ..][0..4], length, .big);
    std.mem.writeInt(u64, ram[at + 8 ..][0..8], address, .big);
}

test "signature and id stream through the data register" {
    var ram = [_]u8{0} ** 64;
    var context = TestMemory{ .base = 0x1000, .bytes = &ram };
    const memory = GuestMemory.bind(TestMemory, &context, TestMemory.get);
    var cfg = FwCfg.init();

    selectViaMmio(&cfg, Selector.SIGNATURE, memory);
    try testing.expectEqual(@as(u64, 0x554D_4551), cfg.read(REG_DATA, 4)); // "QEMU" LE
    try testing.expectEqual(@as(u64, 0), cfg.read(REG_DATA, 4)); // past the end

    selectViaMmio(&cfg, Selector.ID, memory);
    try testing.expectEqual(@as(u64, 3), cfg.read(REG_DATA, 1));
    selectViaMmio(&cfg, Selector.ID, memory);
    try testing.expectEqual(@as(u64, 3), cfg.read(REG_DATA, 4));
}

test "file directory lists published files big-endian" {
    var cfg = FwCfg.init();
    var payload = [_]u8{ 1, 2, 3, 4, 5 };
    const sel = try cfg.addFile("etc/acpi/rsdp", &payload, null, null);
    try testing.expectEqual(Selector.FILE_FIRST, sel);

    var ram = [_]u8{0} ** 64;
    var context = TestMemory{ .base = 0x1000, .bytes = &ram };
    const memory = GuestMemory.bind(TestMemory, &context, TestMemory.get);
    selectViaMmio(&cfg, Selector.FILE_DIR, memory);
    try testing.expectEqual(@as(u64, 0x0100_0000), cfg.read(REG_DATA, 4)); // count=1 BE
    try testing.expectEqual(@as(u64, 0x0500_0000), cfg.read(REG_DATA, 4)); // size=5 BE
    try testing.expectEqual(@as(u64, 0x2000), cfg.read(REG_DATA, 2)); // select 0x0020 BE
    _ = cfg.read(REG_DATA, 2);
    var name: [56]u8 = undefined;
    for (&name) |*byte| byte.* = @truncate(cfg.read(REG_DATA, 1));
    try testing.expectEqualStrings("etc/acpi/rsdp", std.mem.sliceTo(&name, 0));

    selectViaMmio(&cfg, sel, memory);
    try testing.expectEqual(@as(u64, 0x0403_0201), cfg.read(REG_DATA, 4));
    try testing.expectEqual(@as(u64, 5), cfg.read(REG_DATA, 8));
}

test "DMA select+read copies a file and zero-fills past its end" {
    var ram = [_]u8{0xAA} ** 128;
    var context = TestMemory{ .base = 0x1000, .bytes = &ram };
    const memory = GuestMemory.bind(TestMemory, &context, TestMemory.get);
    var cfg = FwCfg.init();
    var payload = [_]u8{ 9, 8, 7 };
    const sel = try cfg.addFile("opt/test", &payload, null, null);

    // Descriptor at 0x1000, destination 0x1040, read 6 bytes with select.
    const control = (@as(u32, sel) << 16) | DMA_SELECT | DMA_READ;
    dmaDescriptor(&ram, 0, control, 6, 0x1040);
    cfg.write(REG_DMA_HIGH, 8, @byteSwap(@as(u64, 0x1000)), memory);

    try testing.expectEqualSlices(u8, &.{ 9, 8, 7, 0, 0, 0 }, ram[0x40..0x46]);
    try testing.expectEqual(@as(u8, 0xAA), ram[0x46]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[0..4], .big));
}

test "DMA address accepts split 32-bit halves and skips advance the offset" {
    var ram = [_]u8{0} ** 128;
    var context = TestMemory{ .base = 0x1000, .bytes = &ram };
    const memory = GuestMemory.bind(TestMemory, &context, TestMemory.get);
    var cfg = FwCfg.init();
    var payload = [_]u8{ 1, 2, 3, 4 };
    const sel = try cfg.addFile("opt/skip", &payload, null, null);

    selectViaMmio(&cfg, sel, memory);
    dmaDescriptor(&ram, 0, DMA_SKIP, 2, 0);
    cfg.write(REG_DMA_HIGH, 4, @byteSwap(@as(u32, 0)), memory);
    cfg.write(REG_DMA_LOW, 4, @byteSwap(@as(u32, 0x1000)), memory);
    try testing.expectEqual(@as(u32, 2), cfg.offset);

    dmaDescriptor(&ram, 16, DMA_READ, 2, 0x1040);
    cfg.write(REG_DMA_HIGH, 8, @byteSwap(@as(u64, 0x1010)), memory);
    try testing.expectEqualSlices(u8, &.{ 3, 4 }, ram[0x40..0x42]);
}

test "DMA write lands in writable files and notifies; read-only files error" {
    const Sink = struct {
        var last_offset: u32 = 0xFFFF;
        var last_len: usize = 0;
        fn cb(_: ?*anyopaque, offset: u32, bytes: []const u8) void {
            last_offset = offset;
            last_len = bytes.len;
        }
    };
    var ram = [_]u8{0} ** 128;
    var context = TestMemory{ .base = 0x1000, .bytes = &ram };
    const memory = GuestMemory.bind(TestMemory, &context, TestMemory.get);
    var cfg = FwCfg.init();
    var writable = [_]u8{0} ** 8;
    var readonly = [_]u8{0} ** 8;
    const w = try cfg.addFile("etc/ramfb", &writable, Sink.cb, null);
    const r = try cfg.addFile("etc/fixed", &readonly, null, null);

    ram[0x40] = 0x11;
    ram[0x41] = 0x22;
    dmaDescriptor(&ram, 0, (@as(u32, w) << 16) | DMA_SELECT | DMA_WRITE, 2, 0x1040);
    cfg.write(REG_DMA_HIGH, 8, @byteSwap(@as(u64, 0x1000)), memory);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, writable[0..2]);
    try testing.expectEqual(@as(u32, 0), Sink.last_offset);
    try testing.expectEqual(@as(usize, 2), Sink.last_len);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ram[0..4], .big));

    dmaDescriptor(&ram, 0, (@as(u32, r) << 16) | DMA_SELECT | DMA_WRITE, 2, 0x1040);
    cfg.write(REG_DMA_HIGH, 8, @byteSwap(@as(u64, 0x1000)), memory);
    try testing.expectEqual(DMA_ERROR, std.mem.readInt(u32, ram[0..4], .big));
    try testing.expectEqual(@as(u8, 0), readonly[0]);
}

test "unknown selectors read as zero and the file table is bounded" {
    var ram = [_]u8{0} ** 16;
    var context = TestMemory{ .base = 0x1000, .bytes = &ram };
    const memory = GuestMemory.bind(TestMemory, &context, TestMemory.get);
    var cfg = FwCfg.init();
    selectViaMmio(&cfg, 0x7777, memory);
    try testing.expectEqual(@as(u64, 0), cfg.read(REG_DATA, 8));

    var payload = [_]u8{0};
    try testing.expectError(error.NameTooLong, cfg.addFile("a" ** 56, &payload, null, null));
    var index: u8 = 0;
    while (index < FILES_MAX) : (index += 1) {
        var name: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&name, "opt/{d}", .{index});
        _ = try cfg.addFile(text, &payload, null, null);
    }
    try testing.expectError(error.TooManyFiles, cfg.addFile("opt/x", &payload, null, null));
    try testing.expect(cfg.findFile("opt/3") != null);
    try testing.expect(cfg.findFile("opt/none") == null);
}
