//! Linux virgl execution backend.
//!
//! The virtio device owns protocol validation and guest-memory access. This
//! module owns only virglrenderer objects and its surfaceless EGL context.

pub const GpuDevice = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const ResourceTarget = @import("virgl/context.zig").ResourceTarget;
const Format = @import("virgl/protocol.zig").Format;

const log = std.log.scoped(.virglrenderer);

const renderer_use_egl: c_int = 1;
const renderer_use_surfaceless: c_int = 1 << 3;
const callbacks_version: c_int = 1;

pub const stats = struct {
    pub var tex_uploads_ok: u64 = 0;
    pub var tex_uploads_fail: u64 = 0;

    pub fn on() bool {
        return false;
    }
};

const Callbacks = extern struct {
    version: c_int,
    write_fence: ?*const fn (?*anyopaque, u32) callconv(.c) void,
    create_gl_context: ?*anyopaque = null,
    destroy_gl_context: ?*anyopaque = null,
    make_current: ?*anyopaque = null,
    get_drm_fd: ?*anyopaque = null,
    write_context_fence: ?*anyopaque = null,
    get_server_fd: ?*anyopaque = null,
    get_egl_display: ?*anyopaque = null,
};

const CreateArgs = extern struct {
    handle: u32,
    target: u32,
    format: u32,
    bind: u32,
    width: u32,
    height: u32,
    depth: u32,
    array_size: u32,
    last_level: u32,
    nr_samples: u32,
    flags: u32,
};

const Box = extern struct {
    x: u32,
    y: u32,
    z: u32,
    w: u32,
    h: u32,
    d: u32,
};

const Iovec = extern struct {
    base: ?[*]u8,
    len: usize,
};

extern "c" fn virgl_renderer_init(
    cookie: ?*anyopaque,
    flags: c_int,
    callbacks: *Callbacks,
) callconv(.c) c_int;
extern "c" fn virgl_renderer_cleanup(cookie: ?*anyopaque) callconv(.c) void;
extern "c" fn virgl_renderer_context_create(
    handle: u32,
    name_len: u32,
    name: [*]const u8,
) callconv(.c) c_int;
extern "c" fn virgl_renderer_context_destroy(handle: u32) callconv(.c) void;
extern "c" fn virgl_renderer_resource_create(
    args: *CreateArgs,
    iov: ?[*]Iovec,
    iov_count: u32,
) callconv(.c) c_int;
extern "c" fn virgl_renderer_resource_unref(handle: u32) callconv(.c) void;
extern "c" fn virgl_renderer_resource_attach_iov(
    handle: c_int,
    iov: [*]Iovec,
    iov_count: c_int,
) callconv(.c) c_int;
extern "c" fn virgl_renderer_resource_detach_iov(
    handle: c_int,
    iov: ?*?[*]Iovec,
    iov_count: ?*c_int,
) callconv(.c) void;
extern "c" fn virgl_renderer_submit_cmd(
    buffer: *anyopaque,
    context_id: c_int,
    dword_count: c_int,
) callconv(.c) c_int;
extern "c" fn virgl_renderer_transfer_write_iov(
    handle: u32,
    context_id: u32,
    level: c_int,
    stride: u32,
    layer_stride: u32,
    box: *Box,
    offset: u64,
    iov: ?[*]Iovec,
    iov_count: u32,
) callconv(.c) c_int;
extern "c" fn virgl_renderer_transfer_read_iov(
    handle: u32,
    context_id: u32,
    level: u32,
    stride: u32,
    layer_stride: u32,
    box: *Box,
    offset: u64,
    iov: *Iovec,
    iov_count: c_int,
) callconv(.c) c_int;
extern "c" fn virgl_renderer_ctx_attach_resource(
    context_id: c_int,
    handle: c_int,
) callconv(.c) void;
extern "c" fn virgl_renderer_ctx_detach_resource(
    context_id: c_int,
    handle: c_int,
) callconv(.c) void;
extern "c" fn virgl_renderer_poll() callconv(.c) void;
extern "c" fn virgl_renderer_get_cap_set(
    id: u32,
    max_version: *u32,
    max_size: *u32,
) callconv(.c) void;
extern "c" fn virgl_renderer_fill_caps(
    id: u32,
    version: u32,
    caps: *anyopaque,
) callconv(.c) void;
extern "c" fn virgl_set_log_callback(
    callback: *const fn (u32, [*:0]const u8, ?*anyopaque) callconv(.c) void,
    userdata: ?*anyopaque,
    free_callback: ?*anyopaque,
) callconv(.c) void;

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
    backing: ?[]align(@alignOf(u64)) u8 = null,
    iov: ?*Iovec = null,
    guest_iovs: ?[]Iovec = null,
};

