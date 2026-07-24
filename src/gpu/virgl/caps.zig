//! Virgl capability set construction (virgl_hw.h layout).
//!
//! The guest Mesa virgl driver reads this blob to decide which OpenGL
//! version and features to expose. glsl_level 430 is what makes Mesa
//! advertise OpenGL 4.3.
//!
//! virgl_caps_v1 is exactly 308 bytes (verified by the offset table
//! below summing to CAPS_V1_SIZE); virgl_caps_v2 extends it to 1384.
//! Scalar limits are populated here; per-format support masks and the
//! bool set stay conservative until the Metal translator can actually
//! honor them (advertising a format we can't render would crash a real
//! guest).

const std = @import("std");

pub const CAPS_V1_SIZE: usize = 308;
pub const CAPS_V2_SIZE: usize = 1384;

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
    put.set(buf, Off.max_texture_gather_components, 4);

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
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, buf[Off.max_render_targets..][0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[Off.max_version..][0..4], .little));
}
