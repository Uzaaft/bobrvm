/**
 * bobrvm - Linux virtualization for macOS
 *
 * C API for Swift/Objective-C integration.
 * Swift owns window/Metal context, Zig owns all rendering.
 */

#ifndef BOBRVM_H
#define BOBRVM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------- */
/* Opaque Handles                                                             */
/* -------------------------------------------------------------------------- */

typedef void* bobrvm_app_t;
typedef void* bobrvm_vm_t;
typedef void* bobrvm_surface_t;
typedef void* bobrvm_config_t;

/* -------------------------------------------------------------------------- */
/* Build Mode                                                                 */
/* -------------------------------------------------------------------------- */

typedef enum {
    BOBRVM_BUILD_MODE_DEBUG = 0,
    BOBRVM_BUILD_MODE_RELEASE_SAFE = 1,
    BOBRVM_BUILD_MODE_RELEASE_FAST = 2,
    BOBRVM_BUILD_MODE_RELEASE_SMALL = 3,
} bobrvm_build_mode_e;

/* -------------------------------------------------------------------------- */
/* Error Codes                                                                */
/* -------------------------------------------------------------------------- */

typedef enum {
    BOBRVM_OK = 0,
    BOBRVM_ERROR_INVALID_ARGUMENT = 1,
    BOBRVM_ERROR_OUT_OF_MEMORY = 2,
    BOBRVM_ERROR_HYPERVISOR = 3,
    BOBRVM_ERROR_VM_CREATE = 4,
    BOBRVM_ERROR_VCPU_CREATE = 5,
    BOBRVM_ERROR_MEMORY_MAP = 6,
    BOBRVM_ERROR_SURFACE_CREATE = 7,
    BOBRVM_ERROR_METAL = 8,
    BOBRVM_ERROR_IO = 9,
    BOBRVM_ERROR_ALREADY_EXISTS = 10,
    BOBRVM_ERROR_CANNOT_SHRINK = 11,
    BOBRVM_ERROR_UNSUPPORTED_FORMAT = 12,
} bobrvm_error_e;

/* -------------------------------------------------------------------------- */
/* Input Events                                                               */
/* -------------------------------------------------------------------------- */

typedef struct {
    uint32_t keycode;
    uint32_t modifiers;
    bool pressed;
} bobrvm_key_event_s;

typedef enum {
    BOBRVM_MOUSE_LEFT = 0,
    BOBRVM_MOUSE_RIGHT = 1,
    BOBRVM_MOUSE_MIDDLE = 2,
} bobrvm_mouse_button_e;

typedef struct {
    double x;
    double y;
} bobrvm_point_s;

/* -------------------------------------------------------------------------- */
/* Configuration                                                              */
/* -------------------------------------------------------------------------- */

typedef struct {
    uint64_t memory_bytes;
    uint8_t vcpu_count;
    /** UEFI firmware path (e.g., QEMU_EFI.fd). If set, boots via firmware. */
    const char* firmware_path;
    /** UEFI variables file path. Created if doesn't exist. */
    const char* vars_path;
    const char* kernel_path;
    const char* initrd_path;
    const char* cmdline;
    const char* disk_path;
    bool disk_read_only;
    /** Secondary disk path (typically ISO for installation). */
    const char* disk2_path;
    /** Whether secondary disk is read-only (default: true for ISO). */
    bool disk2_read_only;
    /** Enable virtio-net with host-side NAT (DHCP/DNS/TCP/UDP). */
    bool enable_net;
    /** Initial guest display width in pixels (0 = default 1280). */
    uint32_t display_width;
    /** Initial guest display height in pixels (0 = default 800). */
    uint32_t display_height;
    /** Host graphics-memory budget for 2D resources and the Venus window. */
    uint64_t gpu_memory_bytes;
    /**
     * Enable 3D acceleration on the virtio-gpu: the virgl capset, plus the
     * venus capset when the library was built with -Dgpu-venus. Off by
     * default — a 2D-only scanout is the safe path, and 3D additionally
     * requires the host venus stack (virglrenderer + KosmicKrisp).
     */
    bool enable_gpu3d;
} bobrvm_vm_config_s;

/** Return the shared VM configuration defaults used by every frontend. */
bobrvm_vm_config_s bobrvm_vm_config_defaults(void);

/** Validate a VM configuration against shared safety policy. */
bobrvm_error_e bobrvm_vm_config_validate(const bobrvm_vm_config_s* cfg);