alloc: Allocator,
contexts: std.AutoHashMap(u32, void),
resources: std.AutoHashMap(u32, Resource),
/// Requested by the VM configuration. The actual renderer is initialized
/// lazily on the vCPU thread that executes all guest GPU commands.
renderer: ?void,
host_active: bool,

pub const Error = Allocator.Error || error{
    InvalidCommand,
    RendererFailure,
};

var host_mutex: std.Io.Mutex = .init;
var host_claimed = false;
var host_cookie: u8 = 0;
var callbacks = Callbacks{
    .version = callbacks_version,
    .write_fence = writeFence,
};

pub fn initWithAcceleration(alloc: Allocator, enabled: bool) GpuDevice {
    return .{
        .alloc = alloc,
        .contexts = std.AutoHashMap(u32, void).init(alloc),
        .resources = std.AutoHashMap(u32, Resource).init(alloc),
        .renderer = if (enabled) {} else null,
        .host_active = false,
    };
}

pub fn deinit(self: *GpuDevice) void {
    var contexts = self.contexts.keyIterator();
    while (contexts.next()) |id| {
        if (self.host_active) virgl_renderer_context_destroy(id.*);
    }
    self.contexts.deinit();

    var resources = self.resources.valueIterator();
    while (resources.next()) |resource| {
        if (self.host_active) {
            if (resource.guest_iovs != null) {
                virgl_renderer_resource_detach_iov(
                    @intCast(resource.handle),
                    null,
                    null,
                );
            }
            virgl_renderer_resource_unref(resource.handle);
        }
        if (resource.guest_iovs) |iovs| self.alloc.free(iovs);
        if (resource.iov) |iov| self.alloc.destroy(iov);
        if (resource.backing) |backing| self.alloc.free(backing);
    }
    self.resources.deinit();
    if (self.host_active) releaseHost();
    self.host_active = false;
    self.renderer = null;
}

pub fn supportsAcceleration(self: *const GpuDevice) bool {
    return self.renderer != null;
}

pub const Capset = struct {
    max_version: u32,
    max_size: u32,
};

pub fn getCapset(self: *GpuDevice, id: u32) Capset {
    if (!self.ensureRenderer()) return .{ .max_version = 0, .max_size = 0 };
    var max_version: u32 = 0;
    var max_size: u32 = 0;
    virgl_renderer_get_cap_set(id, &max_version, &max_size);
    return .{ .max_version = max_version, .max_size = max_size };
}

pub fn fillCaps(self: *GpuDevice, id: u32, version: u32, output: []u8) void {
    if (!self.ensureRenderer()) return;
    virgl_renderer_fill_caps(id, version, output.ptr);
}

pub fn createContextId(self: *GpuDevice, id: u32) Error!void {
    if (self.contexts.contains(id)) return;
    if (!self.ensureRenderer()) return error.RendererFailure;
    const name = "bobrvm";
    if (virgl_renderer_context_create(id, name.len, name) != 0) {
        return error.RendererFailure;
    }
    errdefer virgl_renderer_context_destroy(id);
    try self.contexts.put(id, {});
}

pub fn destroyContextId(self: *GpuDevice, id: u32) void {
    if (self.contexts.remove(id)) virgl_renderer_context_destroy(id);
}

pub fn hasContext(self: *const GpuDevice, id: u32) bool {
    return self.contexts.contains(id);
}

