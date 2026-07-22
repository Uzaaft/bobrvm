//! Virgl → Metal execution backend.
//!
//! The decoder/context layer parses the guest Gallium command stream and
//! tracks state; this module is where those commands actually hit the GPU.
//! It owns the MTLDevice/queue and the Metal-side backing for each guest
//! render-target resource, and executes the terminal operations (clear,
//! and later draw) by encoding real Metal command buffers.
//!
//! Milestone 1 (this file): resource-backed render targets + `clear`,
//! validated end-to-end against a real Metal device by reading the pixels
//! back. No guest required — the translator is driven directly by tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const metal = @import("../metal.zig");
const proto = @import("protocol.zig");

const NSUInteger = metal.NSUInteger;

pub const ResourceHandle = u32;

/// A guest render-target resource backed by an MTLTexture.
pub const Target = struct {
    tex: metal.Texture,
    width: u32,
    height: u32,
    format: metal.MTLPixelFormat,
};

pub const Error = error{
    NoMetalDevice,
    NoCommandQueue,
    TextureCreateFailed,
    CommandBufferFailed,
    EncoderFailed,
    UnknownTarget,
    ShaderCompileFailed,
    PipelineCreateFailed,
} || Allocator.Error;

/// Passthrough shader: positions come from buffer(0) as clip-space float2,
/// fragments are a solid color from buffer(0). This is the fixed-function
/// stand-in used until the TGSI→MSL compiler lands — it proves the full
/// pipeline (library → functions → PSO → draw → attachment) end to end.
const passthrough_msl: [*:0]const u8 =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct VOut { float4 pos [[position]]; };
    \\vertex VOut v_passthrough(uint vid [[vertex_id]],
    \\                          const device float2* verts [[buffer(0)]]) {
    \\    VOut o;
    \\    o.pos = float4(verts[vid], 0.0, 1.0);
    \\    return o;
    \\}
    \\fragment float4 f_solid(constant float4& color [[buffer(0)]]) {
    \\    return color;
    \\}
;

/// Map a virgl/Gallium pixel format to the closest Metal pixel format.
/// Covers the formats a render target realistically uses; unknown formats
/// fall back to BGRA8 so we still produce a usable attachment.
pub fn mapFormat(fmt: proto.Format) metal.MTLPixelFormat {
    return switch (fmt) {
        .b8g8r8a8_unorm, .b8g8r8x8_unorm => .bgra8Unorm,
        .r8g8b8a8_unorm => .rgba8Unorm,
        .r32g32b32a32_float => .rgba16Float, // narrowing; adequate for scanout
        .r8_unorm => .r8Unorm,
        else => .bgra8Unorm,
    };
}

/// Bytes per pixel for a Metal pixel format we produce here.
fn bytesPerPixel(fmt: metal.MTLPixelFormat) u32 {
    return switch (fmt) {
        .bgra8Unorm, .bgra8Unorm_sRGB, .rgba8Unorm, .rgba8Unorm_sRGB => 4,
        .rgba16Float => 8,
        .r8Unorm => 1,
        .rg8Unorm => 2,
        else => 4,
    };
}