/** Create a new sparse disk at exactly size_bytes logical bytes. */
bobrvm_error_e bobrvm_disk_create_sparse(const char* path, uint64_t size_bytes);

/** Grow an existing raw disk. Shrinking and non-raw formats are rejected. */
bobrvm_error_e bobrvm_disk_grow_raw(const char* path, uint64_t size_bytes);

/** Read a disk's logical size. */
bobrvm_error_e bobrvm_disk_logical_size(const char* path, uint64_t* out_size_bytes);

/** Sanitize a VM name for use as a filename without allocating. */
bobrvm_error_e bobrvm_filename_sanitize(
    const char* input,
    char* output,
    size_t output_capacity,
    size_t* out_length
);

/* -------------------------------------------------------------------------- */
/* Runtime Callbacks (Zig → Swift)                                            */
/* -------------------------------------------------------------------------- */

typedef struct {
    void* userdata;

    /** Wake the main thread to process pending work. */
    void (*wakeup)(void* userdata);

    /** Request window title change. */
    void (*set_title)(void* userdata, const char* title);

    /** Request window close. */
    void (*request_close)(void* userdata);

    /** Read from system clipboard. Returns true if text was read. */
    bool (*read_clipboard)(void* userdata, char** out_text);

    /** Write to system clipboard. */
    void (*write_clipboard)(void* userdata, const char* text);

    /** Free clipboard text allocated by read_clipboard. */
    void (*free_clipboard)(void* userdata, char* text);

    /** GPU frame ready. Swift should call bobrvm_surface_draw on next display link. */
    void (*gpu_frame_ready)(void* userdata);

    /** Console output from VM. Called on vCPU thread - dispatch to main if needed. */
    void (*console_output)(void* userdata, const char* data, size_t len);
} bobrvm_runtime_config_s;

/* -------------------------------------------------------------------------- */
/* Library Initialization                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Initialize the library.
 *
 * Should be called once at application startup before any other calls.
 * Parses BOBRVM_LOG environment variable for logging configuration.
 */
void bobrvm_init(void);

/**
 * Deinitialize the library.
 *
 * Should be called at application shutdown.
 */
void bobrvm_deinit(void);

/* -------------------------------------------------------------------------- */
/* App Lifecycle                                                              */
/* -------------------------------------------------------------------------- */

/**
 * Create a new app instance.
 *
 * @param runtime_cfg Callbacks for platform integration (retained, not copied).
 * @return App handle, or NULL on failure.
 */
bobrvm_app_t bobrvm_app_new(const bobrvm_runtime_config_s* runtime_cfg);

/**
 * Destroy the app instance and all owned VMs.
 */
void bobrvm_app_destroy(bobrvm_app_t app);

/**
 * Process pending events. Call from main thread periodically.
 */
void bobrvm_app_tick(bobrvm_app_t app);

/* -------------------------------------------------------------------------- */
/* VM Lifecycle                                                               */
/* -------------------------------------------------------------------------- */

/**
 * Create a new VM instance.
 *
 * @param app Parent app handle.
 * @param cfg VM configuration (copied).
 * @return VM handle, or NULL on failure.
 */
bobrvm_vm_t bobrvm_vm_new(bobrvm_app_t app, const bobrvm_vm_config_s* cfg);

/**
 * Destroy the VM and release all resources.
 */
void bobrvm_vm_destroy(bobrvm_vm_t vm);

/**
 * Start VM execution.
 *
 * @return BOBRVM_OK on success.
 */
bobrvm_error_e bobrvm_vm_start(bobrvm_vm_t vm);

/**
 * Stop VM execution.
 */
void bobrvm_vm_stop(bobrvm_vm_t vm);

/**
 * Pause VM execution.
 */
void bobrvm_vm_pause(bobrvm_vm_t vm);

/**
 * Resume VM execution.
 */
void bobrvm_vm_resume(bobrvm_vm_t vm);

/**
 * Ask the guest to shut down cleanly via qemu-guest-agent (requires the
 * agent running in the guest). The VM then stops through the normal
 * guest-initiated poweroff path; keep bobrvm_vm_stop as force fallback.
 */
void bobrvm_vm_shutdown_graceful(bobrvm_vm_t vm);

/**
 * Notify the guest that the HOST clipboard changed (vdagent GRAB). The
 * guest pulls the text via the runtime read_clipboard callback when it
 * pastes. Call on NSPasteboard changeCount transitions.
 */