pub fn createResourceRecord(self: *GpuDevice, resource: Resource) Error!void {
    if (!self.ensureRenderer()) return error.RendererFailure;
    self.removeResource(resource.handle);

    var owned = resource;
    errdefer {
        if (owned.iov) |iov| self.alloc.destroy(iov);
        if (owned.backing) |backing| self.alloc.free(backing);
    }
    if (resource.target == .buffer) {
        const backing = try self.alloc.alignedAlloc(u8, .of(u64), resource.width);
        @memset(backing, 0);
        owned.backing = backing;
        const iov = try self.alloc.create(Iovec);
        iov.* = .{ .base = backing.ptr, .len = backing.len };
        owned.iov = iov;
    }

    var args = CreateArgs{
        .handle = resource.handle,
        .target = @intFromEnum(resource.target),
        .format = @intFromEnum(resource.format),
        .bind = resource.bind,
        .width = resource.width,
        .height = resource.height,
        .depth = resource.depth,
        .array_size = resource.array_size,
        .last_level = resource.last_level,
        .nr_samples = resource.nr_samples,
        .flags = resource.flags,
    };
    const iov_count: u32 = if (owned.iov != null) 1 else 0;
    const iov_pointer: ?[*]Iovec = if (owned.iov) |iov| @ptrCast(iov) else null;
    if (virgl_renderer_resource_create(&args, iov_pointer, iov_count) != 0) {
        return error.RendererFailure;
    }
    errdefer virgl_renderer_resource_unref(resource.handle);
    try self.resources.put(resource.handle, owned);
}

pub fn removeResource(self: *GpuDevice, handle: u32) void {
    const removed = self.resources.fetchRemove(handle) orelse return;
    if (removed.value.guest_iovs != null) {
        virgl_renderer_resource_detach_iov(@intCast(handle), null, null);
    }
    virgl_renderer_resource_unref(handle);
    if (removed.value.guest_iovs) |iovs| self.alloc.free(iovs);
    if (removed.value.iov) |iov| self.alloc.destroy(iov);
    if (removed.value.backing) |backing| self.alloc.free(backing);
}

pub fn getResource(self: *GpuDevice, handle: u32) ?*Resource {
    return self.resources.getPtr(handle);
}

pub fn attachResource(self: *GpuDevice, context_id: u32, handle: u32) void {
    if (!self.contexts.contains(context_id) or !self.resources.contains(handle)) return;
    virgl_renderer_ctx_attach_resource(@intCast(context_id), @intCast(handle));
}

pub fn detachResource(self: *GpuDevice, context_id: u32, handle: u32) void {
    if (!self.contexts.contains(context_id) or !self.resources.contains(handle)) return;
    virgl_renderer_ctx_detach_resource(@intCast(context_id), @intCast(handle));
}

/// Make guest-owned backing visible to virglrenderer. The guest RAM mappings
/// remain stable for the VM lifetime; only the iovec array is owned here.
pub fn attachBacking(
    self: *GpuDevice,
    handle: u32,
    entries: anytype,
    get_mem: anytype,
) Error!void {
    const resource = self.resources.getPtr(handle) orelse return error.InvalidCommand;
    if (entries.len == 0 or entries.len > std.math.maxInt(c_int)) {
        return error.InvalidCommand;
    }

    const iovs = try self.alloc.alloc(Iovec, entries.len);
    errdefer self.alloc.free(iovs);
    for (entries, iovs) |entry, *iov| {
        const memory = get_mem.get(entry.addr, entry.length) orelse return error.InvalidCommand;
        iov.* = .{ .base = memory.ptr, .len = memory.len };
    }

    if (resource.guest_iovs != null or resource.iov != null) {
        virgl_renderer_resource_detach_iov(@intCast(handle), null, null);
    }
    if (virgl_renderer_resource_attach_iov(
        @intCast(handle),
        iovs.ptr,
        @intCast(iovs.len),
    ) != 0) {
        if (resource.iov) |iov| {
            _ = virgl_renderer_resource_attach_iov(@intCast(handle), @ptrCast(iov), 1);
        }
        return error.RendererFailure;
    }

    if (resource.guest_iovs) |old| self.alloc.free(old);
    resource.guest_iovs = iovs;
}

pub fn detachBacking(self: *GpuDevice, handle: u32) void {
    const resource = self.resources.getPtr(handle) orelse return;
    const iovs = resource.guest_iovs orelse return;
    virgl_renderer_resource_detach_iov(@intCast(handle), null, null);
    self.alloc.free(iovs);
    resource.guest_iovs = null;
}

pub fn transferToHost(
    self: *GpuDevice,
    handle: u32,
    context_id: u32,
    level: u32,
    stride: u32,
    layer_stride: u32,
    box_value: anytype,
    offset: u64,
) bool {
    const resource = self.resources.get(handle) orelse return false;
    if (resource.guest_iovs == null) return false;
    var box = Box{
        .x = box_value.x,
        .y = box_value.y,
        .z = box_value.z,
        .w = box_value.w,
        .h = box_value.h,
        .d = box_value.d,
    };
    return virgl_renderer_transfer_write_iov(
        handle,
        context_id,
        @intCast(level),
        stride,
        layer_stride,
        &box,
        offset,
        null,
        0,
    ) == 0;
}

