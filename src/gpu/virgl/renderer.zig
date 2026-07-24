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
const tgsi = @import("tgsi.zig");
const iosurface = @import("../iosurface.zig");

const NSUInteger = metal.NSUInteger;

pub const ResourceHandle = u32;

/// A guest render-target resource backed by an MTLTexture.
pub const Target = struct {
    tex: metal.Texture,
    width: u32,
    height: u32,
    format: metal.MTLPixelFormat,
    /// IOSurface the texture is rendered into, when this target is presentable
    /// (BGRA8). Lets the display renderer wrap its own texture over the same
    /// pixels and blit them straight to screen — no readback, no re-upload.
    surface: ?iosurface.IOSurface = null,
};

/// Optional per-draw state for the pipeline draw paths.
pub const DrawOpts = struct {
    vs_consts: []const u8 = &.{},
    fs_consts: []const u8 = &.{},
    frag_tex: ?ResourceHandle = null,
    /// Depth resource to attach (loadAction=load) with this draw.
    depth: ?ResourceHandle = null,
    /// Depth test/write state; null = no depth testing.
    dss: ?metal.DepthStencilState = null,
};

/// Resolved Metal blend state for a pipeline's color attachment (raw
/// MTLBlendFactor/MTLBlendOperation/write-mask integers).
pub const BlendDesc = struct {
    enabled: bool,
    rgb_op: metal.NSUInteger,
    alpha_op: metal.NSUInteger,
    src_rgb: metal.NSUInteger,
    dst_rgb: metal.NSUInteger,
    src_alpha: metal.NSUInteger,
    dst_alpha: metal.NSUInteger,
    write_mask: metal.NSUInteger,
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
    /// Lazily-created linear-filtering sampler shared by all sampled draws
    /// (per-guest sampler-state translation lands with GL3).
    default_sampler: ?metal.SamplerState = null,
    /// Guest depth-stencil resources backed by depth32Float textures.
    depth_targets: std.AutoHashMap(ResourceHandle, Target),
    /// Cached MTLDepthStencilStates keyed by (compare func, write mask).
    dss_cache: std.AutoHashMap(u32, metal.DepthStencilState),
    /// Guest buffer resources (vertex/index/constant) backed by MTLBuffers
    /// in shared storage, so guest uploads are a plain memcpy (no copy on
    /// the GPU side — the buffer is read in place by the vertex stage).
    buffers: std.AutoHashMap(ResourceHandle, metal.Buffer),

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
            .buffers = std.AutoHashMap(ResourceHandle, metal.Buffer).init(alloc),
            .depth_targets = std.AutoHashMap(ResourceHandle, Target).init(alloc),
            .dss_cache = std.AutoHashMap(u32, metal.DepthStencilState).init(alloc),
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
            .buffers = std.AutoHashMap(ResourceHandle, metal.Buffer).init(alloc),
            .depth_targets = std.AutoHashMap(ResourceHandle, Target).init(alloc),
            .dss_cache = std.AutoHashMap(u32, metal.DepthStencilState).init(alloc),
        };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.targets.valueIterator();
        while (it.next()) |t| {
            t.tex.release();
            if (t.surface) |s| s.release();
        }
        self.targets.deinit();
        var pit = self.passthrough.valueIterator();
        while (pit.next()) |p| p.release();
        self.passthrough.deinit();
        if (self.passthrough_lib) |lib| lib.release();
        var bit = self.buffers.valueIterator();
        while (bit.next()) |b| b.release();
        self.buffers.deinit();
        var dit = self.depth_targets.valueIterator();
        while (dit.next()) |t| t.tex.release();
        self.depth_targets.deinit();
        var sit = self.dss_cache.valueIterator();
        while (sit.next()) |s| s.release();
        self.dss_cache.deinit();
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
        const usage = metal.MTLTextureUsage.render_target | metal.MTLTextureUsage.shader_read;

        // For a presentable (BGRA8) target, render into an IOSurface so the
        // display renderer can wrap it and present without a readback round-trip.
        // Any failure falls back to a plain texture (readback present path).
        var surface: ?iosurface.IOSurface = null;
        var tex: ?metal.Texture = null;
        if (mtl_fmt == .bgra8Unorm) {
            if (iosurface.IOSurface.createBGRA(width, height)) |surf| {
                if (self.device.newTextureFromIOSurface(mtl_fmt, width, height, surf.ref, usage)) |t| {
                    surface = surf;
                    tex = t;
                } else {
                    surf.release();
                }
            }
        }
        const final_tex = tex orelse (self.device.newTexture2D(mtl_fmt, width, height, usage, .shared) orelse
            return Error.TextureCreateFailed);

        if (self.targets.fetchRemove(handle)) |old| {
            old.value.tex.release();
            if (old.value.surface) |s| s.release();
        }
        try self.targets.put(handle, .{
            .tex = final_tex,
            .width = width,
            .height = height,
            .format = mtl_fmt,
            .surface = surface,
        });
    }

    /// The IOSurfaceRef a target renders into, if it is presentable (BGRA8) and
    /// IOSurface-backed. The display renderer uses it for zero-copy present.
    pub fn targetSurfaceRef(self: *Renderer, handle: ResourceHandle) ?*anyopaque {
        const target = self.targets.get(handle) orelse return null;
        return if (target.surface) |s| s.ref else null;
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

    // =========================================================================
    // Buffer resources (vertex / index / constant)
    // =========================================================================

    /// Back a guest buffer resource with an MTLBuffer of `size` bytes.
    /// Idempotent per handle (re-create releases the old buffer).
    /// Back a guest depth-stencil resource with a depth32Float texture.
    pub fn createDepthTarget(self: *Renderer, handle: ResourceHandle, width: u32, height: u32) Error!void {
        if (width == 0 or height == 0) return Error.TextureCreateFailed;
        const tex = self.device.newTexture2D(.depth32Float, width, height, metal.MTLTextureUsage.render_target, .private) orelse
            return Error.TextureCreateFailed;
        if (self.depth_targets.fetchRemove(handle)) |old| old.value.tex.release();
        try self.depth_targets.put(handle, .{ .tex = tex, .width = width, .height = height, .format = .depth32Float });
    }

    /// Clear a depth target to `depth` (depth-only render pass).
    pub fn clearDepthTarget(self: *Renderer, handle: ResourceHandle, depth: f64) Error!void {
        const target = self.depth_targets.get(handle) orelse return Error.UnknownTarget;
        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const att = pass.depthAttachment() orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.clear);
        att.setStoreAction(.store);
        att.setClearDepth(depth);
        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    /// Cached depth-stencil state for (compare func, write enable).
    pub fn ensureDss(self: *Renderer, func: metal.MTLCompareFunction, write: bool) ?metal.DepthStencilState {
        const key: u32 = (@as(u32, @intCast(@intFromEnum(func))) << 1) | @intFromBool(write);
        if (self.dss_cache.get(key)) |s| return s;
        const desc = metal.DepthStencilDescriptor.create() orelse return null;
        defer desc.release();
        desc.setDepthCompareFunction(func);
        desc.setDepthWriteEnabled(write);
        const dss = self.device.newDepthStencilState(desc) orelse return null;
        self.dss_cache.put(key, dss) catch {
            dss.release();
            return null;
        };
        return self.dss_cache.get(key);
    }

    /// Create a texture a fragment shader can sample (guest texture
    /// resources with the sampler_view bind). Shared storage so uploads
    /// are plain replaceRegion copies.
    pub fn createSamplerTexture(
        self: *Renderer,
        handle: ResourceHandle,
        format: proto.Format,
        width: u32,
        height: u32,
    ) Error!void {
        const px = mapFormat(format);
        const tex = self.device.newTexture2D(px, width, height, metal.MTLTextureUsage.shader_read, .shared) orelse
            return Error.TextureCreateFailed;
        if (self.targets.fetchRemove(handle)) |old| old.value.tex.release();
        try self.targets.put(handle, .{ .tex = tex, .width = width, .height = height, .format = px });
    }

    /// Upload pixel data into a sampler texture (bytes are the full
    /// mip-0 rect at the given stride).
    pub fn uploadTexture(self: *Renderer, handle: ResourceHandle, data: []const u8, bytes_per_row: u32) bool {
        const target = self.targets.get(handle) orelse return false;
        return self.uploadTextureRegion(handle, 0, 0, target.width, target.height, data, bytes_per_row);
    }

    /// Upload a sub-rect of a sampler texture (guest transfer_to_host_3d).
    pub fn uploadTextureRegion(
        self: *Renderer,
        handle: ResourceHandle,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        data: []const u8,
        bytes_per_row: u32,
    ) bool {
        const target = self.targets.get(handle) orelse return false;
        if (w == 0 or h == 0) return false;
        if (x + w > target.width or y + h > target.height) return false;
        if (data.len < @as(usize, bytes_per_row) * h) return false;
        target.tex.replaceRegion(
            .{
                .origin = .{ .x = x, .y = y },
                .size = .{ .width = w, .height = h },
            },
            0,
            data.ptr,
            bytes_per_row,
        );
        return true;
    }

    fn ensureSampler(self: *Renderer) ?metal.SamplerState {
        if (self.default_sampler) |s| return s;
        const desc = metal.SamplerDescriptor.create() orelse return null;
        self.default_sampler = self.device.newSamplerState(desc);
        return self.default_sampler;
    }

    pub fn createBuffer(self: *Renderer, handle: ResourceHandle, size: u32) Error!void {
        if (size == 0) return Error.TextureCreateFailed;
        const buf = self.device.newBufferWithLength(size) orelse return Error.TextureCreateFailed;
        if (self.buffers.fetchRemove(handle)) |old| old.value.release();
        try self.buffers.put(handle, buf);
    }

    pub fn getBuffer(self: *Renderer, handle: ResourceHandle) ?metal.Buffer {
        return self.buffers.get(handle);
    }

    /// Upload guest data into a buffer resource at `offset`. This is the
    /// transfer_to_host_3d data movement for buffers: shared storage means
    /// it is a direct memcpy into GPU-visible memory (no staging copy).
    pub fn uploadBuffer(self: *Renderer, handle: ResourceHandle, offset: u32, data: []const u8) Error!void {
        const buf = self.buffers.get(handle) orelse return Error.UnknownTarget;
        const cap = buf.length();
        if (@as(usize, offset) + data.len > cap) return Error.TextureCreateFailed;
        const dst = buf.contents() orelse return Error.TextureCreateFailed;
        @memcpy(dst[offset .. offset + data.len], data);
    }

    /// Clear a target and draw solid-colored triangles whose clip-space
    /// float2 vertices come from a buffer resource (bound at vertex
    /// buffer index 0, starting at `vbuf_offset`). This is the form the
    /// decoded draw_vbo feeds: geometry lives in a guest-uploaded MTLBuffer.
    pub fn clearAndDrawBuffer(
        self: *Renderer,
        handle: ResourceHandle,
        clear_color: [4]f32,
        vbuf_handle: ResourceHandle,
        vbuf_offset: u32,
        vertex_count: u32,
        tri_color: [4]f32,
    ) Error!void {
        const target = self.targets.get(handle) orelse return Error.UnknownTarget;
        const vbuf = self.buffers.get(vbuf_handle) orelse return Error.UnknownTarget;
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
        enc.setVertexBuffer(vbuf, vbuf_offset, 0);
        var color = tri_color;
        enc.setFragmentBytes(@ptrCast(&color), @sizeOf([4]f32), 0);
        enc.drawPrimitives(.triangle, 0, vertex_count);
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    /// One vertex attribute pulled from a bound vertex buffer (built from
    /// the guest's vertex_elements).
    pub const VertexAttr = struct {
        format: metal.MTLVertexFormat,
        offset: u32,
        buffer_index: u32 = 0,
    };

    /// Build a real render pipeline from TGSI-translated MSL sources and a
    /// vertex layout. The returned PSO is owned by the caller (release()).
    /// This is what replaces the passthrough pipeline once guest shaders are
    /// available.
    pub fn buildPipeline(
        self: *Renderer,
        vs_msl: [:0]const u8,
        vs_entry: [*:0]const u8,
        fs_msl: [:0]const u8,
        fs_entry: [*:0]const u8,
        attrs: []const VertexAttr,
        stride: u32,
        format: metal.MTLPixelFormat,
        has_depth: bool,
        blend: ?BlendDesc,
    ) Error!metal.RenderPipelineState {
        const vlib = self.device.newLibraryWithSource(vs_msl) orelse return Error.ShaderCompileFailed;
        defer vlib.release();
        const flib = self.device.newLibraryWithSource(fs_msl) orelse return Error.ShaderCompileFailed;
        defer flib.release();
        const vfn = vlib.newFunction(vs_entry) orelse return Error.ShaderCompileFailed;
        defer vfn.release();
        const ffn = flib.newFunction(fs_entry) orelse return Error.ShaderCompileFailed;
        defer ffn.release();

        const desc = metal.RenderPipelineDescriptor.create() orelse return Error.PipelineCreateFailed;
        defer desc.release();
        desc.setVertexFunction(vfn);
        desc.setFragmentFunction(ffn);
        desc.setColorFormat0(format);
        if (has_depth) desc.setDepthFormat(.depth32Float);
        if (blend) |b| desc.setColorBlend(
            b.enabled,
            b.rgb_op,
            b.alpha_op,
            b.src_rgb,
            b.dst_rgb,
            b.src_alpha,
            b.dst_alpha,
            b.write_mask,
        );

        if (attrs.len > 0) {
            const vd = metal.VertexDescriptor.create() orelse return Error.PipelineCreateFailed;
            for (attrs, 0..) |a, i| vd.setAttribute(i, a.format, a.offset, a.buffer_index);
            vd.setLayoutStride(0, stride);
            desc.setVertexDescriptor(vd);
        }

        return self.device.newRenderPipelineState(desc) orelse return Error.PipelineCreateFailed;
    }

    /// Clear a target then draw from a vertex buffer using a caller-supplied
    /// pipeline (e.g. one built from translated guest shaders).
    pub fn clearDrawPipeline(
        self: *Renderer,
        target_handle: ResourceHandle,
        clear_color: [4]f32,
        pso: metal.RenderPipelineState,
        vbuf_handle: ResourceHandle,
        vbuf_offset: u32,
        vertex_count: u32,
        prim: metal.MTLPrimitiveType,
    ) Error!void {
        const target = self.targets.get(target_handle) orelse return Error.UnknownTarget;
        const vbuf = self.buffers.get(vbuf_handle) orelse return Error.UnknownTarget;

        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const attachments = pass.colorAttachments() orelse return Error.EncoderFailed;
        const att = attachments.objectAtIndex(0) orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.clear);
        att.setStoreAction(.store);
        att.setClearColor(.{ .red = clear_color[0], .green = clear_color[1], .blue = clear_color[2], .alpha = clear_color[3] });

        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        enc.setRenderPipelineState(pso.ptr);
        enc.setVertexBuffer(vbuf, vbuf_offset, 0);
        enc.drawPrimitives(prim, 0, vertex_count);
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    /// Map a Gallium vertex attribute format to Metal's vertex format.
    pub fn mapVertexFormat(fmt: proto.Format) metal.MTLVertexFormat {
        return switch (fmt) {
            .r32_float => .float,
            .r32g32_float => .float2,
            .r32g32b32_float => .float3,
            .r32g32b32a32_float => .float4,
            else => .float4,
        };
    }

    /// Draw a vertex buffer with a caller-supplied pipeline into a target
    /// WITHOUT clearing it (loadAction=load), so it composes after a prior
    /// clear/draw. This is the real-shader draw_vbo path. `vs_consts`/
    /// `fs_consts` are the stages' inline constant blocks, bound at
    /// buffer(1) to match the TGSI translator's `constant float4* c
    /// [[buffer(1)]]` (empty = stage uses no constants).
    pub fn drawWithPipeline(
        self: *Renderer,
        target_handle: ResourceHandle,
        pso: metal.RenderPipelineState,
        vbuf_handle: ResourceHandle,
        vbuf_offset: u32,
        vertex_count: u32,
        prim: metal.MTLPrimitiveType,
        opts: DrawOpts,
    ) Error!void {
        const vbuf = self.buffers.get(vbuf_handle) orelse return Error.UnknownTarget;
        const pass = try self.beginLoadPassOpts(target_handle, opts.depth);
        pass.enc.setRenderPipelineState(pso.ptr);
        pass.enc.setVertexBuffer(vbuf, vbuf_offset, 0);
        self.applyOpts(pass.enc, opts);
        pass.enc.drawPrimitives(prim, 0, vertex_count);
        pass.enc.endEncoding();
        pass.cmd.commit();
        pass.cmd.waitUntilCompleted();
    }

    /// Indexed variant of drawWithPipeline: indices come from a
    /// guest-uploaded MTLBuffer (set_index_buffer).
    pub fn drawIndexedWithPipeline(
        self: *Renderer,
        target_handle: ResourceHandle,
        pso: metal.RenderPipelineState,
        vbuf_handle: ResourceHandle,
        vbuf_offset: u32,
        ibuf_handle: ResourceHandle,
        ibuf_offset: u32,
        index_size: u8,
        index_count: u32,
        prim: metal.MTLPrimitiveType,
        opts: DrawOpts,
    ) Error!void {
        // Metal has no 8-bit indices; those need index-widening (deferred).
        const index_type: metal.MTLIndexType = switch (index_size) {
            2 => .uint16,
            4 => .uint32,
            else => return Error.UnknownTarget,
        };
        const vbuf = self.buffers.get(vbuf_handle) orelse return Error.UnknownTarget;
        const ibuf = self.buffers.get(ibuf_handle) orelse return Error.UnknownTarget;
        const pass = try self.beginLoadPassOpts(target_handle, opts.depth);
        pass.enc.setRenderPipelineState(pso.ptr);
        pass.enc.setVertexBuffer(vbuf, vbuf_offset, 0);
        self.applyOpts(pass.enc, opts);
        pass.enc.drawIndexedPrimitives(prim, index_count, index_type, ibuf, ibuf_offset);
        pass.enc.endEncoding();
        pass.cmd.commit();
        pass.cmd.waitUntilCompleted();
    }

    const LoadPass = struct {
        cmd: metal.CommandBuffer,
        enc: metal.RenderCommandEncoder,
    };

    /// beginLoadPass with an optional depth attachment (loadAction=load
    /// so depth composes across draws; cleared via clearDepthTarget).
    fn beginLoadPassOpts(self: *Renderer, target_handle: ResourceHandle, depth: ?ResourceHandle) Error!LoadPass {
        const target = self.targets.get(target_handle) orelse return Error.UnknownTarget;
        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const attachments = pass.colorAttachments() orelse return Error.EncoderFailed;
        const att = attachments.objectAtIndex(0) orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.load);
        att.setStoreAction(.store);
        if (depth) |dh| {
            if (self.depth_targets.get(dh)) |dt| {
                const datt = pass.depthAttachment() orelse return Error.EncoderFailed;
                datt.setTexture(dt.tex.ptr);
                datt.setLoadAction(.load);
                datt.setStoreAction(.store);
            }
        }
        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        return .{ .cmd = cmd, .enc = enc };
    }

    /// Bind DrawOpts state on an open encoder.
    fn applyOpts(self: *Renderer, enc: metal.RenderCommandEncoder, opts: DrawOpts) void {
        bindConsts(enc, opts.vs_consts, opts.fs_consts);
        self.bindFragTexture(enc, opts.frag_tex);
        if (opts.dss) |dss| enc.setDepthStencilState(dss);
    }

    /// Open a loadAction=load render pass onto a target (composes with
    /// prior clears/draws).
    fn beginLoadPass(self: *Renderer, target_handle: ResourceHandle) Error!LoadPass {
        const target = self.targets.get(target_handle) orelse return Error.UnknownTarget;
        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const attachments = pass.colorAttachments() orelse return Error.EncoderFailed;
        const att = attachments.objectAtIndex(0) orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.load);
        att.setStoreAction(.store);
        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        return .{ .cmd = cmd, .enc = enc };
    }

    /// Bind inline constant blocks at buffer(1) (both stages; Metal's
    /// setBytes path handles blocks up to 4 KB — plenty for GL2-era
    /// default uniform blocks).
    fn bindConsts(enc: metal.RenderCommandEncoder, vs: []const u8, fs: []const u8) void {
        if (vs.len > 0) enc.setVertexBytes(vs.ptr, vs.len, 1);
        if (fs.len > 0) enc.setFragmentBytes(fs.ptr, fs.len, 1);
    }

    /// Bind the fragment stage's sampled texture + default sampler at
    /// index 0 (single texture unit so far).
    fn bindFragTexture(self: *Renderer, enc: metal.RenderCommandEncoder, frag_tex: ?ResourceHandle) void {
        const handle = frag_tex orelse return;
        const target = self.targets.get(handle) orelse return;
        enc.setFragmentTexture(target.tex.ptr, 0);
        enc.setFragmentSamplerState(self.ensureSampler(), 0);
    }

    /// Map a Gallium primitive type to Metal's. Metal has no loop/fan/quad
    /// primitives; those fall back to the closest supported topology (a
    /// proper impl expands them index-side — deferred).
    pub fn mapPrimitive(mode: proto.PrimitiveType) metal.MTLPrimitiveType {
        return switch (mode) {
            .points => .point,
            .lines, .line_loop => .line,
            .line_strip => .lineStrip,
            .triangles, .quads, .polygon => .triangle,
            .triangle_strip, .quad_strip => .triangleStrip,
            else => .triangle,
        };
    }

    /// Draw into an already-established render target WITHOUT clearing it
    /// (loadAction=load), so it composes after a prior clear/draw. This is
    /// the routing target for a decoded draw_vbo: geometry from a bound
    /// vertex buffer is rasterized into the bound framebuffer color target.
    pub fn drawTargetFromBuffer(
        self: *Renderer,
        target_handle: ResourceHandle,
        vbuf_handle: ResourceHandle,
        vbuf_offset: u32,
        vertex_count: u32,
        prim: metal.MTLPrimitiveType,
        color: [4]f32,
    ) Error!void {
        const target = self.targets.get(target_handle) orelse return Error.UnknownTarget;
        const vbuf = self.buffers.get(vbuf_handle) orelse return Error.UnknownTarget;
        const pso = try self.passthroughPipeline(target.format);

        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const attachments = pass.colorAttachments() orelse return Error.EncoderFailed;
        const att = attachments.objectAtIndex(0) orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.load); // preserve prior contents
        att.setStoreAction(.store);

        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        enc.setRenderPipelineState(pso.ptr);
        enc.setVertexBuffer(vbuf, vbuf_offset, 0);
        var c = color;
        enc.setFragmentBytes(@ptrCast(&c), @sizeOf([4]f32), 0);
        enc.drawPrimitives(prim, 0, vertex_count);
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

