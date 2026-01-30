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
pub const GpuDevice = struct {
    alloc: Allocator,
    contexts: std.AutoHashMap(ContextId, *Context),
    resources: std.AutoHashMap(ResourceHandle, Resource),
    next_ctx_id: ContextId,
    next_resource_id: ResourceHandle,

    pub const Error = Allocator.Error || virgl.decoder.DecodeError;

    pub fn init(alloc: Allocator) GpuDevice {
        return .{
            .alloc = alloc,
            .contexts = std.AutoHashMap(ContextId, *Context).init(alloc),
            .resources = std.AutoHashMap(ResourceHandle, Resource).init(alloc),
            .next_ctx_id = 1,
            .next_resource_id = 1,
        };
    }

    pub fn deinit(self: *GpuDevice) void {
        var ctx_iter = self.contexts.valueIterator();
        while (ctx_iter.next()) |ctx| {
            ctx.*.deinit();
        }
        self.contexts.deinit();
        self.resources.deinit();
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

        const ctx = try Context.init(self.alloc, id);
        errdefer ctx.deinit();

        try self.contexts.put(id, ctx);
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
        _ = self;
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
                },

                .draw_vbo => {
                    const draw_cmd = try dec.decodeDrawVbo(header.length);
                    ctx.draw(draw_cmd);
                },

                else => dec.skip(header.length),
            }
        }
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

test {
    _ = virgl;
    _ = metal;
}
