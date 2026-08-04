//! Thin bindings for virglrenderer's Venus host backend.
//!
//! Guest Vulkan travels through virtio-gpu and virglrenderer to a host Vulkan
//! driver backed by Metal. See `docs/gpu-venus-moltenvk.md`.

const std = @import("std");
const build_options = @import("build_options");
const log = std.log.scoped(.venus);

pub const RENDERER_USE_EGL: c_int = 1;
pub const RENDERER_THREAD_SYNC: c_int = 2;
pub const RENDERER_VENUS: c_int = 1 << 6;
pub const RENDERER_NO_VIRGL: c_int = 1 << 7;
pub const RENDERER_RENDER_SERVER: c_int = 1 << 9;

/// Enable Venus and its render server without the EGL-dependent virgl winsys.
pub const INIT_FLAGS: c_int = RENDERER_VENUS | RENDERER_NO_VIRGL | RENDERER_RENDER_SERVER;

/// Point virglrenderer at the `virgl_render_server` binary. Must be called
/// before init(); virglrenderer reads RENDER_SERVER_EXEC_PATH from the env when
/// it forks the Venus render server. Requires the macOS-patched virglrenderer
/// (SOCK_STREAM proxy + kqueue fix; tools/build-virglrenderer-macos.sh).
pub fn setRenderServerPath(path: [:0]const u8) void {
    _ = setenv("RENDER_SERVER_EXEC_PATH", path.ptr, 1);
}
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;

/// Venus capset ID from virglrenderer.
pub const CAPSET_VIRGL: u32 = 1;
pub const CAPSET_VIRGL2: u32 = 2;
pub const CAPSET_VENUS: u32 = 4;

/// The low byte of a context's flags selects its capset (which host renderer
/// decodes its command stream). Venus contexts carry CAPSET_VENUS here.
pub const CONTEXT_FLAG_CAPSET_ID_MASK: u32 = 0xff;

/// blob_mem values for resource_create_blob.
pub const BLOB_MEM_GUEST: u32 = 0x0001;
pub const BLOB_MEM_HOST3D: u32 = 0x0002;
pub const BLOB_MEM_HOST3D_GUEST: u32 = 0x0003;
/// blob_flags.
pub const BLOB_FLAG_USE_MAPPABLE: u32 = 0x0001;
pub const BLOB_FLAG_USE_SHAREABLE: u32 = 0x0002;

/// POSIX iovec, as virglrenderer's transfer/blob APIs expect it.
pub const iovec = extern struct {
    base: ?[*]u8,
    len: usize,
};

/// struct virgl_renderer_resource_create_blob_args.
pub const BlobArgs = extern struct {
    res_handle: u32,
    ctx_id: u32,
    blob_mem: u32,
    blob_flags: u32,
    blob_id: u64,
    size: u64,
    iovecs: ?[*]const iovec,
    num_iovs: u32,
};

/// virgl_renderer_callbacks. Declared through the v4 layout so the struct is
/// ABI-sized correctly. We pass version = 3: Venus contexts use per-context
/// fences and require the v3 `write_context_fence` callback (v1 with only
/// `write_fence` makes context_create_with_flags fail). v4 is avoided because it
/// demands a working EGL display (`get_egl_display`), which macOS lacks.
pub const Callbacks = extern struct {
    version: c_int,
    write_fence: ?*const fn (cookie: ?*anyopaque, fence: u32) callconv(.c) void = null,
    create_gl_context: ?*anyopaque = null,
    destroy_gl_context: ?*anyopaque = null,
    make_current: ?*anyopaque = null,
    get_drm_fd: ?*anyopaque = null,
    write_context_fence: ?*const fn (cookie: ?*anyopaque, ctx_id: u32, ring_idx: u32, fence_id: u64) callconv(.c) void = null,
    get_server_fd: ?*anyopaque = null,
    get_egl_display: ?*anyopaque = null,
};

pub const CALLBACKS_VERSION: c_int = 3;