void bobrvm_vm_host_clipboard_changed(bobrvm_vm_t vm);

/**
 * Kick a specific vCPU to wake it from WFI/sleep.
 * Injects an IRQ and forces an exit from hv_vcpu_run.
 * Useful for debugging when vCPU is stuck in WFI.
 *
 * @param vcpu_id The vCPU ID to kick (0-based).
 */
void bobrvm_vm_kick_vcpu(bobrvm_vm_t vm, uint32_t vcpu_id);

/**
 * Force all vCPUs to exit from hv_vcpu_run.
 * Useful for debugging stuck VMs.
 */
void bobrvm_vm_force_exit_all(bobrvm_vm_t vm);

/* -------------------------------------------------------------------------- */
/* Surface (Display)                                                          */
/* Swift creates Metal context, passes to Zig. Zig owns all rendering.       */
/* -------------------------------------------------------------------------- */

/**
 * Create a new display surface.
 *
 * Swift passes Metal context pointers. Zig owns rendering from here.
 *
 * @param vm Parent VM handle.
 * @param mtl_device MTLDevice* (retained by Zig).
 * @param mtl_layer CAMetalLayer* (retained by Zig).
 * @param mtl_queue MTLCommandQueue* (retained by Zig).
 * @return Surface handle, or NULL on failure.
 */
bobrvm_surface_t bobrvm_surface_new(
    bobrvm_vm_t vm,
    void* mtl_device,
    void* mtl_layer,
    void* mtl_queue
);

/**
 * Destroy the surface.
 */
void bobrvm_surface_destroy(bobrvm_surface_t surface);

/**
 * Notify surface of size change.
 *
 * @param width New width in pixels.
 * @param height New height in pixels.
 */
void bobrvm_surface_set_size(bobrvm_surface_t surface, uint32_t width, uint32_t height);

/**
 * Request a live guest display resolution change. Updates the virtio-gpu
 * display info and raises a config-change interrupt; the guest DRM driver
 * re-queries and modesets (fbcon immediately, desktops via hotplug).
 * Distinct from bobrvm_surface_set_size, which only resizes the host
 * drawable.
 *
 * @param width Desired guest width in guest pixels.
 * @param height Desired guest height in guest pixels.
 */
void bobrvm_surface_request_display_size(bobrvm_surface_t surface, uint32_t width, uint32_t height);

/**
 * Set content scale for HiDPI displays.
 *
 * @param x Horizontal scale factor.
 * @param y Vertical scale factor.
 */
void bobrvm_surface_set_content_scale(bobrvm_surface_t surface, double x, double y);

/**
 * Set surface focus state.
 *
 * @param focused True if surface has keyboard focus.
 */
void bobrvm_surface_set_focus(bobrvm_surface_t surface, bool focused);

/**
 * Request a frame draw. Call from CVDisplayLink callback.
 *
 * Zig will encode Metal commands and present to the layer.
 */
void bobrvm_surface_draw(bobrvm_surface_t surface);

/* -------------------------------------------------------------------------- */
/* Input (Swift routes events to Zig)                                         */
/* -------------------------------------------------------------------------- */

/**
 * Send keyboard event to VM.
 */
void bobrvm_surface_key(bobrvm_surface_t surface, bobrvm_key_event_s event);

/**
 * Send mouse button event to VM.
 */
void bobrvm_surface_mouse_button(
    bobrvm_surface_t surface,
    bobrvm_mouse_button_e button,
    bool pressed
);

/**
 * Send mouse position update to VM.
 */
void bobrvm_surface_mouse_pos(bobrvm_surface_t surface, double x, double y);

/**
 * Send mouse scroll event to VM.
 */
void bobrvm_surface_mouse_scroll(bobrvm_surface_t surface, double dx, double dy);

/* -------------------------------------------------------------------------- */
/* Version                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Get library version string.
 *
 * @return Static string, do not free.
 */
const char* bobrvm_version(void);

/**
 * Get library build mode.
 *
 * @return Build mode enum value.
 */
bobrvm_build_mode_e bobrvm_build_mode(void);

/**
 * Check if this is a debug build.
 *
 * @return True for Debug or ReleaseSafe builds.
 */
bool bobrvm_is_debug(void);

#ifdef __cplusplus
}
#endif

#endif /* BOBRVM_H */
