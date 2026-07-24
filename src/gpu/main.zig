//! GPU translation layer.
//!
//! Translates guest GPU commands to Metal:
//! - virgl: OpenGL 4.3 → Metal (via Gallium3D command stream)
//! - venus: Vulkan 1.3 → Metal (via MoltenVK or custom) [future]
//!
//! Architecture:
//! 1. Guest Mesa driver sends virgl/venus commands via virtio-gpu
//! 2. This module parses the command stream
//! 3. Commands are translated to Metal API calls
//! 4. Rendered frames are presented via IOSurface to Swift

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

pub const virgl = @import("virgl/main.zig");
pub const metal = @import("metal.zig");
// pub const venus = @import("venus/main.zig"); // Future

// Re-export virgl types for convenience
pub const Command = virgl.Command;
pub const Decoder = virgl.Decoder;
pub const Context = virgl.Context;

/// GPU context ID.
pub const ContextId = u32;

/// Resource handle.
pub const ResourceHandle = u32;

/// Virtio-GPU command types.
pub const VirtioGpuCmd = enum(u32) {
    // 2D commands
    get_display_info = 0x0100,
    resource_create_2d = 0x0101,
    resource_unref = 0x0102,
    set_scanout = 0x0103,
    resource_flush = 0x0104,
    transfer_to_host_2d = 0x0105,
    resource_attach_backing = 0x0106,
    resource_detach_backing = 0x0107,
    get_capset_info = 0x0108,
    get_capset = 0x0109,
    get_edid = 0x010a,

    // 3D commands (virgl/venus)
    ctx_create = 0x0200,
    ctx_destroy = 0x0201,
    ctx_attach_resource = 0x0202,
    ctx_detach_resource = 0x0203,
    resource_create_3d = 0x0204,
    transfer_to_host_3d = 0x0205,
    transfer_from_host_3d = 0x0206,
    submit_3d = 0x0207,
    resource_map_blob = 0x0208,
    resource_unmap_blob = 0x0209,

    // Cursor commands
    update_cursor = 0x0300,
    move_cursor = 0x0301,

    _,
};

/// Capset types.
pub const CapsetType = enum(u32) {
    virgl = 1,
    virgl2 = 2,
    venus = 4,
    drm = 5,
    _,
};

/// GPU resource (texture, buffer, etc.).
pub const Resource = struct {
    handle: ResourceHandle,
    target: virgl.context.ResourceTarget,
    format: virgl.protocol.Format,
    width: u32,
    height: u32,
    depth: u32,
    array_size: u32,
    last_level: u32,
    nr_samples: u32,
    flags: u32,
    bind: u32,
    // TODO: IOSurface/MTLTexture backing
};

/// GPU device managing contexts and resources.
/// Gallium PIPE_BIND_* flags relevant to resource classification (subset).
pub const PipeBind = struct {
    pub const depth_stencil: u32 = 1 << 0;
    pub const render_target: u32 = 1 << 1;
    pub const sampler_view: u32 = 1 << 3;
    pub const vertex_buffer: u32 = 1 << 4;
    pub const index_buffer: u32 = 1 << 5;
    pub const constant_buffer: u32 = 1 << 6;
};

/// Identifies a translated-shader pipeline for caching.
pub const PipelineKey = struct {
    vs: u32,
    fs: u32,
    ve: u32,
    fmt: u32,
    has_depth: bool,
    blend: u32, // bound blend-state handle (0 = none)
};

