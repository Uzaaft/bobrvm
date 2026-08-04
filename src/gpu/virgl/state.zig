//! Virgl state objects created and bound by the guest command stream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
pub const proto = @import("protocol.zig");

/// Blend state object (VIRGL_OBJECT_BLEND).
pub const BlendState = struct {
    handle: u32,
    independent_blend: bool,
    logicop_enable: bool,
    logicop_func: u8,
    dither: bool,
    alpha_to_coverage: bool,
    alpha_to_one: bool,
    rt: [8]proto.RtBlendState,

    pub fn parse(handle: u32, data: []const u32) BlendState {
        var state = BlendState{
            .handle = handle,
            .independent_blend = false,
            .logicop_enable = false,
            .logicop_func = 0,
            .dither = false,
            .alpha_to_coverage = false,
            .alpha_to_one = false,
            .rt = undefined,
        };

        if (data.len >= 1) {
            const s0 = data[0];
            state.independent_blend = (s0 & proto.BlendState.S0_INDEPENDENT_BLEND_ENABLE) != 0;
            state.logicop_enable = (s0 & proto.BlendState.S0_LOGICOP_ENABLE) != 0;
            state.dither = (s0 & proto.BlendState.S0_DITHER) != 0;
            state.alpha_to_coverage = (s0 & proto.BlendState.S0_ALPHA_TO_COVERAGE) != 0;
            state.alpha_to_one = (s0 & proto.BlendState.S0_ALPHA_TO_ONE) != 0;
        }

        if (data.len >= 2) {
            state.logicop_func = @truncate(data[1]);
        }

        // Parse per-RT blend state (S2..S9 → rt[0..7])
        for (0..8) |i| {
            if (data.len >= 3 + i) {
                state.rt[i] = proto.BlendState.parseRtBlend(data[2 + i]);
            } else {
                state.rt[i] = .{
                    .blend_enable = false,
                    .rgb_func = .add,
                    .rgb_src_factor = .one,
                    .rgb_dst_factor = .zero,
                    .alpha_func = .add,
                    .alpha_src_factor = .one,
                    .alpha_dst_factor = .zero,
                    .color_mask = 0xf,
                };
            }
        }

        return state;
    }
};

/// Fill mode (PIPE_POLYGON_MODE_*).
pub const FillMode = enum(u2) {
    fill = 0,
    line = 1,
    point = 2,
    _,
};

/// Cull mode (PIPE_FACE_*).
pub const CullMode = enum(u2) {
    none = 0,
    front = 1,
    back = 2,
    front_and_back = 3,
};

