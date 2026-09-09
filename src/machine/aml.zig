//! AML (ACPI Machine Language) assembler for the tables bobrvm hands the
//! guest. Only the encodings the DSDT needs are provided; everything is
//! emitted into one growable byte buffer, with nested blocks assembled in
//! child buffers so package lengths are known when the parent is written.
//!
//! Reference: ACPI Specification 6.5, section 20 "ACPI Machine Language".

const Aml = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

alloc: Allocator,
bytes: std.ArrayList(u8),

pub const Error = Allocator.Error;

pub const Op = struct {
    pub const ZERO: u8 = 0x00;
    pub const ONE: u8 = 0x01;
    pub const ONES: u8 = 0xFF;
    pub const NAME: u8 = 0x08;
    pub const BYTE_PREFIX: u8 = 0x0A;
    pub const WORD_PREFIX: u8 = 0x0B;
    pub const DWORD_PREFIX: u8 = 0x0C;
    pub const STRING_PREFIX: u8 = 0x0D;
    pub const QWORD_PREFIX: u8 = 0x0E;
    pub const SCOPE: u8 = 0x10;
    pub const BUFFER: u8 = 0x11;
    pub const PACKAGE: u8 = 0x12;
    pub const METHOD: u8 = 0x14;
    pub const EXT_PREFIX: u8 = 0x5B;
    pub const DEVICE: u8 = 0x82; // after EXT_PREFIX
    pub const ROOT_CHAR: u8 = 0x5C;
    pub const PARENT_CHAR: u8 = 0x5E;
    pub const DUAL_NAME_PREFIX: u8 = 0x2E;
    pub const MULTI_NAME_PREFIX: u8 = 0x2F;
    pub const NULL_NAME: u8 = 0x00;
    pub const LOCAL0: u8 = 0x60;
    pub const ARG0: u8 = 0x68;
    pub const STORE: u8 = 0x70;
    pub const AND: u8 = 0x7B;
    pub const OR: u8 = 0x7D;
    pub const LEQUAL: u8 = 0x93;
    pub const IF: u8 = 0xA0;
    pub const ELSE: u8 = 0xA1;
    pub const RETURN: u8 = 0xA4;
    pub const CREATE_DWORD_FIELD: u8 = 0x8A;
};

pub fn init(alloc: Allocator) Aml {
    return .{ .alloc = alloc, .bytes = .empty };
}

pub fn deinit(self: *Aml) void {
    self.bytes.deinit(self.alloc);
}

pub fn items(self: *const Aml) []const u8 {
    return self.bytes.items;
}

pub fn toOwnedSlice(self: *Aml) Error![]u8 {
    return self.bytes.toOwnedSlice(self.alloc);
}

pub fn raw(self: *Aml, bytes: []const u8) Error!void {
    try self.bytes.appendSlice(self.alloc, bytes);
}

pub fn byte(self: *Aml, value: u8) Error!void {
    try self.bytes.append(self.alloc, value);
}

/// Smallest integer encoding for `value`.
pub fn integer(self: *Aml, value: u64) Error!void {
    if (value == 0) return self.byte(Op.ZERO);
    if (value == 1) return self.byte(Op.ONE);
    if (value <= 0xFF) {
        try self.byte(Op.BYTE_PREFIX);
        try self.byte(@intCast(value));
    } else if (value <= 0xFFFF) {
        try self.byte(Op.WORD_PREFIX);
        try self.appendInt(u16, @intCast(value));
    } else if (value <= 0xFFFF_FFFF) {
        try self.byte(Op.DWORD_PREFIX);
        try self.appendInt(u32, @intCast(value));
    } else {
        try self.byte(Op.QWORD_PREFIX);
        try self.appendInt(u64, value);
    }
}

pub fn string(self: *Aml, text: []const u8) Error!void {
    try self.byte(Op.STRING_PREFIX);
    try self.raw(text);
    try self.byte(0);
}

