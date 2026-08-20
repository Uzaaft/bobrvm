/* Swift owns the window and Metal context. Zig owns rendering. */

#ifndef BOBRVM_H
#define BOBRVM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles. */

typedef void* bobrvm_app_t;
typedef void* bobrvm_vm_t;
typedef void* bobrvm_surface_t;
typedef void* bobrvm_config_t;
typedef void* bobrvm_macos_vm_t;
typedef void* bobrvm_vz_vm_t;

/* Build mode. */

typedef enum {
    BOBRVM_BUILD_MODE_DEBUG = 0,
    BOBRVM_BUILD_MODE_RELEASE_SAFE = 1,
    BOBRVM_BUILD_MODE_RELEASE_FAST = 2,
    BOBRVM_BUILD_MODE_RELEASE_SMALL = 3,
} bobrvm_build_mode_e;

/* Errors and state. */

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
    BOBRVM_ERROR_INVALID_STATE = 13,
} bobrvm_error_e;

typedef enum {
    BOBRVM_VM_STATE_STOPPED = 0,
    BOBRVM_VM_STATE_STARTING = 1,
    BOBRVM_VM_STATE_RUNNING = 2,
    BOBRVM_VM_STATE_PAUSING = 3,
    BOBRVM_VM_STATE_PAUSED = 4,
    BOBRVM_VM_STATE_STOPPING = 5,
    BOBRVM_VM_STATE_FAILED = 6,
} bobrvm_vm_state_e;

typedef enum {
    BOBRVM_GUEST_TOOLS_DISCONNECTED = 0,
    BOBRVM_GUEST_TOOLS_CONNECTING = 1,
    BOBRVM_GUEST_TOOLS_READY = 2,
    BOBRVM_GUEST_TOOLS_PROTOCOL_ERROR = 3,
} bobrvm_guest_tools_connection_e;

typedef struct {
    bobrvm_guest_tools_connection_e connection;
    uint64_t capabilities;
} bobrvm_guest_tools_status_s;

typedef enum {
    BOBRVM_GUEST_TOOLS_CLIPBOARD = 1ULL << 0,
    BOBRVM_GUEST_TOOLS_FILE_TRANSFER = 1ULL << 1,
    BOBRVM_GUEST_TOOLS_MANAGEMENT = 1ULL << 8,
} bobrvm_guest_tools_capability_e;

/* Input. */

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

/* Configuration. */

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
    const char* disk2_path;
    /** Defaults to read-only for ISO media. */
    bool disk2_read_only;
    bool enable_net;
    /** Host directory exported through virtio-9p with mount tag "host". */
    const char* shared_dir;
    /** Initial guest display width in pixels (0 = default 1280). */
    uint32_t display_width;
    /** Initial guest display height in pixels (0 = default 800). */
    uint32_t display_height;
    /** Shared budget for 2D resources and the Venus window. */
    uint64_t gpu_memory_bytes;
    /**
     * Enables virgl and, for -Dgpu-venus builds, Venus. Requires the host
     * Venus stack; disabled by default.
     */
    bool enable_gpu3d;
} bobrvm_vm_config_s;

typedef struct {
    uint64_t memory_bytes;
    uint8_t vcpu_count;
    uint32_t display_width;
    uint32_t display_height;
    bool retina;
    const char* disk_path;
    const char* auxiliary_storage_path;
    const char* hardware_model_base64;
    const char* machine_identifier_base64;
    const char* mac_address;
} bobrvm_macos_vm_config_s;

typedef struct {
    uint64_t memory_bytes;
    uint8_t vcpu_count;
    uint32_t display_width;
    uint32_t display_height;
    bool enable_net;
    bool disk_read_only;
    const char* disk_path;
    const char* installer_path;
    const char* variable_store_path;
    const char* machine_id_path;
    const char* mac_address;
} bobrvm_vz_vm_config_s;

bobrvm_vm_config_s bobrvm_vm_config_defaults(void);

/** Validate a VM configuration against shared safety policy. */
bobrvm_error_e bobrvm_vm_config_validate(const bobrvm_vm_config_s* cfg);

/** Create a new sparse disk at exactly size_bytes logical bytes. */
bobrvm_error_e bobrvm_disk_create_sparse(const char* path, uint64_t size_bytes);

/** Grow an existing raw disk. Shrinking and non-raw formats are rejected. */
bobrvm_error_e bobrvm_disk_grow_raw(const char* path, uint64_t size_bytes);

