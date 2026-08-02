//! Virgl Command Stream Decoder.
//!
//! Parses the command stream from guest Mesa driver and dispatches
//! to the appropriate handlers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const proto = @import("protocol.zig");

/// Decoded draw command.
pub const DrawCommand = struct {
    start: u32,
    count: u32,
    mode: proto.PrimitiveType,
    indexed: bool,
    instance_count: u32,
    index_bias: i32,
    start_instance: u32,
    primitive_restart: bool,
    restart_index: u32,
    min_index: u32,
    max_index: u32,
    // Tessellation
    vertices_per_patch: u32 = 0,
    draw_id: u32 = 0,
    // Indirect
    indirect_handle: u32 = 0,
    indirect_offset: u32 = 0,
    indirect_stride: u32 = 0,
    indirect_draw_count: u32 = 0,
};

/// Decoded clear command.
pub const ClearCommand = struct {
    flags: proto.ClearFlags,
    color: [4]f32,
    depth: f64,
    stencil: u32,
};

/// Decoded viewport state.
pub const ViewportState = struct {
    scale: [3]f32,
    translate: [3]f32,
};

/// Decoded framebuffer state.
pub const FramebufferState = struct {
    nr_cbufs: u32,
    zsurf_handle: u32,
    surf_handles: [8]u32,
};

/// Decoded vertex buffer binding.
pub const VertexBuffer = struct {
    stride: u32,
    offset: u32,
    handle: u32,
};

/// Decoder error.
pub const DecodeError = error{
    UnexpectedEnd,
    InvalidCommand,
    InvalidLength,
};

/// Command decoder state machine.
/// Largest payload a single virgl command can describe: the header's length
/// field is a u16, in words.
pub const MAX_PAYLOAD_WORDS: usize = std.math.maxInt(u16);

/// Overflow scratch for payloads too large for the inline buffer. A real
/// compositor sends commands well past 4096 words, and rejecting them used to
/// abort the entire command batch (dropping every command behind it, which is
/// how ~60 object creations went missing and left the screen blank).
///
/// Module-level rather than per-Decoder so a 256 KiB buffer never lands on the
/// vCPU stack. Safe because virgl command decoding is serialized: submits are
/// processed one at a time on the vCPU thread under the GPU lock, and a
/// payload slice is always consumed before the next payload() call.
var overflow_scratch: [MAX_PAYLOAD_WORDS]u32 = undefined;