/// Encode an ASL name path such as "\\_SB", "^PCI0", "_SB_.PCI0" or "COM0".
/// Segments shorter than four characters are padded with '_'.
pub fn nameString(self: *Aml, path: []const u8) Error!void {
    var rest = path;
    while (rest.len > 0 and (rest[0] == '\\' or rest[0] == '^')) {
        try self.byte(if (rest[0] == '\\') Op.ROOT_CHAR else Op.PARENT_CHAR);
        rest = rest[1..];
    }
    var segments: [8][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, rest, '.');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        assert(count < segments.len);
        assert(segment.len <= 4);
        segments[count] = segment;
        count += 1;
    }
    switch (count) {
        0 => try self.byte(Op.NULL_NAME),
        1 => {},
        2 => try self.byte(Op.DUAL_NAME_PREFIX),
        else => {
            try self.byte(Op.MULTI_NAME_PREFIX);
            try self.byte(@intCast(count));
        },
    }
    for (segments[0..count]) |segment| {
        var padded: [4]u8 = .{ '_', '_', '_', '_' };
        @memcpy(padded[0..segment.len], segment);
        try self.raw(&padded);
    }
}

/// PkgLength for a payload of `payload_len` bytes; the length covers the
/// PkgLength bytes themselves.
pub fn pkgLength(self: *Aml, payload_len: usize) Error!void {
    if (payload_len + 1 < 0x40) {
        try self.byte(@intCast(payload_len + 1));
        return;
    }
    if (payload_len + 2 < 0x1000) {
        const total: u32 = @intCast(payload_len + 2);
        try self.byte(@as(u8, 0x40) | @as(u8, @truncate(total & 0xF)));
        try self.byte(@truncate(total >> 4));
        return;
    }
    if (payload_len + 3 < 0x10_0000) {
        const total: u32 = @intCast(payload_len + 3);
        try self.byte(@as(u8, 0x80) | @as(u8, @truncate(total & 0xF)));
        try self.byte(@truncate(total >> 4));
        try self.byte(@truncate(total >> 12));
        return;
    }
    const total: u32 = @intCast(payload_len + 4);
    assert(total < 0x1000_0000);
    try self.byte(@as(u8, 0xC0) | @as(u8, @truncate(total & 0xF)));
    try self.byte(@truncate(total >> 4));
    try self.byte(@truncate(total >> 12));
    try self.byte(@truncate(total >> 20));
}

/// Emit `opcode` (one or two bytes), a PkgLength, then `payload`.
fn packaged(self: *Aml, opcode: []const u8, payload: []const u8) Error!void {
    try self.raw(opcode);
    try self.pkgLength(payload.len);
    try self.raw(payload);
}

pub fn scope(self: *Aml, path: []const u8, body: []const u8) Error!void {
    var head = Aml.init(self.alloc);
    defer head.deinit();
    try head.nameString(path);
    try self.raw(&.{Op.SCOPE});
    try self.pkgLength(head.items().len + body.len);
    try self.raw(head.items());
    try self.raw(body);
}

pub fn device(self: *Aml, name: []const u8, body: []const u8) Error!void {
    var head = Aml.init(self.alloc);
    defer head.deinit();
    try head.nameString(name);
    try self.raw(&.{ Op.EXT_PREFIX, Op.DEVICE });
    try self.pkgLength(head.items().len + body.len);
    try self.raw(head.items());
    try self.raw(body);
}

/// Method(name, arg_count, Serialized/NotSerialized) { body }
pub fn method(self: *Aml, name: []const u8, arg_count: u3, serialized: bool, body: []const u8) Error!void {
    var head = Aml.init(self.alloc);
    defer head.deinit();
    try head.nameString(name);
    const flags: u8 = @as(u8, arg_count) | (if (serialized) @as(u8, 0x08) else 0);
    try head.byte(flags);
    try self.raw(&.{Op.METHOD});
    try self.pkgLength(head.items().len + body.len);
    try self.raw(head.items());
    try self.raw(body);
}

/// Name(name, <value AML>)
pub fn nameDecl(self: *Aml, name: []const u8, value: []const u8) Error!void {
    try self.byte(Op.NAME);
    try self.nameString(name);
    try self.raw(value);
}