/// Rasterizer state object (VIRGL_OBJECT_RASTERIZER).
pub const RasterizerState = struct {
    handle: u32,
    flatshade: bool,
    depth_clip: bool,
    clip_halfz: bool,
    rasterizer_discard: bool,
    flatshade_first: bool,
    light_twoside: bool,
    sprite_coord_mode: bool,
    point_quad_rasterization: bool,
    cull_face: CullMode,
    fill_front: FillMode,
    fill_back: FillMode,
    scissor: bool,
    front_ccw: bool,
    clamp_vertex_color: bool,
    clamp_fragment_color: bool,
    offset_line: bool,
    offset_point: bool,
    offset_tri: bool,
    poly_smooth: bool,
    poly_stipple_enable: bool,
    point_smooth: bool,
    point_size_per_vertex: bool,
    multisample: bool,
    line_smooth: bool,
    line_stipple_enable: bool,
    line_last_pixel: bool,
    half_pixel_center: bool,
    bottom_edge_rule: bool,
    force_persample_interp: bool,
    point_size: f32,
    line_width: f32,
    offset_units: f32,
    offset_scale: f32,
    offset_clamp: f32,

    pub fn parse(handle: u32, data: []const u32) RasterizerState {
        var state = RasterizerState{
            .handle = handle,
            .flatshade = false,
            .depth_clip = true,
            .clip_halfz = false,
            .rasterizer_discard = false,
            .flatshade_first = false,
            .light_twoside = false,
            .sprite_coord_mode = false,
            .point_quad_rasterization = false,
            .cull_face = .none,
            .fill_front = .fill,
            .fill_back = .fill,
            .scissor = false,
            .front_ccw = false,
            .clamp_vertex_color = false,
            .clamp_fragment_color = false,
            .offset_line = false,
            .offset_point = false,
            .offset_tri = false,
            .poly_smooth = false,
            .poly_stipple_enable = false,
            .point_smooth = false,
            .point_size_per_vertex = false,
            .multisample = false,
            .line_smooth = false,
            .line_stipple_enable = false,
            .line_last_pixel = false,
            .half_pixel_center = true,
            .bottom_edge_rule = false,
            .force_persample_interp = false,
            .point_size = 1.0,
            .line_width = 1.0,
            .offset_units = 0.0,
            .offset_scale = 0.0,
            .offset_clamp = 0.0,
        };

        if (data.len >= 1) {
            const s0 = data[0];
            state.flatshade = (s0 & (1 << 0)) != 0;
            state.depth_clip = (s0 & (1 << 1)) != 0;
            state.clip_halfz = (s0 & (1 << 2)) != 0;
            state.rasterizer_discard = (s0 & (1 << 3)) != 0;
            state.flatshade_first = (s0 & (1 << 4)) != 0;
            state.light_twoside = (s0 & (1 << 5)) != 0;
            state.sprite_coord_mode = (s0 & (1 << 6)) != 0;
            state.point_quad_rasterization = (s0 & (1 << 7)) != 0;
            state.cull_face = @enumFromInt(@as(u2, @truncate((s0 >> 8) & 0x3)));
            state.fill_front = @enumFromInt(@as(u2, @truncate((s0 >> 10) & 0x3)));
            state.fill_back = @enumFromInt(@as(u2, @truncate((s0 >> 12) & 0x3)));
            state.scissor = (s0 & (1 << 14)) != 0;
            state.front_ccw = (s0 & (1 << 15)) != 0;
        }

        if (data.len >= 6) {
            state.point_size = @bitCast(data[1]);
            // sprite_coord_enable skipped (data[2])
            state.line_width = @bitCast(data[3]);
            state.offset_units = @bitCast(data[4]);
            state.offset_scale = @bitCast(data[5]);
        }

        if (data.len >= 7) {
            state.offset_clamp = @bitCast(data[6]);
        }

        return state;
    }
};

/// Stencil state for one face.
pub const StencilFaceState = struct {
    enabled: bool,
    func: proto.CompareFunc,
    fail_op: proto.StencilOp,
    zpass_op: proto.StencilOp,
    zfail_op: proto.StencilOp,
    valuemask: u8,
    writemask: u8,
};

/// Depth-Stencil-Alpha state object (VIRGL_OBJECT_DSA).
pub const DepthStencilAlphaState = struct {
    handle: u32,
    depth_enabled: bool,
    depth_writemask: bool,
    depth_func: proto.CompareFunc,
    alpha_enabled: bool,
    alpha_func: proto.CompareFunc,
    alpha_ref: f32,
    stencil: [2]StencilFaceState, // [0] = front, [1] = back

    pub fn parse(handle: u32, data: []const u32) DepthStencilAlphaState {
        var state = DepthStencilAlphaState{
            .handle = handle,
            .depth_enabled = false,
            .depth_writemask = false,
            .depth_func = .always,
            .alpha_enabled = false,
            .alpha_func = .always,
            .alpha_ref = 0.0,
            .stencil = undefined,
        };

        // Initialize stencil to disabled
        for (&state.stencil) |*face| {
            face.* = .{
                .enabled = false,
                .func = .always,
                .fail_op = .keep,
                .zpass_op = .keep,
                .zfail_op = .keep,
                .valuemask = 0xff,
                .writemask = 0xff,
            };
        }

        if (data.len >= 1) {
            const s0 = data[0];
            state.depth_enabled = (s0 & (1 << 0)) != 0;
            state.depth_writemask = (s0 & (1 << 1)) != 0;
            state.depth_func = @enumFromInt(@as(u3, @truncate((s0 >> 2) & 0x7)));
            state.alpha_enabled = (s0 & (1 << 8)) != 0;
            state.alpha_func = @enumFromInt(@as(u3, @truncate((s0 >> 9) & 0x7)));
        }

        // Parse stencil states (S1, S2 for front; S3, S4 for back)
        for (0..2) |face| {
            if (data.len >= 2 + face * 2) {
                const s1 = data[1 + face * 2];
                state.stencil[face].enabled = (s1 & (1 << 0)) != 0;
                state.stencil[face].func = @enumFromInt(@as(u3, @truncate((s1 >> 1) & 0x7)));
                state.stencil[face].fail_op = @enumFromInt(@as(u3, @truncate((s1 >> 4) & 0x7)));
                state.stencil[face].zpass_op = @enumFromInt(@as(u3, @truncate((s1 >> 7) & 0x7)));
                state.stencil[face].zfail_op = @enumFromInt(@as(u3, @truncate((s1 >> 10) & 0x7)));
                state.stencil[face].valuemask = @truncate((s1 >> 16) & 0xff);
                state.stencil[face].writemask = @truncate((s1 >> 24) & 0xff);
            }
        }

        if (data.len >= 6) {
            state.alpha_ref = @bitCast(data[5]);
        }

        return state;
    }
};

