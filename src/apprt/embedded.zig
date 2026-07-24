//! Embedded Runtime for macOS/Swift integration.
//!
//! Platform-agnostic wrapper that:
//! - Exports C API functions for Swift FFI
//! - Accepts callback struct from Swift for platform actions
//! - Manages VM instances and surfaces
//!
//! Pattern follows Ghostty's apprt/embedded.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const machine = @import("../machine/main.zig");
const keymap = @import("keymap.zig");
const renderer = @import("../renderer/main.zig");

const log = std.log.scoped(.apprt);

/// Runtime configuration with platform callbacks.
/// Passed from Swift to Zig at app creation.
/// All function pointers use C calling convention for FFI.
pub const RuntimeConfig = extern struct {
    /// Opaque pointer passed back to all callbacks.
    userdata: ?*anyopaque = null,

    /// Wake the main thread to process pending work.
    /// Called when Zig has work that needs main thread attention.
    wakeup: ?*const fn (?*anyopaque) callconv(.c) void = null,

    /// Request window title change.
    set_title: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void = null,

    /// Request window close.
    request_close: ?*const fn (?*anyopaque) callconv(.c) void = null,

    /// Read from system clipboard.
    /// Returns true if text was successfully read into out_text.
    /// Caller must free via free_clipboard.
    read_clipboard: ?*const fn (?*anyopaque, *?[*:0]u8) callconv(.c) bool = null,

    /// Write to system clipboard.
    write_clipboard: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void = null,

    /// Free clipboard text allocated by read_clipboard.
    free_clipboard: ?*const fn (?*anyopaque, [*:0]u8) callconv(.c) void = null,

    /// Notify Swift that a GPU frame is ready.
    /// Swift should call bobrvm_surface_draw on next CVDisplayLink.
    gpu_frame_ready: ?*const fn (?*anyopaque) callconv(.c) void = null,

    /// Console output from VM.
    /// Called on vCPU thread - Swift should dispatch to main if needed.
    console_output: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null,
};

/// VM configuration (C API struct - pointers are temporary).
pub const VMConfig = extern struct {
    memory_bytes: u64,
    vcpu_count: u8,
    /// UEFI firmware path (e.g., QEMU_EFI.fd). If set, boots via firmware.
    firmware_path: ?[*:0]const u8 = null,
    /// UEFI variables file path. Created if doesn't exist.
    vars_path: ?[*:0]const u8 = null,
    kernel_path: ?[*:0]const u8 = null,
    initrd_path: ?[*:0]const u8 = null,
    cmdline: ?[*:0]const u8 = null,
    disk_path: ?[*:0]const u8 = null,
    disk_read_only: bool = false,
    /// Secondary disk path (typically ISO for installation).
    disk2_path: ?[*:0]const u8 = null,
    /// Whether secondary disk is read-only (default: true for ISO).
    disk2_read_only: bool = true,
    /// Enable virtio-net with host-side NAT (DHCP/DNS/TCP/UDP).
    enable_net: bool = false,
    /// Initial guest display size in pixels (0 = machine default).
    display_width: u32 = 0,
    display_height: u32 = 0,

    /// Validate configuration for sanity.
    pub fn validate(self: VMConfig) bool {
        if (self.memory_bytes == 0) return false;
        if (self.vcpu_count == 0) return false;
        return true;
    }

    /// Dupe a C string to owned slice.
    fn dupeString(alloc: Allocator, ptr: ?[*:0]const u8) Allocator.Error!?[]const u8 {
        if (ptr) |p| {
            const slice = std.mem.span(p);
            if (slice.len == 0) return null;
            return try alloc.dupe(u8, slice);
        }
        return null;
    }

    /// Create owned copy of all string fields.
    pub fn dupe(self: VMConfig, alloc: Allocator) Allocator.Error!OwnedVMConfig {
        return OwnedVMConfig{
            .memory_bytes = self.memory_bytes,
            .vcpu_count = self.vcpu_count,
            .firmware_path = try dupeString(alloc, self.firmware_path),
            .vars_path = try dupeString(alloc, self.vars_path),
            .kernel_path = try dupeString(alloc, self.kernel_path),
            .initrd_path = try dupeString(alloc, self.initrd_path),
            .cmdline = try dupeString(alloc, self.cmdline),
            .disk_path = try dupeString(alloc, self.disk_path),
            .disk_read_only = self.disk_read_only,
            .disk2_path = try dupeString(alloc, self.disk2_path),
            .disk2_read_only = self.disk2_read_only,
            .enable_net = self.enable_net,
            .display_width = self.display_width,
            .display_height = self.display_height,
        };
    }
};