pub const GpuDevice = struct {
    alloc: Allocator,
    contexts: std.AutoHashMap(ContextId, *Context),
    resources: std.AutoHashMap(ResourceHandle, Resource),
    next_ctx_id: ContextId,
    next_resource_id: ResourceHandle,
    /// Metal execution backend. Created lazily on the first 3D resource so
    /// GpuDevice construction never depends on a Metal device being present
    /// (headless CI without a GPU falls back to decode-only, as before).
    renderer: ?virgl.Renderer = null,
    /// Set once we've tried (and possibly failed) to create the renderer,
    /// so we don't retry device creation on every resource.
    renderer_tried: bool = false,
    /// Cache of pipelines built from translated guest shaders, keyed by the
    /// bound shader/vertex-layout/target-format combination.
    pipelines: std.AutoHashMap(PipelineKey, metal.RenderPipelineState) = undefined,

    pub const Error = Allocator.Error || virgl.decoder.DecodeError;

    pub fn init(alloc: Allocator) GpuDevice {
        return .{
            .alloc = alloc,
            .contexts = std.AutoHashMap(ContextId, *Context).init(alloc),
            .resources = std.AutoHashMap(ResourceHandle, Resource).init(alloc),
            .next_ctx_id = 1,
            .next_resource_id = 1,
            .renderer = null,
            .renderer_tried = false,
            .pipelines = std.AutoHashMap(PipelineKey, metal.RenderPipelineState).init(alloc),
        };
    }

    pub fn deinit(self: *GpuDevice) void {
        var ctx_iter = self.contexts.valueIterator();
        while (ctx_iter.next()) |ctx| {
            ctx.*.deinit();
        }
        self.contexts.deinit();
        self.resources.deinit();
        var pit = self.pipelines.valueIterator();
        while (pit.next()) |p| p.release();
        self.pipelines.deinit();
        if (self.renderer) |*r| r.deinit();
    }

    /// Lazily create the Metal renderer. Returns null if no Metal device is
    /// available; callers then behave as decode-only (no execution).
    fn ensureRenderer(self: *GpuDevice) ?*virgl.Renderer {
        if (self.renderer) |*r| return r;
        if (self.renderer_tried) return null;
        self.renderer_tried = true;
        self.renderer = virgl.Renderer.init(self.alloc) catch return null;
        return if (self.renderer) |*r| r else null;
    }

    /// Process a virtio-gpu control command.
    pub fn processCommand(self: *GpuDevice, cmd: VirtioGpuCmd, data: []const u8) Error!void {
        switch (cmd) {
            .ctx_create => try self.createContext(),
            .ctx_destroy => try self.destroyContext(data),
            .resource_create_3d => try self.createResource3D(data),
            .resource_unref => try self.destroyResource(data),
            .submit_3d => try self.submit3D(data),
            else => {}, // TODO: Handle other commands
        }
    }

    fn createContext(self: *GpuDevice) Error!void {
        const id = self.next_ctx_id;
        self.next_ctx_id += 1;
        try self.createContextId(id);
    }

    /// Create a context with a guest-chosen id (virtio-gpu ctx_id).
    pub fn createContextId(self: *GpuDevice, id: ContextId) Error!void {
        if (self.contexts.contains(id)) return;
        const ctx = try Context.init(self.alloc, id);
        errdefer ctx.deinit();
        try self.contexts.put(id, ctx);
    }

    /// Destroy a context by guest id.
    pub fn destroyContextId(self: *GpuDevice, id: ContextId) void {
        if (self.contexts.fetchRemove(id)) |entry| {
            entry.value.deinit();
        }
    }

    /// Record a 3D resource created by the guest, and back it on the GPU.
    /// This is the path the virtio-gpu device actually uses.
    pub fn createResourceRecord(self: *GpuDevice, res: Resource) Error!void {
        try self.resources.put(res.handle, res);
        self.backResource(res);
    }

    /// Give a recorded resource its GPU backing: buffers → MTLBuffer (sized
    /// by width, which holds the byte size for buffer resources), render
    /// targets → MTLTexture. No-op when there is no Metal device.
    fn backResource(self: *GpuDevice, res: Resource) void {
        const r = self.ensureRenderer() orelse return;
        if (res.target == .buffer) {
            r.createBuffer(res.handle, res.width) catch {};
        } else if (res.bind & PipeBind.render_target != 0) {
            r.createRenderTarget(res.handle, res.format, res.width, if (res.height == 0) 1 else res.height) catch {};
        } else if (res.bind & PipeBind.depth_stencil != 0) {
            r.createDepthTarget(res.handle, res.width, if (res.height == 0) 1 else res.height) catch {};
        } else if (res.bind & PipeBind.sampler_view != 0) {
            r.createSamplerTexture(res.handle, res.format, res.width, if (res.height == 0) 1 else res.height) catch {};
        }
    }

    /// Upload pixel data into a texture resource (sampler textures).
    pub fn uploadToTexture(self: *GpuDevice, handle: ResourceHandle, data: []const u8, bytes_per_row: u32) bool {
        const r = self.ensureRenderer() orelse return false;
        return r.uploadTexture(handle, data, bytes_per_row);
    }

    /// Upload a sub-rect into a texture resource (transfer_to_host_3d).
    pub fn uploadToTextureRegion(
        self: *GpuDevice,
        handle: ResourceHandle,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        data: []const u8,
        bytes_per_row: u32,
    ) bool {
        const r = self.ensureRenderer() orelse return false;
        return r.uploadTextureRegion(handle, x, y, w, h, data, bytes_per_row);
    }

    /// Upload guest data into a buffer resource's MTLBuffer at `offset`.
    /// Returns false if there is no GPU-backed buffer for the handle.
    pub fn uploadToBuffer(self: *GpuDevice, handle: ResourceHandle, offset: u32, data: []const u8) bool {
        const r = if (self.renderer) |*rr| rr else return false;
        r.uploadBuffer(handle, offset, data) catch return false;
        return true;
    }

    /// The CPU-visible contents of a buffer resource's MTLBuffer, for
    /// zero-copy fills (e.g. transfer_to_host_3d copying guest backing pages
    /// straight into GPU-visible memory). Null if not buffer-backed.
    pub fn bufferContents(self: *GpuDevice, handle: ResourceHandle) ?[]u8 {
        const r = if (self.renderer) |*rr| rr else return null;
        const buf = r.getBuffer(handle) orelse return null;
        const ptr = buf.contents() orelse return null;
        return ptr[0..buf.length()];
    }

    /// Execute a virgl command buffer for a context.
    pub fn submit(self: *GpuDevice, ctx_id: ContextId, cmd_data: []const u8) Error!void {
        const ctx = self.contexts.get(ctx_id) orelse return;
        try self.processCommandBuffer(ctx, cmd_data);
    }

    fn destroyContext(self: *GpuDevice, data: []const u8) Error!void {
        if (data.len < 4) return;
        const ctx_id = std.mem.readInt(u32, data[0..4], .little);

        if (self.contexts.fetchRemove(ctx_id)) |entry| {
            entry.value.deinit();
        }
    }

    fn createResource3D(self: *GpuDevice, data: []const u8) Error!void {
        if (data.len < 44) return;

        const handle = std.mem.readInt(u32, data[0..4], .little);
        const target = @as(virgl.context.ResourceTarget, @enumFromInt(data[4]));
        const format = @as(virgl.protocol.Format, @enumFromInt(std.mem.readInt(u32, data[8..12], .little)));
        const bind = std.mem.readInt(u32, data[12..16], .little);
        const width = std.mem.readInt(u32, data[16..20], .little);
        const height = std.mem.readInt(u32, data[20..24], .little);
        const depth = std.mem.readInt(u32, data[24..28], .little);
        const array_size = std.mem.readInt(u32, data[28..32], .little);
        const last_level = std.mem.readInt(u32, data[32..36], .little);
        const nr_samples = std.mem.readInt(u32, data[36..40], .little);
        const flags = std.mem.readInt(u32, data[40..44], .little);

        try self.resources.put(handle, .{
            .handle = handle,
            .target = target,
            .format = format,
            .width = width,
            .height = height,
            .depth = depth,
            .array_size = array_size,
            .last_level = last_level,
            .nr_samples = nr_samples,
            .flags = flags,
            .bind = bind,
        });

        // Back the resource on the GPU (buffer → MTLBuffer, RT → MTLTexture).
        self.backResource(self.resources.get(handle).?);
    }

    /// Read a rendered resource's pixels back to host memory (for scanout
    /// or verification). Returns false if there is no GPU-backed texture.
    pub fn readbackResource(self: *GpuDevice, handle: ResourceHandle, out: []u8) bool {
        const r = if (self.renderer) |*rr| rr else return false;
        r.readback(handle, out) catch return false;
        return true;
    }

    /// The IOSurfaceRef the given rendered resource presents from, if it is a
    /// presentable target backed by an IOSurface. Non-null means the scanout
    /// can be shown with no readback (the display renderer wraps this surface).
    pub fn scanoutSurfaceRef(self: *GpuDevice, handle: ResourceHandle) ?*anyopaque {
        const r = if (self.renderer) |*rr| rr else return null;
        return r.targetSurfaceRef(handle);
    }

    fn destroyResource(self: *GpuDevice, data: []const u8) Error!void {
        if (data.len < 4) return;
        const handle = std.mem.readInt(u32, data[0..4], .little);
        _ = self.resources.remove(handle);
    }

    fn submit3D(self: *GpuDevice, data: []const u8) Error!void {
        if (data.len < 8) return;

        const ctx_id = std.mem.readInt(u32, data[0..4], .little);
        // const size = std.mem.readInt(u32, data[4..8], .little);
        const cmd_data = data[8..];

        const ctx = self.contexts.get(ctx_id) orelse return;
        try self.processCommandBuffer(ctx, cmd_data);
    }

    /// Process a virgl command buffer.
    fn processCommandBuffer(self: *GpuDevice, ctx: *Context, data: []const u8) Error!void {
        var dec = Decoder.init(data);

        while (dec.hasMore()) {
            const header = try dec.nextHeader();

            switch (header.opcode) {
                .nop => {},

                .create_object => {
                    const handle = try dec.decodeObjectHandle();
                    const payload = try dec.payload(header.length - 1);

                    switch (header.object_type) {
                        .blend => try ctx.createBlendState(handle, payload),
                        .rasterizer => try ctx.createRasterizerState(handle, payload),
                        .dsa => try ctx.createDsaState(handle, payload),
                        .sampler_state => try ctx.createSamplerState(handle, payload),
                        .vertex_elements => try ctx.createVertexElements(handle, payload),
                        .shader => {
                            // SHADER payload: [type, offset, num_tokens,
                            // so_num_outputs, <packed TGSI text words...>].
                            // Single-part shaders without stream-out only.
                            if (payload.len > 4 and payload[3] == 0) {
                                try ctx.createShader(handle, payload[4..]);
                            }
                        },
                        .surface => {
                            // Surface create payload: [res_handle, format, ...].
                            if (payload.len >= 2) {
                                const res_handle = payload[0];
                                const fmt: virgl.protocol.Format = @enumFromInt(payload[1]);
                                try ctx.createSurface(handle, res_handle, fmt);
                            }
                        },
                        .sampler_view => {
                            // [res_handle, format, first/last elem, swizzle].
                            if (payload.len >= 2) {
                                const res_handle = payload[0];
                                const fmt: virgl.protocol.Format = @enumFromInt(payload[1]);
                                try ctx.createSamplerView(handle, res_handle, fmt);
                            }
                        },
                        else => dec.skip(header.length - 1),
                    }
                },

                .bind_object => {
                    const handle = try dec.readU32();
                    switch (header.object_type) {
                        .blend => ctx.bindBlendState(handle),
                        .rasterizer => ctx.bindRasterizerState(handle),
                        .dsa => ctx.bindDsaState(handle),
                        .vertex_elements => ctx.bindVertexElements(handle),
                        else => {},
                    }
                },

                .bind_shader => {
                    // Payload: [handle, type]. Route by the shader's captured
                    // stage rather than trusting the wire type encoding.
                    const shandle = try dec.readU32();
                    if (header.length >= 2) _ = try dec.readU32();
                    if (ctx.shaders.get(shandle)) |sh| {
                        ctx.bindShader(sh.shader_type, shandle);
                    }
                },

                .destroy_object => {
                    const handle = try dec.readU32();
                    ctx.destroyObject(header.object_type, handle);
                },

                .set_viewport_state => {
                    const viewport = try dec.decodeViewport(header.length);
                    ctx.setViewport(0, .{
                        .scale = viewport.scale,
                        .translate = viewport.translate,
                    });
                },

                .set_framebuffer_state => {
                    const fb = try dec.decodeFramebuffer(header.length);
                    ctx.setFramebuffer(fb);
                },

                .clear => {
                    const clear_cmd = try dec.decodeClear(header.length);
                    ctx.clear(clear_cmd);
                    // Execute the clear against the bound framebuffer's first
                    // color target: framebuffer cbuf[0] → surface → resource →
                    // MTLTexture. Only color clears are handled for now.
                    if (self.ensureRenderer()) |r| {
                        if (self.resolveColorTarget(ctx, 0)) |res_handle| {
                            r.clearTarget(res_handle, clear_cmd.color) catch {};
                        }
                        if (clear_cmd.flags.depth) {
                            if (self.resolveDepthTarget(ctx)) |dh| {
                                r.clearDepthTarget(dh, clear_cmd.depth) catch {};
                            }
                        }
                    }
                },

                .set_sampler_views => {
                    // [shader_type, start_slot, view handles...].
                    if (header.length >= 2) {
                        const shader_type = try dec.readU32();
                        const start_slot = try dec.readU32();
                        const n: u16 = header.length - 2;
                        var k: u16 = 0;
                        while (k < n) : (k += 1) {
                            const vh = try dec.readU32();
                            const slot = start_slot + k;
                            if (shader_type < 6 and slot < 16) {
                                ctx.sampler_views_bound[shader_type][slot] =
                                    if (vh == 0) null else vh;
                            }
                        }
                    } else dec.skip(header.length);
                },

                .set_constant_buffer => {
                    // [shader_type, index, data words...] — a stage's inline
                    // default uniform block.
                    if (header.length >= 2) {
                        const shader_type = try dec.readU32();
                        const index = try dec.readU32();
                        const nwords: u16 = header.length - 2;
                        if (index == 0 and shader_type < 6) {
                            var cbuf: [4096]u8 = undefined;
                            const n = @min(@as(usize, nwords) * 4, cbuf.len);
                            var w: usize = 0;
                            while (w * 4 < n) : (w += 1) {
                                std.mem.writeInt(u32, cbuf[w * 4 ..][0..4], try dec.readU32(), .little);
                            }
                            // Words beyond our 4KB inline cap are dropped.
                            if (@as(usize, nwords) * 4 > n) {
                                dec.skip(@intCast(nwords - n / 4));
                            }
                            ctx.setConstants(shader_type, cbuf[0..n]) catch {};
                        } else {
                            dec.skip(nwords);
                        }
                    } else dec.skip(header.length);
                },

                .set_index_buffer => {
                    // [handle] or [handle, index_size, offset].
                    const ihandle = try dec.readU32();
                    var idx_size: u32 = 4;
                    var idx_offset: u32 = 0;
                    if (header.length >= 3) {
                        idx_size = try dec.readU32();
                        idx_offset = try dec.readU32();
                        if (header.length > 3) dec.skip(header.length - 3);
                    }
                    ctx.setIndexBuffer(ihandle, @intCast(@min(idx_size, 4)), idx_offset);
                },

                .set_vertex_buffers => {
                    // N triples of [stride, offset, handle].
                    const n: u16 = header.length / 3;
                    var idx: u8 = 0;
                    while (idx < n) : (idx += 1) {
                        const stride = try dec.readU32();
                        const offset = try dec.readU32();
                        const vhandle = try dec.readU32();
                        ctx.setVertexBuffer(idx, vhandle, stride, offset);
                    }
                    const consumed: u16 = n * 3;
                    if (header.length > consumed) dec.skip(header.length - consumed);
                },

                .draw_vbo => {
                    const draw_cmd = try dec.decodeDrawVbo(header.length);
                    ctx.draw(draw_cmd);
                    // Route the draw: rasterize the bound vertex buffer into the
                    // bound framebuffer color target. Shading is the passthrough
                    // stand-in (solid white) until TGSI→MSL lands.
                    if (self.ensureRenderer()) |r| {
                        if (self.resolveColorTarget(ctx, 0)) |target| {
                            const vbo_handle = ctx.vbo_handles[0];
                            if (vbo_handle != 0 and draw_cmd.count > 0) {
                                const prim = virgl.Renderer.mapPrimitive(draw_cmd.mode);
                                // Per-draw state first: the pipeline needs
                                // to know whether a depth attachment exists.
                                var opts = virgl.renderer.DrawOpts{
                                    .vs_consts = ctx.constants(0),
                                    .fs_consts = ctx.constants(1),
                                };
                                // Fragment texture: bound sampler view 0
                                // (stage 1 = fragment) -> resource.
                                if (ctx.sampler_views_bound[1][0]) |view_h| {
                                    if (ctx.sampler_views.get(view_h)) |view| {
                                        opts.frag_tex = view.resource_handle;
                                    }
                                }
                                // Depth: bound zsurf + bound DSA state.
                                opts.depth = self.resolveDepthTarget(ctx);
                                if (opts.depth != null) {
                                    if (ctx.bound.dsa) |dsa_h| {
                                        if (ctx.dsa_states.get(dsa_h)) |dsa| {
                                            if (dsa.depth_enabled) {
                                                opts.dss = r.ensureDss(
                                                    mapCompareFunc(dsa.depth_func),
                                                    dsa.depth_writemask,
                                                );
                                            }
                                        }
                                    }
                                    // No depth test wanted: drop the
                                    // attachment (PSO has no depth fmt).
                                    if (opts.dss == null) opts.depth = null;
                                }
                                if (self.getOrBuildPipeline(ctx, r, target, opts.depth != null)) |pso| {
                                    if (draw_cmd.indexed and ctx.index_buffer != 0) {
                                        r.drawIndexedWithPipeline(
                                            target,
                                            pso,
                                            vbo_handle,
                                            ctx.vbo_offsets[0],
                                            ctx.index_buffer,
                                            ctx.index_offset + draw_cmd.start * ctx.index_size,
                                            ctx.index_size,
                                            draw_cmd.count,
                                            prim,
                                            opts,
                                        ) catch {};
                                    } else {
                                        r.drawWithPipeline(target, pso, vbo_handle, ctx.vbo_offsets[0], draw_cmd.count, prim, opts) catch {};
                                    }
                                } else {
                                    // Passthrough fallback (no bound shaders yet).
                                    r.drawTargetFromBuffer(
                                        target,
                                        vbo_handle,
                                        ctx.vbo_offsets[0],
                                        draw_cmd.count,
                                        prim,
                                        .{ 1.0, 1.0, 1.0, 1.0 },
                                    ) catch {};
                                }
                            }
                        }
                    }
                },

                else => dec.skip(header.length),
            }
        }
    }

    /// Resolve color attachment `index` of the context's bound framebuffer
    /// to the underlying resource handle: framebuffer cbuf → surface object →
    /// surface.resource_handle. Returns null if unbound.
    fn resolveColorTarget(self: *GpuDevice, ctx: *Context, index: usize) ?ResourceHandle {
        _ = self;
        if (index >= ctx.framebuffer.cbufs.len) return null;
        const surf_handle = ctx.framebuffer.cbufs[index] orelse return null;
        const surface = ctx.surfaces.get(surf_handle) orelse return null;
        return surface.resource_handle;
    }

    /// Resolve the bound framebuffer's depth surface to its resource, if
    /// the resource has a Metal depth texture.
    fn resolveDepthTarget(self: *GpuDevice, ctx: *Context) ?ResourceHandle {
        const zsurf = ctx.framebuffer.zsurf orelse return null;
        const surface = ctx.surfaces.get(zsurf) orelse return null;
        const r = if (self.renderer) |*rr| rr else return null;
        if (!r.depth_targets.contains(surface.resource_handle)) return null;
        return surface.resource_handle;
    }

    /// Gallium PIPE_FUNC_* -> Metal compare function.
    fn mapCompareFunc(f: virgl.protocol.CompareFunc) metal.MTLCompareFunction {
        return switch (f) {
            .never => .never,
            .less => .less,
            .equal => .equal,
            .lequal => .lessEqual,
            .greater => .greater,
            .notequal => .notEqual,
            .gequal => .greaterEqual,
            .always => .always,
        };
    }

    /// Gallium PIPE_BLENDFACTOR_* -> MTLBlendFactor integer.
    fn mapBlendFactor(f: virgl.protocol.BlendFactor) metal.NSUInteger {
        return switch (f) {
            .zero => 0,
            .one => 1,
            .src_color => 2,
            .inv_src_color => 3,
            .src_alpha => 4,
            .inv_src_alpha => 5,
            .dst_alpha => 6,
            .inv_dst_alpha => 7,
            .dst_color => 8,
            .inv_dst_color => 9,
            .src_alpha_saturate => 10,
            .const_color => 11,
            .inv_const_color => 12,
            .const_alpha => 13,
            .inv_const_alpha => 14,
            .src1_color => 15,
            .inv_src1_color => 16,
            .src1_alpha => 17,
            .inv_src1_alpha => 18,
            else => 1, // unknown -> one
        };
    }

    /// Gallium PIPE_BLEND_* -> MTLBlendOperation integer.
    fn mapBlendOp(f: virgl.protocol.BlendFunc) metal.NSUInteger {
        return switch (f) {
            .add => 0,
            .subtract => 1,
            .reverse_subtract => 2,
            .min => 3,
            .max => 4,
            else => 0,
        };
    }

    /// Resolve the context's bound blend state (RT0) to a BlendDesc.
    fn resolveBlend(ctx: *Context) ?virgl.renderer.BlendDesc {
        const bh = ctx.bound.blend orelse return null;
        const bs = ctx.blend_states.get(bh) orelse return null;
        const rt = bs.rt[0];
        return .{
            .enabled = rt.blend_enable,
            .rgb_op = mapBlendOp(rt.rgb_func),
            .alpha_op = mapBlendOp(rt.alpha_func),
            .src_rgb = mapBlendFactor(rt.rgb_src_factor),
            .dst_rgb = mapBlendFactor(rt.rgb_dst_factor),
            .src_alpha = mapBlendFactor(rt.alpha_src_factor),
            .dst_alpha = mapBlendFactor(rt.alpha_dst_factor),
            .write_mask = rt.color_mask,
        };
    }

    /// Build (or fetch from cache) a real Metal pipeline from the context's
    /// currently bound vertex/fragment shaders and vertex_elements, targeting
    /// `target_handle`'s format. Returns null if anything needed is missing or
    /// translation fails, in which case the caller uses the passthrough.
    fn getOrBuildPipeline(
        self: *GpuDevice,
        ctx: *Context,
        r: *virgl.Renderer,
        target_handle: ResourceHandle,
        has_depth: bool,
    ) ?metal.RenderPipelineState {
        const vs_h = ctx.bound.vs orelse return null;
        const fs_h = ctx.bound.fs orelse return null;
        const ve_h = ctx.bound.vertex_elements orelse return null;
        const target = r.getTarget(target_handle) orelse return null;

        const key = PipelineKey{
            .vs = vs_h,
            .fs = fs_h,
            .ve = ve_h,
            .fmt = @intCast(@intFromEnum(target.format)),
            .has_depth = has_depth,
            .blend = ctx.bound.blend orelse 0,
        };
        if (self.pipelines.get(key)) |pso| return pso;

        const vs = ctx.shaders.get(vs_h) orelse return null;
        const fs = ctx.shaders.get(fs_h) orelse return null;
        const vs_text = vs.tgsi_text orelse return null;
        const fs_text = fs.tgsi_text orelse return null;
        const ve = ctx.vertex_elements.get(ve_h) orelse return null;

        const pso = self.buildTranslatedPipeline(r, vs_text, fs_text, ve, ctx, target.format, has_depth) catch return null;
        self.pipelines.put(key, pso) catch {
            pso.release();
            return null;
        };
        return pso;
    }

    fn buildTranslatedPipeline(
        self: *GpuDevice,
        r: *virgl.Renderer,
        vs_text: []const u8,
        fs_text: []const u8,
        ve: virgl.state.VertexElementsState,
        ctx: *Context,
        format: metal.MTLPixelFormat,
        has_depth: bool,
    ) !metal.RenderPipelineState {
        const tgsi = virgl.tgsi;
        const vprog = try tgsi.parse(vs_text);
        var vmsl = try tgsi.emit(self.alloc, &vprog);
        defer vmsl.deinit(self.alloc);
        const fprog = try tgsi.parse(fs_text);
        var fmsl = try tgsi.emit(self.alloc, &fprog);
        defer fmsl.deinit(self.alloc);

        const vz = try self.alloc.dupeZ(u8, vmsl.source);
        defer self.alloc.free(vz);
        const fz = try self.alloc.dupeZ(u8, fmsl.source);
        defer self.alloc.free(fz);

        // Vertex layout from vertex_elements (single vertex buffer, index 0).
        var attrs: [16]virgl.Renderer.VertexAttr = undefined;
        const n = @min(ve.count, 16);
        for (0..n) |i| {
            attrs[i] = .{
                .format = virgl.Renderer.mapVertexFormat(ve.elements[i].src_format),
                .offset = ve.elements[i].src_offset,
                .buffer_index = 0,
            };
        }
        const stride = ctx.vbo_strides[0];
        return r.buildPipeline(vz, "vs_main", fz, "fs_main", attrs[0..n], stride, format, has_depth, resolveBlend(ctx));
    }

    /// Get a context by ID.
    pub fn getContext(self: *GpuDevice, id: ContextId) ?*Context {
        return self.contexts.get(id);
    }

    /// Get a resource by handle.
    pub fn getResource(self: *GpuDevice, handle: ResourceHandle) ?*Resource {
        return self.resources.getPtr(handle);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GpuDevice init and context creation" {
    var gpu = GpuDevice.init(std.testing.allocator);
    defer gpu.deinit();

    try gpu.processCommand(.ctx_create, &.{});
    try std.testing.expectEqual(@as(usize, 1), gpu.contexts.count());
}

test "createResourceRecord backs a buffer on the GPU and round-trips upload" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    // The real virtio path: cmdResourceCreate3D → createResourceRecord.
    try gpu.createResourceRecord(.{
        .handle = 5,
        .target = .buffer,
        .format = .none,
        .width = 256, // buffers encode byte size in width
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.vertex_buffer,
    });

    if (gpu.renderer == null) return error.SkipZigTest;

    // Upload guest bytes and read them straight back out of GPU memory.
    const data = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expect(gpu.uploadToBuffer(5, 16, &data));

    const contents = gpu.bufferContents(5) orelse return error.TestUnexpectedResult;
    try std.testing.expect(contents.len >= 256);
    try std.testing.expectEqualSlices(u8, &data, contents[16 .. 16 + data.len]);
}

