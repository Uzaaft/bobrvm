//! Virgl Rendering Context.
//!
//! Manages OpenGL state for a single guest rendering context.
//! Tracks bound state objects and translates commands to Metal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;
const proto = @import("protocol.zig");
const state = @import("state.zig");
const decoder = @import("decoder.zig");

/// Resource handle type.
pub const ResourceHandle = u32;

/// Object handle type.
pub const ObjectHandle = u32;

/// GPU resource (texture, buffer, render target).
pub const Resource = struct {
    handle: ResourceHandle,
    target: ResourceTarget,
    format: proto.Format,
    width: u32,
    height: u32,
    depth: u32,
    array_size: u32,
    last_level: u32,
    nr_samples: u32,
    flags: u32,
    // TODO: IOSurface/MTLTexture/MTLBuffer backing
};

/// Resource target type (PIPE_TEXTURE_*, PIPE_BUFFER).
pub const ResourceTarget = enum(u8) {
    buffer = 0,
    texture_1d = 1,
    texture_2d = 2,
    texture_3d = 3,
    texture_cube = 4,
    texture_rect = 5,
    texture_1d_array = 6,
    texture_2d_array = 7,
    texture_cube_array = 8,
    _,
};

/// Shader object.
pub const Shader = struct {
    handle: ObjectHandle,
    shader_type: proto.ShaderType,
    /// Owned TGSI text (as dumped by the guest mesa driver), translated to
    /// MSL when a pipeline is built. Null if not captured.
    tgsi_text: ?[]u8 = null,
};

/// Detect a shader stage from the leading TGSI header token.
fn detectStage(text: []const u8) proto.ShaderType {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const first = it.next() orelse return .vertex;
    if (std.mem.eql(u8, first, "FRAG")) return .fragment;
    if (std.mem.eql(u8, first, "GEOM")) return .geometry;
    if (std.mem.eql(u8, first, "TESS_CTRL")) return .tess_ctrl;
    if (std.mem.eql(u8, first, "TESS_EVAL")) return .tess_eval;
    if (std.mem.eql(u8, first, "COMP")) return .compute;
    return .vertex;
}

/// Surface object (render target view).
pub const Surface = struct {
    handle: ObjectHandle,
    resource_handle: ResourceHandle,
    format: proto.Format,
    first_layer: u16,
    last_layer: u16,
    level: u8,
};

/// Sampler view object (texture view).
pub const SamplerView = struct {
    handle: ObjectHandle,
    resource_handle: ResourceHandle,
    format: proto.Format,
    first_layer: u16,
    last_layer: u16,
    first_level: u8,
    last_level: u8,
    swizzle_r: u8,
    swizzle_g: u8,
    swizzle_b: u8,
    swizzle_a: u8,
};

/// Current bound state.
pub const BoundState = struct {
    blend: ?ObjectHandle = null,
    rasterizer: ?ObjectHandle = null,
    dsa: ?ObjectHandle = null,
    vertex_elements: ?ObjectHandle = null,
    vs: ?ObjectHandle = null,
    fs: ?ObjectHandle = null,
    gs: ?ObjectHandle = null,
    tcs: ?ObjectHandle = null,
    tes: ?ObjectHandle = null,
    cs: ?ObjectHandle = null,
};

/// Framebuffer state.
pub const FramebufferState = struct {
    width: u32 = 0,
    height: u32 = 0,
    nr_cbufs: u32 = 0,
    zsurf: ?ObjectHandle = null,
    cbufs: [8]?ObjectHandle = .{null} ** 8,
};