extern "c" fn virgl_renderer_init(cookie: ?*anyopaque, flags: c_int, cb: *Callbacks) callconv(.c) c_int;
extern "c" fn virgl_renderer_cleanup(cookie: ?*anyopaque) callconv(.c) void;
extern "c" fn virgl_renderer_get_cap_set(set: u32, max_ver: *u32, max_size: *u32) callconv(.c) void;
extern "c" fn virgl_renderer_fill_caps(set: u32, version: u32, caps: *anyopaque) callconv(.c) void;
extern "c" fn virgl_renderer_context_create_with_flags(ctx_id: u32, ctx_flags: u32, nlen: u32, name: [*]const u8) callconv(.c) c_int;
extern "c" fn virgl_renderer_context_destroy(handle: u32) callconv(.c) void;
extern "c" fn virgl_renderer_submit_cmd(buffer: *anyopaque, ctx_id: c_int, ndw: c_int) callconv(.c) c_int;
extern "c" fn virgl_renderer_create_fence(client_fence_id: c_int, ctx_id: u32) callconv(.c) c_int;
extern "c" fn virgl_renderer_ctx_attach_resource(ctx_id: c_int, res_handle: c_int) callconv(.c) void;
extern "c" fn virgl_renderer_ctx_detach_resource(ctx_id: c_int, res_handle: c_int) callconv(.c) void;
extern "c" fn virgl_renderer_resource_create_blob(args: *const BlobArgs) callconv(.c) c_int;
extern "c" fn virgl_renderer_resource_map(res_handle: u32, map: *?*anyopaque, out_size: *u64) callconv(.c) c_int;
extern "c" fn virgl_renderer_resource_unmap(res_handle: u32) callconv(.c) c_int;
extern "c" fn virgl_renderer_resource_unref(res_handle: u32) callconv(.c) void;
extern "c" fn virgl_renderer_poll() callconv(.c) void;
extern "c" fn virgl_set_log_callback(cb: *const fn (level: u32, msg: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque, free_cb: ?*anyopaque) callconv(.c) void;

pub const Capset = struct {
    max_ver: u32,
    max_size: u32,
    pub fn present(self: Capset) bool {
        return self.max_size != 0;
    }
};

/// A live virglrenderer instance. virglrenderer keeps global state, so at most
/// one Host should exist per process.
pub const Host = struct {
    initialized: bool = false,

    // virglrenderer stores the callbacks pointer; keep it alive for the
    // process. write_context_fence is required for Venus (per-context fences).
    var callbacks: Callbacks = .{
        .version = CALLBACKS_VERSION,
        .write_fence = writeFence,
        .write_context_fence = writeContextFence,
    };

    fn writeFence(cookie: ?*anyopaque, fence: u32) callconv(.c) void {
        _ = cookie;
        _ = fence;
        // Legacy global fence path; unused by Venus (uses write_context_fence).
    }

    fn writeContextFence(cookie: ?*anyopaque, ctx_id: u32, ring_idx: u32, fence_id: u64) callconv(.c) void {
        _ = cookie;
        _ = ctx_id;
        _ = ring_idx;
        _ = fence_id;
        // Fence completion is wired into the virtio-gpu used-buffer IRQ in a
        // later milestone; for now the host stack runs synchronously.
    }

    fn logCallback(level: u32, msg: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
        _ = user_data;
        _ = level;
        log.info("[virgl] {s}", .{msg});
    }

    pub fn init() error{VirglInitFailed}!Host {
        // Route virglrenderer/vkr logs through our logger — with in-process
        // venus, this surfaces host-side Vulkan errors that were invisible in
        // the render-server model.
        virgl_set_log_callback(logCallback, null, null);
        callbacks = .{
            .version = CALLBACKS_VERSION,
            .write_fence = writeFence,
            .write_context_fence = writeContextFence,
        };
        const rc = virgl_renderer_init(null, INIT_FLAGS, &callbacks);
        if (rc != 0) return error.VirglInitFailed;
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Host) void {
        if (self.initialized) {
            virgl_renderer_cleanup(null);
            self.initialized = false;
        }
    }

    pub fn getCapset(self: *const Host, id: u32) Capset {
        std.debug.assert(self.initialized);
        var ver: u32 = 0;
        var size: u32 = 0;
        virgl_renderer_get_cap_set(id, &ver, &size);
        return .{ .max_ver = ver, .max_size = size };
    }

    /// Write the capset blob for (set, version) into `buf` — this is what the
    /// guest's Mesa driver reads to configure itself. `buf.len` must be at least
    /// the max_size reported by getCapset.
    pub fn fillCaps(self: *const Host, set: u32, version: u32, buf: []u8) void {
        std.debug.assert(self.initialized);
        virgl_renderer_fill_caps(set, version, buf.ptr);
    }

    /// Create a Venus context: the capset id lives in the low byte of the flags,
    /// which tells virglrenderer to decode this context's command stream as
    /// Venus (Vulkan) rather than virgl (GL).
    pub fn createVenusContext(self: *const Host, ctx_id: u32) error{VirglContextFailed}!void {
        std.debug.assert(self.initialized);
        const name = "bobrvm";
        const rc = virgl_renderer_context_create_with_flags(
            ctx_id,
            CAPSET_VENUS & CONTEXT_FLAG_CAPSET_ID_MASK,
            name.len,
            name,
        );
        if (rc != 0) {
            // rc=22 (EINVAL) here means the host Vulkan driver can't back Venus
            // — typically the wrong ICD (MoltenVK lacks VK_EXT_external_memory_metal;
            // this venus build needs Mesa's KosmicKrisp). See docs/gpu-venus-moltenvk.md.
            log.warn("context_create_with_flags(ctx={d}, capset=VENUS) failed rc={d}", .{ ctx_id, rc });
            return error.VirglContextFailed;
        }
    }

    pub fn destroyContext(self: *const Host, ctx_id: u32) void {
        std.debug.assert(self.initialized);
        virgl_renderer_context_destroy(ctx_id);
    }

    /// Submit a guest command stream to a context. virglrenderer takes a dword
    /// count and promises never to mutate the buffer (so a const slice is safe
    /// to @constCast here).
    pub fn submit(self: *const Host, ctx_id: u32, data: []const u8) error{VirglSubmitFailed}!void {
        std.debug.assert(self.initialized);
        const ndw: c_int = @intCast(data.len / 4);
        const rc = virgl_renderer_submit_cmd(@constCast(data.ptr), @intCast(ctx_id), ndw);
        if (rc != 0) return error.VirglSubmitFailed;
    }

    pub fn attachResource(self: *const Host, ctx_id: u32, res_handle: u32) void {
        std.debug.assert(self.initialized);
        virgl_renderer_ctx_attach_resource(@intCast(ctx_id), @intCast(res_handle));
    }

    pub fn detachResource(self: *const Host, ctx_id: u32, res_handle: u32) void {
        std.debug.assert(self.initialized);
        virgl_renderer_ctx_detach_resource(@intCast(ctx_id), @intCast(res_handle));
    }

    pub fn createBlob(self: *const Host, args: *const BlobArgs) error{VirglBlobFailed}!void {
        std.debug.assert(self.initialized);
        if (virgl_renderer_resource_create_blob(args) != 0) return error.VirglBlobFailed;
    }

    pub const Mapping = struct { ptr: [*]u8, size: u64 };

    pub fn mapResource(self: *const Host, res_handle: u32) error{VirglMapFailed}!Mapping {
        std.debug.assert(self.initialized);
        var map: ?*anyopaque = null;
        var size: u64 = 0;
        if (virgl_renderer_resource_map(res_handle, &map, &size) != 0) return error.VirglMapFailed;
        return .{ .ptr = @ptrCast(map orelse return error.VirglMapFailed), .size = size };
    }

    pub fn unmapResource(self: *const Host, res_handle: u32) void {
        std.debug.assert(self.initialized);
        _ = virgl_renderer_resource_unmap(res_handle);
    }

    pub fn unrefResource(self: *const Host, res_handle: u32) void {
        std.debug.assert(self.initialized);
        virgl_renderer_resource_unref(res_handle);
    }

    /// Create a host fence tagged with client_fence_id; completion is reported
    /// through the write_fence callback (later wired to the used-buffer IRQ).
    pub fn createFence(self: *const Host, client_fence_id: c_int, ctx_id: u32) error{VirglFenceFailed}!void {
        std.debug.assert(self.initialized);
        if (virgl_renderer_create_fence(client_fence_id, ctx_id) != 0) return error.VirglFenceFailed;
    }

    /// Force retirement of pending fences (drives the write_fence callback).
    pub fn poll(self: *const Host) void {
        std.debug.assert(self.initialized);
        virgl_renderer_poll();
    }
};

// virglrenderer keeps process-global state, so a single Host per process is the
// natural model. The virtio-gpu device uses this singleton rather than storing
// its own instance.
var global_host: ?Host = null;

/// Configure the render-server binary + KosmicKrisp ICD paths from the build's
/// virgl install prefix, without clobbering values the user set in the env. The
/// render server (RENDER_SERVER_EXEC_PATH) and ICD (VK_ICD_FILENAMES) can be set
/// after launch since virglrenderer reads them at init; DYLD_LIBRARY_PATH cannot
/// (dyld reads it at exec) so the vulkan-loader path still comes from the env.
fn configureEnv() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (getenv("RENDER_SERVER_EXEC_PATH") == null) {
        const p = std.fmt.bufPrintZ(&buf, "{s}/libexec/virgl_render_server", .{build_options.virgl_prefix}) catch return;
        _ = setenv("RENDER_SERVER_EXEC_PATH", p.ptr, 1);
    }
    if (getenv("VK_ICD_FILENAMES") == null) {
        // KosmicKrisp: the only Vulkan-on-Metal driver with the zink
        // requirements (robustness2 nullDescriptor — MoltenVK reports 0), i.e.
        // the route to high guest GL. Its missing VK_EXT_metal_objects is
        // covered by our virglrenderer host-pointer-import patch
        // (tools/patches/virglrenderer-0001-vkr-host-pointer-shm-import.patch;
        // probes: tools/host_vk_mem_probe.m, /tmp/hostptr_probe).
        const p = std.fmt.bufPrintZ(&buf, "{s}/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json", .{build_options.virgl_prefix}) catch return;
        _ = setenv("VK_ICD_FILENAMES", p.ptr, 1);
    }
}
extern "c" fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;

/// Initialize (once) and return the process Venus host, or null if the host
/// stack is unavailable (wrong/missing driver, render server can't start, …).
pub fn ensureHost() ?*Host {
    if (global_host == null) {
        configureEnv();
        global_host = Host.init() catch {
            log.warn("venus host init failed — venus GPU path unavailable", .{});
            return null;
        };
    }
    return &global_host.?;
}

pub fn deinitHost() void {
    if (global_host) |*h| {
        h.deinit();
        global_host = null;
    }
}