test "BGRA render target is IOSurface-backed and presents without readback" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch |err| {
        if (err == Error.NoMetalDevice) return error.SkipZigTest;
        return err;
    };
    defer r.deinit();

    const w: u32 = 16;
    const h: u32 = 8;
    try r.createRenderTarget(1, .b8g8r8a8_unorm, w, h);

    // A presentable BGRA target must expose an IOSurface for zero-copy present.
    const ref = r.targetSurfaceRef(1) orelse return error.SkipZigTest;

    // Clear on the GPU (clearTarget commits + waits), then read the pixels
    // straight from the IOSurface's shared memory — no getBytes readback. This
    // is exactly what the display renderer relies on for 3D direct-present.
    try r.clearTarget(1, .{ 0.25, 0.5, 0.75, 1.0 });

    const base = iosurface.baseAddressOf(ref) orelse return error.SkipZigTest;
    const px = base[0 .. @as(usize, w) * h * 4];

    const expect_b: u8 = @intFromFloat(@round(0.75 * 255.0));
    const expect_g: u8 = @intFromFloat(@round(0.5 * 255.0));
    const expect_r: u8 = @intFromFloat(@round(0.25 * 255.0));
    const samples = [_]usize{ 0, (w * h / 2), (w * h - 1) };
    for (samples) |p| {
        const o = p * 4;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_b)), @as(f32, @floatFromInt(px[o + 0])), 1.5);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_g)), @as(f32, @floatFromInt(px[o + 1])), 1.5);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_r)), @as(f32, @floatFromInt(px[o + 2])), 1.5);
        try std.testing.expectEqual(@as(u8, 255), px[o + 3]);
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

