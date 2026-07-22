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
        };
    }

    pub fn deinit(self: *GpuDevice) void {
        var ctx_iter = self.contexts.valueIterator();
        while (ctx_iter.next()) |ctx| {
            ctx.*.deinit();
        }
        self.contexts.deinit();
        self.resources.deinit();
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
        }
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
                        .shader => try ctx.createShader(handle, .vertex, payload),
                        .surface => {
                            // Surface create payload: [res_handle, format, ...].
                            if (payload.len >= 2) {
                                const res_handle = payload[0];
                                const fmt: virgl.protocol.Format = @enumFromInt(payload[1]);
                                try ctx.createSurface(handle, res_handle, fmt);
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
                    }
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
