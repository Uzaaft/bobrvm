//! Metal bindings for GPU rendering.
//!
//! Provides Zig wrappers around Metal Objective-C API using
//! direct message passing. This allows command buffer encoding
//! without external dependencies.
//!
//! Pattern follows Ghostty's renderer/metal implementation.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;

// =============================================================================
// Objective-C Runtime Bindings
// =============================================================================

pub const id = *anyopaque;
pub const SEL = *anyopaque;
pub const Class = *anyopaque;
pub const BOOL = bool;
pub const NSUInteger = usize;
pub const NSInteger = isize;

extern "objc" fn objc_msgSend() callconv(.c) void;
extern "objc" fn objc_getClass(name: [*:0]const u8) callconv(.c) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) callconv(.c) SEL;
extern "objc" fn objc_autoreleasePoolPush() callconv(.c) ?*anyopaque;
extern "objc" fn objc_autoreleasePoolPop(pool: ?*anyopaque) callconv(.c) void;

/// Create the system default Metal device (C function in the Metal framework).
/// Works headlessly — no window/display required.
extern "c" fn MTLCreateSystemDefaultDevice() callconv(.c) ?id;

/// Send a message with no return value.
pub fn msgSendVoid(target: id, selector: SEL) void {
    const func: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    func(target, selector);
}

/// Send a message returning an object.
pub fn msgSendId(target: id, selector: SEL) ?id {
    const func: *const fn (id, SEL) callconv(.c) ?id = @ptrCast(&objc_msgSend);
    return func(target, selector);
}

/// Send a message with one argument returning an object.
pub fn msgSendId1(target: id, selector: SEL, arg: anytype) ?id {
    const ArgType = @TypeOf(arg);
    const func: *const fn (id, SEL, ArgType) callconv(.c) ?id = @ptrCast(&objc_msgSend);
    return func(target, selector, arg);
}

/// Get a selector.
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Create an NSString from a null-terminated UTF-8 C string (autoreleased).
pub fn nsString(c_str: [*:0]const u8) ?id {
    const nsstring = objc_getClass("NSString") orelse return null;
    const s = sel("stringWithUTF8String:");
    const func: *const fn (Class, SEL, [*:0]const u8) callconv(.c) ?id = @ptrCast(&objc_msgSend);
    return func(nsstring, s, c_str);
}