test "GpuDevice renders with translated guest shaders end to end" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt: u32 = 10;
    const buf: u32 = 30;

    try gpu.createResourceRecord(.{
        .handle = rt,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 64,
        .height = 64,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.render_target,
    });
    try gpu.createResourceRecord(.{
        .handle = buf,
        .target = .buffer,
        .format = .none,
        .width = 24,
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.vertex_buffer,
    });
    if (gpu.renderer == null) return error.SkipZigTest;

    const verts = [_][2]f32{ .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ 0.0, 0.9 } };
    const vb: [*]const u8 = @ptrCast(&verts);
    try std.testing.expect(gpu.uploadToBuffer(buf, 0, vb[0..@sizeOf(@TypeOf(verts))]));
    try gpu.createContextId(1);

    const vs_text = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n0: MOV OUT[0], IN[0]\n1: END\n";
    // Fragment shader outputs solid RED — distinguishes real shading from the
    // passthrough (which is white).
    const fs_text = "FRAG\nDCL OUT[0], COLOR\nIMM[0] FLT32 { 1.0000, 0.0000, 0.0000, 1.0000}\n0: MOV OUT[0], IMM[0]\n1: END\n";

    var storage: [512]u32 = undefined;
    const B = struct {
        buf: []u32,
        i: usize = 0,
        fn w(self: *@This(), v: u32) void {
            self.buf[self.i] = v;
            self.i += 1;
        }
        fn cmd(self: *@This(), opcode: u32, objtype: u32, len: u32) void {
            self.w(opcode | (objtype << 8) | (len << 16));
        }
        fn f(self: *@This(), v: f32) void {
            self.w(@bitCast(v));
        }
        fn shader(self: *@This(), handle: u32, text: []const u8) void {
            const nwords: u32 = @intCast((text.len + 1 + 3) / 4);
            self.cmd(1, 4, 1 + 4 + nwords);
            self.w(handle);
            self.w(0);
            self.w(0);
            self.w(0);
            self.w(0);
            var k: usize = 0;
            while (k < nwords) : (k += 1) {
                var word: u32 = 0;
                inline for (0..4) |bb| {
                    const idx = k * 4 + bb;
                    if (idx < text.len) word |= @as(u32, text[idx]) << (bb * 8);
                }
                self.w(word);
            }
        }
    };
    var b = B{ .buf = &storage };
    b.shader(50, vs_text);
    b.shader(51, fs_text);
    // vertex_elements: 1 element {src_offset 0, buffer 0, format r32g32_float}
    b.cmd(1, 5, 5);
    b.w(52);
    b.w(0);
    b.w(0);
    b.w(@intFromEnum(virgl.protocol.Format.r32g32_float));
    b.w(0);
    // bind_shader vs, fs
    b.cmd(31, 0, 2);
    b.w(50);
    b.w(0);
    b.cmd(31, 0, 2);
    b.w(51);
    b.w(0);
    // bind_object vertex_elements
    b.cmd(2, 5, 1);
    b.w(52);
    // create surface
    b.cmd(1, 8, 3);
    b.w(60);
    b.w(rt);
    b.w(@intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm));
    // set_framebuffer
    b.cmd(5, 0, 3);
    b.w(1);
    b.w(0);
    b.w(60);
    // set_vertex_buffers [stride, offset, handle]
    b.cmd(6, 0, 3);
    b.w(8);
    b.w(0);
    b.w(buf);
    // clear black
    b.cmd(7, 0, 8);
    b.w(4);
    b.f(0.0);
    b.f(0.0);
    b.f(0.0);
    b.f(1.0);
    b.w(0);
    b.w(0);
    b.w(0);
    // draw_vbo triangles,3
    b.cmd(8, 0, 12);
    b.w(0);
    b.w(3);
    b.w(@intFromEnum(virgl.protocol.PrimitiveType.triangles));
    for (0..9) |_| b.w(0);

    try gpu.submit(1, std.mem.sliceAsBytes(storage[0..b.i]));

    var px: [64 * 64 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt, &px));
    const center = ((32 * 64) + 32) * 4;
    // RED (BGRA): B<40, G<40, R>200 — passthrough would be white (all >200).
    try std.testing.expect(px[center + 2] > 200); // R
    try std.testing.expect(px[center + 1] < 40); // G
    try std.testing.expect(px[center + 0] < 40); // B
    try std.testing.expect(px[0] < 40 and px[1] < 40 and px[2] < 40); // corner black
}

