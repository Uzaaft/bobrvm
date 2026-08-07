//! Decode-only 3D backend for hosts without the macOS Metal renderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ResourceTarget = @import("virgl/context.zig").ResourceTarget;
const Format = @import("virgl/protocol.zig").Format;

pub const stats = struct {
    pub var tex_uploads_ok: u64 = 0;
    pub var tex_uploads_fail: u64 = 0;

    pub fn on() bool {
        return false;
    }
};

pub const Resource = struct {
    handle: u32,
    target: ResourceTarget,
    format: Format,
    width: u32,
    height: u32,
    depth: u32,
    array_size: u32,
    last_level: u32,
    nr_samples: u32,
    flags: u32,
    bind: u32,
};

pub const GpuDevice = struct {
    alloc: Allocator,
    contexts: std.AutoHashMap(u32, void),
    resources: std.AutoHashMap(u32, Resource),
    renderer: ?void = null,

    pub const Error = Allocator.Error;

    pub fn init(alloc: Allocator) GpuDevice {
        return .{
            .alloc = alloc,
            .contexts = std.AutoHashMap(u32, void).init(alloc),
            .resources = std.AutoHashMap(u32, Resource).init(alloc),
        };
    }

    pub fn deinit(self: *GpuDevice) void {
        self.contexts.deinit();
        self.resources.deinit();
    }

    pub fn createContextId(self: *GpuDevice, id: u32) Error!void {
        try self.contexts.put(id, {});
    }

    pub fn destroyContextId(self: *GpuDevice, id: u32) void {
        _ = self.contexts.remove(id);
    }

    pub fn createResourceRecord(self: *GpuDevice, resource: Resource) Error!void {
        try self.resources.put(resource.handle, resource);
    }

    pub fn getResource(self: *GpuDevice, handle: u32) ?*Resource {
        return self.resources.getPtr(handle);
    }

    pub fn submit(self: *GpuDevice, context_id: u32, commands: []const u8) Error!void {
        _ = self;
        _ = context_id;
        _ = commands;
    }

    pub fn uploadToTextureRegion(
        self: *GpuDevice,
        handle: u32,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        data: []const u8,
        bytes_per_row: u32,
    ) bool {
        _ = self;
        _ = handle;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = data;
        _ = bytes_per_row;
        return false;
    }

    pub fn bufferContents(self: *GpuDevice, handle: u32) ?[]u8 {
        _ = self;
        _ = handle;
        return null;
    }

    pub fn readbackResource(self: *GpuDevice, handle: u32, output: []u8) bool {
        _ = self;
        _ = handle;
        _ = output;
        return false;
    }

    pub fn scanoutSurfaceRef(self: *GpuDevice, handle: u32) ?*anyopaque {
        _ = self;
        _ = handle;
        return null;
    }
};