test "draw triangle from an uploaded vertex buffer" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch |err| {
        if (err == Error.NoMetalDevice) return error.SkipZigTest;
        return err;
    };
    defer r.deinit();

    const w: u32 = 64;
    const h: u32 = 64;
    try r.createRenderTarget(1, .b8g8r8a8_unorm, w, h);

    // Guest uploads triangle vertices into a buffer resource (handle 2),
    // exactly the transfer_to_host_3d → draw_vbo data path.
    const verts = [_][2]f32{
        .{ -0.9, -0.9 },
        .{ 0.9, -0.9 },
        .{ 0.0, 0.9 },
    };
    try r.createBuffer(2, @sizeOf(@TypeOf(verts)));
    const bytes: [*]const u8 = @ptrCast(&verts);
    try r.uploadBuffer(2, 0, bytes[0..@sizeOf(@TypeOf(verts))]);

    // Green triangle this time (RGBA (0,1,0,1)).
    try r.clearAndDrawBuffer(1, .{ 0.0, 0.0, 0.0, 1.0 }, 2, 0, 3, .{ 0.0, 1.0, 0.0, 1.0 });

    var buf: [64 * 64 * 4]u8 = undefined;
    try r.readback(1, &buf);

    const center = ((h / 2) * w + (w / 2)) * 4;
    try std.testing.expect(buf[center + 1] > 200); // G
    try std.testing.expect(buf[center + 2] < 40); // R
    try std.testing.expect(buf[center + 0] < 40); // B

    // Corner still black.
    try std.testing.expect(buf[1] < 40);
}