/// Get a class.
pub fn cls(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

// =============================================================================
// Metal Types
// =============================================================================

/// Metal pixel format.
pub const MTLPixelFormat = enum(NSUInteger) {
    invalid = 0,
    bgra8Unorm = 80,
    bgra8Unorm_sRGB = 81,
    rgba8Unorm = 70,
    rgba8Unorm_sRGB = 71,
    rgba16Float = 115,
    r8Unorm = 10,
    rg8Unorm = 30,
    _,
};

/// Metal texture usage flags (bitmask).
pub const MTLTextureUsage = struct {
    pub const unknown: NSUInteger = 0;
    pub const shader_read: NSUInteger = 1;
    pub const shader_write: NSUInteger = 2;
    pub const render_target: NSUInteger = 4;
};

/// Metal storage mode.
pub const MTLStorageMode = enum(NSUInteger) {
    shared = 0,
    managed = 1,
    private = 2,
    memoryless = 3,
};

/// Metal load action.
pub const MTLLoadAction = enum(NSUInteger) {
    dontCare = 0,
    load = 1,
    clear = 2,
};

/// Metal store action.
pub const MTLStoreAction = enum(NSUInteger) {
    dontCare = 0,
    store = 1,
    multisampleResolve = 2,
    storeAndMultisampleResolve = 3,
};

/// Metal primitive type.
pub const MTLPrimitiveType = enum(NSUInteger) {
    point = 0,
    line = 1,
    lineStrip = 2,
    triangle = 3,
    triangleStrip = 4,
};

/// Metal index type.
pub const MTLIndexType = enum(NSUInteger) {
    uint16 = 0,
    uint32 = 1,
};

/// Metal command buffer status.
pub const MTLCommandBufferStatus = enum(NSUInteger) {
    notEnqueued = 0,
    enqueued = 1,
    committed = 2,
    scheduled = 3,
    completed = 4,
    @"error" = 5,
};

/// Clear color.
pub const MTLClearColor = extern struct {
    red: f64 = 0.0,
    green: f64 = 0.0,
    blue: f64 = 0.0,
    alpha: f64 = 1.0,
};

/// Viewport.
pub const MTLViewport = extern struct {
    originX: f64 = 0.0,
    originY: f64 = 0.0,
    width: f64,
    height: f64,
    znear: f64 = 0.0,
    zfar: f64 = 1.0,
};

/// Scissor rect.
pub const MTLScissorRect = extern struct {
    x: NSUInteger = 0,
    y: NSUInteger = 0,
    width: NSUInteger,
    height: NSUInteger,
};

// =============================================================================
// Metal Wrapper Types
// =============================================================================

/// MTLDevice wrapper.
pub const Device = struct {
    ptr: id,

    /// Create a command queue.
    pub fn newCommandQueue(self: Device) ?CommandQueue {
        const result = msgSendId(self.ptr, sel("newCommandQueue"));
        return if (result) |p| CommandQueue{ .ptr = p } else null;
    }

    /// Create a buffer.
    pub fn newBufferWithLength(self: Device, length: NSUInteger) ?Buffer {
        const s = sel("newBufferWithLength:options:");
        const func: *const fn (id, SEL, NSUInteger, NSUInteger) callconv(.c) ?id = @ptrCast(&objc_msgSend);
        const result = func(self.ptr, s, length, 0); // MTLResourceStorageModeShared = 0
        return if (result) |p| Buffer{ .ptr = p } else null;
    }

    /// Create from opaque pointer.
    pub fn fromPtr(ptr: *anyopaque) Device {
        return .{ .ptr = ptr };
    }

    /// Create the system default device (headless-capable).
    pub fn createSystemDefault() ?Device {
        const p = MTLCreateSystemDefaultDevice() orelse return null;
        return .{ .ptr = p };
    }

    /// Create a buffer initialized with the given bytes (shared storage).
    pub fn newBufferWithBytes(self: Device, bytes: []const u8) ?Buffer {
        const s = sel("newBufferWithBytes:length:options:");
        const func: *const fn (id, SEL, [*]const u8, NSUInteger, NSUInteger) callconv(.c) ?id = @ptrCast(&objc_msgSend);
        const result = func(self.ptr, s, bytes.ptr, bytes.len, 0);
        return if (result) |p| Buffer{ .ptr = p } else null;
    }

    /// Create a 2D texture with explicit usage and storage mode.
    /// Used for render targets that are also read back / sampled.
    pub fn newTexture2D(
        self: Device,
        format: MTLPixelFormat,
        width: u32,
        height: u32,
        usage: NSUInteger,
        storage: MTLStorageMode,
    ) ?Texture {
        const desc_class = cls("MTLTextureDescriptor") orelse return null;
        const s = sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const func: *const fn (Class, SEL, NSUInteger, NSUInteger, NSUInteger, BOOL) callconv(.c) ?id =
            @ptrCast(&objc_msgSend);
        const desc = func(desc_class, s, @intFromEnum(format), width, height, false) orelse return null;

        // desc.setUsage(usage)
        const set_usage: *const fn (id, SEL, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        set_usage(desc, sel("setUsage:"), usage);
        // desc.setStorageMode(storage)
        const set_storage: *const fn (id, SEL, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        set_storage(desc, sel("setStorageMode:"), @intFromEnum(storage));

        const tex = msgSendId1(self.ptr, sel("newTextureWithDescriptor:"), desc) orelse return null;
        return .{ .ptr = tex };
    }

    /// Compile a Metal shader library from MSL source text. Returns null on
    /// compile failure (the NSError is discarded — callers treat null as
    /// "shader did not compile").
    pub fn newLibraryWithSource(self: Device, source: [*:0]const u8) ?Library {
        const src = nsString(source) orelse return null;
        const s = sel("newLibraryWithSource:options:error:");
        var err: ?id = null;
        const func: *const fn (id, SEL, id, ?id, *?id) callconv(.c) ?id = @ptrCast(&objc_msgSend);
        const lib = func(self.ptr, s, src, null, &err) orelse return null;
        return .{ .ptr = lib };
    }

    /// Create a render pipeline state from a descriptor. Returns null on
    /// failure.
    pub fn newRenderPipelineState(self: Device, desc: RenderPipelineDescriptor) ?RenderPipelineState {
        const s = sel("newRenderPipelineStateWithDescriptor:error:");
        var err: ?id = null;
        const func: *const fn (id, SEL, id, *?id) callconv(.c) ?id = @ptrCast(&objc_msgSend);
        const pso = func(self.ptr, s, desc.ptr, &err) orelse return null;
        return .{ .ptr = pso };
    }
};

/// MTLLibrary wrapper.
pub const Library = struct {
    ptr: id,

    /// Look up a function by name.
    pub fn newFunction(self: Library, name: [*:0]const u8) ?Function {
        const ns = nsString(name) orelse return null;
        const f = msgSendId1(self.ptr, sel("newFunctionWithName:"), ns) orelse return null;
        return .{ .ptr = f };
    }

    pub fn release(self: Library) void {
        msgSendVoid(self.ptr, sel("release"));
    }
};

/// MTLFunction wrapper.
pub const Function = struct {
    ptr: id,

    pub fn release(self: Function) void {
        msgSendVoid(self.ptr, sel("release"));
    }
};

/// MTLRenderPipelineState wrapper (opaque; bound on an encoder).
pub const RenderPipelineState = struct {
    ptr: id,

    pub fn release(self: RenderPipelineState) void {
        msgSendVoid(self.ptr, sel("release"));
    }
};

/// MTLRenderPipelineDescriptor wrapper.
pub const RenderPipelineDescriptor = struct {
    ptr: id,

    pub fn create() ?RenderPipelineDescriptor {
        const class = cls("MTLRenderPipelineDescriptor") orelse return null;
        const obj = msgSendId(class, sel("alloc")) orelse return null;
        const inited = msgSendId(obj, sel("init")) orelse return null;
        return .{ .ptr = inited };
    }

    pub fn setVertexFunction(self: RenderPipelineDescriptor, func: Function) void {
        const s = sel("setVertexFunction:");
        const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
        f(self.ptr, s, func.ptr);
    }

    pub fn setFragmentFunction(self: RenderPipelineDescriptor, func: Function) void {
        const s = sel("setFragmentFunction:");
        const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
        f(self.ptr, s, func.ptr);
    }

    /// Set the pixel format of color attachment 0.
    pub fn setColorFormat0(self: RenderPipelineDescriptor, format: MTLPixelFormat) void {
        const arr = msgSendId(self.ptr, sel("colorAttachments")) orelse return;
        const s_idx = sel("objectAtIndexedSubscript:");
        const idx_func: *const fn (id, SEL, NSUInteger) callconv(.c) ?id = @ptrCast(&objc_msgSend);
        const att = idx_func(arr, s_idx, 0) orelse return;
        const s_fmt = sel("setPixelFormat:");
        const fmt_func: *const fn (id, SEL, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        fmt_func(att, s_fmt, @intFromEnum(format));
    }

    pub fn release(self: RenderPipelineDescriptor) void {
        msgSendVoid(self.ptr, sel("release"));
    }
};

/// MTLCommandQueue wrapper.
pub const CommandQueue = struct {
    ptr: id,

    /// Create a command buffer.
    pub fn commandBuffer(self: CommandQueue) ?CommandBuffer {
        const result = msgSendId(self.ptr, sel("commandBuffer"));
        return if (result) |p| CommandBuffer{ .ptr = p } else null;
    }

    pub fn fromPtr(ptr: *anyopaque) CommandQueue {
        return .{ .ptr = ptr };
    }
};

/// MTLCommandBuffer wrapper.
pub const CommandBuffer = struct {
    ptr: id,

    /// Create a render command encoder.
    pub fn renderCommandEncoderWithDescriptor(self: CommandBuffer, desc: RenderPassDescriptor) ?RenderCommandEncoder {
        const result = msgSendId1(self.ptr, sel("renderCommandEncoderWithDescriptor:"), desc.ptr);
        return if (result) |p| RenderCommandEncoder{ .ptr = p } else null;
    }

    /// Create a blit command encoder.
    pub fn blitCommandEncoder(self: CommandBuffer) ?BlitCommandEncoder {
        const result = msgSendId(self.ptr, sel("blitCommandEncoder"));
        return if (result) |p| BlitCommandEncoder{ .ptr = p } else null;
    }

    /// Present a drawable.
    pub fn presentDrawable(self: CommandBuffer, drawable: Drawable) void {
        const s = sel("presentDrawable:");
        const func: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, drawable.ptr);
    }

    /// Commit the command buffer.
    pub fn commit(self: CommandBuffer) void {
        msgSendVoid(self.ptr, sel("commit"));
    }

    /// Wait until completed.
    pub fn waitUntilCompleted(self: CommandBuffer) void {
        msgSendVoid(self.ptr, sel("waitUntilCompleted"));
    }

    /// Get status.
    pub fn status(self: CommandBuffer) MTLCommandBufferStatus {
        const s = sel("status");
        const func: *const fn (id, SEL) callconv(.c) NSUInteger = @ptrCast(&objc_msgSend);
        return @enumFromInt(func(self.ptr, s));
    }
};

/// MTLRenderPassDescriptor wrapper.
pub const RenderPassDescriptor = struct {
    ptr: id,

    /// Create a new render pass descriptor.
    pub fn create() ?RenderPassDescriptor {
        const class = cls("MTLRenderPassDescriptor") orelse return null;
        const result = msgSendId(class, sel("renderPassDescriptor"));
        return if (result) |p| RenderPassDescriptor{ .ptr = p } else null;
    }

    /// Get color attachments.
    pub fn colorAttachments(self: RenderPassDescriptor) ?ColorAttachmentArray {
        const result = msgSendId(self.ptr, sel("colorAttachments"));
        return if (result) |p| ColorAttachmentArray{ .ptr = p } else null;
    }
};

/// Color attachment array.
pub const ColorAttachmentArray = struct {
    ptr: id,

    /// Get attachment at index.
    pub fn objectAtIndex(self: ColorAttachmentArray, index: NSUInteger) ?ColorAttachment {
        const s = sel("objectAtIndexedSubscript:");
        const func: *const fn (id, SEL, NSUInteger) callconv(.c) ?id = @ptrCast(&objc_msgSend);
        const result = func(self.ptr, s, index);
        return if (result) |p| ColorAttachment{ .ptr = p } else null;
    }
};

/// Color attachment.
pub const ColorAttachment = struct {
    ptr: id,

    /// Set texture.
    pub fn setTexture(self: ColorAttachment, texture: ?id) void {
        const s = sel("setTexture:");
        const func: *const fn (id, SEL, ?id) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, texture);
    }

    /// Set load action.
    pub fn setLoadAction(self: ColorAttachment, action: MTLLoadAction) void {
        const s = sel("setLoadAction:");
        const func: *const fn (id, SEL, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, @intFromEnum(action));
    }

    /// Set store action.
    pub fn setStoreAction(self: ColorAttachment, action: MTLStoreAction) void {
        const s = sel("setStoreAction:");
        const func: *const fn (id, SEL, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, @intFromEnum(action));
    }

    /// Set clear color.
    pub fn setClearColor(self: ColorAttachment, color: MTLClearColor) void {
        const s = sel("setClearColor:");
        const func: *const fn (id, SEL, MTLClearColor) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, color);
    }
};

/// MTLRenderCommandEncoder wrapper.
pub const RenderCommandEncoder = struct {
    ptr: id,

    /// Set viewport.
    pub fn setViewport(self: RenderCommandEncoder, viewport: MTLViewport) void {
        const s = sel("setViewport:");
        const func: *const fn (id, SEL, MTLViewport) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, viewport);
    }

    /// Set scissor rect.
    pub fn setScissorRect(self: RenderCommandEncoder, rect: MTLScissorRect) void {
        const s = sel("setScissorRect:");
        const func: *const fn (id, SEL, MTLScissorRect) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, rect);
    }

    /// Set render pipeline state.
    pub fn setRenderPipelineState(self: RenderCommandEncoder, pipeline: id) void {
        const s = sel("setRenderPipelineState:");
        const func: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, pipeline);
    }

    /// Set inline vertex bytes (small data, ≤4KB, no separate MTLBuffer).
    pub fn setVertexBytes(self: RenderCommandEncoder, bytes: [*]const u8, len: NSUInteger, index: NSUInteger) void {
        const s = sel("setVertexBytes:length:atIndex:");
        const func: *const fn (id, SEL, [*]const u8, NSUInteger, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, bytes, len, index);
    }

    /// Set inline fragment bytes (small uniforms, ≤4KB).
    pub fn setFragmentBytes(self: RenderCommandEncoder, bytes: [*]const u8, len: NSUInteger, index: NSUInteger) void {
        const s = sel("setFragmentBytes:length:atIndex:");
        const func: *const fn (id, SEL, [*]const u8, NSUInteger, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, bytes, len, index);
    }

    /// Set vertex buffer.
    pub fn setVertexBuffer(self: RenderCommandEncoder, buffer: ?Buffer, offset: NSUInteger, index: NSUInteger) void {
        const s = sel("setVertexBuffer:offset:atIndex:");
        const func: *const fn (id, SEL, ?id, NSUInteger, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, if (buffer) |b| b.ptr else null, offset, index);
    }

    /// Set fragment buffer.
    pub fn setFragmentBuffer(self: RenderCommandEncoder, buffer: ?Buffer, offset: NSUInteger, index: NSUInteger) void {
        const s = sel("setFragmentBuffer:offset:atIndex:");
        const func: *const fn (id, SEL, ?id, NSUInteger, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, if (buffer) |b| b.ptr else null, offset, index);
    }

    /// Set fragment texture.
    pub fn setFragmentTexture(self: RenderCommandEncoder, texture: ?id, index: NSUInteger) void {
        const s = sel("setFragmentTexture:atIndex:");
        const func: *const fn (id, SEL, ?id, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, texture, index);
    }

    /// Draw primitives.
    pub fn drawPrimitives(self: RenderCommandEncoder, ptype: MTLPrimitiveType, start: NSUInteger, count: NSUInteger) void {
        const s = sel("drawPrimitives:vertexStart:vertexCount:");
        const func: *const fn (id, SEL, NSUInteger, NSUInteger, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, @intFromEnum(ptype), start, count);
    }

    /// Draw indexed primitives.
    pub fn drawIndexedPrimitives(
        self: RenderCommandEncoder,
        ptype: MTLPrimitiveType,
        count: NSUInteger,
        indexType: MTLIndexType,
        indexBuffer: Buffer,
        indexOffset: NSUInteger,
    ) void {
        const s = sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:");
        const func: *const fn (id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, @intFromEnum(ptype), count, @intFromEnum(indexType), indexBuffer.ptr, indexOffset);
    }

    /// End encoding.
    pub fn endEncoding(self: RenderCommandEncoder) void {
        msgSendVoid(self.ptr, sel("endEncoding"));
    }
};