/// Owned VM configuration (strings are allocated, must be freed).
pub const OwnedVMConfig = struct {
    memory_bytes: u64,
    vcpu_count: u8,
    firmware_path: ?[]const u8 = null,
    vars_path: ?[]const u8 = null,
    kernel_path: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
    cmdline: ?[]const u8 = null,
    disk_path: ?[]const u8 = null,
    disk_read_only: bool = false,
    disk2_path: ?[]const u8 = null,
    disk2_read_only: bool = true,
    enable_net: bool = false,
    display_width: u32 = 0,
    display_height: u32 = 0,

    pub fn deinit(self: *OwnedVMConfig, alloc: Allocator) void {
        if (self.firmware_path) |p| alloc.free(p);
        if (self.vars_path) |p| alloc.free(p);
        if (self.kernel_path) |p| alloc.free(p);
        if (self.initrd_path) |p| alloc.free(p);
        if (self.cmdline) |p| alloc.free(p);
        if (self.disk_path) |p| alloc.free(p);
        if (self.disk2_path) |p| alloc.free(p);
        self.* = .{ .memory_bytes = 0, .vcpu_count = 0 };
    }
};

/// Keyboard event from Swift.
pub const KeyEvent = extern struct {
    keycode: u32,
    modifiers: u32,
    pressed: bool,
};

/// Mouse button enumeration.
pub const MouseButton = enum(c_int) {
    left = 0,
    right = 1,
    middle = 2,
};

/// Content scale for HiDPI displays.
pub const ContentScale = extern struct {
    x: f64 = 1.0,
    y: f64 = 1.0,
};