pub const Decoder = struct {
    /// Raw guest bytes (arbitrary alignment: the command buffer comes
    /// straight from a guest descriptor, which need not be 4-aligned).
    bytes: []const u8,
    /// Length in whole u32 words.
    word_len: usize,
    /// Direct word view for the common aligned, little-endian command buffer.
    aligned_words: ?[]const u32,
    /// Current position, in words.
    pos: usize,
    /// Inline scratch for the common (small) payload. Kept modest because a
    /// Decoder lives on the caller's stack.
    scratch: [4096]u32 = undefined,

    pub fn init(data: []const u8) Decoder {
        comptime assert(builtin.cpu.arch.endian() == .little);
        const word_len = data.len / @sizeOf(u32);
        const word_bytes = data[0 .. word_len * @sizeOf(u32)];
        const aligned_words: ?[]const u32 = if (std.mem.isAligned(
            @intFromPtr(word_bytes.ptr),
            @alignOf(u32),
        )) blk: {
            const aligned: []align(@alignOf(u32)) const u8 = @alignCast(word_bytes);
            break :blk std.mem.bytesAsSlice(u32, aligned);
        } else null;
        return .{
            .bytes = data,
            .word_len = word_len,
            .aligned_words = aligned_words,
            .pos = 0,
        };
    }

    /// Read word `i` with no alignment requirement.
    fn wordAt(self: *const Decoder, i: usize) u32 {
        if (self.aligned_words) |words| return words[i];
        return std.mem.readInt(u32, self.bytes[i * 4 ..][0..4], .little);
    }

    /// Payload-only decoders read from a scratch slice; keep them working
    /// by materializing words on demand. `data` exposes the word count.
    pub fn data_len(self: *const Decoder) usize {
        return self.word_len;
    }

    /// Check if more commands are available.
    pub fn hasMore(self: *const Decoder) bool {
        return self.pos < self.word_len;
    }

    /// Read the next command header.
    pub fn nextHeader(self: *Decoder) DecodeError!proto.CommandHeader {
        if (self.pos >= self.word_len) return DecodeError.UnexpectedEnd;

        const header = proto.CommandHeader.parse(self.wordAt(self.pos));
        self.pos += 1;

        // Validate length (guest-controlled: guard against overflow and
        // running past the buffer).
        if (@as(usize, self.pos) + header.length > self.word_len) {
            return DecodeError.InvalidLength;
        }

        return header;
    }

    /// Get payload slice for current command. Returns owned words copied
    /// into a bounded scratch buffer so callers get a []const u32 without
    /// any alignment assumption on the guest bytes.
    pub fn payload(self: *Decoder, length: u16) DecodeError![]const u32 {
        if (self.pos + length > self.word_len) {
            return DecodeError.UnexpectedEnd;
        }
        if (self.aligned_words) |words| {
            const result = words[self.pos..][0..length];
            self.pos += length;
            return result;
        }
        const dst: []u32 = if (length <= self.scratch.len)
            self.scratch[0..length]
        else
            overflow_scratch[0..length];
        for (0..length) |i| dst[i] = self.wordAt(self.pos + i);
        self.pos += length;
        return dst;
    }

    /// Skip current command payload (bounded to the buffer).
    pub fn skip(self: *Decoder, length: u16) void {
        self.pos = @min(self.pos + length, self.word_len);
    }

    /// Read a single u32.
    pub fn readU32(self: *Decoder) DecodeError!u32 {
        if (self.pos >= self.word_len) return DecodeError.UnexpectedEnd;
        const val = self.wordAt(self.pos);
        self.pos += 1;
        return val;
    }

    /// Read a single f32.
    pub fn readF32(self: *Decoder) DecodeError!f32 {
        const bits = try self.readU32();
        return @bitCast(bits);
    }

    /// Read a single i32.
    pub fn readI32(self: *Decoder) DecodeError!i32 {
        const bits = try self.readU32();
        return @bitCast(bits);
    }

    // =========================================================================
    // Command Decoders
    // =========================================================================

    /// Decode DRAW_VBO command.
    pub fn decodeDrawVbo(self: *Decoder, length: u16) DecodeError!DrawCommand {
        if (length < proto.CommandSize.DRAW_VBO) {
            return DecodeError.InvalidLength;
        }

        var cmd = DrawCommand{
            .start = try self.readU32(),
            .count = try self.readU32(),
            .mode = @enumFromInt(@as(u8, @truncate(try self.readU32()))),
            .indexed = (try self.readU32()) != 0,
            .instance_count = try self.readU32(),
            .index_bias = try self.readI32(),
            .start_instance = try self.readU32(),
            .primitive_restart = (try self.readU32()) != 0,
            .restart_index = try self.readU32(),
            .min_index = try self.readU32(),
            .max_index = try self.readU32(),
        };

        // Skip cso field
        _ = try self.readU32();

        // Check for tessellation extension
        if (length >= proto.CommandSize.DRAW_VBO_TESS) {
            cmd.vertices_per_patch = try self.readU32();
            cmd.draw_id = try self.readU32();
        }

        // Check for indirect extension
        if (length >= proto.CommandSize.DRAW_VBO_INDIRECT) {
            // Skip remaining fields for now
            const remaining = length - @as(u16, proto.CommandSize.DRAW_VBO_TESS);
            for (0..remaining) |_| {
                _ = try self.readU32();
            }
        }

        return cmd;
    }

    /// Decode CLEAR command.
    pub fn decodeClear(self: *Decoder, length: u16) DecodeError!ClearCommand {
        _ = length;
        return ClearCommand{
            .flags = @bitCast(try self.readU32()),
            .color = .{
                try self.readF32(),
                try self.readF32(),
                try self.readF32(),
                try self.readF32(),
            },
            .depth = @as(f64, @bitCast(@as(u64, try self.readU32()) | (@as(u64, try self.readU32()) << 32))),
            .stencil = try self.readU32(),
        };
    }

    /// Decode SET_VIEWPORT_STATE command.
    pub fn decodeViewport(self: *Decoder, length: u16) DecodeError!ViewportState {
        _ = length;
        // First word is start_slot
        _ = try self.readU32();

        return ViewportState{
            .scale = .{
                try self.readF32(),
                try self.readF32(),
                try self.readF32(),
            },
            .translate = .{
                try self.readF32(),
                try self.readF32(),
                try self.readF32(),
            },
        };
    }

    /// Decode SET_FRAMEBUFFER_STATE command.
    pub fn decodeFramebuffer(self: *Decoder, length: u16) DecodeError!FramebufferState {
        const nr_cbufs = try self.readU32();
        const zsurf_handle = try self.readU32();

        var state = FramebufferState{
            .nr_cbufs = nr_cbufs,
            .zsurf_handle = zsurf_handle,
            .surf_handles = .{0} ** 8,
        };

        const cbufs_to_read = @min(nr_cbufs, 8);
        for (0..cbufs_to_read) |i| {
            state.surf_handles[i] = try self.readU32();
        }

        // Skip any remaining
        const read_so_far = 2 + cbufs_to_read;
        if (length > read_so_far) {
            for (0..(length - @as(u16, @intCast(read_so_far)))) |_| {
                _ = try self.readU32();
            }
        }

        return state;
    }

    /// Decode SET_VERTEX_BUFFERS command.
    pub fn decodeVertexBuffers(self: *Decoder, length: u16) DecodeError![]VertexBuffer {
        // Each VBO is 3 dwords
        const count = length / 3;

        // For now, just skip and return empty
        // In real implementation, would allocate and return
        for (0..count) |_| {
            _ = try self.readU32(); // stride
            _ = try self.readU32(); // offset
            _ = try self.readU32(); // handle
        }

        return &.{};
    }

    /// Decode CREATE_OBJECT handle.
    pub fn decodeObjectHandle(self: *Decoder) DecodeError!u32 {
        return self.readU32();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Decoder init and header parse" {
    // Create a simple command: NOP with length 0
    const header = proto.CommandHeader{
        .opcode = .nop,
        .object_type = .null,
        .length = 0,
    };
    const data = [_]u32{header.encode()};
    const bytes = std.mem.sliceAsBytes(&data);

    var decoder = Decoder.init(bytes);

    try std.testing.expect(decoder.hasMore());
    const decoded = try decoder.nextHeader();
    try std.testing.expectEqual(proto.Command.nop, decoded.opcode);
    try std.testing.expectEqual(@as(u16, 0), decoded.length);
    try std.testing.expect(!decoder.hasMore());
}

test "Decoder clear command" {
    // CLEAR command with 8 dwords payload
    const clear_header = proto.CommandHeader{
        .opcode = .clear,
        .object_type = .null,
        .length = 8,
    };
    const clear_flags = proto.ClearFlags{ .color0 = true, .depth = true };
    var data: [9]u32 = undefined;
    data[0] = clear_header.encode();
    data[1] = @bitCast(clear_flags);
    data[2] = @bitCast(@as(f32, 1.0)); // r
    data[3] = @bitCast(@as(f32, 0.0)); // g
    data[4] = @bitCast(@as(f32, 0.0)); // b
    data[5] = @bitCast(@as(f32, 1.0)); // a
    data[6] = 0; // depth low
    data[7] = 0x3FF00000; // depth high (1.0 in f64)
    data[8] = 0; // stencil

    const bytes = std.mem.sliceAsBytes(&data);
    var dec = Decoder.init(bytes);

    const header = try dec.nextHeader();
    try std.testing.expectEqual(proto.Command.clear, header.opcode);

    const clear = try dec.decodeClear(header.length);
    try std.testing.expect(clear.flags.color0);
    try std.testing.expect(clear.flags.depth);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), clear.color[0], 0.001);
}