/// Viewport state.
pub const ViewportState = struct {
    scale: [3]f32 = .{ 1.0, 1.0, 1.0 },
    translate: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

/// Scissor state.
pub const ScissorState = struct {
    minx: u16 = 0,
    miny: u16 = 0,
    maxx: u16 = 0xffff,
    maxy: u16 = 0xffff,
};

/// Rendering context.
pub const Context = struct {
    alloc: Allocator,
    id: u32,

    // Object storage
    blend_states: std.AutoHashMap(ObjectHandle, state.BlendState),
    rasterizer_states: std.AutoHashMap(ObjectHandle, state.RasterizerState),
    dsa_states: std.AutoHashMap(ObjectHandle, state.DepthStencilAlphaState),
    sampler_states: std.AutoHashMap(ObjectHandle, state.SamplerState),
    vertex_elements: std.AutoHashMap(ObjectHandle, state.VertexElementsState),
    shaders: std.AutoHashMap(ObjectHandle, Shader),
    surfaces: std.AutoHashMap(ObjectHandle, Surface),
    sampler_views: std.AutoHashMap(ObjectHandle, SamplerView),

    // Current bound state
    bound: BoundState,
    framebuffer: FramebufferState,
    viewports: [16]ViewportState,
    scissors: [16]ScissorState,
    stencil_ref: [2]u8,
    blend_color: [4]f32,
    sample_mask: u32,

    // Vertex buffers
    vbo_handles: [16]ResourceHandle,
    vbo_strides: [16]u32,
    vbo_offsets: [16]u32,

    // Index buffer
    index_buffer: ResourceHandle,
    index_offset: u32,
    index_size: u8, // 1, 2, or 4 bytes

    // Sampler bindings per stage
    sampler_views_bound: [6][16]?ObjectHandle, // [stage][slot]
    samplers_bound: [6][16]?ObjectHandle,

    // Uniform/constant buffers per stage
    ubo_handles: [6][16]ResourceHandle,
    ubo_offsets: [6][16]u32,
    ubo_sizes: [6][16]u32,

    // Inline constants (set_constant_buffer): raw little-endian float
    // words per stage (0 = vertex, 1 = fragment; other stages accepted
    // but unused by the Metal translator so far).
    const_data: [6]std.ArrayListUnmanaged(u8),

    pub const Error = Allocator.Error;

    pub fn init(alloc: Allocator, id: u32) Error!*Context {
        const ctx = try alloc.create(Context);
        ctx.* = .{
            .alloc = alloc,
            .id = id,
            .blend_states = std.AutoHashMap(ObjectHandle, state.BlendState).init(alloc),
            .rasterizer_states = std.AutoHashMap(ObjectHandle, state.RasterizerState).init(alloc),
            .dsa_states = std.AutoHashMap(ObjectHandle, state.DepthStencilAlphaState).init(alloc),
            .sampler_states = std.AutoHashMap(ObjectHandle, state.SamplerState).init(alloc),
            .vertex_elements = std.AutoHashMap(ObjectHandle, state.VertexElementsState).init(alloc),
            .shaders = std.AutoHashMap(ObjectHandle, Shader).init(alloc),
            .surfaces = std.AutoHashMap(ObjectHandle, Surface).init(alloc),
            .sampler_views = std.AutoHashMap(ObjectHandle, SamplerView).init(alloc),
            .bound = .{},
            .framebuffer = .{},
            .viewports = [_]ViewportState{.{}} ** 16,
            .scissors = [_]ScissorState{.{}} ** 16,
            .stencil_ref = .{ 0, 0 },
            .blend_color = .{ 0, 0, 0, 0 },
            .sample_mask = 0xffffffff,
            .vbo_handles = .{0} ** 16,
            .vbo_strides = .{0} ** 16,
            .vbo_offsets = .{0} ** 16,
            .index_buffer = 0,
            .index_offset = 0,
            .index_size = 2,
            .sampler_views_bound = .{.{null} ** 16} ** 6,
            .samplers_bound = .{.{null} ** 16} ** 6,
            .ubo_handles = .{.{0} ** 16} ** 6,
            .ubo_offsets = .{.{0} ** 16} ** 6,
            .ubo_sizes = .{.{0} ** 16} ** 6,
            .const_data = .{std.ArrayListUnmanaged(u8).empty} ** 6,
        };
        return ctx;
    }

    /// Replace the inline constant block for a shader stage.
    pub fn setConstants(self: *Context, stage: usize, data: []const u8) Error!void {
        if (stage >= self.const_data.len) return;
        self.const_data[stage].clearRetainingCapacity();
        try self.const_data[stage].appendSlice(self.alloc, data);
    }

    /// Inline constants for a stage ([] if never set).
    pub fn constants(self: *const Context, stage: usize) []const u8 {
        if (stage >= self.const_data.len) return &.{};
        return self.const_data[stage].items;
    }

    /// Bind a buffer resource as uniform-buffer `index` for a stage
    /// (set_uniform_buffer). index 0 is the default block; named UBOs use
    /// index >= 1. handle 0 unbinds.
    pub fn setUniformBuffer(self: *Context, stage: usize, index: usize, handle: ResourceHandle, offset: u32, size: u32) void {
        if (stage >= 6 or index >= 16) return;
        self.ubo_handles[stage][index] = handle;
        self.ubo_offsets[stage][index] = offset;
        self.ubo_sizes[stage][index] = size;
    }

    /// Record a sampler view (texture binding descriptor).
    pub fn createSamplerView(
        self: *Context,
        handle: ObjectHandle,
        resource_handle: ResourceHandle,
        format: proto.Format,
    ) Error!void {
        try self.sampler_views.put(handle, .{
            .handle = handle,
            .resource_handle = resource_handle,
            .format = format,
            .first_layer = 0,
            .last_layer = 0,
            .first_level = 0,
            .last_level = 0,
            .swizzle_r = 0,
            .swizzle_g = 1,
            .swizzle_b = 2,
            .swizzle_a = 3,
        });
    }

    pub fn deinit(self: *Context) void {
        var sh_it = self.shaders.valueIterator();
        while (sh_it.next()) |sh| {
            if (sh.tgsi_text) |t| self.alloc.free(t);
        }
        self.blend_states.deinit();
        self.rasterizer_states.deinit();
        self.dsa_states.deinit();
        self.sampler_states.deinit();
        self.vertex_elements.deinit();
        self.shaders.deinit();
        self.surfaces.deinit();
        self.sampler_views.deinit();
        for (&self.const_data) |*cd| cd.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // =========================================================================
    // Object Creation
    // =========================================================================

    pub fn createBlendState(self: *Context, handle: ObjectHandle, data: []const u32) Error!void {
        const blend = state.BlendState.parse(handle, data);
        try self.blend_states.put(handle, blend);
    }

    pub fn createRasterizerState(self: *Context, handle: ObjectHandle, data: []const u32) Error!void {
        const rast = state.RasterizerState.parse(handle, data);
        try self.rasterizer_states.put(handle, rast);
    }

    pub fn createDsaState(self: *Context, handle: ObjectHandle, data: []const u32) Error!void {
        const dsa = state.DepthStencilAlphaState.parse(handle, data);
        try self.dsa_states.put(handle, dsa);
    }

    pub fn createSamplerState(self: *Context, handle: ObjectHandle, data: []const u32) Error!void {
        const sampler = state.SamplerState.parse(handle, data);
        try self.sampler_states.put(handle, sampler);
    }

    pub fn createVertexElements(self: *Context, handle: ObjectHandle, data: []const u32) Error!void {
        const ve = state.VertexElementsState.parse(handle, data);
        try self.vertex_elements.put(handle, ve);
    }

    /// Capture a shader from its packed TGSI text words (4 chars/word,
    /// little-endian, nul-terminated). The stage is derived from the TGSI
    /// header token so we don't depend on the wire type encoding.
    pub fn createShader(self: *Context, handle: ObjectHandle, words: []const u32) Error!void {
        const raw = try self.alloc.alloc(u8, words.len * 4);
        defer self.alloc.free(raw);
        for (0..words.len) |i| std.mem.writeInt(u32, raw[i * 4 ..][0..4], words[i], .little);
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        const text = try self.alloc.dupe(u8, raw[0..end]);
        errdefer self.alloc.free(text);

        const stage = detectStage(text);
        if (self.shaders.fetchRemove(handle)) |old| {
            if (old.value.tgsi_text) |t| self.alloc.free(t);
        }
        try self.shaders.put(handle, .{
            .handle = handle,
            .shader_type = stage,
            .tgsi_text = text,
        });
    }

    pub fn createSurface(self: *Context, handle: ObjectHandle, resource: ResourceHandle, format: proto.Format) Error!void {
        try self.surfaces.put(handle, .{
            .handle = handle,
            .resource_handle = resource,
            .format = format,
            .first_layer = 0,
            .last_layer = 0,
            .level = 0,
        });
    }

    // =========================================================================
    // Object Binding
    // =========================================================================

    pub fn bindBlendState(self: *Context, handle: ObjectHandle) void {
        self.bound.blend = if (handle != 0) handle else null;
    }

    pub fn bindRasterizerState(self: *Context, handle: ObjectHandle) void {
        self.bound.rasterizer = if (handle != 0) handle else null;
    }

    pub fn bindDsaState(self: *Context, handle: ObjectHandle) void {
        self.bound.dsa = if (handle != 0) handle else null;
    }

    pub fn bindVertexElements(self: *Context, handle: ObjectHandle) void {
        self.bound.vertex_elements = if (handle != 0) handle else null;
    }

    pub fn bindShader(self: *Context, shader_type: proto.ShaderType, handle: ObjectHandle) void {
        const h = if (handle != 0) handle else null;
        switch (shader_type) {
            .vertex => self.bound.vs = h,
            .fragment => self.bound.fs = h,
            .geometry => self.bound.gs = h,
            .tess_ctrl => self.bound.tcs = h,
            .tess_eval => self.bound.tes = h,
            .compute => self.bound.cs = h,
            else => {},
        }
    }

    // =========================================================================
    // Object Destruction
    // =========================================================================

    pub fn destroyObject(self: *Context, obj_type: proto.ObjectType, handle: ObjectHandle) void {
        switch (obj_type) {
            .blend => _ = self.blend_states.remove(handle),
            .rasterizer => _ = self.rasterizer_states.remove(handle),
            .dsa => _ = self.dsa_states.remove(handle),
            .sampler_state => _ = self.sampler_states.remove(handle),
            .vertex_elements => _ = self.vertex_elements.remove(handle),
            .shader => {
                if (self.shaders.fetchRemove(handle)) |old| {
                    if (old.value.tgsi_text) |t| self.alloc.free(t);
                }
            },
            .surface => _ = self.surfaces.remove(handle),
            .sampler_view => _ = self.sampler_views.remove(handle),
            else => {},
        }
    }

    // =========================================================================
    // State Updates
    // =========================================================================

    pub fn setViewport(self: *Context, index: u8, viewport: ViewportState) void {
        if (index < 16) {
            self.viewports[index] = viewport;
        }
    }

    pub fn setScissor(self: *Context, index: u8, scissor: ScissorState) void {
        if (index < 16) {
            self.scissors[index] = scissor;
        }
    }

    pub fn setFramebuffer(self: *Context, fb: decoder.FramebufferState) void {
        self.framebuffer.nr_cbufs = fb.nr_cbufs;
        self.framebuffer.zsurf = if (fb.zsurf_handle != 0) fb.zsurf_handle else null;
        for (0..8) |i| {
            self.framebuffer.cbufs[i] = if (fb.surf_handles[i] != 0) fb.surf_handles[i] else null;
        }
    }

    pub fn setStencilRef(self: *Context, front: u8, back: u8) void {
        self.stencil_ref = .{ front, back };
    }

    pub fn setBlendColor(self: *Context, color: [4]f32) void {
        self.blend_color = color;
    }

    pub fn setSampleMask(self: *Context, mask: u32) void {
        self.sample_mask = mask;
    }

    pub fn setVertexBuffer(self: *Context, index: u8, handle: ResourceHandle, stride: u32, offset: u32) void {
        if (index < 16) {
            self.vbo_handles[index] = handle;
            self.vbo_strides[index] = stride;
            self.vbo_offsets[index] = offset;
        }
    }

    pub fn setIndexBuffer(self: *Context, handle: ResourceHandle, size: u8, offset: u32) void {
        self.index_buffer = handle;
        self.index_size = size;
        self.index_offset = offset;
    }

    // =========================================================================
    // Drawing
    // =========================================================================

    pub fn draw(self: *Context, cmd: decoder.DrawCommand) void {
        // TODO: Translate to Metal draw call
        _ = self;
        _ = cmd;
    }

    pub fn clear(self: *Context, cmd: decoder.ClearCommand) void {
        // TODO: Translate to Metal clear
        _ = self;
        _ = cmd;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Context init and deinit" {
    var ctx = try Context.init(std.testing.allocator, 1);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(u32, 1), ctx.id);
}

test "Context create and bind blend state" {
    var ctx = try Context.init(std.testing.allocator, 1);
    defer ctx.deinit();

    const data = [_]u32{
        state.proto.BlendState.S0_INDEPENDENT_BLEND_ENABLE,
        0,
        0x1 | (0xf << 27),
    };

    try ctx.createBlendState(42, &data);
    ctx.bindBlendState(42);

    try std.testing.expectEqual(@as(?ObjectHandle, 42), ctx.bound.blend);
    try std.testing.expect(ctx.blend_states.contains(42));
}