pub fn submit(self: *GpuDevice, context_id: u32, commands: []const u8) Error!void {
    if (!self.contexts.contains(context_id)) return error.InvalidCommand;
    if (commands.len == 0 or commands.len % 4 != 0) return error.InvalidCommand;
    if (commands.len / 4 > std.math.maxInt(c_int)) return error.InvalidCommand;
    const dword_count: c_int = @intCast(commands.len / 4);

    if (@intFromPtr(commands.ptr) % 4 == 0) {
        const buffer: *anyopaque = @ptrCast(@constCast(commands.ptr));
        if (virgl_renderer_submit_cmd(buffer, @intCast(context_id), dword_count) != 0) {
            return error.RendererFailure;
        }
        return;
    }

    const aligned = try self.alloc.alignedAlloc(u8, .of(u32), commands.len);
    defer self.alloc.free(aligned);
    @memcpy(aligned, commands);
    if (virgl_renderer_submit_cmd(aligned.ptr, @intCast(context_id), dword_count) != 0) {
        return error.RendererFailure;
    }
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
    const resource = self.resources.get(handle) orelse return false;
    if (resource.target == .buffer or width == 0 or height == 0) return false;
    const required = std.math.mul(usize, bytes_per_row, height) catch return false;
    const layer_stride = std.math.mul(u32, bytes_per_row, height) catch return false;
    if (required > data.len) return false;

    var box = Box{ .x = x, .y = y, .z = 0, .w = width, .h = height, .d = 1 };
    var iov = Iovec{ .base = @constCast(data.ptr), .len = required };
    return virgl_renderer_transfer_write_iov(
        handle,
        0,
        0,
        bytes_per_row,
        layer_stride,
        &box,
        0,
        &iov,
        1,
    ) == 0;
}

pub fn bufferContents(self: *GpuDevice, handle: u32) ?[]u8 {
    const resource = self.resources.getPtr(handle) orelse return null;
    return resource.backing;
}

pub fn readbackResource(self: *GpuDevice, handle: u32, output: []u8) bool {
    const resource = self.resources.get(handle) orelse return false;
    if (resource.target == .buffer or resource.width == 0 or resource.height == 0) return false;
    const stride = std.math.mul(u32, resource.width, 4) catch return false;
    const needed = std.math.mul(usize, stride, resource.height) catch return false;
    if (needed > output.len) return false;

    virgl_renderer_poll();
    var box = Box{
        .x = 0,
        .y = 0,
        .z = 0,
        .w = resource.width,
        .h = resource.height,
        .d = 1,
    };
    var iov = Iovec{ .base = output.ptr, .len = needed };
    return virgl_renderer_transfer_read_iov(
        handle,
        0,
        0,
        stride,
        stride * resource.height,
        &box,
        0,
        &iov,
        1,
    ) == 0;
}

pub fn scanoutSurfaceRef(_: *GpuDevice, _: u32) ?*anyopaque {
    return null;
}

fn ensureRenderer(self: *GpuDevice) bool {
    if (self.host_active) return true;
    if (self.renderer == null or !claimHost()) return false;
    self.host_active = true;
    log.info("surfaceless virgl renderer active on GPU command thread", .{});
    return true;
}

fn claimHost() bool {
    host_mutex.lockUncancelable(global.io());
    defer host_mutex.unlock(global.io());
    if (host_claimed) {
        log.warn("only one accelerated virgl device is supported per process", .{});
        return false;
    }
    virgl_set_log_callback(logCallback, null, null);
    callbacks = .{ .version = callbacks_version, .write_fence = writeFence };
    const flags = renderer_use_egl | renderer_use_surfaceless;
    if (virgl_renderer_init(&host_cookie, flags, &callbacks) != 0) {
        log.warn("surfaceless virgl initialization failed; using 2D scanout", .{});
        return false;
    }
    host_claimed = true;
    return true;
}

fn releaseHost() void {
    host_mutex.lockUncancelable(global.io());
    defer host_mutex.unlock(global.io());
    if (!host_claimed) return;
    virgl_renderer_cleanup(&host_cookie);
    host_claimed = false;
}

fn writeFence(_: ?*anyopaque, _: u32) callconv(.c) void {}

fn logCallback(level: u32, message: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level >= 2) {
        log.warn("{s}", .{message});
    } else {
        log.info("{s}", .{message});
    }
}