/// Texture wrap mode (PIPE_TEX_WRAP_*).
pub const WrapMode = enum(u3) {
    repeat = 0,
    clamp = 1,
    clamp_to_edge = 2,
    clamp_to_border = 3,
    mirror_repeat = 4,
    mirror_clamp = 5,
    mirror_clamp_to_edge = 6,
    mirror_clamp_to_border = 7,
};

/// Texture filter mode (PIPE_TEX_FILTER_*).
pub const FilterMode = enum(u2) {
    nearest = 0,
    linear = 1,
    _,
};

/// Sampler state object (VIRGL_OBJECT_SAMPLER_STATE).
pub const SamplerState = struct {
    handle: u32,
    wrap_s: WrapMode,
    wrap_t: WrapMode,
    wrap_r: WrapMode,
    min_filter: FilterMode,
    mag_filter: FilterMode,
    mip_filter: FilterMode,
    compare_mode: bool,
    compare_func: proto.CompareFunc,
    seamless_cube_map: bool,
    lod_bias: f32,
    min_lod: f32,
    max_lod: f32,
    border_color: [4]f32,
    max_anisotropy: u8,

    pub fn parse(handle: u32, data: []const u32) SamplerState {
        var state = SamplerState{
            .handle = handle,
            .wrap_s = .repeat,
            .wrap_t = .repeat,
            .wrap_r = .repeat,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mip_filter = .nearest,
            .compare_mode = false,
            .compare_func = .never,
            .seamless_cube_map = false,
            .lod_bias = 0.0,
            .min_lod = 0.0,
            .max_lod = 1000.0,
            .border_color = .{ 0.0, 0.0, 0.0, 0.0 },
            .max_anisotropy = 1,
        };

        if (data.len >= 1) {
            const s0 = data[0];
            state.wrap_s = @enumFromInt(@as(u3, @truncate(s0 & 0x7)));
            state.wrap_t = @enumFromInt(@as(u3, @truncate((s0 >> 3) & 0x7)));
            state.wrap_r = @enumFromInt(@as(u3, @truncate((s0 >> 6) & 0x7)));
            state.min_filter = @enumFromInt(@as(u2, @truncate((s0 >> 9) & 0x3)));
            state.mag_filter = @enumFromInt(@as(u2, @truncate((s0 >> 11) & 0x3)));
            state.mip_filter = @enumFromInt(@as(u2, @truncate((s0 >> 13) & 0x3)));
            state.compare_mode = (s0 & (1 << 15)) != 0;
            state.compare_func = @enumFromInt(@as(u3, @truncate((s0 >> 16) & 0x7)));
            state.seamless_cube_map = (s0 & (1 << 19)) != 0;
            state.max_anisotropy = @truncate((s0 >> 20) & 0x1f);
        }

        if (data.len >= 5) {
            state.lod_bias = @bitCast(data[1]);
            state.min_lod = @bitCast(data[2]);
            state.max_lod = @bitCast(data[3]);
            // Border color packed in data[4..7]
        }

        if (data.len >= 8) {
            state.border_color[0] = @bitCast(data[4]);
            state.border_color[1] = @bitCast(data[5]);
            state.border_color[2] = @bitCast(data[6]);
            state.border_color[3] = @bitCast(data[7]);
        }

        return state;
    }
};