pub fn nameInteger(self: *Aml, name: []const u8, value: u64) Error!void {
    var v = Aml.init(self.alloc);
    defer v.deinit();
    try v.integer(value);
    try self.nameDecl(name, v.items());
}

pub fn nameStringValue(self: *Aml, name: []const u8, text: []const u8) Error!void {
    var v = Aml.init(self.alloc);
    defer v.deinit();
    try v.string(text);
    try self.nameDecl(name, v.items());
}

/// Buffer(size) { bytes } — size is the byte count.
pub fn buffer(self: *Aml, bytes: []const u8) Error!void {
    var size = Aml.init(self.alloc);
    defer size.deinit();
    try size.integer(bytes.len);
    try self.raw(&.{Op.BUFFER});
    try self.pkgLength(size.items().len + bytes.len);
    try self.raw(size.items());
    try self.raw(bytes);
}

/// Package() { elements } — `count` is the number of elements in `body`.
pub fn package(self: *Aml, count: u8, body: []const u8) Error!void {
    try self.raw(&.{Op.PACKAGE});
    try self.pkgLength(1 + body.len);
    try self.byte(count);
    try self.raw(body);
}

/// If (predicate) { body }
pub fn ifBlock(self: *Aml, predicate: []const u8, body: []const u8) Error!void {
    try self.raw(&.{Op.IF});
    try self.pkgLength(predicate.len + body.len);
    try self.raw(predicate);
    try self.raw(body);
}

pub fn elseBlock(self: *Aml, body: []const u8) Error!void {
    try self.packaged(&.{Op.ELSE}, body);
}

/// Buffer holding a UUID in its ACPI byte order, as ToUUID() produces.
pub fn uuidBuffer(self: *Aml, text: []const u8) Error!void {
    // Textual order first, then the mixed-endian layout: the first three
    // groups are little-endian, the rest stays as written.
    var textual: [16]u8 = undefined;
    var index: usize = 0;
    var pos: usize = 0;
    while (pos < text.len and index < textual.len) : (pos += 1) {
        if (text[pos] == '-') continue;
        assert(pos + 1 < text.len);
        textual[index] = std.fmt.parseInt(u8, text[pos .. pos + 2], 16) catch unreachable;
        index += 1;
        pos += 1;
    }
    assert(index == textual.len);
    const bytes = [16]u8{
        textual[3],  textual[2],  textual[1],  textual[0],
        textual[5],  textual[4],  textual[7],  textual[6],
        textual[8],  textual[9],  textual[10], textual[11],
        textual[12], textual[13], textual[14], textual[15],
    };
    try self.buffer(&bytes);
}

pub fn appendInt(self: *Aml, comptime T: type, value: T) Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try self.raw(&buf);
}

// =============================================================================
// Resource descriptors (ACPI 6.5 section 6.4). These append raw descriptor
// bytes; wrap them with `resourceTemplate` to form the _CRS buffer.
// =============================================================================