bobrvm_error_e bobrvm_disk_logical_size(const char* path, uint64_t* out_size_bytes);

/** Sanitize a VM name for use as a filename without allocating. */
bobrvm_error_e bobrvm_filename_sanitize(
    const char* input,
    char* output,
    size_t output_capacity,
    size_t* out_length
);

/* Runtime callbacks from Zig to the frontend. */

typedef struct {
    void* userdata;

    /** Wake the main thread to process pending work. */
    void (*wakeup)(void* userdata);

    void (*set_title)(void* userdata, const char* title);

    void (*request_close)(void* userdata);

    /** Read from system clipboard. Returns true if text was read. */
    bool (*read_clipboard)(void* userdata, char** out_text);

    void (*write_clipboard)(void* userdata, const char* text);

    /** Free clipboard text allocated by read_clipboard. */
    void (*free_clipboard)(void* userdata, char* text);

    /** Schedule bobrvm_surface_draw on the next display-link callback. */
    void (*gpu_frame_ready)(void* userdata);

    /** Called on a vCPU thread. */
    void (*console_output)(
        void* userdata,
        bobrvm_vm_t vm,
        const uint8_t* data,
        size_t len
    );
} bobrvm_runtime_config_s;

/* Library lifecycle. */

/** Call once before other API calls. Reads BOBRVM_LOG. */
void bobrvm_init(void);

void bobrvm_deinit(void);

/* App lifecycle. */

/** runtime_cfg is retained, not copied. Returns NULL on failure. */
bobrvm_app_t bobrvm_app_new(const bobrvm_runtime_config_s* runtime_cfg);

/** Also destroys owned VMs. */
void bobrvm_app_destroy(bobrvm_app_t app);

/** Process pending events from the main thread. */
void bobrvm_app_tick(bobrvm_app_t app);

/* VM lifecycle. */

/** Copies cfg. Returns NULL on failure. */
bobrvm_vm_t bobrvm_vm_new(bobrvm_app_t app, const bobrvm_vm_config_s* cfg);

void bobrvm_vm_destroy(bobrvm_vm_t vm);

bobrvm_error_e bobrvm_vm_start(bobrvm_vm_t vm);

void bobrvm_vm_stop(bobrvm_vm_t vm);
void bobrvm_vm_request_stop(bobrvm_vm_t vm);
void bobrvm_vm_finish_stop(bobrvm_vm_t vm);

void bobrvm_vm_pause(bobrvm_vm_t vm);

void bobrvm_vm_resume(bobrvm_vm_t vm);

/** Send raw terminal bytes to the guest console. */
bobrvm_error_e bobrvm_vm_console_write(
    bobrvm_vm_t vm,
    const uint8_t* data,
    size_t length
);

/** Set guest-visible terminal dimensions in character cells. */
bobrvm_error_e bobrvm_vm_console_resize(
    bobrvm_vm_t vm,
    uint16_t columns,
    uint16_t rows
);

/**
 * Ask the guest to shut down cleanly via qemu-guest-agent (requires the
 * agent running in the guest). The VM then stops through the normal
 * guest-initiated poweroff path; keep bobrvm_vm_stop as force fallback.
 */
void bobrvm_vm_shutdown_graceful(bobrvm_vm_t vm);

/** Return the aggregate state of the negotiated guest integration channels. */
bobrvm_guest_tools_status_s bobrvm_vm_guest_tools_status(bobrvm_vm_t vm);

bool bobrvm_vm_guest_management_ready(bobrvm_vm_t vm);
void bobrvm_vm_guest_reboot(bobrvm_vm_t vm);
void bobrvm_vm_guest_trim(bobrvm_vm_t vm);
void bobrvm_vm_guest_sync_time(bobrvm_vm_t vm);
bobrvm_error_e bobrvm_vm_snapshot_quiesced(bobrvm_vm_t vm, const char* directory);
/** Queue one regular file for delivery to the configured guest inbox. */
bobrvm_error_e bobrvm_vm_send_file(bobrvm_vm_t vm, const char* path);

/**
 * Notify the guest that the HOST clipboard changed (vdagent GRAB). The
 * guest pulls the text via the runtime read_clipboard callback when it
 * pastes. Call on NSPasteboard changeCount transitions.
 */
void bobrvm_vm_host_clipboard_changed(bobrvm_vm_t vm);