test "GpuDevice draws indexed with uniform constants (buffer(1) binding)" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt: u32 = 10;
    const vbuf: u32 = 30;
    const ibuf: u32 = 31;

    try gpu.createResourceRecord(.{
        .handle = rt,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 64,
        .height = 64,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.render_target,
    });
    try gpu.createResourceRecord(.{
        .handle = vbuf,
        .target = .buffer,
        .format = .none,
        .width = 32,
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.vertex_buffer,
    });
    try gpu.createResourceRecord(.{
        .handle = ibuf,
        .target = .buffer,
        .format = .none,
        .width = 12,
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.index_buffer,
    });
    if (gpu.renderer == null) return error.SkipZigTest;

    // Vertex 0 is a decoy: a non-indexed draw of the first 3 vertices
    // would use it and produce a sliver, not a center-covering triangle.
    const verts = [_][2]f32{ .{ 10.0, 10.0 }, .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ 0.0, 0.9 } };
    const vb: [*]const u8 = @ptrCast(&verts);
    try std.testing.expect(gpu.uploadToBuffer(vbuf, 0, vb[0..@sizeOf(@TypeOf(verts))]));
    // Indices select vertices 1,2,3 (u32).
    const indices = [_]u32{ 1, 2, 3 };
    const ib: [*]const u8 = @ptrCast(&indices);
    try std.testing.expect(gpu.uploadToBuffer(ibuf, 0, ib[0..@sizeOf(@TypeOf(indices))]));
    try gpu.createContextId(1);

    const vs_text = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n0: MOV OUT[0], IN[0]\n1: END\n";
    // Fragment color comes from CONST[0] — proves the inline constant
    // block reaches the shader via buffer(1).
    const fs_text = "FRAG\nDCL OUT[0], COLOR\nDCL CONST[0]\n0: MOV OUT[0], CONST[0]\n1: END\n";

    var storage: [512]u32 = undefined;
    const B = struct {
        buf: []u32,
        i: usize = 0,
        fn w(self: *@This(), v: u32) void {
            self.buf[self.i] = v;
            self.i += 1;
        }
        fn cmd(self: *@This(), opcode: u32, objtype: u32, len: u32) void {
            self.w(opcode | (objtype << 8) | (len << 16));
        }
        fn f(self: *@This(), v: f32) void {
            self.w(@bitCast(v));
        }
        fn shader(self: *@This(), handle: u32, text: []const u8) void {
            const nwords: u32 = @intCast((text.len + 1 + 3) / 4);
            self.cmd(1, 4, 1 + 4 + nwords);
            self.w(handle);
            self.w(0);
            self.w(0);
            self.w(0);
            self.w(0);
            var k: usize = 0;
            while (k < nwords) : (k += 1) {
                var word: u32 = 0;
                inline for (0..4) |bb| {
                    const idx = k * 4 + bb;
                    if (idx < text.len) word |= @as(u32, text[idx]) << (bb * 8);
                }
                self.w(word);
            }
        }
    };
    var b = B{ .buf = &storage };
    b.shader(50, vs_text);
    b.shader(51, fs_text);
    b.cmd(1, 5, 5); // vertex_elements
    b.w(52);
    b.w(0);
    b.w(0);
    b.w(@intFromEnum(virgl.protocol.Format.r32g32_float));
    b.w(0);
    b.cmd(31, 0, 2); // bind vs
    b.w(50);
    b.w(0);
    b.cmd(31, 0, 2); // bind fs
    b.w(51);
    b.w(0);
    b.cmd(2, 5, 1); // bind vertex_elements
    b.w(52);
    b.cmd(1, 8, 3); // surface
    b.w(60);
    b.w(rt);
    b.w(@intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm));
    b.cmd(5, 0, 3); // set_framebuffer
    b.w(1);
    b.w(0);
    b.w(60);
    b.cmd(6, 0, 3); // set_vertex_buffers
    b.w(8);
    b.w(0);
    b.w(vbuf);
    // set_constant_buffer: FRAGMENT stage (1), index 0, GREEN
    b.cmd(12, 0, 6);
    b.w(1);
    b.w(0);
    b.f(0.0);
    b.f(1.0);
    b.f(0.0);
    b.f(1.0);
    // set_index_buffer: [handle, index_size, offset]
    b.cmd(11, 0, 3);
    b.w(ibuf);
    b.w(4);
    b.w(0);
    // clear black
    b.cmd(7, 0, 8);
    b.w(4);
    b.f(0.0);
    b.f(0.0);
    b.f(0.0);
    b.f(1.0);
    b.w(0);
    b.w(0);
    b.w(0);
    // draw_vbo indexed: start=0, count=3, triangles, indexed=1
    b.cmd(8, 0, 12);
    b.w(0);
    b.w(3);
    b.w(@intFromEnum(virgl.protocol.PrimitiveType.triangles));
    b.w(1); // indexed
    for (0..8) |_| b.w(0);

    try gpu.submit(1, std.mem.sliceAsBytes(storage[0..b.i]));

    var px: [64 * 64 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt, &px));
    const center = ((32 * 64) + 32) * 4;
    // GREEN (BGRA): the uniform's color, via the indexed triangle 1-2-3.
    try std.testing.expect(px[center + 1] > 200); // G
    try std.testing.expect(px[center + 2] < 40); // R
    try std.testing.expect(px[center + 0] < 40); // B
    try std.testing.expect(px[0] < 40 and px[1] < 40 and px[2] < 40); // corner black
}