pub const Resource = struct {
    pub fn memory32Fixed(aml: *Aml, base: u32, length: u32, writable: bool) Error!void {
        try aml.raw(&.{ 0x86, 0x09, 0x00, @intFromBool(writable) });
        try aml.appendInt(u32, base);
        try aml.appendInt(u32, length);
    }

    pub const InterruptFlags = packed struct(u8) {
        consumer: bool = true,
        edge: bool = false,
        active_low: bool = false,
        shared: bool = false,
        wake: bool = false,
        _padding: u3 = 0,
    };

    pub fn extendedInterrupt(aml: *Aml, flags: InterruptFlags, gsivs: []const u32) Error!void {
        assert(gsivs.len > 0 and gsivs.len < 0xFF);
        const length: u16 = @intCast(2 + 4 * gsivs.len);
        try aml.byte(0x89);
        try aml.appendInt(u16, length);
        try aml.byte(@bitCast(flags));
        try aml.byte(@intCast(gsivs.len));
        for (gsivs) |gsiv| try aml.appendInt(u32, gsiv);
    }

    const GENERAL_FLAGS_PRODUCER_FIXED: u8 = 0x0C; // _MIF | _MAF, producer
    const GENERAL_FLAGS_CONSUMER_FIXED: u8 = 0x0D;

    /// WordBusNumber(ResourceProducer, MinFixed, MaxFixed, PosDecode, ...)
    pub fn wordBusNumber(aml: *Aml, min: u16, max: u16) Error!void {
        try aml.raw(&.{ 0x88, 0x0D, 0x00, 0x02, GENERAL_FLAGS_PRODUCER_FIXED, 0x00 });
        try aml.appendInt(u16, 0); // granularity
        try aml.appendInt(u16, min);
        try aml.appendInt(u16, max);
        try aml.appendInt(u16, 0); // translation
        try aml.appendInt(u16, max - min + 1);
    }

    /// DWordMemory(ResourceProducer, PosDecode, MinFixed, MaxFixed,
    /// NonCacheable, ReadWrite, ...) with a CPU-side translation offset.
    pub fn dwordMemory(aml: *Aml, min: u32, length: u32, translation: u32) Error!void {
        try aml.raw(&.{ 0x87, 0x17, 0x00, 0x00, GENERAL_FLAGS_PRODUCER_FIXED, 0x01 });
        try aml.appendInt(u32, 0);
        try aml.appendInt(u32, min);
        try aml.appendInt(u32, min + length - 1);
        try aml.appendInt(u32, translation);
        try aml.appendInt(u32, length);
    }

    /// DWordIO(ResourceProducer, MinFixed, MaxFixed, PosDecode, EntireRange,
    /// ..., TypeStatic, DenseTranslation) mapping ports at a CPU offset.
    pub fn dwordIo(aml: *Aml, min: u32, length: u32, translation: u32) Error!void {
        try aml.raw(&.{ 0x87, 0x17, 0x00, 0x01, GENERAL_FLAGS_PRODUCER_FIXED, 0x03 });
        try aml.appendInt(u32, 0);
        try aml.appendInt(u32, min);
        try aml.appendInt(u32, min + length - 1);
        try aml.appendInt(u32, translation);
        try aml.appendInt(u32, length);
    }

    /// QWordMemory(ResourceConsumer, PosDecode, MinFixed, MaxFixed,
    /// NonCacheable, ReadWrite, ...) — a fixed reservation such as ECAM.
    pub fn qwordMemoryConsumer(aml: *Aml, min: u64, length: u64) Error!void {
        try aml.raw(&.{ 0x8A, 0x2B, 0x00, 0x00, GENERAL_FLAGS_CONSUMER_FIXED, 0x01 });
        try aml.appendInt(u64, 0);
        try aml.appendInt(u64, min);
        try aml.appendInt(u64, min + length - 1);
        try aml.appendInt(u64, 0);
        try aml.appendInt(u64, length);
    }

    pub fn endTag(aml: *Aml) Error!void {
        try aml.raw(&.{ 0x79, 0x00 });
    }
};

/// Name(name, ResourceTemplate() { descriptors })
pub fn resourceTemplate(self: *Aml, name: []const u8, descriptors: []const u8) Error!void {
    var body = Aml.init(self.alloc);
    defer body.deinit();
    try body.raw(descriptors);
    try Resource.endTag(&body);
    var value = Aml.init(self.alloc);
    defer value.deinit();
    try value.buffer(body.items());
    try self.nameDecl(name, value.items());
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "integers pick the shortest prefix" {
    var aml = Aml.init(testing.allocator);
    defer aml.deinit();
    try aml.integer(0);
    try aml.integer(1);
    try aml.integer(0x7F);
    try aml.integer(0x1234);
    try aml.integer(0x1234_5678);
    try aml.integer(0x1_0000_0000);
    try testing.expectEqualSlices(u8, &.{
        0x00,
        0x01,
        0x0A,
        0x7F,
        0x0B,
        0x34,
        0x12,
        0x0C,
        0x78,
        0x56,
        0x34,
        0x12,
        0x0E,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
    }, aml.items());
}

test "name strings pad, prefix and chain segments" {
    var aml = Aml.init(testing.allocator);
    defer aml.deinit();
    try aml.nameString("\\_SB");
    try aml.nameString("^PCI0");
    try aml.nameString("_SB_.PCI0");
    try aml.nameString("\\_SB.PCI0.RES0");
    try testing.expectEqualSlices(u8, "\x5C_SB_" ++ "\x5EPCI0" ++ "\x2E_SB_PCI0" ++
        "\x5C\x2F\x03_SB_PCI0RES0", aml.items());
}

test "package lengths use one to three bytes as needed" {
    var aml = Aml.init(testing.allocator);
    defer aml.deinit();
    try aml.pkgLength(5);
    try testing.expectEqualSlices(u8, &.{0x06}, aml.items());

    aml.bytes.clearRetainingCapacity();
    try aml.pkgLength(0x3E); // 0x3E + 1 = 0x3F still fits one byte
    try testing.expectEqualSlices(u8, &.{0x3F}, aml.items());

    aml.bytes.clearRetainingCapacity();
    try aml.pkgLength(0x3F); // needs two bytes: total 0x41
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x04 }, aml.items());

    aml.bytes.clearRetainingCapacity();
    try aml.pkgLength(0x1000); // total 0x1003 → three bytes
    try testing.expectEqualSlices(u8, &.{ 0x83, 0x00, 0x01 }, aml.items());
}