pub const Renderer = struct {
    alloc: Allocator,
    device: metal.Device,
    queue: metal.CommandQueue,
    /// Whether we own the device (created it) vs. borrowing it from Swift.
    owns_device: bool,
    targets: std.AutoHashMap(ResourceHandle, Target),
    /// Cached passthrough pipeline per color-attachment pixel format (the
    /// PSO's color format must match the render target it draws into).
    passthrough: std.AutoHashMap(NSUInteger, metal.RenderPipelineState),
    passthrough_lib: ?metal.Library,

    /// Create a renderer with the system default Metal device. Works
    /// headlessly (no window), which is exactly what tests and the
    /// WSL-like path need.
    pub fn init(alloc: Allocator) Error!Renderer {
        const device = metal.Device.createSystemDefault() orelse return Error.NoMetalDevice;
        const queue = device.newCommandQueue() orelse return Error.NoCommandQueue;
        return .{
            .alloc = alloc,
            .device = device,
            .queue = queue,
            .owns_device = true,
            .targets = std.AutoHashMap(ResourceHandle, Target).init(alloc),
            .passthrough = std.AutoHashMap(NSUInteger, metal.RenderPipelineState).init(alloc),
            .passthrough_lib = null,
        };
    }

    /// Create a renderer borrowing an existing device/queue (e.g. the one
    /// backing the CAMetalLayer handed over by Swift), so on-screen and
    /// off-screen rendering share resources with zero copies.
    pub fn initWithDevice(alloc: Allocator, device: metal.Device, queue: metal.CommandQueue) Renderer {
        return .{
            .alloc = alloc,
            .device = device,
            .queue = queue,
            .owns_device = false,
            .targets = std.AutoHashMap(ResourceHandle, Target).init(alloc),
            .passthrough = std.AutoHashMap(NSUInteger, metal.RenderPipelineState).init(alloc),
            .passthrough_lib = null,
        };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.targets.valueIterator();
        while (it.next()) |t| t.tex.release();
        self.targets.deinit();
        var pit = self.passthrough.valueIterator();
        while (pit.next()) |p| p.release();
        self.passthrough.deinit();
        if (self.passthrough_lib) |lib| lib.release();
    }

    /// Back a guest render-target resource with an MTLTexture. Idempotent
    /// per handle: re-creating replaces (and releases) the old texture.
    pub fn createRenderTarget(
        self: *Renderer,
        handle: ResourceHandle,
        format: proto.Format,
        width: u32,
        height: u32,
    ) Error!void {
        if (width == 0 or height == 0) return Error.TextureCreateFailed;
        const mtl_fmt = mapFormat(format);
        const tex = self.device.newTexture2D(
            mtl_fmt,
            width,
            height,
            metal.MTLTextureUsage.render_target | metal.MTLTextureUsage.shader_read,
            .shared,
        ) orelse return Error.TextureCreateFailed;

        if (self.targets.fetchRemove(handle)) |old| old.value.tex.release();
        try self.targets.put(handle, .{
            .tex = tex,
            .width = width,
            .height = height,
            .format = mtl_fmt,
        });
    }

    pub fn getTarget(self: *Renderer, handle: ResourceHandle) ?Target {
        return self.targets.get(handle);
    }

    /// Execute a clear against a render-target resource: encode a render
    /// pass whose color attachment is the target's texture with
    /// loadAction=clear, then end + commit. With no draws, this is exactly
    /// a hardware clear to `color`.
    pub fn clearTarget(self: *Renderer, handle: ResourceHandle, color: [4]f32) Error!void {
        const target = self.targets.get(handle) orelse return Error.UnknownTarget;

        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const attachments = pass.colorAttachments() orelse return Error.EncoderFailed;
        const att = attachments.objectAtIndex(0) orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.clear);
        att.setStoreAction(.store);
        att.setClearColor(.{
            .red = color[0],
            .green = color[1],
            .blue = color[2],
            .alpha = color[3],
        });

        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    /// Get (compiling+caching on first use) the passthrough pipeline whose
    /// color attachment matches `format`.
    fn passthroughPipeline(self: *Renderer, format: metal.MTLPixelFormat) Error!metal.RenderPipelineState {
        const key: NSUInteger = @intFromEnum(format);
        if (self.passthrough.get(key)) |pso| return pso;

        if (self.passthrough_lib == null) {
            self.passthrough_lib = self.device.newLibraryWithSource(passthrough_msl) orelse
                return Error.ShaderCompileFailed;
        }
        const lib = self.passthrough_lib.?;
        const vfn = lib.newFunction("v_passthrough") orelse return Error.ShaderCompileFailed;
        const ffn = lib.newFunction("f_solid") orelse return Error.ShaderCompileFailed;

        const desc = metal.RenderPipelineDescriptor.create() orelse return Error.PipelineCreateFailed;
        desc.setVertexFunction(vfn);
        desc.setFragmentFunction(ffn);
        desc.setColorFormat0(format);

        const pso = self.device.newRenderPipelineState(desc) orelse return Error.PipelineCreateFailed;
        try self.passthrough.put(key, pso);
        return pso;
    }

    /// Clear a target and draw solid-colored triangles from clip-space
    /// vertices in one render pass. This is the concrete draw path the
    /// decoded virgl draw_vbo will feed into once vertex buffers are wired;
    /// for now it is driven directly (host vertex data) to validate that a
    /// real Metal pipeline renders geometry into a guest render target.
    pub fn clearAndDraw(
        self: *Renderer,
        handle: ResourceHandle,
        clear_color: [4]f32,
        verts: []const [2]f32,
        tri_color: [4]f32,
    ) Error!void {
        const target = self.targets.get(handle) orelse return Error.UnknownTarget;
        const pso = try self.passthroughPipeline(target.format);

        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const attachments = pass.colorAttachments() orelse return Error.EncoderFailed;
        const att = attachments.objectAtIndex(0) orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.clear);
        att.setStoreAction(.store);
        att.setClearColor(.{
            .red = clear_color[0],
            .green = clear_color[1],
            .blue = clear_color[2],
            .alpha = clear_color[3],
        });

        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        enc.setRenderPipelineState(pso.ptr);

        const vbytes: [*]const u8 = @ptrCast(verts.ptr);
        enc.setVertexBytes(vbytes, verts.len * @sizeOf([2]f32), 0);
        var color = tri_color;
        enc.setFragmentBytes(@ptrCast(&color), @sizeOf([4]f32), 0);
        enc.drawPrimitives(.triangle, 0, verts.len);

        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    /// Read a render target's pixels back into a host buffer (tight rows).
    /// `out` must be at least width*height*bytesPerPixel.
    pub fn readback(self: *Renderer, handle: ResourceHandle, out: []u8) Error!void {
        const target = self.targets.get(handle) orelse return Error.UnknownTarget;
        const bpp = bytesPerPixel(target.format);
        const bpr: usize = @as(usize, target.width) * bpp;
        std.debug.assert(out.len >= bpr * target.height);
        target.tex.getBytes(
            out.ptr,
            bpr,
            .{ .size = .{ .width = target.width, .height = target.height } },
            0,
        );
    }
};

