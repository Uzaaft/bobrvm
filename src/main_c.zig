//! C API exports for libbobrvm.
//!
//! This file exports all public C functions defined in include/bobrvm.h.
//! Swift calls these functions via the C FFI.
//!
//! Also provides custom logging infrastructure for the entire library.
//! Pattern follows Ghostty's main_ghostty.zig.

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const global = @import("global.zig");
const os = @import("os/main.zig");
const apprt = lib.apprt;

const log = std.log.scoped(.main);

// ---------------------------------------------------------------------------
// Logging Configuration
// ---------------------------------------------------------------------------

/// Custom log function for all std.log calls in the library.
/// Routes to stderr and/or macOS unified logging based on configuration.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Get logging config
    const cfg = global.state.logging;

    // Log to stderr if enabled
    if (cfg.stderr) {
        logToStderr(level, scope, format, args);
    }

    // Log to macOS unified logging if enabled
    if (builtin.os.tag.isDarwin() and cfg.macos) {
        logToMacOS(level, scope, format, args);
    }
}

/// Log to stderr with thread-safe locking.
fn logToStderr(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = level_txt ++ ": " ++ scope_prefix;

    // Thread-safe stderr access
    const stderr = std.posix.STDERR_FILENO;
    var buf: [4096]u8 = undefined;
    const msg = nosuspend std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch return;
    _ = std.c.write(stderr, msg.ptr, msg.len);
}

/// Log to macOS unified logging system.
fn logToMacOS(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const logger = os.log.scopedLogger(scope) orelse return;
    const log_type = os.log.LogType.fromStdLevel(level);

    // Use temporary allocator for formatting
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    logger.log(fba.allocator(), log_type, format, args);
}

/// Standard options for the entire library.
/// Sets log level based on build mode and uses our custom logFn.
pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = logFn,
};

// ---------------------------------------------------------------------------
// Library Initialization
// ---------------------------------------------------------------------------

/// Called automatically when library is loaded (or call manually).
pub export fn bobrvm_init() void {
    global.state.init();
    log.info("bobrvm initialized (version {s})", .{lib.version});
}

/// Called when library is unloaded.
pub export fn bobrvm_deinit() void {
    log.debug("bobrvm deinitializing", .{});
    global.state.deinit();
}

// ---------------------------------------------------------------------------
// Version and Build Info
// ---------------------------------------------------------------------------

pub export fn bobrvm_version() [*:0]const u8 {
    return lib.version;
}

/// Build mode enum matching bobrvm_build_mode_e in C header.
pub const BuildMode = enum(c_int) {
    debug = 0,
    release_safe = 1,
    release_fast = 2,
    release_small = 3,
};

pub export fn bobrvm_build_mode() BuildMode {
    return switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .release_safe,
        .ReleaseFast => .release_fast,
        .ReleaseSmall => .release_small,
    };
}

pub export fn bobrvm_is_debug() bool {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
}

// --------------------------------------------------------------------------
// App Lifecycle
// --------------------------------------------------------------------------

pub export fn bobrvm_app_new(runtime_cfg: ?*const apprt.RuntimeConfig) ?*apprt.App {
    const cfg = runtime_cfg orelse return null;
    return apprt.App.create(cfg) catch null;
}

pub export fn bobrvm_app_destroy(app: ?*apprt.App) void {
    const a = app orelse return;
    a.destroy();
}

pub export fn bobrvm_app_tick(app: ?*apprt.App) void {
    const a = app orelse return;
    a.tick();
}

// --------------------------------------------------------------------------
// VM Lifecycle
// --------------------------------------------------------------------------

pub export fn bobrvm_vm_new(app: ?*apprt.App, cfg: ?*const apprt.VMConfig) ?*apprt.VM {
    const a = app orelse return null;
    const c = cfg orelse return null;
    return a.createVM(c) catch null;
}

pub export fn bobrvm_vm_destroy(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.destroy();
}