test "GpuDevice samples a guest texture through TEX (fragment texturing)" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt: u32 = 10;
    const vbuf: u32 = 30;
    const tex: u32 = 40;

    try gpu.createResourceRecord(.{
        .handle = rt,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 64,
        .height = 64,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.render_target,
    });
    try gpu.createResourceRecord(.{
        .handle = vbuf,
        .target = .buffer,
        .format = .none,
        .width = 24,
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.vertex_buffer,
    });
    // A 1x1 sampled texture: every sample returns its single texel.
    try gpu.createResourceRecord(.{
        .handle = tex,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 1,
        .height = 1,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.sampler_view,
    });
    if (gpu.renderer == null) return error.SkipZigTest;

    // Orange texel (BGRA).
    const orange = [_]u8{ 0, 165, 255, 255 };
    try std.testing.expect(gpu.uploadToTexture(tex, &orange, 4));

    const verts = [_][2]f32{ .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ 0.0, 0.9 } };
    const vb: [*]const u8 = @ptrCast(&verts);
    try std.testing.expect(gpu.uploadToBuffer(vbuf, 0, vb[0..@sizeOf(@TypeOf(verts))]));
    try gpu.createContextId(1);

    const vs_text = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\nDCL OUT[1], GENERIC[0]\n0: MOV OUT[0], IN[0]\n1: MOV OUT[1], IN[0]\n2: END\n";
    const fs_text = "FRAG\nDCL IN[0], GENERIC[0]\nDCL OUT[0], COLOR\nDCL SAMP[0]\n0: TEX OUT[0], IN[0], SAMP[0], 2D\n1: END\n";

    var storage: [512]u32 = undefined;
    const B = struct {
        buf: []u32,
        i: usize = 0,
        fn w(self: *@This(), v: u32) void {
            self.buf[self.i] = v;
            self.i += 1;
        }
        fn cmd(self: *@This(), opcode: u32, objtype: u32, len: u32) void {
            self.w(opcode | (objtype << 8) | (len << 16));
        }
        fn f(self: *@This(), v: f32) void {
            self.w(@bitCast(v));
        }
        fn shader(self: *@This(), handle: u32, text: []const u8) void {
            const nwords: u32 = @intCast((text.len + 1 + 3) / 4);
            self.cmd(1, 4, 1 + 4 + nwords);
            self.w(handle);
            self.w(0);
            self.w(0);
            self.w(0);
            self.w(0);
            var k: usize = 0;
            while (k < nwords) : (k += 1) {
                var word: u32 = 0;
                inline for (0..4) |bb| {
                    const idx = k * 4 + bb;
                    if (idx < text.len) word |= @as(u32, text[idx]) << (bb * 8);
                }
                self.w(word);
            }
        }
    };
    var b = B{ .buf = &storage };
    b.shader(50, vs_text);
    b.shader(51, fs_text);
    b.cmd(1, 5, 5); // vertex_elements: one r32g32_float element
    b.w(52);
    b.w(0);
    b.w(0);
    b.w(@intFromEnum(virgl.protocol.Format.r32g32_float));
    b.w(0);
    b.cmd(31, 0, 2); // bind vs
    b.w(50);
    b.w(0);
    b.cmd(31, 0, 2); // bind fs
    b.w(51);
    b.w(0);
    b.cmd(2, 5, 1); // bind vertex_elements
    b.w(52);
    // create sampler_view (object type 6): [handle, res, format, ...]
    b.cmd(1, 6, 6);
    b.w(70);
    b.w(tex);
    b.w(@intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm));
    b.w(0);
    b.w(0);
    b.w(0);
    // set_sampler_views: fragment stage, slot 0 -> view 70
    b.cmd(10, 0, 3);
    b.w(1);
    b.w(0);
    b.w(70);
    b.cmd(1, 8, 3); // surface
    b.w(60);
    b.w(rt);
    b.w(@intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm));
    b.cmd(5, 0, 3); // set_framebuffer
    b.w(1);
    b.w(0);
    b.w(60);
    b.cmd(6, 0, 3); // set_vertex_buffers
    b.w(8);
    b.w(0);
    b.w(vbuf);
    b.cmd(7, 0, 8); // clear black
    b.w(4);
    b.f(0.0);
    b.f(0.0);
    b.f(0.0);
    b.f(1.0);
    b.w(0);
    b.w(0);
    b.w(0);
    b.cmd(8, 0, 12); // draw
    b.w(0);
    b.w(3);
    b.w(@intFromEnum(virgl.protocol.PrimitiveType.triangles));
    for (0..9) |_| b.w(0);

    try gpu.submit(1, std.mem.sliceAsBytes(storage[0..b.i]));

    var px: [64 * 64 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt, &px));
    const center = ((32 * 64) + 32) * 4;
    // Orange from the sampled texel (BGRA).
    try std.testing.expect(px[center + 2] > 200); // R
    try std.testing.expect(px[center + 1] > 120 and px[center + 1] < 210); // G ~165
    try std.testing.expect(px[center + 0] < 40); // B
    try std.testing.expect(px[0] < 40 and px[1] < 40 and px[2] < 40); // corner black
}