test "device with a name and resource template assembles like iasl" {
    // Device (COM0) { Name (_HID, "ARMH0011") Name (_CRS, ResourceTemplate () {
    //   Memory32Fixed (ReadWrite, 0x09000000, 0x1000) Interrupt (..., Level, ActiveHigh, Exclusive) { 33 } }) }
    var body = Aml.init(testing.allocator);
    defer body.deinit();
    try body.nameStringValue("_HID", "ARMH0011");
    var crs = Aml.init(testing.allocator);
    defer crs.deinit();
    try Resource.memory32Fixed(&crs, 0x0900_0000, 0x1000, true);
    try Resource.extendedInterrupt(&crs, .{}, &.{33});
    try body.resourceTemplate("_CRS", crs.items());

    var aml = Aml.init(testing.allocator);
    defer aml.deinit();
    try aml.device("COM0", body.items());

    const expected = [_]u8{
        0x5B, 0x82, 0x34, 'C',  'O',  'M',  '0',
        0x08, '_',  'H',  'I',  'D',  0x0D, 'A',
        'R',  'M',  'H',  '0',  '0',  '1',  '1',
        0x00, 0x08, '_',  'C',  'R',  'S',  0x11,
        0x1A, 0x0A, 0x17, 0x86, 0x09, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x09, 0x00, 0x10, 0x00,
        0x00, 0x89, 0x06, 0x00, 0x01, 0x01, 0x21,
        0x00, 0x00, 0x00, 0x79, 0x00,
    };
    try testing.expectEqualSlices(u8, &expected, aml.items());
}

test "uuid buffers follow the ToUUID byte order" {
    var aml = Aml.init(testing.allocator);
    defer aml.deinit();
    try aml.uuidBuffer("e5c937d0-3553-4d7a-9117-ea4d19c3434d");
    try testing.expectEqualSlices(u8, &.{
        0x11, 0x13, 0x0A, 0x10,
        0xD0, 0x37, 0xC9, 0xE5,
        0x53, 0x35, 0x7A, 0x4D,
        0x91, 0x17, 0xEA, 0x4D,
        0x19, 0xC3, 0x43, 0x4D,
    }, aml.items());
}

test "method encodes flags and package counts" {
    var body = Aml.init(testing.allocator);
    defer body.deinit();
    try body.byte(Op.RETURN);
    try body.integer(0x0F);
    var aml = Aml.init(testing.allocator);
    defer aml.deinit();
    try aml.method("_STA", 0, false, body.items());
    try testing.expectEqualSlices(u8, &.{ 0x14, 0x09, '_', 'S', 'T', 'A', 0x00, 0xA4, 0x0A, 0x0F }, aml.items());

    aml.bytes.clearRetainingCapacity();
    var elems = Aml.init(testing.allocator);
    defer elems.deinit();
    try elems.integer(1);
    try elems.integer(2);
    try aml.package(2, elems.items());
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x05, 0x02, 0x01, 0x0A, 0x02 }, aml.items());
}