test "TGSI ALU opcodes (XPD/NRM/DST/LIT/CEIL) compile on Metal" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch return error.SkipZigTest;
    defer r.deinit();

    const vs_text =
        \\VERT
        \\DCL IN[0]
        \\DCL OUT[0], POSITION
        \\DCL TEMP[0]
        \\DCL TEMP[1]
        \\  0: XPD TEMP[0], IN[0], IN[0]
        \\  1: NRM TEMP[1], TEMP[0]
        \\  2: DST TEMP[0], TEMP[1], IN[0]
        \\  3: LIT TEMP[1], TEMP[0]
        \\  4: CEIL TEMP[0], TEMP[1]
        \\  5: MOV OUT[0], TEMP[0]
        \\  6: END
    ;
    const prog = try tgsi.parse(vs_text);
    var msl = try tgsi.emit(alloc, &prog);
    defer msl.deinit(alloc);
    const z = try alloc.dupeZ(u8, msl.source);
    defer alloc.free(z);
    const lib = r.device.newLibraryWithSource(z) orelse {
        std.debug.print("MSL failed to compile:\n{s}\n", .{msl.source});
        return error.TestUnexpectedResult;
    };
    lib.release();
}

test "TGSI control flow and extended opcodes compile on Metal" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch return error.SkipZigTest;
    defer r.deinit();

    const fs_text =
        \\FRAG
        \\DCL IN[0], GENERIC[0]
        \\DCL OUT[0], COLOR
        \\DCL CONST[0]
        \\DCL TEMP[0]
        \\DCL TEMP[1]
        \\IMM[0] FLT32 { 1.0000, 0.0000, 0.0000, 1.0000}
        \\IMM[1] FLT32 { 0.0000, 1.0000, 0.0000, 1.0000}
        \\  0: IF CONST[0].xxxx :4
        \\  1:   MOV TEMP[0], IMM[1]
        \\  2: ELSE :5
        \\  3:   MOV TEMP[0], IMM[0]
        \\  4: ENDIF
        \\  5: CMP TEMP[1], IN[0], TEMP[0], IMM[0]
        \\  6: LRP TEMP[1], CONST[0], TEMP[1], TEMP[0]
        \\  7: POW TEMP[1].x, TEMP[1].xxxx, IMM[0].xxxx
        \\  8: SLT TEMP[1].y, IN[0], TEMP[0]
        \\  9: MOV_SAT OUT[0], TEMP[1]
        \\ 10: KILL_IF -IN[0].wwww
        \\ 11: END
    ;
    const prog = try tgsi.parse(fs_text);
    var msl = try tgsi.emit(alloc, &prog);
    defer msl.deinit(alloc);

    const z = try alloc.dupeZ(u8, msl.source);
    defer alloc.free(z);
    const lib = r.device.newLibraryWithSource(z) orelse {
        std.debug.print("MSL failed to compile:\n{s}\n", .{msl.source});
        return error.TestUnexpectedResult;
    };
    lib.release();
}