/// Single vertex element (attribute).
pub const VertexElement = struct {
    src_offset: u16,
    instance_divisor: u16,
    vertex_buffer_index: u8,
    src_format: proto.Format,
};

/// Vertex elements state object (VIRGL_OBJECT_VERTEX_ELEMENTS).
pub const VertexElementsState = struct {
    handle: u32,
    count: u8,
    elements: [16]VertexElement,

    pub fn parse(handle: u32, data: []const u32) VertexElementsState {
        var state = VertexElementsState{
            .handle = handle,
            .count = 0,
            .elements = undefined,
        };

        // Each element is 4 dwords
        const elem_count = @min(data.len / 4, 16);
        state.count = @intCast(elem_count);

        for (0..elem_count) |i| {
            const base = i * 4;
            // Per virgl_protocol.h, each element is FOUR separate dwords:
            // SRC_OFFSET, INSTANCE_DIVISOR, VERTEX_BUFFER_INDEX, SRC_FORMAT.
            // The old decode packed offset+divisor into dword 0 and shifted
            // the rest down one — so the divisor was always 0 (per-instance
            // attributes stepped per VERTEX, warping every instanced quad
            // into wedges), the divisor was read as the buffer index (which
            // only coincidentally matched for smithay's layout), and the
            // buffer index was read as the format.
            state.elements[i] = .{
                .src_offset = @truncate(data[base]),
                .instance_divisor = @truncate(data[base + 1]),
                .vertex_buffer_index = @truncate(data[base + 2]),
                .src_format = @enumFromInt(data[base + 3]),
            };
        }

        return state;
    }
};

test "BlendState parse" {
    // S0: independent=1, S1: logicop=0, S2: rt0 blend state
    const data = [_]u32{
        proto.BlendState.S0_INDEPENDENT_BLEND_ENABLE,
        0,
        0x1 | (0x01 << 4) | (0x11 << 9) | (0xf << 27), // blend on, src=ONE, dst=ZERO, mask=0xf
    };

    const state = BlendState.parse(1, &data);
    try std.testing.expect(state.independent_blend);
    try std.testing.expect(state.rt[0].blend_enable);
    try std.testing.expectEqual(proto.BlendFactor.one, state.rt[0].rgb_src_factor);
}

test "RasterizerState parse" {
    // S0: depth_clip=1, scissor=1, cull_back=2
    const data = [_]u32{
        (1 << 1) | (2 << 8) | (1 << 14), // depth_clip, cull_back, scissor
        @bitCast(@as(f32, 2.0)), // point_size
        0, // sprite_coord_enable
        @bitCast(@as(f32, 1.5)), // line_width
        0, // offset_units
        0, // offset_scale
        0, // offset_clamp
    };

    const state = RasterizerState.parse(1, &data);
    try std.testing.expect(state.depth_clip);
    try std.testing.expect(state.scissor);
    try std.testing.expectEqual(CullMode.back, state.cull_face);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), state.point_size, 0.001);
}

test "vertex elements parse the four per-element dwords per virgl_protocol.h" {
    // Two elements, exactly as smithay/niri sends them: a per-vertex vec2 in
    // buffer 0 and a per-INSTANCE vec4 in buffer 1 (divisor 1). The old
    // decode read the divisor as the buffer index (coincidentally equal
    // here) and left the real divisor 0, which warped every instanced quad.
    const words = [_]u32{
        0, 0, 0, 29, // el0: offset 0, divisor 0, buffer 0, R32G32_FLOAT
        0, 1, 1, 31, // el1: offset 0, divisor 1, buffer 1, R32G32B32A32_FLOAT
    };
    const st = VertexElementsState.parse(7, &words);
    try std.testing.expectEqual(@as(u8, 2), st.count);
    try std.testing.expectEqual(@as(u16, 0), st.elements[0].instance_divisor);
    try std.testing.expectEqual(@as(u8, 0), st.elements[0].vertex_buffer_index);
    try std.testing.expectEqual(@as(u16, 1), st.elements[1].instance_divisor);
    try std.testing.expectEqual(@as(u8, 1), st.elements[1].vertex_buffer_index);
    try std.testing.expectEqual(@as(u32, 29), @intFromEnum(st.elements[0].src_format));
    try std.testing.expectEqual(@as(u32, 31), @intFromEnum(st.elements[1].src_format));
}