/// MTLBuffer wrapper.
pub const Buffer = struct {
    ptr: id,

    /// Get buffer contents.
    pub fn contents(self: Buffer) ?[*]u8 {
        const result = msgSendId(self.ptr, sel("contents"));
        return @ptrCast(result);
    }

    /// Get buffer length.
    pub fn length(self: Buffer) NSUInteger {
        const s = sel("length");
        const func: *const fn (id, SEL) callconv(.c) NSUInteger = @ptrCast(&objc_msgSend);
        return func(self.ptr, s);
    }
};

/// CAMetalDrawable wrapper.
pub const Drawable = struct {
    ptr: id,

    /// Get the texture.
    pub fn texture(self: Drawable) ?id {
        return msgSendId(self.ptr, sel("texture"));
    }
};

/// CAMetalLayer wrapper.
pub const MetalLayer = struct {
    ptr: id,

    /// Get next drawable.
    pub fn nextDrawable(self: MetalLayer) ?Drawable {
        const result = msgSendId(self.ptr, sel("nextDrawable"));
        return if (result) |p| Drawable{ .ptr = p } else null;
    }

    /// Set device.
    pub fn setDevice(self: MetalLayer, device: Device) void {
        const s = sel("setDevice:");
        const func: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, device.ptr);
    }

    /// Set pixel format.
    pub fn setPixelFormat(self: MetalLayer, format: MTLPixelFormat) void {
        const s = sel("setPixelFormat:");
        const func: *const fn (id, SEL, NSUInteger) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, @intFromEnum(format));
    }

    /// Set drawable size.
    pub fn setDrawableSize(self: MetalLayer, width: f64, height: f64) void {
        const Size = extern struct { width: f64, height: f64 };
        const s = sel("setDrawableSize:");
        const func: *const fn (id, SEL, Size) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, .{ .width = width, .height = height });
    }

    pub fn fromPtr(ptr: *anyopaque) MetalLayer {
        return .{ .ptr = ptr };
    }
};

