//! Virgl Command Stream Decoder.
//!
//! Parses the command stream from guest Mesa driver and dispatches
//! to the appropriate handlers.

const std = @import("std");
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
pub const Decoder = struct {
    data: []const u32,
    pos: usize,

    pub fn init(data: []const u8) Decoder {
        // Reinterpret bytes as u32 slice (must handle alignment)
        const ptr: [*]const u32 = @ptrCast(@alignCast(data.ptr));
        const len = data.len / @sizeOf(u32);
        return .{
            .data = ptr[0..len],
            .pos = 0,
        };
    }

    /// Check if more commands are available.
    pub fn hasMore(self: *const Decoder) bool {
        return self.pos < self.data.len;
    }

    /// Read the next command header.
    pub fn nextHeader(self: *Decoder) DecodeError!proto.CommandHeader {
        if (self.pos >= self.data.len) return DecodeError.UnexpectedEnd;

        const header = proto.CommandHeader.parse(self.data[self.pos]);
        self.pos += 1;

        // Validate length
        if (self.pos + header.length > self.data.len) {
            return DecodeError.InvalidLength;
        }

        return header;
    }

    /// Get payload slice for current command.
    pub fn payload(self: *Decoder, length: u16) DecodeError![]const u32 {
        if (self.pos + length > self.data.len) {
            return DecodeError.UnexpectedEnd;
        }
        const result = self.data[self.pos .. self.pos + length];
        self.pos += length;
        return result;
    }

    /// Skip current command payload.
    pub fn skip(self: *Decoder, length: u16) void {
        self.pos += length;
    }

    /// Read a single u32.
    pub fn readU32(self: *Decoder) DecodeError!u32 {
        if (self.pos >= self.data.len) return DecodeError.UnexpectedEnd;
        const val = self.data[self.pos];
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