test "GpuDevice depth-tests draws (far fragment loses to near)" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt: u32 = 10;
    const zres: u32 = 11;
    const vbuf: u32 = 30;

    try gpu.createResourceRecord(.{
        .handle = rt,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 64,
        .height = 64,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.render_target,
    });
    try gpu.createResourceRecord(.{
        .handle = zres,
        .target = .texture_2d,
        .format = .none,
        .width = 64,
        .height = 64,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.depth_stencil,
    });
    try gpu.createResourceRecord(.{
        .handle = vbuf,
        .target = .buffer,
        .format = .none,
        .width = 72,
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.vertex_buffer,
    });
    if (gpu.renderer == null) return error.SkipZigTest;

    // Two overlapping triangles as float3 (x, y, z):
    // verts 0-2: NEAR (z=0.2) — drawn FIRST;
    // verts 3-5: FAR (z=0.8) — drawn SECOND, must lose the depth test.
    const verts = [_][3]f32{
        .{ -0.9, -0.9, 0.2 }, .{ 0.9, -0.9, 0.2 }, .{ 0.0, 0.9, 0.2 },
        .{ -0.9, -0.9, 0.8 }, .{ 0.9, -0.9, 0.8 }, .{ 0.0, 0.9, 0.8 },
    };
    const vb: [*]const u8 = @ptrCast(&verts);
    try std.testing.expect(gpu.uploadToBuffer(vbuf, 0, vb[0..@sizeOf(@TypeOf(verts))]));
    try gpu.createContextId(1);

    const vs_text = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n0: MOV OUT[0], IN[0]\n1: END\n";
    // Color from CONST[0] so the two draws can differ (green near, red far).
    const fs_text = "FRAG\nDCL OUT[0], COLOR\nDCL CONST[0]\n0: MOV OUT[0], CONST[0]\n1: END\n";

    var storage: [512]u32 = undefined;
    const B = struct {
        buf: []u32,
        i: usize = 0,
        fn w(self: *@This(), v: u32) void {
            self.buf[self.i] = v;
            self.i += 1;
        }
        fn cmd(self: *@This(), opcode: u32, objtype: u32, len: u32) void {
            self.w(opcode | (objtype << 8) | (len << 16));
        }
        fn f(self: *@This(), v: f32) void {
            self.w(@bitCast(v));
        }
        fn consts(self: *@This(), r: f32, g: f32) void {
            self.cmd(12, 0, 6);
            self.w(1); // fragment stage
            self.w(0);
            self.f(r);
            self.f(g);
            self.f(0.0);
            self.f(1.0);
        }
        fn draw(self: *@This(), start: u32) void {
            self.cmd(8, 0, 12);
            self.w(start);
            self.w(3);
            self.w(@intFromEnum(virgl.protocol.PrimitiveType.triangles));
            for (0..9) |_| self.w(0);
        }
        fn shader(self: *@This(), handle: u32, text: []const u8) void {
            const nwords: u32 = @intCast((text.len + 1 + 3) / 4);
            self.cmd(1, 4, 1 + 4 + nwords);
            self.w(handle);
            self.w(0);
            self.w(0);
            self.w(0);
            self.w(0);
            var k: usize = 0;
            while (k < nwords) : (k += 1) {
                var word: u32 = 0;
                inline for (0..4) |bb| {
                    const idx = k * 4 + bb;
                    if (idx < text.len) word |= @as(u32, text[idx]) << (bb * 8);
                }
                self.w(word);
            }
        }
    };
    var b = B{ .buf = &storage };
    b.shader(50, vs_text);
    b.shader(51, fs_text);
    b.cmd(1, 5, 5); // vertex_elements: one r32g32b32_float element
    b.w(52);
    b.w(0);
    b.w(0);
    b.w(@intFromEnum(virgl.protocol.Format.r32g32b32_float));
    b.w(0);
    // DSA: depth enabled, write enabled, func LESS (bits: 1|2|(1<<2)).
    b.cmd(1, 3, 5);
    b.w(53);
    b.w(1 | 2 | (1 << 2));
    b.w(0);
    b.w(0);
    b.w(0);
    b.cmd(31, 0, 2); // bind vs
    b.w(50);
    b.w(0);
    b.cmd(31, 0, 2); // bind fs
    b.w(51);
    b.w(0);
    b.cmd(2, 5, 1); // bind vertex_elements
    b.w(52);
    b.cmd(2, 3, 1); // bind dsa
    b.w(53);
    b.cmd(1, 8, 3); // color surface
    b.w(60);
    b.w(rt);
    b.w(@intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm));
    b.cmd(1, 8, 3); // depth surface
    b.w(61);
    b.w(zres);
    b.w(0);
    // set_framebuffer: nr_cbufs=1, zsurf=61, cbuf0=60
    b.cmd(5, 0, 3);
    b.w(1);
    b.w(61);
    b.w(60);
    // set_vertex_buffers: stride 12 (float3)
    b.cmd(6, 0, 3);
    b.w(12);
    b.w(0);
    b.w(vbuf);
    // clear color black + depth 1.0 (flags = depth|color0)
    b.cmd(7, 0, 8);
    b.w(1 | 4);
    b.f(0.0);
    b.f(0.0);
    b.f(0.0);
    b.f(1.0);
    b.w(0); // depth f64 low
    b.w(0x3FF00000); // depth f64 high = 1.0
    b.w(0);
    // NEAR green first, FAR red second.
    b.consts(0.0, 1.0);
    b.draw(0);
    b.consts(1.0, 0.0);
    b.draw(3);

    try gpu.submit(1, std.mem.sliceAsBytes(storage[0..b.i]));

    var px: [64 * 64 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt, &px));
    const center = ((32 * 64) + 32) * 4;
    // Depth test must keep the NEAR green fragment (BGRA).
    try std.testing.expect(px[center + 1] > 200); // G
    try std.testing.expect(px[center + 2] < 40); // R (red lost)
    try std.testing.expect(px[0] < 40 and px[1] < 40 and px[2] < 40); // corner black
}

