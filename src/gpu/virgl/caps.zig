//! Virgl capability set construction (virgl_hw.h layout).
//!
//! The guest Mesa virgl driver reads this blob to decide which OpenGL
//! version and features to expose. glsl_level 430 is what makes Mesa
//! advertise OpenGL 4.3.
//!
//! virgl_caps_v1 is exactly 308 bytes (verified by the offset table
//! below summing to CAPS_V1_SIZE); virgl_caps_v2 extends it to 1408.
//! Scalar limits are populated for BOTH v1 and v2 — the v2 block is what
//! Mesa reads for vertex-attribute and texture limits, and leaving it
//! zeroed (as this file originally did) makes every guest GL client fail
//! to link a shader. Per-format support masks and the bool set stay
//! conservative until the Metal translator can actually honor them
//! (advertising a format we can't render would crash a real guest).

const std = @import("std");

pub const CAPS_V1_SIZE: usize = 308;
/// sizeof(struct virgl_caps_v2) in third_party/src/virglrenderer/src/virgl_hw.h.
/// The guest sizes its own receive buffer from the capset_max_size we
/// advertise, so this must match the struct the guest's Mesa expects.
pub const CAPS_V2_SIZE: usize = 1408;

/// GLSL 4.30 → OpenGL 4.3.
pub const GLSL_LEVEL_GL43: u32 = 430;

/// Field offsets within virgl_caps_v1 (bytes). Four 64-byte format masks
/// (16 u32 each) sit between max_version and the scalar block.
const Off = struct {
    const max_version: usize = 0;
    const sampler_mask: usize = 4; // [16]u32
    const render_mask: usize = 68; // [16]u32
    const depthstencil_mask: usize = 132; // [16]u32
    const vertexbuffer_mask: usize = 196; // [16]u32
    const bset: usize = 260;
    const glsl_level: usize = 264;
    const max_texture_array_layers: usize = 268;
    const max_streamout_buffers: usize = 272;
    const max_dual_source_render_targets: usize = 276;
    const max_render_targets: usize = 280;
    const max_samples: usize = 284;
    const prim_mask: usize = 288;
    const max_tbo_size: usize = 292;
    const max_uniform_blocks: usize = 296;
    const max_viewports: usize = 300;
    const max_texture_gather_components: usize = 304;
    // 304 + 4 == 308 == CAPS_V1_SIZE
};

comptime {
    std.debug.assert(Off.max_texture_gather_components + 4 == CAPS_V1_SIZE);
}

/// Field offsets within virgl_caps_v2 (bytes), taken straight from
/// offsetof() on the vendored virgl_hw.h. The v2 block is NOT optional
/// decoration: Mesa reads its scalar limits directly, and leaving it zeroed
/// makes every guest GL client fail to link a shader with
/// "too many vertex shader inputs (max 0)" — which is what stopped GBM/EGL
/// clients (kmscube, and every Wayland compositor) from starting.
const OffV2 = struct {
    const min_aliased_point_size: usize = 308; // f32 from here…
    const max_aliased_point_size: usize = 312;
    const min_smooth_point_size: usize = 316;
    const max_smooth_point_size: usize = 320;
    const min_aliased_line_width: usize = 324;
    const max_aliased_line_width: usize = 328;
    const min_smooth_line_width: usize = 332;
    const max_smooth_line_width: usize = 336;
    const max_texture_lod_bias: usize = 340; // …to here
    const max_geom_output_vertices: usize = 344;
    const max_geom_total_output_components: usize = 348;
    const max_vertex_outputs: usize = 352;
    const max_vertex_attribs: usize = 356;
    const max_shader_patch_varyings: usize = 360;
    const min_texel_offset: usize = 364; // i32
    const max_texel_offset: usize = 368; // i32
    const min_texture_gather_offset: usize = 372; // i32
    const max_texture_gather_offset: usize = 376; // i32
    const texture_buffer_offset_alignment: usize = 380;
    const uniform_buffer_offset_alignment: usize = 384;
    const shader_buffer_offset_alignment: usize = 388;
    const capability_bits: usize = 392;
    const max_vertex_attrib_stride: usize = 428;
    const max_texture_2d_size: usize = 484;
    const max_texture_3d_size: usize = 488;
    const max_texture_cube_size: usize = 492;
    const host_feature_check_version: usize = 556;
    const supported_readback_formats: usize = 560; // [16]u32 mask
    const scanout: usize = 624; // [16]u32 mask
    const capability_bits_v2: usize = 688;
    const renderer: usize = 696; // char[64]
    const max_anisotropy: usize = 760; // f32
    const max_texture_samplers: usize = 764;
    const max_const_buffer_size: usize = 832; // [6]u32, PIPE_SHADER_TYPES
    const max_uniform_block_size: usize = 1372;
};