// =============================================================================
// Textures & Blit
// =============================================================================

pub const MTLOrigin = extern struct {
    x: NSUInteger = 0,
    y: NSUInteger = 0,
    z: NSUInteger = 0,
};

pub const MTLSize = extern struct {
    width: NSUInteger,
    height: NSUInteger,
    depth: NSUInteger = 1,
};

pub const MTLRegion = extern struct {
    origin: MTLOrigin = .{},
    size: MTLSize,
};

/// MTLTexture wrapper.
pub const Texture = struct {
    ptr: id,

    /// Upload pixel data into the texture.
    pub fn replaceRegion(
        self: Texture,
        region: MTLRegion,
        mipmap_level: NSUInteger,
        bytes: [*]const u8,
        bytes_per_row: NSUInteger,
    ) void {
        const s = sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
        const func: *const fn (
            id,
            SEL,
            MTLRegion,
            NSUInteger,
            [*]const u8,
            NSUInteger,
        ) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, region, mipmap_level, bytes, bytes_per_row);
    }

    /// Read pixel data out of the texture into a host buffer.
    pub fn getBytes(
        self: Texture,
        out: [*]u8,
        bytes_per_row: NSUInteger,
        region: MTLRegion,
        mipmap_level: NSUInteger,
    ) void {
        const s = sel("getBytes:bytesPerRow:fromRegion:mipmapLevel:");
        const func: *const fn (id, SEL, [*]u8, NSUInteger, MTLRegion, NSUInteger) callconv(.c) void =
            @ptrCast(&objc_msgSend);
        func(self.ptr, s, out, bytes_per_row, region, mipmap_level);
    }

    pub fn release(self: Texture) void {
        msgSendVoid(self.ptr, sel("release"));
    }
};