test "GpuDevice executes TGSI control flow (IF on a uniform)" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt: u32 = 10;
    const vbuf: u32 = 30;
    try gpu.createResourceRecord(.{
        .handle = rt,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 64,
        .height = 64,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.render_target,
    });
    try gpu.createResourceRecord(.{
        .handle = vbuf,
        .target = .buffer,
        .format = .none,
        .width = 24,
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.vertex_buffer,
    });
    if (gpu.renderer == null) return error.SkipZigTest;

    const verts = [_][2]f32{ .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ 0.0, 0.9 } };
    const vb: [*]const u8 = @ptrCast(&verts);
    try std.testing.expect(gpu.uploadToBuffer(vbuf, 0, vb[0..@sizeOf(@TypeOf(verts))]));
    try gpu.createContextId(1);

    const vs_text = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n0: MOV OUT[0], IN[0]\n1: END\n";
    // Branch on CONST[0].x: non-zero -> green, zero -> red.
    const fs_text = "FRAG\nDCL OUT[0], COLOR\nDCL CONST[0]\nDCL TEMP[0]\nIMM[0] FLT32 { 1.0000, 0.0000, 0.0000, 1.0000}\nIMM[1] FLT32 { 0.0000, 1.0000, 0.0000, 1.0000}\n0: IF CONST[0].xxxx :3\n1: MOV TEMP[0], IMM[1]\n2: ELSE :4\n3: MOV TEMP[0], IMM[0]\n4: ENDIF\n5: MOV OUT[0], TEMP[0]\n6: END\n";

    var storage: [512]u32 = undefined;
    const B = struct {
        buf: []u32,
        i: usize = 0,
        fn w(self: *@This(), v: u32) void {
            self.buf[self.i] = v;
            self.i += 1;
        }
        fn cmd(self: *@This(), opcode: u32, objtype: u32, len: u32) void {
            self.w(opcode | (objtype << 8) | (len << 16));
        }
        fn f(self: *@This(), v: f32) void {
            self.w(@bitCast(v));
        }
        fn shader(self: *@This(), handle: u32, text: []const u8) void {
            const nwords: u32 = @intCast((text.len + 1 + 3) / 4);
            self.cmd(1, 4, 1 + 4 + nwords);
            self.w(handle);
            self.w(0);
            self.w(0);
            self.w(0);
            self.w(0);
            var k: usize = 0;
            while (k < nwords) : (k += 1) {
                var word: u32 = 0;
                inline for (0..4) |bb| {
                    const idx = k * 4 + bb;
                    if (idx < text.len) word |= @as(u32, text[idx]) << (bb * 8);
                }
                self.w(word);
            }
        }
    };
    var b = B{ .buf = &storage };
    b.shader(50, vs_text);
    b.shader(51, fs_text);
    b.cmd(1, 5, 5);
    b.w(52);
    b.w(0);
    b.w(0);
    b.w(@intFromEnum(virgl.protocol.Format.r32g32_float));
    b.w(0);
    b.cmd(31, 0, 2);
    b.w(50);
    b.w(0);
    b.cmd(31, 0, 2);
    b.w(51);
    b.w(0);
    b.cmd(2, 5, 1);
    b.w(52);
    b.cmd(1, 8, 3);
    b.w(60);
    b.w(rt);
    b.w(@intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm));
    b.cmd(5, 0, 3);
    b.w(1);
    b.w(0);
    b.w(60);
    b.cmd(6, 0, 3);
    b.w(8);
    b.w(0);
    b.w(vbuf);
    // CONST[0] = (1, 0, 0, 0): the IF takes the green branch.
    b.cmd(12, 0, 6);
    b.w(1);
    b.w(0);
    b.f(1.0);
    b.f(0.0);
    b.f(0.0);
    b.f(0.0);
    b.cmd(7, 0, 8);
    b.w(4);
    b.f(0.0);
    b.f(0.0);
    b.f(0.0);
    b.f(1.0);
    b.w(0);
    b.w(0);
    b.w(0);
    b.cmd(8, 0, 12);
    b.w(0);
    b.w(3);
    b.w(@intFromEnum(virgl.protocol.PrimitiveType.triangles));
    for (0..9) |_| b.w(0);

    try gpu.submit(1, std.mem.sliceAsBytes(storage[0..b.i]));

    var px: [64 * 64 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt, &px));
    const center = ((32 * 64) + 32) * 4;
    // Green branch taken (BGRA).
    try std.testing.expect(px[center + 1] > 200); // G
    try std.testing.expect(px[center + 2] < 40); // R
}

test "GpuDevice applies guest blend state (additive over)" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt: u32 = 10;
    const vbuf: u32 = 30;
    try gpu.createResourceRecord(.{
        .handle = rt, .target = .texture_2d, .format = .b8g8r8a8_unorm,
        .width = 64, .height = 64, .depth = 1, .array_size = 1,
        .last_level = 0, .nr_samples = 0, .flags = 0, .bind = PipeBind.render_target,
    });
    try gpu.createResourceRecord(.{
        .handle = vbuf, .target = .buffer, .format = .none,
        .width = 24, .height = 0, .depth = 1, .array_size = 1,
        .last_level = 0, .nr_samples = 0, .flags = 0, .bind = PipeBind.vertex_buffer,
    });
    if (gpu.renderer == null) return error.SkipZigTest;

    const verts = [_][2]f32{ .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ 0.0, 0.9 } };
    const vb: [*]const u8 = @ptrCast(&verts);
    try std.testing.expect(gpu.uploadToBuffer(vbuf, 0, vb[0..@sizeOf(@TypeOf(verts))]));
    try gpu.createContextId(1);

    const vs_text = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n0: MOV OUT[0], IN[0]\n1: END\n";
    const fs_text = "FRAG\nDCL OUT[0], COLOR\nDCL CONST[0]\n0: MOV OUT[0], CONST[0]\n1: END\n";

    var storage: [512]u32 = undefined;
    const B = struct {
        buf: []u32,
        i: usize = 0,
        fn w(self: *@This(), v: u32) void { self.buf[self.i] = v; self.i += 1; }
        fn cmd(self: *@This(), opcode: u32, objtype: u32, len: u32) void { self.w(opcode | (objtype << 8) | (len << 16)); }
        fn f(self: *@This(), v: f32) void { self.w(@bitCast(v)); }
        fn consts(self: *@This(), r: f32, g: f32, bl: f32) void {
            self.cmd(12, 0, 6); self.w(1); self.w(0); self.f(r); self.f(g); self.f(bl); self.f(1.0);
        }
        fn draw(self: *@This()) void {
            self.cmd(8, 0, 12); self.w(0); self.w(3);
            self.w(@intFromEnum(virgl.protocol.PrimitiveType.triangles));
            for (0..9) |_| self.w(0);
        }
        fn shader(self: *@This(), handle: u32, text: []const u8) void {
            const nwords: u32 = @intCast((text.len + 1 + 3) / 4);
            self.cmd(1, 4, 1 + 4 + nwords);
            self.w(handle); self.w(0); self.w(0); self.w(0); self.w(0);
            var k: usize = 0;
            while (k < nwords) : (k += 1) {
                var word: u32 = 0;
                inline for (0..4) |bb| { const idx = k * 4 + bb; if (idx < text.len) word |= @as(u32, text[idx]) << (bb * 8); }
                self.w(word);
            }
        }
    };
    var b = B{ .buf = &storage };
    b.shader(50, vs_text);
    b.shader(51, fs_text);
    b.cmd(1, 5, 5); b.w(52); b.w(0); b.w(0);
    b.w(@intFromEnum(virgl.protocol.Format.r32g32_float)); b.w(0);
    // Blend state: RT0 blend_enable, ADD, src=ONE, dst=ONE (additive).
    // Word layout (state.zig BlendState.parse): s0 flags at [0]; RT states
    // begin at data[1], one u32 each. RtBlendState bit layout (protocol
    // BlendState helpers): bit0 blend_enable, then rgb_func<<1,
    // rgb_src<<4, rgb_dst<<9, alpha_func<<14, alpha_src<<17, alpha_dst<<22,
    // color_mask<<27.
    const one_factor: u32 = 0x01; // BlendFactor.one
    const add_func: u32 = 0; // BlendFunc.add
    const rt0: u32 = 1 | (add_func << 1) | (one_factor << 4) | (one_factor << 9) |
        (add_func << 14) | (one_factor << 17) | (one_factor << 22) | (0xf << 27);
    // create_object BLEND (type 1): handle + [s0, logicop, rt0]; the
    // parser reads rt[i] from data[2+i], so RT0 is the 3rd payload word.
    b.cmd(1, 1, 4);
    b.w(70);
    b.w(0); // s0 flags
    b.w(0); // logicop func
    b.w(rt0);
    b.cmd(2, 1, 1); // bind_object BLEND
    b.w(70);
    b.cmd(31, 0, 2); b.w(50); b.w(0);
    b.cmd(31, 0, 2); b.w(51); b.w(0);
    b.cmd(2, 5, 1); b.w(52);
    b.cmd(1, 8, 3); b.w(60); b.w(rt); b.w(@intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm));
    b.cmd(5, 0, 3); b.w(1); b.w(0); b.w(60);
    b.cmd(6, 0, 3); b.w(8); b.w(0); b.w(vbuf);
    b.cmd(7, 0, 8); b.w(4); b.f(0.0); b.f(0.0); b.f(0.0); b.f(1.0); b.w(0); b.w(0); b.w(0);
    // Two additive draws: red then green -> yellow.
    b.consts(1.0, 0.0, 0.0);
    b.draw();
    b.consts(0.0, 1.0, 0.0);
    b.draw();

    try gpu.submit(1, std.mem.sliceAsBytes(storage[0..b.i]));

    var px: [64 * 64 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt, &px));
    const center = ((32 * 64) + 32) * 4;
    // Additive: R and G both ~full (yellow), not just the last (green).
    try std.testing.expect(px[center + 2] > 200); // R survived the 2nd draw
    try std.testing.expect(px[center + 1] > 200); // G
    try std.testing.expect(px[center + 0] < 40); // B
}

