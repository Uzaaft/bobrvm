//! Venus host backend — thin wrapper over virglrenderer's Venus (Vulkan) path.
//!
//! This is the forward-looking GPU backend (see docs/gpu-venus-moltenvk.md): the
//! guest runs Zink (OpenGL→Vulkan) and the Venus Mesa driver, which serializes
//! Vulkan over virtio-gpu; virglrenderer decodes it and replays onto host Vulkan
//! (MoltenVK → Metal). We link the system `libvirglrenderer` rather than
//! reimplementing the Venus decoder — that is the whole point of the pivot away
//! from the hand-rolled `src/gpu/virgl` TGSI→MSL translator.
//!
//! Only a tiny slice of the virglrenderer C API is declared here (matching the
//! codebase's `extern "c"` convention instead of `@cImport`). The bridge that
//! routes virtio-gpu 3D commands into `virgl_renderer_submit_cmd` etc. builds on
//! top of this in later milestones.

const std = @import("std");

// --- virglrenderer flags (virglrenderer.h) ---
pub const RENDERER_USE_EGL: c_int = 1;
pub const RENDERER_THREAD_SYNC: c_int = 2;
pub const RENDERER_VENUS: c_int = 1 << 6;
pub const RENDERER_NO_VIRGL: c_int = 1 << 7;

/// Init flags proven on macOS/MoltenVK (tools/virgl_smoke.c): drive the Venus
/// path and skip the virgl-GL (vrend) winsys entirely — that winsys needs an
/// EGL/ANGLE display which does not initialize on macOS ("EGL is not supported
/// on this platform"), and without NO_VIRGL init fails with "invalid renderer
/// vrend callbacks". Venus talks to Vulkan (MoltenVK) directly.
pub const INIT_FLAGS: c_int = RENDERER_VENUS | RENDERER_NO_VIRGL;

/// Capset ids (mesa/virglrenderer): VIRGL=1, VIRGL2=2, GFXSTREAM=3, VENUS=4.
pub const CAPSET_VIRGL: u32 = 1;
pub const CAPSET_VIRGL2: u32 = 2;
pub const CAPSET_VENUS: u32 = 4;

/// virgl_renderer_callbacks. We declare through the v4 layout so the struct is
/// ABI-sized correctly, but only `version` + `write_fence` are read when we pass
/// version = 1. The unused slots stay null.
pub const Callbacks = extern struct {
    version: c_int,
    write_fence: ?*const fn (cookie: ?*anyopaque, fence: u32) callconv(.c) void = null,
    create_gl_context: ?*anyopaque = null,
    destroy_gl_context: ?*anyopaque = null,
    make_current: ?*anyopaque = null,
    get_drm_fd: ?*anyopaque = null,
    write_context_fence: ?*anyopaque = null,
    get_server_fd: ?*anyopaque = null,
    get_egl_display: ?*anyopaque = null,
};

extern "c" fn virgl_renderer_init(cookie: ?*anyopaque, flags: c_int, cb: *Callbacks) callconv(.c) c_int;
extern "c" fn virgl_renderer_cleanup(cookie: ?*anyopaque) callconv(.c) void;
extern "c" fn virgl_renderer_get_cap_set(set: u32, max_ver: *u32, max_size: *u32) callconv(.c) void;
extern "c" fn virgl_renderer_get_fd_for_texture(res_handle: u32, fd: *c_int) callconv(.c) c_int;

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
    // process. version = 1 means only write_fence is consulted.
    var callbacks: Callbacks = .{ .version = 1, .write_fence = writeFence };

    fn writeFence(cookie: ?*anyopaque, fence: u32) callconv(.c) void {
        _ = cookie;
        _ = fence;
        // Fence completion is wired into the virtio-gpu used-buffer IRQ in a
        // later milestone; for now the host stack runs synchronously.
    }

    pub fn init() error{VirglInitFailed}!Host {
        callbacks = .{ .version = 1, .write_fence = writeFence };
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
};
