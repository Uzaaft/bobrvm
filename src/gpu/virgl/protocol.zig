//! Virgl Protocol Definitions.
//!
//! Command opcodes, object types, and header structures for the
//! virglrenderer wire protocol (virgl_protocol.h).
//!
//! Reference: https://github.com/virglrenderer/virglrenderer

const std = @import("std");

// =============================================================================
// Command Header
// =============================================================================

/// Virgl command header (packed in a single u32).
/// Bits 0-7: opcode, Bits 8-15: object_type, Bits 16-31: length (in dwords)
pub const CommandHeader = struct {
    opcode: Command,
    object_type: ObjectType,
    length: u16,

    pub fn parse(header: u32) CommandHeader {
        return .{
            .opcode = @enumFromInt(@as(u8, @truncate(header))),
            .object_type = @enumFromInt(@as(u8, @truncate(header >> 8))),
            .length = @truncate(header >> 16),
        };
    }

    pub fn encode(self: CommandHeader) u32 {
        return @as(u32, @intFromEnum(self.opcode)) |
            (@as(u32, @intFromEnum(self.object_type)) << 8) |
            (@as(u32, self.length) << 16);
    }
};

// =============================================================================
// Command Opcodes
// =============================================================================

/// Virgl context commands (VIRGL_CCMD_*).
pub const Command = enum(u8) {
    nop = 0,
    create_object = 1,
    bind_object = 2,
    destroy_object = 3,
    set_viewport_state = 4,
    set_framebuffer_state = 5,
    set_vertex_buffers = 6,
    clear = 7,
    draw_vbo = 8,
    resource_inline_write = 9,
    set_sampler_views = 10,
    set_index_buffer = 11,
    set_constant_buffer = 12,
    set_stencil_ref = 13,
    set_blend_color = 14,
    set_scissor_state = 15,
    blit = 16,
    resource_copy_region = 17,
    bind_sampler_states = 18,
    begin_query = 19,
    end_query = 20,
    get_query_result = 21,
    set_polygon_stipple = 22,
    set_clip_state = 23,
    set_sample_mask = 24,
    set_streamout_targets = 25,
    set_render_condition = 26,
    set_uniform_buffer = 27,
    set_sub_ctx = 28,
    create_sub_ctx = 29,
    destroy_sub_ctx = 30,
    bind_shader = 31,
    set_tess_state = 32,
    set_min_samples = 33,
    set_shader_buffers = 34,
    set_shader_images = 35,
    memory_barrier = 36,
    launch_grid = 37,
    set_framebuffer_state_no_attach = 38,
    texture_barrier = 39,
    set_atomic_buffers = 40,
    set_debug_flags = 41,
    get_query_result_qbo = 42,
    transfer_3d = 43,
    end_transfers = 44,
    copy_transfer_3d = 45,
    set_tweaks = 46,
    clear_texture = 47,
    pipe_resource_create = 48,
    pipe_resource_set_type = 49,
    get_memory_info = 50,
    send_string_marker = 51,
    link_shader = 52,
    _,
};

// =============================================================================
// Object Types
// =============================================================================

/// Virgl object types for CREATE_OBJECT command.
pub const ObjectType = enum(u8) {
    null = 0,
    blend = 1,
    rasterizer = 2,
    dsa = 3, // Depth-Stencil-Alpha
    shader = 4,
    vertex_elements = 5,
    sampler_view = 6,
    sampler_state = 7,
    surface = 8,
    query = 9,
    streamout_target = 10,
    msaa_surface = 11,
    _,
};

// =============================================================================
// Shader Types
// =============================================================================

/// Pipe shader types (PIPE_SHADER_*).
pub const ShaderType = enum(u8) {
    fragment = 0,
    vertex = 1,
    geometry = 2,
    tess_ctrl = 3,
    tess_eval = 4,
    compute = 5,
    _,
};

// =============================================================================
// Primitive Types
// =============================================================================

/// Pipe primitive types (PIPE_PRIM_*).
pub const PrimitiveType = enum(u8) {
    points = 0,
    lines = 1,
    line_loop = 2,
    line_strip = 3,
    triangles = 4,
    triangle_strip = 5,
    triangle_fan = 6,
    quads = 7,
    quad_strip = 8,
    polygon = 9,
    lines_adjacency = 10,
    line_strip_adjacency = 11,
    triangles_adjacency = 12,
    triangle_strip_adjacency = 13,
    patches = 14,
    _,
};

// =============================================================================
// Blend Factors
// =============================================================================

/// Pipe blend factors (PIPE_BLENDFACTOR_*).
pub const BlendFactor = enum(u5) {
    one = 0x01,
    src_color = 0x02,
    src_alpha = 0x03,
    dst_alpha = 0x04,
    dst_color = 0x05,
    src_alpha_saturate = 0x06,
    const_color = 0x07,
    const_alpha = 0x08,
    src1_color = 0x09,
    src1_alpha = 0x0A,
    zero = 0x11,
    inv_src_color = 0x12,
    inv_src_alpha = 0x13,
    inv_dst_alpha = 0x14,
    inv_dst_color = 0x15,
    inv_const_color = 0x17,
    inv_const_alpha = 0x18,
    inv_src1_color = 0x19,
    inv_src1_alpha = 0x1A,
    _,
};