test "Decoder tolerates an unaligned guest buffer" {
    // A guest command buffer at an odd offset must not trip @alignCast.
    var raw: [12]u8 align(@alignOf(u32)) = undefined;
    // header word at offset 1: opcode=nop(0), len=1
    const hdr = (proto.CommandHeader{ .opcode = .nop, .object_type = .null, .length = 1 }).encode();
    std.mem.writeInt(u32, raw[1..5], hdr, .little);
    std.mem.writeInt(u32, raw[5..9], 0xDEADBEEF, .little);

    var dec = Decoder.init(raw[1..9]); // 2 words, misaligned base
    const h = try dec.nextHeader();
    try std.testing.expectEqual(proto.Command.nop, h.opcode);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try dec.readU32());
    try std.testing.expect(!dec.hasMore());
}

test "Decoder rejects a header claiming more payload than present" {
    var raw: [4]u8 = undefined;
    // opcode=clear(7), length=100 but only 0 payload words follow
    const hdr = (proto.CommandHeader{ .opcode = .clear, .object_type = .null, .length = 100 }).encode();
    std.mem.writeInt(u32, raw[0..4], hdr, .little);

    var dec = Decoder.init(&raw);
    try std.testing.expectError(DecodeError.InvalidLength, dec.nextHeader());
}

test "Decoder skip is bounded and readU32 stops at end" {
    var raw: [8]u8 = undefined;
    std.mem.writeInt(u32, raw[0..4], 1, .little);
    std.mem.writeInt(u32, raw[4..8], 2, .little);

    var dec = Decoder.init(&raw);
    dec.skip(1000); // over-long skip must not run past the buffer
    try std.testing.expect(!dec.hasMore());
    try std.testing.expectError(DecodeError.UnexpectedEnd, dec.readU32());
}

test "Decoder payload copies words without alignment assumptions" {
    var raw: [13]u8 align(@alignOf(u32)) = undefined;
    std.mem.writeInt(u32, raw[1..5], 0x11111111, .little);
    std.mem.writeInt(u32, raw[5..9], 0x22222222, .little);
    std.mem.writeInt(u32, raw[9..13], 0x33333333, .little);

    var dec = Decoder.init(raw[1..13]); // misaligned, 3 words
    const p = try dec.payload(3);
    try std.testing.expect(@intFromPtr(p.ptr) != @intFromPtr(&raw[1]));
    try std.testing.expectEqual(@as(u32, 0x11111111), p[0]);
    try std.testing.expectEqual(@as(u32, 0x33333333), p[2]);
}

test "Decoder aligned payload staging profile" {
    const words = [_]u32{ 0x11111111, 0x22222222, 0x33333333 };
    const bytes = std.mem.sliceAsBytes(&words);
    var dec = Decoder.init(bytes);
    const payload = try dec.payload(words.len);

    try std.testing.expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(payload.ptr));
    try std.testing.expectEqualSlices(u32, &words, payload);
}