test "GpuDevice captures shader TGSI text and binds by stage" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();
    try gpu.createContextId(1);

    const vs_text = "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n0: MOV OUT[0], IN[0]\n1: END\n";
    // Pack the text (nul-terminated) into TGSI words (4 chars/word, little).
    const nwords: usize = (vs_text.len + 1 + 3) / 4;
    var words: [64]u32 = .{0} ** 64;
    for (vs_text, 0..) |ch, i| {
        words[i / 4] |= @as(u32, ch) << @intCast((i % 4) * 8);
    }

    const shader_handle: u32 = 50;
    var stream: [128]u32 = undefined;
    var i: usize = 0;
    // create_object(1), object_type shader(4), length = handle + 4 hdr + text
    stream[i] = 1 | (4 << 8) | (@as(u32, @intCast(1 + 4 + nwords)) << 16);
    i += 1;
    stream[i] = shader_handle;
    i += 1;
    stream[i] = 0; // type (ignored; stage from text)
    i += 1;
    stream[i] = 0; // offset
    i += 1;
    stream[i] = 0; // num_tokens
    i += 1;
    stream[i] = 0; // so_num_outputs
    i += 1;
    for (0..nwords) |k| {
        stream[i] = words[k];
        i += 1;
    }
    // bind_shader(31), length 2 [handle, type]
    stream[i] = 31 | (2 << 16);
    i += 1;
    stream[i] = shader_handle;
    i += 1;
    stream[i] = 0;
    i += 1;

    try gpu.submit(1, std.mem.sliceAsBytes(stream[0..i]));

    const ctx = gpu.getContext(1).?;
    const sh = ctx.shaders.get(shader_handle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(sh.tgsi_text != null);
    try std.testing.expect(std.mem.indexOf(u8, sh.tgsi_text.?, "MOV OUT[0], IN[0]") != null);
    try std.testing.expectEqual(virgl.protocol.ShaderType.vertex, sh.shader_type);
    // bind_shader routed to the vertex slot.
    try std.testing.expectEqual(@as(?u32, shader_handle), ctx.bound.vs);
}

test "GpuDevice routes a guest draw_vbo command stream to Metal" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt_handle: u32 = 10;
    const surf_handle: u32 = 20;
    const buf_handle: u32 = 30;

    // Render target + vertex buffer via the real record path.
    try gpu.createResourceRecord(.{
        .handle = rt_handle,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 64,
        .height = 64,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.render_target,
    });
    try gpu.createResourceRecord(.{
        .handle = buf_handle,
        .target = .buffer,
        .format = .none,
        .width = 24,
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = PipeBind.vertex_buffer,
    });

    if (gpu.renderer == null) return error.SkipZigTest;

    // Upload triangle vertices (clip-space float2) into the buffer.
    const verts = [_][2]f32{ .{ -0.9, -0.9 }, .{ 0.9, -0.9 }, .{ 0.0, 0.9 } };
    const vbytes: [*]const u8 = @ptrCast(&verts);
    try std.testing.expect(gpu.uploadToBuffer(buf_handle, 0, vbytes[0..@sizeOf(@TypeOf(verts))]));

    try gpu.createContextId(1);

    var w: [34]u32 = undefined;
    var i: usize = 0;
    // create SURFACE
    w[i] = 1 | (8 << 8) | (3 << 16);
    i += 1;
    w[i] = surf_handle;
    i += 1;
    w[i] = rt_handle;
    i += 1;
    w[i] = @intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm);
    i += 1;
    // set_framebuffer_state
    w[i] = 5 | (3 << 16);
    i += 1;
    w[i] = 1;
    i += 1; // nr_cbufs
    w[i] = 0;
    i += 1; // zsurf
    w[i] = surf_handle;
    i += 1;
    // clear to black
    w[i] = 7 | (8 << 16);
    i += 1;
    w[i] = 0x4;
    i += 1;
    w[i] = @bitCast(@as(f32, 0.0));
    i += 1;
    w[i] = @bitCast(@as(f32, 0.0));
    i += 1;
    w[i] = @bitCast(@as(f32, 0.0));
    i += 1;
    w[i] = @bitCast(@as(f32, 1.0));
    i += 1;
    w[i] = 0;
    i += 1;
    w[i] = 0;
    i += 1;
    w[i] = 0;
    i += 1;
    // set_vertex_buffers: 1 triple [stride, offset, handle]
    w[i] = 6 | (3 << 16);
    i += 1;
    w[i] = 8; // stride (float2)
    i += 1;
    w[i] = 0; // offset
    i += 1;
    w[i] = buf_handle;
    i += 1;
    // draw_vbo (length 12): start,count,mode,indexed,inst,bias,start_inst,prim_restart,restart,min,max,cso
    w[i] = 8 | (12 << 16);
    i += 1;
    w[i] = 0; // start
    i += 1;
    w[i] = 3; // count
    i += 1;
    w[i] = @intFromEnum(virgl.protocol.PrimitiveType.triangles);
    i += 1;
    // remaining draw_vbo payload words: indexed, instance_count, index_bias,
    // start_instance, primitive_restart, restart_index, min_index, max_index, cso
    for (0..9) |_| {
        w[i] = 0;
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 34), i);

    try gpu.submit(1, std.mem.sliceAsBytes(w[0..]));

    var buf: [64 * 64 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt_handle, &buf));

    // Center: covered by the (white) triangle. Corner: cleared black.
    const center = ((32 * 64) + 32) * 4;
    try std.testing.expect(buf[center + 0] > 200); // B
    try std.testing.expect(buf[center + 1] > 200); // G
    try std.testing.expect(buf[center + 2] > 200); // R
    try std.testing.expect(buf[0] < 40 and buf[1] < 40 and buf[2] < 40); // corner black
}

test "GpuDevice routes a guest clear command stream to Metal" {
    const alloc = std.testing.allocator;
    var gpu = GpuDevice.init(alloc);
    defer gpu.deinit();

    const rt_handle: u32 = 10;
    const surf_handle: u32 = 20;

    // resource_create_3d for a 32x32 BGRA render target (44-byte payload).
    var res: [44]u8 = .{0} ** 44;
    std.mem.writeInt(u32, res[0..4], rt_handle, .little);
    res[4] = @intFromEnum(virgl.context.ResourceTarget.texture_2d);
    std.mem.writeInt(u32, res[8..12], @intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm), .little);
    std.mem.writeInt(u32, res[12..16], PipeBind.render_target, .little);
    std.mem.writeInt(u32, res[16..20], 32, .little); // width
    std.mem.writeInt(u32, res[20..24], 32, .little); // height
    std.mem.writeInt(u32, res[24..28], 1, .little); // depth
    std.mem.writeInt(u32, res[28..32], 1, .little); // array_size
    try gpu.processCommand(.resource_create_3d, &res);

    // No Metal device available (headless CI) → nothing to execute.
    if (gpu.renderer == null) return error.SkipZigTest;

    try gpu.createContextId(1);

    // Build a virgl command buffer: create SURFACE → set_framebuffer → clear.
    var w: [17]u32 = undefined;
    var i: usize = 0;
    // create_object(1), object_type surface(8), length 3 (handle + 2 payload)
    w[i] = 1 | (8 << 8) | (3 << 16);
    i += 1;
    w[i] = surf_handle;
    i += 1;
    w[i] = rt_handle;
    i += 1;
    w[i] = @intFromEnum(virgl.protocol.Format.b8g8r8a8_unorm);
    i += 1;
    // set_framebuffer_state(5), length 3
    w[i] = 5 | (3 << 16);
    i += 1;
    w[i] = 1; // nr_cbufs
    i += 1;
    w[i] = 0; // zsurf
    i += 1;
    w[i] = surf_handle; // cbuf[0]
    i += 1;
    // clear(7), length 8
    w[i] = 7 | (8 << 16);
    i += 1;
    w[i] = 0x4; // flags (ignored by executor)
    i += 1;
    w[i] = @bitCast(@as(f32, 1.0)); // r
    i += 1;
    w[i] = @bitCast(@as(f32, 0.5)); // g
    i += 1;
    w[i] = @bitCast(@as(f32, 0.25)); // b
    i += 1;
    w[i] = @bitCast(@as(f32, 1.0)); // a
    i += 1;
    w[i] = 0; // depth lo
    i += 1;
    w[i] = 0; // depth hi
    i += 1;
    w[i] = 0; // stencil
    i += 1;
    try std.testing.expectEqual(@as(usize, 17), i);

    try gpu.submit(1, std.mem.sliceAsBytes(w[0..]));

    // Read the render target back and confirm the guest clear landed.
    var buf: [32 * 32 * 4]u8 = undefined;
    try std.testing.expect(gpu.readbackResource(rt_handle, &buf));

    const center = ((16 * 32) + 16) * 4;
    try std.testing.expect(buf[center + 2] > 250); // R ~255
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(buf[center + 1])), 2.0); // G ~0.5
    try std.testing.expectApproxEqAbs(@as(f32, 64), @as(f32, @floatFromInt(buf[center + 0])), 2.0); // B ~0.25
    try std.testing.expectEqual(@as(u8, 255), buf[center + 3]); // A
}

test {
    _ = virgl;
    _ = metal;
}