/// Pipe blend functions (PIPE_BLEND_*).
pub const BlendFunc = enum(u3) {
    add = 0,
    subtract = 1,
    reverse_subtract = 2,
    min = 3,
    max = 4,
    _,
};

// =============================================================================
// Compare Functions
// =============================================================================

/// Pipe compare functions (PIPE_FUNC_*).
pub const CompareFunc = enum(u3) {
    never = 0,
    less = 1,
    equal = 2,
    lequal = 3,
    greater = 4,
    notequal = 5,
    gequal = 6,
    always = 7,
};

// =============================================================================
// Stencil Operations
// =============================================================================

/// Pipe stencil operations (PIPE_STENCIL_OP_*).
pub const StencilOp = enum(u3) {
    keep = 0,
    zero = 1,
    replace = 2,
    incr = 3,
    decr = 4,
    incr_wrap = 5,
    decr_wrap = 6,
    invert = 7,
};

// =============================================================================
// Texture Formats
// =============================================================================

/// Pipe texture formats (subset, full list is ~200 entries).
pub const Format = enum(u32) {
    none = 0,
    b8g8r8a8_unorm = 1,
    b8g8r8x8_unorm = 2,
    a8r8g8b8_unorm = 3,
    x8r8g8b8_unorm = 4,
    b5g5r5a1_unorm = 5,
    b4g4r4a4_unorm = 6,
    b5g6r5_unorm = 7,
    r10g10b10a2_unorm = 8,
    l8_unorm = 9,
    a8_unorm = 10,
    l8a8_unorm = 12,
    l16_unorm = 13,
    z16_unorm = 16,
    z32_unorm = 17,
    z32_float = 18,
    z24_unorm_s8_uint = 19,
    s8_uint_z24_unorm = 20,
    z24x8_unorm = 21,
    x8z24_unorm = 22,
    s8_uint = 23,
    r64_float = 24,
    r64g64_float = 25,
    r64g64b64_float = 26,
    r64g64b64a64_float = 27,
    r32_float = 28,
    r32g32_float = 29,
    r32g32b32_float = 30,
    r32g32b32a32_float = 31,
    r32_unorm = 32,
    r32g32_unorm = 33,
    r32g32b32_unorm = 34,
    r32g32b32a32_unorm = 35,
    r32_uscaled = 36,
    r32g32_uscaled = 37,
    r32g32b32_uscaled = 38,
    r32g32b32a32_uscaled = 39,
    r32_snorm = 40,
    r32g32_snorm = 41,
    r32g32b32_snorm = 42,
    r32g32b32a32_snorm = 43,
    r32_sscaled = 44,
    r32g32_sscaled = 45,
    r32g32b32_sscaled = 46,
    r32g32b32a32_sscaled = 47,
    r16_unorm = 48,
    r16g16_unorm = 49,
    r16g16b16_unorm = 50,
    r16g16b16a16_unorm = 51,
    r8_unorm = 64,
    r8g8_unorm = 65,
    r8g8b8_unorm = 66,
    r8g8b8a8_unorm = 67,
    r8_uint = 115,
    r8g8_uint = 116,
    r8g8b8_uint = 117,
    r8g8b8a8_uint = 118,
    r8_sint = 119,
    r16_uint = 123,
    r16g16_uint = 124,
    r16g16b16_uint = 125,
    r16g16b16a16_uint = 126,
    r32_uint = 131,
    r32g32_uint = 132,
    r32g32b32_uint = 133,
    r32g32b32a32_uint = 134,
    r32_sint = 135,
    r32g32_sint = 136,
    r32g32b32_sint = 137,
    r32g32b32a32_sint = 138,
    _,
};

// =============================================================================
// Clear Flags
// =============================================================================

/// Pipe clear flags (PIPE_CLEAR_*).
pub const ClearFlags = packed struct(u32) {
    depth: bool = false,
    stencil: bool = false,
    color0: bool = false,
    color1: bool = false,
    color2: bool = false,
    color3: bool = false,
    color4: bool = false,
    color5: bool = false,
    color6: bool = false,
    color7: bool = false,
    _padding: u22 = 0,
};

// =============================================================================
// Memory Barrier Flags
// =============================================================================

/// Pipe barrier flags.
pub const BarrierFlags = packed struct(u32) {
    mapped_buffer: bool = false,
    shader_buffer: bool = false,
    query_buffer: bool = false,
    vertex_buffer: bool = false,
    index_buffer: bool = false,
    constant_buffer: bool = false,
    indirect_buffer: bool = false,
    framebuffer: bool = false,
    streamout_buffer: bool = false,
    global_buffer: bool = false,
    texture: bool = false,
    image: bool = false,
    all: bool = false,
    _padding: u19 = 0,
};