/**
 * Inject an IRQ and force vCPU vcpu_id out of hv_vcpu_run.
 */
void bobrvm_vm_kick_vcpu(bobrvm_vm_t vm, uint32_t vcpu_id);

/** Force all vCPUs out of hv_vcpu_run. */
void bobrvm_vm_force_exit_all(bobrvm_vm_t vm);

/* macOS guest runtime. */

bobrvm_macos_vm_t bobrvm_macos_vm_new(const bobrvm_macos_vm_config_s* cfg);
void bobrvm_macos_vm_destroy(bobrvm_macos_vm_t vm);
bobrvm_error_e bobrvm_macos_vm_start(bobrvm_macos_vm_t vm);
void bobrvm_macos_vm_stop(bobrvm_macos_vm_t vm);
void bobrvm_macos_vm_pause(bobrvm_macos_vm_t vm);
void bobrvm_macos_vm_resume(bobrvm_macos_vm_t vm);
bobrvm_vm_state_e bobrvm_macos_vm_state(bobrvm_macos_vm_t vm);
void* bobrvm_macos_vm_display_view(bobrvm_macos_vm_t vm);
typedef void (*bobrvm_macos_install_callback_f)(void* userdata, bool success);
bobrvm_error_e bobrvm_macos_vm_install(
    bobrvm_macos_vm_t vm,
    const char* restore_path,
    void* userdata,
    bobrvm_macos_install_callback_f callback
);
double bobrvm_macos_vm_install_progress(bobrvm_macos_vm_t vm);

/* Virtualization.framework Linux guest runtime. */

bobrvm_vz_vm_t bobrvm_vz_vm_new(const bobrvm_vz_vm_config_s* cfg);
void bobrvm_vz_vm_destroy(bobrvm_vz_vm_t vm);
bobrvm_error_e bobrvm_vz_vm_start(bobrvm_vz_vm_t vm);
void bobrvm_vz_vm_stop(bobrvm_vz_vm_t vm);
void bobrvm_vz_vm_pause(bobrvm_vz_vm_t vm);
void bobrvm_vz_vm_resume(bobrvm_vz_vm_t vm);
bobrvm_vm_state_e bobrvm_vz_vm_state(bobrvm_vz_vm_t vm);
void* bobrvm_vz_vm_display_view(bobrvm_vz_vm_t vm);

/* Display surfaces. */

/**
 * Zig retains the MTLDevice, CAMetalLayer, and MTLCommandQueue pointers and
 * owns rendering. Returns NULL on failure.
 */
bobrvm_surface_t bobrvm_surface_new(
    bobrvm_vm_t vm,
    void* mtl_device,
    void* mtl_layer,
    void* mtl_queue
);

void bobrvm_surface_destroy(bobrvm_surface_t surface);

/** Resize the host drawable in pixels. */
void bobrvm_surface_set_size(bobrvm_surface_t surface, uint32_t width, uint32_t height);

/**
 * Request a live guest display resolution change. Updates the virtio-gpu
 * display info and raises a config-change interrupt; the guest DRM driver
 * re-queries and modesets (fbcon immediately, desktops via hotplug).
 * Distinct from bobrvm_surface_set_size, which only resizes the host
 * drawable.
 *
 */
void bobrvm_surface_request_display_size(bobrvm_surface_t surface, uint32_t width, uint32_t height);

void bobrvm_surface_set_content_scale(bobrvm_surface_t surface, double x, double y);

void bobrvm_surface_set_focus(bobrvm_surface_t surface, bool focused);

/** Encode and present a frame from the CVDisplayLink callback. */
void bobrvm_surface_draw(bobrvm_surface_t surface);

/* Input routed from Swift to Zig. */

void bobrvm_surface_key(bobrvm_surface_t surface, bobrvm_key_event_s event);

void bobrvm_surface_mouse_button(
    bobrvm_surface_t surface,
    bobrvm_mouse_button_e button,
    bool pressed
);

void bobrvm_surface_mouse_pos(bobrvm_surface_t surface, double x, double y);

void bobrvm_surface_mouse_scroll(bobrvm_surface_t surface, double dx, double dy);

/* Version. */

/** Returns a static string. */
const char* bobrvm_version(void);

bobrvm_build_mode_e bobrvm_build_mode(void);

/** True for Debug and ReleaseSafe builds. */
bool bobrvm_is_debug(void);

#ifdef __cplusplus
}
#endif

#endif /* BOBRVM_H */