test "TGSI→MSL output compiles on a real Metal device" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch |err| {
        if (err == Error.NoMetalDevice) return error.SkipZigTest;
        return err;
    };
    defer r.deinit();

    // Passthrough VS and FS in TGSI text, as mesa's virgl driver would dump.
    const vs_src =
        \\VERT
        \\DCL IN[0]
        \\DCL IN[1]
        \\DCL OUT[0], POSITION
        \\DCL OUT[1], GENERIC[0]
        \\  0: MOV OUT[0], IN[0]
        \\  1: MOV OUT[1], IN[1]
        \\  2: END
    ;
    const fs_src =
        \\FRAG
        \\DCL IN[0], GENERIC[0]
        \\DCL OUT[0], COLOR
        \\  0: MOV OUT[0], IN[0]
        \\  1: END
    ;

    const vprog = try tgsi.parse(vs_src);
    var vmsl = try tgsi.emit(alloc, &vprog);
    defer vmsl.deinit(alloc);
    const fprog = try tgsi.parse(fs_src);
    var fmsl = try tgsi.emit(alloc, &fprog);
    defer fmsl.deinit(alloc);

    // Both translated shaders must compile as MSL on the GPU.
    const vsrcz = try alloc.dupeZ(u8, vmsl.source);
    defer alloc.free(vsrcz);
    const fsrcz = try alloc.dupeZ(u8, fmsl.source);
    defer alloc.free(fsrcz);

    const vlib = r.device.newLibraryWithSource(vsrcz) orelse return error.TestUnexpectedResult;
    defer vlib.release();
    const flib = r.device.newLibraryWithSource(fsrcz) orelse return error.TestUnexpectedResult;
    defer flib.release();

    const vfn = vlib.newFunction("vs_main") orelse return error.TestUnexpectedResult;
    defer vfn.release();
    const ffn = flib.newFunction("fs_main") orelse return error.TestUnexpectedResult;
    defer ffn.release();

    // An arithmetic VS (MAD/DP4/swizzle/IMM/TEMP) must also compile.
    const arith_vs =
        \\VERT
        \\DCL IN[0]
        \\DCL OUT[0], POSITION
        \\DCL TEMP[0]
        \\IMM[0] FLT32 { 0.5000, 0.5000, 0.0000, 1.0000}
        \\  0: MAD TEMP[0], IN[0], IMM[0].xxxx, IMM[0]
        \\  1: MOV OUT[0], TEMP[0]
        \\  2: END
    ;
    const aprog = try tgsi.parse(arith_vs);
    var amsl = try tgsi.emit(alloc, &aprog);
    defer amsl.deinit(alloc);
    const asrcz = try alloc.dupeZ(u8, amsl.source);
    defer alloc.free(asrcz);
    const alib = r.device.newLibraryWithSource(asrcz) orelse return error.TestUnexpectedResult;
    defer alib.release();
    const afn = alib.newFunction("vs_main") orelse return error.TestUnexpectedResult;
    defer afn.release();
}