// =============================================================================
// Tests
// =============================================================================

test "clear render target produces exact pixels" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch |err| {
        // On a machine without a usable Metal device (unlikely on macOS),
        // skip rather than fail the whole suite.
        if (err == Error.NoMetalDevice) return error.SkipZigTest;
        return err;
    };
    defer r.deinit();

    const w: u32 = 16;
    const h: u32 = 8;
    try r.createRenderTarget(1, .b8g8r8a8_unorm, w, h);

    // Clear to a known color. Metal bgra8Unorm stores as B,G,R,A in memory.
    // color = (r=0.25, g=0.5, b=0.75, a=1.0)
    try r.clearTarget(1, .{ 0.25, 0.5, 0.75, 1.0 });

    var buf: [16 * 8 * 4]u8 = undefined;
    try r.readback(1, &buf);

    const expect_b: u8 = @intFromFloat(@round(0.75 * 255.0));
    const expect_g: u8 = @intFromFloat(@round(0.5 * 255.0));
    const expect_r: u8 = @intFromFloat(@round(0.25 * 255.0));
    const expect_a: u8 = 255;

    // Check a few sample pixels (allow ±1 for rounding/format conversion).
    const samples = [_]usize{ 0, (w * h / 2), (w * h - 1) };
    for (samples) |px| {
        const o = px * 4;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_b)), @as(f32, @floatFromInt(buf[o + 0])), 1.5);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_g)), @as(f32, @floatFromInt(buf[o + 1])), 1.5);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_r)), @as(f32, @floatFromInt(buf[o + 2])), 1.5);
        try std.testing.expectEqual(expect_a, buf[o + 3]);
    }
}

test "draw triangle renders geometry through a Metal pipeline" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch |err| {
        if (err == Error.NoMetalDevice) return error.SkipZigTest;
        return err;
    };
    defer r.deinit();

    const w: u32 = 64;
    const h: u32 = 64;
    try r.createRenderTarget(1, .b8g8r8a8_unorm, w, h);

    // A large triangle that covers the center of the target. Clip space:
    // x,y ∈ [-1,1]; this triangle contains (0,0).
    const verts = [_][2]f32{
        .{ -0.9, -0.9 },
        .{ 0.9, -0.9 },
        .{ 0.0, 0.9 },
    };
    // Clear to opaque black; draw a red triangle (RGBA).
    try r.clearAndDraw(1, .{ 0.0, 0.0, 0.0, 1.0 }, &verts, .{ 1.0, 0.0, 0.0, 1.0 });

    var buf: [64 * 64 * 4]u8 = undefined;
    try r.readback(1, &buf);

    // Center pixel should be red (BGRA memory: B=0,G=0,R=255).
    const center = ((h / 2) * w + (w / 2)) * 4;
    try std.testing.expect(buf[center + 2] > 200); // R
    try std.testing.expect(buf[center + 1] < 40); // G
    try std.testing.expect(buf[center + 0] < 40); // B

    // Top-left corner (0,0) is outside the triangle → still black.
    try std.testing.expect(buf[2] < 40); // R at pixel 0
    try std.testing.expect(buf[1] < 40); // G
    try std.testing.expect(buf[0] < 40); // B
}