pub export fn bobrvm_vm_start(vm: ?*apprt.VM) c_int {
    const v = vm orelse return 1;
    v.start() catch return 3;
    return 0;
}

pub export fn bobrvm_vm_stop(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.stop();
}

pub export fn bobrvm_vm_pause(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.pause();
}

pub export fn bobrvm_vm_shutdown_graceful(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.requestGracefulShutdown();
}

pub export fn bobrvm_vm_host_clipboard_changed(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.hostClipboardChanged();
}

pub export fn bobrvm_vm_resume(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.unpause();
}

/// Force a vCPU to exit from hv_vcpu_run (for debugging stuck vCPUs).
/// This injects an IRQ and forces an exit, useful when vCPU is stuck in WFI.
pub export fn bobrvm_vm_kick_vcpu(vm: ?*apprt.VM, vcpu_id: u32) void {
    const v = vm orelse return;
    v.kickVcpu(vcpu_id);
}

/// Force all vCPUs to exit from hv_vcpu_run (for debugging).
pub export fn bobrvm_vm_force_exit_all(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.forceExitAll();
}

// --------------------------------------------------------------------------
// Surface
// --------------------------------------------------------------------------

pub export fn bobrvm_surface_new(
    vm: ?*apprt.VM,
    mtl_device: ?*anyopaque,
    mtl_layer: ?*anyopaque,
    mtl_queue: ?*anyopaque,
) ?*apprt.Surface {
    const v = vm orelse return null;
    const device = mtl_device orelse return null;
    const layer = mtl_layer orelse return null;
    const queue = mtl_queue orelse return null;
    return v.createSurface(device, layer, queue) catch null;
}

pub export fn bobrvm_surface_destroy(surface: ?*apprt.Surface) void {
    const s = surface orelse return;
    s.destroy();
}

pub export fn bobrvm_surface_set_size(surface: ?*apprt.Surface, width: u32, height: u32) void {
    const s = surface orelse return;
    if (width == 0 or height == 0) return;
    s.setSize(width, height);
}

pub export fn bobrvm_surface_request_display_size(surface: ?*apprt.Surface, width: u32, height: u32) void {
    const s = surface orelse return;
    if (width == 0 or height == 0) return;
    s.requestDisplaySize(width, height);
}

pub export fn bobrvm_surface_set_content_scale(surface: ?*apprt.Surface, x: f64, y: f64) void {
    const s = surface orelse return;
    if (x <= 0.0 or y <= 0.0) return;
    s.setContentScale(x, y);
}

pub export fn bobrvm_surface_set_focus(surface: ?*apprt.Surface, focused: bool) void {
    const s = surface orelse return;
    s.setFocus(focused);
}

pub export fn bobrvm_surface_draw(surface: ?*apprt.Surface) void {
    const s = surface orelse return;
    s.draw();
}

pub export fn bobrvm_surface_start_renderer(surface: ?*apprt.Surface) c_int {
    const s = surface orelse return 1;
    s.startRenderer() catch return 2;
    return 0;
}

// --------------------------------------------------------------------------
// Input
// --------------------------------------------------------------------------

pub export fn bobrvm_surface_key(surface: ?*apprt.Surface, event: apprt.KeyEvent) void {
    const s = surface orelse return;
    s.handleKey(event);
}

pub export fn bobrvm_surface_mouse_button(
    surface: ?*apprt.Surface,
    button: c_int,
    pressed: bool,
) void {
    const s = surface orelse return;
    s.handleMouseButton(@enumFromInt(button), pressed);
}

pub export fn bobrvm_surface_mouse_pos(surface: ?*apprt.Surface, x: f64, y: f64) void {
    const s = surface orelse return;
    s.handleMousePos(x, y);
}

pub export fn bobrvm_surface_mouse_scroll(surface: ?*apprt.Surface, dx: f64, dy: f64) void {
    const s = surface orelse return;
    s.handleMouseScroll(dx, dy);
}