/// Write the virgl_caps_v2 blob (GL 4.3 limits) into `buf`. `buf.len`
/// must be at least CAPS_V2_SIZE; the tail beyond v1 is zeroed.
pub fn writeV2(buf: []u8) void {
    std.debug.assert(buf.len >= CAPS_V2_SIZE);
    @memset(buf[0..CAPS_V2_SIZE], 0);

    const put = struct {
        fn set(b: []u8, off: usize, v: u32) void {
            std.mem.writeInt(u32, b[off..][0..4], v, .little);
        }
    };

    put.set(buf, Off.max_version, 2);
    put.set(buf, Off.glsl_level, GLSL_LEVEL_GL43);
    // Scalar limits sufficient for a GL 4.3 context.
    put.set(buf, Off.max_texture_array_layers, 256);
    put.set(buf, Off.max_streamout_buffers, 4);
    put.set(buf, Off.max_dual_source_render_targets, 1);
    put.set(buf, Off.max_render_targets, 8);
    put.set(buf, Off.max_samples, 8);
    // prim_mask: point/line/tri/adjacency/patches (bits 0..10).
    put.set(buf, Off.prim_mask, 0x7FF);
    put.set(buf, Off.max_tbo_size, 65536);
    put.set(buf, Off.max_uniform_blocks, 14);
    put.set(buf, Off.max_viewports, 16);
    // textureGather has no translator support (no TG4 opcode), so claim none.
    put.set(buf, Off.max_texture_gather_components, 0);

    // ---------------------------------------------------------------------
    // virgl_caps_v2 scalars. Everything here was previously zero, which made
    // Mesa compute a limit of 0 for vertex attributes and fail every shader
    // link ("too many vertex shader inputs (max 0)").
    // ---------------------------------------------------------------------
    const putf = struct {
        fn set(b: []u8, off: usize, v: f32) void {
            std.mem.writeInt(u32, b[off..][0..4], @bitCast(v), .little);
        }
    };
    const puti = struct {
        fn set(b: []u8, off: usize, v: i32) void {
            std.mem.writeInt(i32, b[off..][0..4], v, .little);
        }
    };

    // Points/lines: Metal rasterizes only 1px-wide lines, and the translator
    // doesn't emit [[point_size]], so both ranges are honestly 1.0.
    putf.set(buf, OffV2.min_aliased_point_size, 1.0);
    putf.set(buf, OffV2.max_aliased_point_size, 1.0);
    putf.set(buf, OffV2.min_smooth_point_size, 1.0);
    putf.set(buf, OffV2.max_smooth_point_size, 1.0);
    putf.set(buf, OffV2.min_aliased_line_width, 1.0);
    putf.set(buf, OffV2.max_aliased_line_width, 1.0);
    putf.set(buf, OffV2.min_smooth_line_width, 1.0);
    putf.set(buf, OffV2.max_smooth_line_width, 1.0);
    putf.set(buf, OffV2.max_texture_lod_bias, 0.0); // no LOD bias plumbed
    putf.set(buf, OffV2.max_anisotropy, 1.0); // sampler is plain linear

    // Geometry/tessellation stages are not translated at all.
    put.set(buf, OffV2.max_geom_output_vertices, 0);
    put.set(buf, OffV2.max_geom_total_output_components, 0);
    put.set(buf, OffV2.max_shader_patch_varyings, 0);

    // ★ The blocker: vertex inputs/outputs. 16 attributes is the GL minimum
    // and well inside Metal's 31 vertex buffers; varyings are matched by
    // semantic in the translator, so 32 components is safe.
    put.set(buf, OffV2.max_vertex_attribs, 16);
    put.set(buf, OffV2.max_vertex_outputs, 32);
    put.set(buf, OffV2.max_vertex_attrib_stride, 2048);

    // Texel offsets for textureOffset(); gather offsets stay 0 (no gather).
    puti.set(buf, OffV2.min_texel_offset, -8);
    puti.set(buf, OffV2.max_texel_offset, 7);
    puti.set(buf, OffV2.min_texture_gather_offset, 0);
    puti.set(buf, OffV2.max_texture_gather_offset, 0);

    // Buffer offset alignments (over-align rather than risk an unaligned
    // Metal bind: Apple silicon wants 16/32-byte constant offsets).
    put.set(buf, OffV2.texture_buffer_offset_alignment, 16);
    put.set(buf, OffV2.uniform_buffer_offset_alignment, 256);
    put.set(buf, OffV2.shader_buffer_offset_alignment, 256);

    // Texture dimensions Metal backs on Apple GPUs.
    put.set(buf, OffV2.max_texture_2d_size, 16384);
    put.set(buf, OffV2.max_texture_3d_size, 2048);
    put.set(buf, OffV2.max_texture_cube_size, 16384);
    put.set(buf, OffV2.max_texture_samplers, 16);

    // Uniform storage: one 64KiB block per translated stage (vertex,
    // fragment); the other PIPE_SHADER_TYPES entries stay 0.
    put.set(buf, OffV2.max_uniform_block_size, 65536);
    put.set(buf, OffV2.max_const_buffer_size + 0 * 4, 65536); // VERTEX
    put.set(buf, OffV2.max_const_buffer_size + 1 * 4, 65536); // FRAGMENT

    // Compute/SSBO/atomics/image caps are all left at 0 — none are translated.
    put.set(buf, OffV2.capability_bits, 0);
    put.set(buf, OffV2.capability_bits_v2, 0);
    put.set(buf, OffV2.host_feature_check_version, 0);

    // Renderer name (char[64]); purely informational but Mesa surfaces it.
    const name = "bobrvm (virgl/Metal)";
    @memcpy(buf[OffV2.renderer..][0..name.len], name);

    // Per-format support masks. Each mask is a bitmap indexed by PIPE_FORMAT
    // (our proto.Format mirrors those values): bit f → mask[f/32] |= 1<<(f%32).
    // The guest virgl driver consults render/sampler here when creating a
    // context; all-zero masks mean "no renderable format" → eglCreateContext
    // fails with EGL_BAD_MATCH. Advertise only what the Metal translator can
    // actually back.
    const setFmt = struct {
        fn f(b: []u8, mask_off: usize, fmt: u32) void {
            const word = mask_off + (fmt / 32) * 4;
            const cur = std.mem.readInt(u32, b[word..][0..4], .little);
            std.mem.writeInt(u32, b[word..][0..4], cur | (@as(u32, 1) << @intCast(fmt % 32)), .little);
        }
    };
    // Color formats usable as both render targets and sampler views.
    const color = [_]u32{ 1, 2, 3, 4, 67 }; // BGRA8, BGRX8, ARGB8, XRGB8, RGBA8
    for (color) |c| {
        setFmt.f(buf, Off.render_mask, c);
        setFmt.f(buf, Off.sampler_mask, c);
    }
    // Single/two-channel sampler formats.
    const extra_sampler = [_]u32{ 9, 10, 12, 32 }; // L8, A8, L8A8, R32_FLOAT-ish
    for (extra_sampler) |c| setFmt.f(buf, Off.sampler_mask, c);
    // Depth/stencil formats.
    const depth = [_]u32{ 16, 18, 19, 20, 21 }; // Z16, Z32F, Z24S8, S8Z24, Z24X8
    for (depth) |d| setFmt.f(buf, Off.depthstencil_mask, d);
    // Vertex attribute formats (float N + common unorm color attrib).
    const vtx = [_]u32{ 28, 29, 30, 31, 67 }; // R32F, RG32F, RGB32F, RGBA32F, RGBA8
    for (vtx) |v| setFmt.f(buf, Off.vertexbuffer_mask, v);

    // v2 format masks. `scanout` is what the guest consults before allocating
    // a buffer with PIPE_BIND_SCANOUT — an empty mask leaves GBM with no
    // scanout-capable format, which is how a compositor ends up reporting
    // "no allocator available for device". Readback mirrors the color set
    // (transfer_from_host_3d reads these back through the same path).
    for (color) |c| {
        setFmt.f(buf, OffV2.scanout, c);
        setFmt.f(buf, OffV2.supported_readback_formats, c);
    }

    // bset (boolean feature set, struct virgl_caps_bool_set1, LSB-first
    // bitfields). Advertise ONLY features the Metal translator actually
    // backs — advertising an unbacked one makes the guest emit commands we
    // cannot honor. Enabled so far:
    //   bit 6  primitive_restart  (Metal restarts strips on canonical index)
    //   bit 8  instanceid         (gl_InstanceID via [[instance_id]])
    //   bit 18 ubo                (named uniform buffers)
    const BSET_PRIMITIVE_RESTART: u32 = 1 << 6;
    const BSET_INSTANCEID: u32 = 1 << 8;
    const BSET_UBO: u32 = 1 << 18;
    put.set(buf, Off.bset, BSET_PRIMITIVE_RESTART | BSET_INSTANCEID | BSET_UBO);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "caps v2 declares GL 4.3 at the right offset" {
    var buf: [CAPS_V2_SIZE]u8 = undefined;
    writeV2(&buf);

    const glsl = std.mem.readInt(u32, buf[Off.glsl_level..][0..4], .little);
    try testing.expectEqual(GLSL_LEVEL_GL43, glsl);

    // The v2 scalars Mesa needs to link ANY shader. Zero here is what made
    // every guest GBM/EGL client die with "too many vertex shader inputs".
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, buf[OffV2.max_vertex_attribs..][0..4], .little));
    try testing.expectEqual(@as(u32, 32), std.mem.readInt(u32, buf[OffV2.max_vertex_outputs..][0..4], .little));
    try testing.expectEqual(@as(u32, 16384), std.mem.readInt(u32, buf[OffV2.max_texture_2d_size..][0..4], .little));
    try testing.expectEqual(@as(u32, 65536), std.mem.readInt(u32, buf[OffV2.max_uniform_block_size..][0..4], .little));

    // A scanout-capable format must be advertised or GBM finds no allocator:
    // BGRA8 is format 1 → bit 1 of the first mask word.
    const scanout0 = std.mem.readInt(u32, buf[OffV2.scanout..][0..4], .little);
    try testing.expect(scanout0 & (1 << 1) != 0);
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, buf[Off.max_render_targets..][0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[Off.max_version..][0..4], .little));
}