// =============================================================================
// Command Sizes (in dwords)
// =============================================================================

pub const CommandSize = struct {
    pub const DRAW_VBO = 12;
    pub const DRAW_VBO_TESS = 14;
    pub const DRAW_VBO_INDIRECT = 21;
    pub const CLEAR = 8;
    pub const SET_VIEWPORT_STATE = 7; // per viewport
    pub const FRAMEBUFFER_STATE_HDR = 2;
    pub const VERTEX_BUFFER = 3; // per buffer
    pub const SAMPLER_VIEW = 11;
    pub const BLIT = 23;
};

// =============================================================================
// Blend State Offsets
// =============================================================================

pub const BlendState = struct {
    /// S0: Control flags
    pub const S0_INDEPENDENT_BLEND_ENABLE: u32 = 1 << 0;
    pub const S0_LOGICOP_ENABLE: u32 = 1 << 1;
    pub const S0_DITHER: u32 = 1 << 2;
    pub const S0_ALPHA_TO_COVERAGE: u32 = 1 << 3;
    pub const S0_ALPHA_TO_ONE: u32 = 1 << 4;

    /// Per-RT blend state bit layout
    pub fn rtBlendEnable(x: bool) u32 {
        return @as(u32, @intFromBool(x));
    }

    pub fn rtRgbFunc(x: BlendFunc) u32 {
        return @as(u32, @intFromEnum(x)) << 1;
    }

    pub fn rtRgbSrcFactor(x: BlendFactor) u32 {
        return @as(u32, @intFromEnum(x)) << 4;
    }

    pub fn rtRgbDstFactor(x: BlendFactor) u32 {
        return @as(u32, @intFromEnum(x)) << 9;
    }

    pub fn rtAlphaFunc(x: BlendFunc) u32 {
        return @as(u32, @intFromEnum(x)) << 14;
    }

    pub fn rtAlphaSrcFactor(x: BlendFactor) u32 {
        return @as(u32, @intFromEnum(x)) << 17;
    }

    pub fn rtAlphaDstFactor(x: BlendFactor) u32 {
        return @as(u32, @intFromEnum(x)) << 22;
    }

    pub fn rtColorMask(x: u4) u32 {
        return @as(u32, x) << 27;
    }

    /// Parse per-RT blend state
    pub fn parseRtBlend(word: u32) RtBlendState {
        return .{
            .blend_enable = (word & 0x1) != 0,
            .rgb_func = @enumFromInt(@as(u3, @truncate((word >> 1) & 0x7))),
            .rgb_src_factor = @enumFromInt(@as(u5, @truncate((word >> 4) & 0x1f))),
            .rgb_dst_factor = @enumFromInt(@as(u5, @truncate((word >> 9) & 0x1f))),
            .alpha_func = @enumFromInt(@as(u3, @truncate((word >> 14) & 0x7))),
            .alpha_src_factor = @enumFromInt(@as(u5, @truncate((word >> 17) & 0x1f))),
            .alpha_dst_factor = @enumFromInt(@as(u5, @truncate((word >> 22) & 0x1f))),
            .color_mask = @truncate((word >> 27) & 0xf),
        };
    }
};

/// Parsed per-RT blend state.
pub const RtBlendState = struct {
    blend_enable: bool,
    rgb_func: BlendFunc,
    rgb_src_factor: BlendFactor,
    rgb_dst_factor: BlendFactor,
    alpha_func: BlendFunc,
    alpha_src_factor: BlendFactor,
    alpha_dst_factor: BlendFactor,
    color_mask: u4,
};

// =============================================================================
// Tests
// =============================================================================

test "CommandHeader parse/encode roundtrip" {
    const header = CommandHeader{
        .opcode = .draw_vbo,
        .object_type = .null,
        .length = 12,
    };
    const encoded = header.encode();
    const decoded = CommandHeader.parse(encoded);

    try std.testing.expectEqual(header.opcode, decoded.opcode);
    try std.testing.expectEqual(header.object_type, decoded.object_type);
    try std.testing.expectEqual(header.length, decoded.length);
}

test "BlendState parseRtBlend" {
    // blend_enable=1, rgb_func=ADD, rgb_src=ONE, rgb_dst=ZERO, ...
    const word: u32 = 0x1 | (0 << 1) | (0x01 << 4) | (0x11 << 9) | (0xf << 27);
    const state = BlendState.parseRtBlend(word);

    try std.testing.expect(state.blend_enable);
    try std.testing.expectEqual(BlendFunc.add, state.rgb_func);
    try std.testing.expectEqual(BlendFactor.one, state.rgb_src_factor);
    try std.testing.expectEqual(BlendFactor.zero, state.rgb_dst_factor);
    try std.testing.expectEqual(@as(u4, 0xf), state.color_mask);
}