/// Application instance.
/// Manages VMs and coordinates with Swift runtime via callbacks.
pub const App = struct {
    alloc: Allocator,
    runtime: RuntimeConfig,
    vms: std.ArrayListUnmanaged(*VM),

    pub const CreateError = Allocator.Error;

    pub fn create(runtime: *const RuntimeConfig) CreateError!*App {
        // Pre-condition: runtime must be valid pointer (guaranteed by caller)
        const alloc = std.heap.c_allocator;

        log.debug("creating app instance", .{});

        const app = try alloc.create(App);
        errdefer alloc.destroy(app);

        app.* = .{
            .alloc = alloc,
            .runtime = runtime.*,
            .vms = .empty,
        };

        // Post-condition: app is initialized
        assert(app.vms.items.len == 0);

        // Register with global state for signal cleanup
        global.state.setActiveApp(app);

        log.info("app created successfully", .{});
        return app;
    }

    pub fn destroy(self: *App) void {
        // Pre-condition: self is valid
        assert(self.vms.items.len <= 1024); // Sanity bound

        log.debug("destroying app with {} VMs", .{self.vms.items.len});

        // Unregister from global state
        global.state.setActiveApp(null);

        for (self.vms.items) |vm| {
            vm.destroy();
        }
        self.vms.deinit(self.alloc);
        self.alloc.destroy(self);

        log.info("app destroyed", .{});
    }

    /// Process pending events from all VMs.
    /// Called from Swift main thread periodically.
    pub fn tick(self: *App) void {
        for (self.vms.items) |vm| {
            vm.tick();
        }
    }

    pub fn createVM(self: *App, cfg: *const VMConfig) !*VM {
        // Pre-condition: config is valid
        assert(cfg.validate());

        log.debug("creating VM: {}MB RAM, {} vCPUs", .{
            cfg.memory_bytes / (1024 * 1024),
            cfg.vcpu_count,
        });

        const vm = try VM.create(self, cfg);
        errdefer vm.destroy();

        try self.vms.append(self.alloc, vm);

        // Post-condition: VM added to list
        assert(self.vms.items.len > 0);

        log.info("VM created (total: {})", .{self.vms.items.len});
        return vm;
    }

    /// Remove VM from app's list (called by VM.destroy).
    fn removeVM(self: *App, vm: *VM) void {
        for (self.vms.items, 0..) |v, i| {
            if (v == vm) {
                _ = self.vms.swapRemove(i);
                return;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Swift Callbacks
    // -------------------------------------------------------------------------

    /// Wake Swift main thread.
    pub fn wakeup(self: *App) void {
        if (self.runtime.wakeup) |cb| {
            cb(self.runtime.userdata);
        }
    }

    /// Request window title change.
    pub fn setTitle(self: *App, title: [*:0]const u8) void {
        if (self.runtime.set_title) |cb| {
            cb(self.runtime.userdata, title);
        }
    }

    /// Request window close.
    pub fn requestClose(self: *App) void {
        if (self.runtime.request_close) |cb| {
            cb(self.runtime.userdata);
        }
    }

    /// Notify Swift that a GPU frame is ready.
    pub fn notifyFrameReady(self: *App) void {
        if (self.runtime.gpu_frame_ready) |cb| {
            cb(self.runtime.userdata);
        }
    }

    /// Send console output to Swift.
    pub fn sendConsoleOutput(self: *App, data: []const u8) void {
        if (self.runtime.console_output) |cb| {
            cb(self.runtime.userdata, data.ptr, data.len);
        }
    }
};

/// Virtual machine instance.
pub const VM = struct {
    alloc: Allocator,
    app: *App,
    config: OwnedVMConfig,
    state: State,
    surfaces: std.ArrayListUnmanaged(*Surface),

    /// The actual machine (hypervisor + devices).
    hw_machine: ?*machine.Machine = null,

    /// Thread running the synchronous vCPU loop.
    vcpu_thread: ?std.Thread = null,

    pub const State = enum {
        stopped,
        running,
        paused,
    };

    pub const CreateError = Allocator.Error;

    pub fn create(app: *App, cfg: *const VMConfig) CreateError!*VM {
        // Pre-condition: app is valid
        assert(cfg.validate());

        const vm = try app.alloc.create(VM);
        errdefer app.alloc.destroy(vm);

        // Dupe the config to own the string data
        const owned_config = try cfg.dupe(app.alloc);

        vm.* = .{
            .alloc = app.alloc,
            .app = app,
            .config = owned_config,
            .state = .stopped,
            .surfaces = .empty,
        };

        // Post-condition: VM starts stopped with no surfaces
        assert(vm.state == .stopped);
        assert(vm.surfaces.items.len == 0);

        return vm;
    }

    pub fn destroy(self: *VM) void {
        // Pre-condition: reasonable surface count
        assert(self.surfaces.items.len <= 16);

        // Destroy surfaces first: their renderer threads read the GPU
        // scanout owned by the machine.
        while (self.surfaces.items.len > 0) {
            self.surfaces.items[self.surfaces.items.len - 1].destroy();
        }
        self.surfaces.deinit(self.alloc);

        // Then stop and destroy the machine (joins the vCPU thread)
        self.stop();

        // Free owned config strings
        self.config.deinit(self.alloc);

        // Remove from app's VM list
        self.app.removeVM(self);

        self.alloc.destroy(self);
    }

    pub fn tick(self: *VM) void {
        _ = self;
        // TODO: Process VM events from hypervisor
    }

    pub fn start(self: *VM) !void {
        // Pre-condition: must be stopped or paused to start
        if (self.state != .stopped and self.state != .paused) {
            return error.InvalidState;
        }

        // Create and start the machine
        if (self.hw_machine == null) {
            log.info("creating hardware machine", .{});

            // Convert OwnedVMConfig to MachineConfig (owned slices are used directly)
            if (self.config.firmware_path) |fw| {
                log.info("firmware_path from config: {s}", .{fw});
            } else {
                log.info("firmware_path is null", .{});
            }

            const machine_config = machine.MachineConfig{
                .ram_size = self.config.memory_bytes,
                .vcpu_count = self.config.vcpu_count,
                .firmware_path = self.config.firmware_path,
                .vars_path = self.config.vars_path,
                .kernel_path = self.config.kernel_path,
                .initrd_path = self.config.initrd_path,
                .disk_path = self.config.disk_path,
                .disk_read_only = self.config.disk_read_only,
                .disk2_path = self.config.disk2_path,
                .disk2_read_only = self.config.disk2_read_only,
                .cmdline = self.config.cmdline orelse "console=hvc0 earlycon=pl011,0x09000000",
                // GUI VMs always get a display device.
                .enable_gpu = true,
                .enable_net = self.config.enable_net,
                .display_width = if (self.config.display_width != 0) self.config.display_width else 1280,
                .display_height = if (self.config.display_height != 0) self.config.display_height else 800,
            };

            self.hw_machine = machine.Machine.init(self.alloc, machine_config) catch |err| {
                log.err("failed to create machine: {}", .{err});
                return error.MachineCreationFailed;
            };

            // Set console output callback
            self.hw_machine.?.setConsoleOutput(consoleOutputCallback, self);
        }

        // Run the synchronous vCPU loop on a dedicated thread (the same
        // proven loop the CLI uses; the async VMRunner path is legacy).
        self.vcpu_thread = std.Thread.spawn(.{}, vcpuThreadMain, .{self.hw_machine.?}) catch |err| {
            log.warn("failed to spawn vCPU thread: {}", .{err});
            return error.MachineStartFailed;
        };

        self.state = .running;

        // Post-condition: now running
        assert(self.state == .running);
        log.info("VM started", .{});
    }

    fn vcpuThreadMain(hw: *machine.Machine) void {
        hw.startSync() catch |err| {
            log.warn("vCPU loop failed: {}", .{err});
        };
    }

    pub fn stop(self: *VM) void {
        log.info("stopping VM", .{});

        if (self.hw_machine) |hw| {
            hw.stop();
            if (self.vcpu_thread) |thread| {
                thread.join();
                self.vcpu_thread = null;
            }
            // Must fully deinit to release hypervisor (only one VM per process)
            hw.deinit();
            self.hw_machine = null;
        }

        self.state = .stopped;

        // Post-condition: now stopped
        assert(self.state == .stopped);
    }

    /// Ask the guest to shut down cleanly via qemu-guest-agent. The VM
    /// stops through the normal guest-initiated poweroff path; callers
    /// keep stop() as the force fallback.
    pub fn requestGracefulShutdown(self: *VM) void {
        if (self.hw_machine) |hw| hw.requestGuestShutdown();
    }

    pub fn pause(self: *VM) void {
        if (self.state == .running) {
            // Real pause: vCPUs park, all guest state stays intact.
            // (This used to stop() the machine — "resume" was a cold boot.)
            if (self.hw_machine) |hw| hw.pause();
            self.state = .paused;
        }
    }

    pub fn unpause(self: *VM) void {
        if (self.state == .paused) {
            if (self.hw_machine) |hw| hw.unpause();
            self.state = .running;
        }
    }

    /// Kick a specific vCPU to wake it from WFI/sleep.
    pub fn kickVcpu(self: *VM, vcpu_id: u32) void {
        if (self.hw_machine) |hw| {
            hw.kickVcpu(vcpu_id);
        }
    }

    /// Force all vCPUs to exit from hv_vcpu_run (for debugging).
    pub fn forceExitAll(self: *VM) void {
        if (self.hw_machine) |hw| {
            hw.forceExitAllVcpus();
        }
    }

    fn consoleOutputCallback(data: []const u8, userdata: ?*anyopaque) void {
        const vm: *VM = @ptrCast(@alignCast(userdata orelse return));
        // Route to Swift via App callback
        vm.app.sendConsoleOutput(data);
    }

    pub fn createSurface(
        self: *VM,
        mtl_device: *anyopaque,
        mtl_layer: *anyopaque,
        mtl_queue: *anyopaque,
    ) !*Surface {
        const surface = try Surface.create(self, mtl_device, mtl_layer, mtl_queue);
        errdefer surface.destroy();

        try self.surfaces.append(self.alloc, surface);

        // Post-condition: surface added
        assert(self.surfaces.items.len > 0);

        return surface;
    }

    /// Remove surface from VM's list (called by Surface.destroy).
    fn removeSurface(self: *VM, surface: *Surface) void {
        for (self.surfaces.items, 0..) |s, i| {
            if (s == surface) {
                _ = self.surfaces.swapRemove(i);
                return;
            }
        }
    }
};

/// Display surface.
/// Swift owns the NSView + CAMetalLayer. Zig owns all Metal rendering.
pub const Surface = struct {
    alloc: Allocator,
    vm: *VM,
    mtl_device: *anyopaque,
    mtl_layer: *anyopaque,
    mtl_queue: *anyopaque,
    width: u32,
    height: u32,
    content_scale: ContentScale,
    focused: bool,
    render: renderer.Renderer,
    render_started: bool,
    last_mouse_x: f64 = 0,
    last_mouse_y: f64 = 0,

    pub const CreateError = Allocator.Error || std.Thread.SpawnError;

    pub fn create(
        vm: *VM,
        mtl_device: *anyopaque,
        mtl_layer: *anyopaque,
        mtl_queue: *anyopaque,
    ) CreateError!*Surface {
        const surface = try vm.alloc.create(Surface);
        errdefer vm.alloc.destroy(surface);

        surface.* = .{
            .alloc = vm.alloc,
            .vm = vm,
            .mtl_device = mtl_device,
            .mtl_layer = mtl_layer,
            .mtl_queue = mtl_queue,
            .width = 0,
            .height = 0,
            .content_scale = .{},
            .focused = false,
            .render = renderer.Renderer.init(vm.alloc, mtl_device, mtl_layer, mtl_queue),
            .render_started = false,
        };

        // Feed the renderer from the VM's virtio-gpu scanout.
        surface.render.setScanoutSource(scanoutLock, scanoutUnlock, vm);

        return surface;
    }

    fn scanoutLock(userdata: ?*anyopaque) ?renderer.Thread.Scanout {
        const vm: *VM = @ptrCast(@alignCast(userdata orelse return null));
        const hw = vm.hw_machine orelse return null;
        const gpu = hw.gpu orelse return null;
        const view = gpu.lockScanout() orelse return null;
        return .{
            .data = view.data,
            .width = view.width,
            .height = view.height,
            .generation = view.generation,
            .surface = view.surface,
            .cursor = if (view.cursor) |c| .{
                .data = c.data,
                .width = c.width,
                .height = c.height,
                .hot_x = c.hot_x,
                .hot_y = c.hot_y,
                .x = c.x,
                .y = c.y,
                .generation = c.generation,
            } else null,
        };
    }

    fn scanoutUnlock(userdata: ?*anyopaque) void {
        const vm: *VM = @ptrCast(@alignCast(userdata orelse return));
        const hw = vm.hw_machine orelse return;
        const gpu = hw.gpu orelse return;
        gpu.unlockScanout();
    }

    pub fn destroy(self: *Surface) void {
        // Stop renderer thread first
        self.render.deinit();

        // Remove from VM's surface list
        self.vm.removeSurface(self);
        self.alloc.destroy(self);
    }

    pub fn setSize(self: *Surface, width: u32, height: u32) void {
        // Pre-condition: valid dimensions
        assert(width > 0);
        assert(height > 0);

        self.width = width;
        self.height = height;

        // Notify renderer of size change
        self.render.resize(width, height);

        // Post-condition: size updated
        assert(self.width == width);
        assert(self.height == height);
    }

    /// Request a live guest display resolution change (virtio-gpu display
    /// hotplug). Unlike setSize, this reaches into the guest; the drawable
    /// follows once the guest modesets. Safe to call from any thread.
    pub fn requestDisplaySize(self: *Surface, width: u32, height: u32) void {
        const hw = self.vm.hw_machine orelse return;
        hw.requestDisplayResize(width, height);
    }

    pub fn setContentScale(self: *Surface, x: f64, y: f64) void {
        // Pre-condition: positive scales
        assert(x > 0.0);
        assert(y > 0.0);

        self.content_scale = .{ .x = x, .y = y };

        // Notify renderer
        self.render.setContentScale(x, y);
    }

    pub fn setFocus(self: *Surface, focused: bool) void {
        self.focused = focused;
        self.render.setFocus(focused);
    }

    /// Start the renderer thread.
    /// Called after surface is configured with size.
    pub fn startRenderer(self: *Surface) !void {
        if (self.render_started) return;
        try self.render.start();
        self.render_started = true;
    }

    pub fn draw(self: *Surface) void {
        // Pre-condition: must have valid size to draw
        if (self.width == 0 or self.height == 0) return;

        // Start renderer on first draw if not started
        if (!self.render_started) {
            self.startRenderer() catch return;
        }

        // Request frame from renderer thread
        self.render.requestFrame();
    }

    // -------------------------------------------------------------------------
    // Input Handling
    // -------------------------------------------------------------------------

    pub fn handleKey(self: *Surface, event: KeyEvent) void {
        const hw = self.vm.hw_machine orelse return;
        const evdev_code = keymap.macosToEvdev(event.keycode);
        if (evdev_code == keymap.UNMAPPED) return;
        hw.injectKey(evdev_code, event.pressed);
    }

    pub fn handleMouseButton(self: *Surface, button: MouseButton, pressed: bool) void {
        const hw = self.vm.hw_machine orelse return;
        const evdev_button: u16 = switch (button) {
            .left => 0x110, // BTN_LEFT
            .right => 0x111, // BTN_RIGHT
            .middle => 0x112, // BTN_MIDDLE
        };
        hw.injectMouseButton(evdev_button, pressed);
    }

    pub fn handleMousePos(self: *Surface, x: f64, y: f64) void {
        const hw = self.vm.hw_machine orelse return;
        // Relative device: convert absolute view coords to deltas.
        const dx: i32 = @intFromFloat(x - self.last_mouse_x);
        const dy: i32 = @intFromFloat(y - self.last_mouse_y);
        self.last_mouse_x = x;
        self.last_mouse_y = y;
        if (dx != 0 or dy != 0) {
            hw.injectMouseMove(dx, dy);
        }
    }

    pub fn handleMouseScroll(self: *Surface, dx: f64, dy: f64) void {
        const hw = self.vm.hw_machine orelse return;
        hw.injectScroll(@intFromFloat(dx), @intFromFloat(dy));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "App lifecycle" {
    var runtime = RuntimeConfig{};

    const app = try App.create(&runtime);
    defer app.destroy();

    app.tick();
}

test "VM lifecycle" {
    // NOTE: This test requires hypervisor entitlements to run.
    // When run without entitlements, VM.start() returns error.Denied.
    // Skip the start/pause/resume/stop tests in CI.
    var runtime = RuntimeConfig{};
    const app = try App.create(&runtime);
    defer app.destroy();

    var cfg = VMConfig{
        .memory_bytes = 1024 * 1024 * 512, // 512MB
        .vcpu_count = 2,
    };

    const vm = try app.createVM(&cfg);
    defer vm.destroy();

    // Try to start - may fail without entitlements
    vm.start() catch |err| {
        if (err == error.MachineStartFailed) {
            // Expected without com.apple.security.hypervisor entitlement
            return;
        }
        return err;
    };

    assert(vm.state == .running);

    vm.pause();
    assert(vm.state == .paused);

    vm.unpause();
    assert(vm.state == .running);

    vm.stop();
    assert(vm.state == .stopped);
}

test "VMConfig validation" {
    const valid = VMConfig{ .memory_bytes = 1024, .vcpu_count = 1 };
    assert(valid.validate());

    const invalid_mem = VMConfig{ .memory_bytes = 0, .vcpu_count = 1 };
    assert(!invalid_mem.validate());

    const invalid_cpu = VMConfig{ .memory_bytes = 1024, .vcpu_count = 0 };
    assert(!invalid_cpu.validate());
}