test "translated shaders build a real pipeline and draw a triangle" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch |err| {
        if (err == Error.NoMetalDevice) return error.SkipZigTest;
        return err;
    };
    defer r.deinit();

    // VS: position passthrough (attribute 0). FS: solid white via IMM.
    const vs_src =
        \\VERT
        \\DCL IN[0]
        \\DCL OUT[0], POSITION
        \\  0: MOV OUT[0], IN[0]
        \\  1: END
    ;
    const fs_src =
        \\FRAG
        \\DCL OUT[0], COLOR
        \\IMM[0] FLT32 { 1.0000, 1.0000, 1.0000, 1.0000}
        \\  0: MOV OUT[0], IMM[0]
        \\  1: END
    ;
    const vprog = try tgsi.parse(vs_src);
    var vmsl = try tgsi.emit(alloc, &vprog);
    defer vmsl.deinit(alloc);
    const fprog = try tgsi.parse(fs_src);
    var fmsl = try tgsi.emit(alloc, &fprog);
    defer fmsl.deinit(alloc);

    const vz = try alloc.dupeZ(u8, vmsl.source);
    defer alloc.free(vz);
    const fz = try alloc.dupeZ(u8, fmsl.source);
    defer alloc.free(fz);

    // Vertex layout: attribute 0 = float2 at offset 0, stride 8. Metal
    // expands the float2 to (x,y,0,1) for the float4 shader input.
    const attrs = [_]Renderer.VertexAttr{.{ .format = .float2, .offset = 0, .buffer_index = 0 }};
    const pso = try r.buildPipeline(vz, "vs_main", fz, "fs_main", &attrs, 8, .bgra8Unorm, false, null);
    defer pso.release();

    const w: u32 = 64;
    const h: u32 = 64;
    try r.createRenderTarget(1, .b8g8r8a8_unorm, w, h);
    const verts = [_][2]f32{ .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ 0.0, 0.9 } };
    try r.createBuffer(2, @sizeOf(@TypeOf(verts)));
    const vb: [*]const u8 = @ptrCast(&verts);
    try r.uploadBuffer(2, 0, vb[0..@sizeOf(@TypeOf(verts))]);

    try r.clearDrawPipeline(1, .{ 0.0, 0.0, 0.0, 1.0 }, pso, 2, 0, 3, .triangle);

    var buf: [64 * 64 * 4]u8 = undefined;
    try r.readback(1, &buf);
    const center = ((h / 2) * w + (w / 2)) * 4;
    try std.testing.expect(buf[center + 0] > 200 and buf[center + 1] > 200 and buf[center + 2] > 200);
    try std.testing.expect(buf[0] < 40 and buf[1] < 40 and buf[2] < 40);
}