/// Create a 2D texture on the device.
pub fn createTexture2D(device: Device, format: MTLPixelFormat, width: u32, height: u32) ?Texture {
    const desc_class = cls("MTLTextureDescriptor") orelse return null;
    const s = sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
    const func: *const fn (
        Class,
        SEL,
        NSUInteger,
        NSUInteger,
        NSUInteger,
        BOOL,
    ) callconv(.c) ?id = @ptrCast(&objc_msgSend);
    const desc = func(desc_class, s, @intFromEnum(format), width, height, false) orelse
        return null;

    const tex = msgSendId1(device.ptr, sel("newTextureWithDescriptor:"), desc) orelse
        return null;
    return .{ .ptr = tex };
}

/// MTLBlitCommandEncoder wrapper.
pub const BlitCommandEncoder = struct {
    ptr: id,

    pub fn copyTexture(
        self: BlitCommandEncoder,
        src: id,
        src_origin: MTLOrigin,
        src_size: MTLSize,
        dst: id,
        dst_origin: MTLOrigin,
    ) void {
        const s = sel("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:" ++
            "toTexture:destinationSlice:destinationLevel:destinationOrigin:");
        const func: *const fn (
            id,
            SEL,
            id,
            NSUInteger,
            NSUInteger,
            MTLOrigin,
            MTLSize,
            id,
            NSUInteger,
            NSUInteger,
            MTLOrigin,
        ) callconv(.c) void = @ptrCast(&objc_msgSend);
        func(self.ptr, s, src, 0, 0, src_origin, src_size, dst, 0, 0, dst_origin);
    }

    pub fn endEncoding(self: BlitCommandEncoder) void {
        msgSendVoid(self.ptr, sel("endEncoding"));
    }
};

