//! C API implementation for `include/bobrvm.h`.

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");
const global = @import("global.zig");
const os = @import("os/main.zig");
const apprt = lib.apprt;
const config = lib.config;
const disk = lib.disk;
const macos_runtime = lib.runtime.macos;

const log = std.log.scoped(.main);

/// Custom log function for all std.log calls in the library.
/// Routes to stderr and/or macOS unified logging based on configuration.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const cfg = global.state.logging;

    if (cfg.stderr) {
        logToStderr(level, scope, format, args);
    }

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

pub export fn bobrvm_vm_config_defaults() apprt.VMConfig {
    return .{};
}

pub export fn bobrvm_vm_config_validate(cfg: ?*const apprt.VMConfig) c_int {
    const value = cfg orelse return 1;
    return if (value.validate()) 0 else 1;
}

pub export fn bobrvm_disk_create_sparse(path: ?[*:0]const u8, size_bytes: u64) c_int {
    const path_ptr = path orelse return 1;
    disk.createSparse(std.mem.span(path_ptr), size_bytes) catch |err| return diskErrorCode(err);
    return 0;
}

pub export fn bobrvm_disk_grow_raw(path: ?[*:0]const u8, size_bytes: u64) c_int {
    const path_ptr = path orelse return 1;
    disk.growRaw(std.mem.span(path_ptr), size_bytes) catch |err| return diskErrorCode(err);
    return 0;
}

pub export fn bobrvm_disk_logical_size(
    path: ?[*:0]const u8,
    out_size_bytes: ?*u64,
) c_int {
    const path_ptr = path orelse return 1;
    const out = out_size_bytes orelse return 1;
    out.* = disk.logicalSize(std.mem.span(path_ptr)) catch |err| return diskErrorCode(err);
    return 0;
}

pub export fn bobrvm_filename_sanitize(
    input: ?[*:0]const u8,
    output: ?[*]u8,
    output_capacity: usize,
    out_length: ?*usize,
) c_int {
    const input_ptr = input orelse return 1;
    const output_ptr = output orelse return 1;
    const length_ptr = out_length orelse return 1;
    const input_slice = std.mem.span(input_ptr);
    const result = config.sanitizeFilename(
        input_slice,
        output_ptr[0..output_capacity],
    ) catch return 1;
    length_ptr.* = result.len;
    return 0;
}

fn diskErrorCode(err: anyerror) c_int {
    return switch (err) {
        error.InvalidPath, error.InvalidSize => 1,
        error.PathAlreadyExists => 10,
        error.CannotShrink => 11,
        error.UnsupportedFormat => 12,
        else => 9,
    };
}

pub export fn bobrvm_vm_new(app: ?*apprt.App, cfg: ?*const apprt.VMConfig) ?*apprt.VM {
    const a = app orelse return null;
    const c = cfg orelse return null;
    if (!c.validate()) return null;
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

pub export fn bobrvm_vm_request_stop(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.requestStop();
}

pub export fn bobrvm_vm_finish_stop(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.finishStop();
}

pub export fn bobrvm_vm_pause(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.pause();
}

pub export fn bobrvm_vm_shutdown_graceful(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.requestGracefulShutdown();
}

pub const GuestToolsStatus = extern struct {
    connection: c_int,
    capabilities: u64,
};

pub export fn bobrvm_vm_guest_tools_status(vm: ?*apprt.VM) GuestToolsStatus {
    const v = vm orelse return .{ .connection = 0, .capabilities = 0 };
    return .{
        .connection = @intFromEnum(v.guestToolsStatus()),
        .capabilities = v.guestToolsCapabilities(),
    };
}

pub export fn bobrvm_vm_guest_management_ready(vm: ?*apprt.VM) bool {
    const v = vm orelse return false;
    return v.guestManagementReady();
}

pub export fn bobrvm_vm_guest_reboot(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.requestGuestReboot();
}

pub export fn bobrvm_vm_guest_trim(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.trimGuestFilesystems();
}

pub export fn bobrvm_vm_guest_sync_time(vm: ?*apprt.VM) void {
    const v = vm orelse return;
    v.syncGuestTime();
}

pub export fn bobrvm_vm_snapshot_quiesced(
    vm: ?*apprt.VM,
    dir: ?[*:0]const u8,
) c_int {
    const v = vm orelse return 1;
    const path = dir orelse return 1;
    v.snapshotQuiesced(std.mem.span(path)) catch return 9;
    return 0;
}

pub export fn bobrvm_vm_send_file(vm: ?*apprt.VM, path: ?[*:0]const u8) c_int {
    const v = vm orelse return 1;
    const file_path = path orelse return 1;
    v.sendFileToGuest(std.mem.span(file_path)) catch return 9;
    return 0;
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

pub const VMState = enum(c_int) {
    stopped = 0,
    starting = 1,
    running = 2,
    pausing = 3,
    paused = 4,
    stopping = 5,
    failed = 6,
};

pub export fn bobrvm_macos_vm_new(
    cfg: ?*const macos_runtime.MacOSConfig,
) ?*macos_runtime.MacRuntime {
    if (builtin.os.tag != .macos) return null;
    const config_value = cfg orelse return null;
    const handle = std.heap.c_allocator.create(macos_runtime.MacRuntime) catch return null;
    handle.* = macos_runtime.MacRuntime.init(config_value) catch {
        std.heap.c_allocator.destroy(handle);
        return null;
    };
    return handle;
}

pub export fn bobrvm_macos_vm_destroy(vm: ?*macos_runtime.MacRuntime) void {
    const handle = vm orelse return;
    handle.backend.deinit();
    std.heap.c_allocator.destroy(handle);
}

pub export fn bobrvm_macos_vm_start(vm: ?*macos_runtime.MacRuntime) c_int {
    const handle = vm orelse return 1;
    handle.start() catch return 3;
    return 0;
}

pub export fn bobrvm_macos_vm_stop(vm: ?*macos_runtime.MacRuntime) void {
    const handle = vm orelse return;
    handle.requestStop();
}

pub export fn bobrvm_macos_vm_pause(vm: ?*macos_runtime.MacRuntime) void {
    const handle = vm orelse return;
    handle.pause();
}

pub export fn bobrvm_macos_vm_resume(vm: ?*macos_runtime.MacRuntime) void {
    const handle = vm orelse return;
    handle.resumeVM();
}

pub export fn bobrvm_macos_vm_state(vm: ?*macos_runtime.MacRuntime) VMState {
    const handle = vm orelse return .failed;
    handle.tick();
    return @enumFromInt(@intFromEnum(handle.state));
}

pub export fn bobrvm_macos_vm_display_view(vm: ?*macos_runtime.MacRuntime) ?*anyopaque {
    const handle = vm orelse return null;
    return handle.displayView();
}

pub export fn bobrvm_macos_vm_install(
    vm: ?*macos_runtime.MacRuntime,
    restore_path: ?[*:0]const u8,
    userdata: ?*anyopaque,
    callback: ?macos_runtime.Backend.InstallCallback,
) c_int {
    const handle = vm orelse return 1;
    const path = restore_path orelse return 1;
    const completion = callback orelse return 1;
    handle.backend.install(path, userdata, completion) catch return 3;
    return 0;
}

pub export fn bobrvm_macos_vm_install_progress(vm: ?*macos_runtime.MacRuntime) f64 {
    const handle = vm orelse return 0;
    return handle.backend.installProgress();
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