// =============================================================================
// Frame Renderer
// =============================================================================

/// Frame renderer for encoding Metal commands.
pub const FrameRenderer = struct {
    device: Device,
    queue: CommandQueue,
    layer: MetalLayer,

    /// Cached staging texture for framebuffer uploads.
    fb_texture: ?Texture = null,
    fb_width: u32 = 0,
    fb_height: u32 = 0,

    /// Initialize with opaque pointers from Swift.
    pub fn init(
        mtl_device: *anyopaque,
        mtl_layer: *anyopaque,
        mtl_queue: *anyopaque,
    ) FrameRenderer {
        return .{
            .device = Device.fromPtr(mtl_device),
            .queue = CommandQueue.fromPtr(mtl_queue),
            .layer = MetalLayer.fromPtr(mtl_layer),
        };
    }

    pub fn deinit(self: *FrameRenderer) void {
        if (self.fb_texture) |tex| tex.release();
        self.fb_texture = null;
    }

    /// Render a frame with the given clear color.
    /// Returns true if frame was successfully rendered.
    pub fn renderFrame(self: *FrameRenderer, clear_color: MTLClearColor) bool {
        // Autorelease pool to prevent Metal object leaks
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // Get next drawable
        const drawable = self.layer.nextDrawable() orelse return false;
        const texture = drawable.texture() orelse return false;

        // Create command buffer
        const cmd_buffer = self.queue.commandBuffer() orelse return false;

        // Create render pass descriptor
        const pass_desc = RenderPassDescriptor.create() orelse return false;
        const color_attachments = pass_desc.colorAttachments() orelse return false;
        const attachment = color_attachments.objectAtIndex(0) orelse return false;

        attachment.setTexture(texture);
        attachment.setLoadAction(.clear);
        attachment.setStoreAction(.store);
        attachment.setClearColor(clear_color);

        // Create render encoder
        const encoder = cmd_buffer.renderCommandEncoderWithDescriptor(pass_desc) orelse return false;

        // TODO: Encode actual draw commands from GPU context
        // For now, just clear the screen

        encoder.endEncoding();

        // Present and commit
        cmd_buffer.presentDrawable(drawable);
        cmd_buffer.commit();

        return true;
    }

    /// Render a frame with framebuffer data (2D scanout).
    /// Uploads the BGRA pixels to a staging texture and blits it to the
    /// drawable. The layer's drawable size is pinned to the framebuffer
    /// size; CoreAnimation scales it to the view.
    pub fn renderFramebuffer(
        self: *FrameRenderer,
        data: []const u8,
        width: u32,
        height: u32,
    ) bool {
        assert(width > 0 and height > 0);
        assert(data.len >= @as(usize, width) * height * 4);

        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);

        // (Re)create the staging texture on size change.
        if (self.fb_texture == null or self.fb_width != width or self.fb_height != height) {
            if (self.fb_texture) |tex| tex.release();
            self.fb_texture = createTexture2D(self.device, .bgra8Unorm, width, height) orelse
                return false;
            self.fb_width = width;
            self.fb_height = height;
            self.layer.setDrawableSize(@floatFromInt(width), @floatFromInt(height));
        }
        const fb_tex = self.fb_texture.?;

        // Upload pixels.
        fb_tex.replaceRegion(
            .{ .size = .{ .width = width, .height = height } },
            0,
            data.ptr,
            @as(NSUInteger, width) * 4,
        );

        // Blit to the drawable.
        const drawable = self.layer.nextDrawable() orelse return false;
        const dst_texture = drawable.texture() orelse return false;
        const cmd_buffer = self.queue.commandBuffer() orelse return false;
        const blit = cmd_buffer.blitCommandEncoder() orelse return false;

        blit.copyTexture(
            fb_tex.ptr,
            .{},
            .{ .width = width, .height = height },
            dst_texture,
            .{},
        );
        blit.endEncoding();

        cmd_buffer.presentDrawable(drawable);
        cmd_buffer.commit();

        return true;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MTLClearColor default" {
    const color = MTLClearColor{};
    try std.testing.expectEqual(@as(f64, 0.0), color.red);
    try std.testing.expectEqual(@as(f64, 1.0), color.alpha);
}

test "MTLViewport size" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(MTLViewport));
}

test "MTLPixelFormat values" {
    try std.testing.expectEqual(@as(NSUInteger, 80), @intFromEnum(MTLPixelFormat.bgra8Unorm));
}
