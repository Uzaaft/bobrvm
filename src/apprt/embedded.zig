//! Embedded Runtime for macOS/Swift integration.
//!
//! Platform-agnostic wrapper that:
//! - Exports C API functions for Swift FFI
//! - Accepts callback struct from Swift for platform actions
//! - Manages VM instances and surfaces

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const config_policy = @import("../config.zig");
const global = @import("../global.zig");
const machine = @import("../machine/main.zig");
const keymap = @import("keymap.zig");
const renderer = @import("../renderer/main.zig");

const log = std.log.scoped(.apprt);
const clipboard_scratch_bytes = 4 * 1024;

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
    console_output: ?*const fn (
        ?*anyopaque,
        *anyopaque,
        [*]const u8,
        usize,
    ) callconv(.c) void = null,
};

/// VM configuration (C API struct - pointers are temporary).
pub const VMConfig = extern struct {
    memory_bytes: u64 = config_policy.memory_bytes_default,
    vcpu_count: u8 = config_policy.vcpu_count_default,
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
    /// Host directory exported through virtio-9p with mount tag "host".
    shared_dir: ?[*:0]const u8 = null,
    /// Initial guest display size in pixels (0 = machine default).
    display_width: u32 = config_policy.display_width_default,
    display_height: u32 = config_policy.display_height_default,
    /// Host graphics-memory budget for 2D resources and the Venus window.
    gpu_memory_bytes: u64 = config_policy.gpu_memory_bytes_default,
    /// Enable 3D acceleration on the GUI's virtio-gpu (virgl capset, and the
    /// venus capset when built with -Dgpu-venus). Off by default: a 2D-only
    /// scanout is the safe path, and 3D needs the venus host stack present.
    enable_gpu3d: bool = false,

    /// Validate configuration for sanity.
    pub fn validate(self: VMConfig) bool {
        assert(config_policy.memory_bytes_default > 0);
        assert(config_policy.vcpu_count_default > 0);
        config_policy.validate(.{
            .memory_bytes = self.memory_bytes,
            .vcpu_count = self.vcpu_count,
            .display_width = self.display_width,
            .display_height = self.display_height,
            .gpu_memory_bytes = self.gpu_memory_bytes,
            .disk_path = optionalString(self.disk_path),
            .disk_read_only = self.disk_read_only,
            .disk2_path = optionalString(self.disk2_path),
            .disk2_read_only = self.disk2_read_only,
        }) catch return false;
        if (optionalString(self.shared_dir)) |path| {
            if (!std.fs.path.isAbsolute(path)) return false;
        }
        return true;
    }

    fn optionalString(ptr: ?[*:0]const u8) ?[]const u8 {
        assert(@sizeOf(?[*:0]const u8) == @sizeOf(?*const anyopaque));
        assert(@sizeOf(u8) == 1);
        const value = ptr orelse return null;
        const slice = std.mem.span(value);
        return if (slice.len == 0) null else slice;
    }

    /// Create owned copy of all string fields.
    pub fn dupe(self: VMConfig, alloc: Allocator) Allocator.Error!OwnedVMConfig {
        const total = try self.stringStorageBytes();
        const storage: []u8 = if (total > 0) try alloc.alloc(u8, total) else @constCast(&.{});
        return self.copyOwned(storage);
    }

    fn ownedStrings(self: VMConfig) [8]?[]const u8 {
        assert(@sizeOf(@TypeOf(self.firmware_path)) == @sizeOf(?*const anyopaque));
        assert(@sizeOf(@TypeOf(self.disk2_path)) == @sizeOf(?*const anyopaque));
        return .{
            optionalString(self.firmware_path),
            optionalString(self.vars_path),
            optionalString(self.kernel_path),
            optionalString(self.initrd_path),
            optionalString(self.cmdline),
            optionalString(self.disk_path),
            optionalString(self.disk2_path),
            optionalString(self.shared_dir),
        };
    }

    fn stringStorageBytes(self: VMConfig) Allocator.Error!usize {
        const strings = self.ownedStrings();
        var total: usize = 0;
        var string_count: usize = 0;
        for (strings) |string| {
            if (string) |value| {
                total = std.math.add(usize, total, value.len) catch return error.OutOfMemory;
                string_count += 1;
            }
        }
        assert(string_count <= strings.len);
        assert((total == 0) == (string_count == 0));
        return total;
    }

    fn copyOwned(self: VMConfig, storage: []u8) OwnedVMConfig {
        const strings = self.ownedStrings();
        var expected: usize = 0;
        for (strings) |string| {
            if (string) |value| {
                expected += value.len;
            }
        }
        assert(storage.len == expected);
        assert(strings.len == 8);

        var owned_strings: [strings.len]?[]const u8 = @splat(null);
        var offset: usize = 0;
        for (strings, 0..) |string, index| {
            const value = string orelse continue;
            @memcpy(storage[offset..][0..value.len], value);
            owned_strings[index] = storage[offset..][0..value.len];
            offset += value.len;
        }
        assert(offset == storage.len);

        return OwnedVMConfig{
            .memory_bytes = self.memory_bytes,
            .vcpu_count = self.vcpu_count,
            .string_storage = storage,
            .firmware_path = owned_strings[0],
            .vars_path = owned_strings[1],
            .kernel_path = owned_strings[2],
            .initrd_path = owned_strings[3],
            .cmdline = owned_strings[4],
            .disk_path = owned_strings[5],
            .disk_read_only = self.disk_read_only,
            .disk2_path = owned_strings[6],
            .disk2_read_only = self.disk2_read_only,
            .enable_net = self.enable_net,
            .shared_dir = owned_strings[7],
            .display_width = self.display_width,
            .display_height = self.display_height,
            .gpu_memory_bytes = self.gpu_memory_bytes,
            .enable_gpu3d = self.enable_gpu3d,
        };
    }
};

/// Owned VM configuration (strings are allocated, must be freed).
pub const OwnedVMConfig = struct {
    memory_bytes: u64,
    vcpu_count: u8,
    string_storage: []u8 = &.{},
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
    shared_dir: ?[]const u8 = null,
    display_width: u32 = 0,
    display_height: u32 = 0,
    gpu_memory_bytes: u64 = config_policy.gpu_memory_bytes_default,
    enable_gpu3d: bool = false,

    pub fn deinit(self: *OwnedVMConfig, alloc: Allocator) void {
        if (self.string_storage.len > 0) alloc.free(self.string_storage);
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
    vms_head: ?*VM,
    vm_count: usize,
    debug_allocator: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void,

    pub const CreateError = Allocator.Error;

    pub fn create(runtime: *const RuntimeConfig) CreateError!*App {
        // Pre-condition: runtime must be valid pointer (guaranteed by caller)
        const app_alloc = std.heap.c_allocator;

        log.debug("creating app instance", .{});

        const app = try app_alloc.create(App);
        errdefer app_alloc.destroy(app);

        app.* = .{
            .alloc = undefined,
            .runtime = runtime.*,
            .vms_head = null,
            .vm_count = 0,
            .debug_allocator = if (builtin.mode == .Debug) .init else {},
        };
        app.alloc = if (builtin.mode == .Debug)
            app.debug_allocator.allocator()
        else
            std.heap.c_allocator;

        // Post-condition: app is initialized
        assert(app.vms_head == null);
        assert(app.vm_count == 0);

        // Register with global state for signal cleanup
        global.state.setActiveApp(app);

        log.info("app created successfully", .{});
        return app;
    }

    pub fn destroy(self: *App) void {
        // Pre-condition: self is valid
        assert(self.vm_count <= 1024); // Sanity bound

        log.debug("destroying app with {} VMs", .{self.vm_count});

        // Unregister from global state
        global.state.setActiveApp(null);

        while (self.vms_head) |vm| vm.destroy();
        assert(self.vm_count == 0);
        if (builtin.mode == .Debug) _ = self.debug_allocator.deinit();
        std.heap.c_allocator.destroy(self);

        log.info("app destroyed", .{});
    }

    /// Process pending events from all VMs.
    /// Called from Swift main thread periodically.
    pub fn tick(self: *App) void {
        var vm = self.vms_head;
        while (vm) |current| {
            const next = current.app_next;
            current.tick();
            vm = next;
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

        vm.app_next = self.vms_head;
        if (self.vms_head) |head| head.app_prev = vm;
        self.vms_head = vm;
        self.vm_count += 1;

        // Post-condition: VM added to list
        assert(self.vms_head == vm);
        assert(self.vm_count > 0);

        log.info("VM created (total: {})", .{self.vm_count});
        return vm;
    }

    /// Remove VM from app's list (called by VM.destroy).
    fn removeVM(self: *App, vm: *VM) void {
        assert(vm.app == self);
        assert(self.vm_count > 0);
        if (vm.app_prev) |previous| {
            previous.app_next = vm.app_next;
        } else {
            assert(self.vms_head == vm);
            self.vms_head = vm.app_next;
        }
        if (vm.app_next) |next| next.app_prev = vm.app_prev;
        vm.app_prev = null;
        vm.app_next = null;
        self.vm_count -= 1;
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
    pub fn sendConsoleOutput(self: *App, vm: *VM, data: []const u8) void {
        if (self.runtime.console_output) |cb| {
            cb(self.runtime.userdata, vm, data.ptr, data.len);
        }
    }
};

/// Virtual machine instance.
pub const VM = struct {
    alloc: Allocator,
    app: *App,
    app_prev: ?*VM,
    app_next: ?*VM,
    config: OwnedVMConfig,
    state: State,
    surfaces_head: ?*Surface,
    surface_count: usize,

    /// The actual machine (hypervisor + devices).
    hw_machine: ?*machine.Machine = null,

    /// Thread running the synchronous vCPU loop.
    vcpu_thread: ?std.Thread = null,

    /// Stop spans the UI thread (request) and a worker thread (join/deinit).
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_mutex: std.Io.Mutex = .init,

    pub const State = enum {
        stopped,
        running,
        paused,
        stopping,
    };

    pub const CreateError = Allocator.Error;

    pub fn create(app: *App, cfg: *const VMConfig) CreateError!*VM {
        // Pre-condition: app is valid
        assert(cfg.validate());

        const string_storage_bytes = try cfg.stringStorageBytes();
        const allocation_bytes = std.math.add(usize, @sizeOf(VM), string_storage_bytes) catch
            return error.OutOfMemory;
        const allocation = try app.alloc.alignedAlloc(u8, .of(VM), allocation_bytes);
        errdefer app.alloc.free(allocation);
        const vm: *VM = @ptrCast(allocation.ptr);
        const string_storage = allocation[@sizeOf(VM)..];
        const owned_config = cfg.copyOwned(string_storage);

        vm.* = .{
            .alloc = app.alloc,
            .app = app,
            .app_prev = null,
            .app_next = null,
            .config = owned_config,
            .state = .stopped,
            .surfaces_head = null,
            .surface_count = 0,
        };

        // Post-condition: VM starts stopped with no surfaces
        assert(vm.state == .stopped);
        assert(vm.surfaces_head == null);
        assert(vm.surface_count == 0);

        return vm;
    }

    pub fn destroy(self: *VM) void {
        // Pre-condition: reasonable surface count
        assert(self.surface_count <= 16);

        // Destroy surfaces first: their renderer threads read the GPU
        // scanout owned by the machine.
        while (self.surfaces_head) |surface| surface.destroy();
        assert(self.surface_count == 0);

        // Then stop and destroy the machine (joins the vCPU thread)
        self.stop();

        const allocation_bytes = @sizeOf(VM) + self.config.string_storage.len;

        // Reset the config: its string storage is the VM allocation tail.
        self.config = .{ .memory_bytes = 0, .vcpu_count = 0 };

        // Remove from app's VM list
        self.app.removeVM(self);

        const allocation_ptr: [*]align(@alignOf(VM)) u8 = @ptrCast(self);
        self.alloc.free(allocation_ptr[0..allocation_bytes]);
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
                // GUI VMs always get a display device; 3D (virgl/venus) is
                // opt-in via the config so a plain 2D scanout stays the default.
                .enable_gpu = true,
                .enable_virgl = self.config.enable_gpu3d,
                .enable_net = self.config.enable_net,
                .shared_dir = self.config.shared_dir,
                .display_width = if (self.config.display_width != 0)
                    self.config.display_width
                else
                    1280,
                .display_height = if (self.config.display_height != 0)
                    self.config.display_height
                else
                    800,
                .gpu_memory_bytes = if (self.config.gpu_memory_bytes != 0)
                    self.config.gpu_memory_bytes
                else
                    config_policy.gpu_memory_bytes_default,
            };

            self.hw_machine = machine.Machine.init(self.alloc, machine_config) catch |err| {
                log.err("failed to create machine: {}", .{err});
                return error.MachineCreationFailed;
            };

            // Set console output callback
            self.hw_machine.?.setConsoleOutput(consoleOutputCallback, self);

            // Bridge the X11 and Wayland guest channels to the app's system
            // clipboard callbacks (NSPasteboard on the Swift side).
            self.hw_machine.?.setClipboardHandlers(
                guestClipboardCallback,
                requestHostClipboardCallback,
                self,
            );
        }

        // Run the synchronous vCPU loop on a dedicated thread (the same
        // proven loop the CLI uses; the async VMRunner path is legacy).
        self.hw_machine.?.prepareStart();
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
        assert(hw.config.vcpu_count > 0);
        assert(hw.cpu_states.len == hw.config.vcpu_count);
        hw.startSyncPrepared() catch |err| {
            if (err == error.StartCancelled) {
                log.debug("VM startup cancelled", .{});
                return;
            }
            log.warn("vCPU loop failed: {}", .{err});
        };
    }

    pub fn stop(self: *VM) void {
        self.requestStop();
        self.finishStop();
    }

    /// Synchronously quiesce renderers and signal the machine to stop, but
    /// leave the potentially blocking vCPU join to finishStop.
    pub fn requestStop(self: *VM) void {
        assert(self.surface_count <= 16);
        assert(self.vcpu_thread != null or self.hw_machine == null);
        if (self.stopping.swap(true, .acq_rel)) return;
        log.info("stopping VM", .{});

        // Renderer threads read the machine's virtio-gpu scanout. Join them
        // before destroying the machine so no surface can retain a pointer to
        // GPU memory during teardown. The surfaces themselves remain alive and
        // restart their renderers on the next draw after a VM restart.
        var surface = self.surfaces_head;
        while (surface) |current| {
            const next = current.vm_next;
            current.stopRenderer();
            surface = next;
        }

        if (self.hw_machine) |hw| {
            hw.stop();
        }
        self.state = .stopping;
    }

    /// Join and destroy the stopped machine. Safe to run off the UI thread
    /// after requestStop has quiesced every surface.
    pub fn finishStop(self: *VM) void {
        self.stop_mutex.lockUncancelable(global.io());
        defer self.stop_mutex.unlock(global.io());
        if (!self.stopping.load(.acquire)) return;
        assert(self.state == .stopping);
        assert(self.hw_machine != null or self.vcpu_thread == null);
        if (self.vcpu_thread) |thread| {
            thread.join();
            self.vcpu_thread = null;
        }
        if (self.hw_machine) |hw| {
            // Must fully deinit to release hypervisor (only one VM per process).
            hw.deinit();
            self.hw_machine = null;
        }

        self.state = .stopped;
        self.stopping.store(false, .release);

        // Post-condition: now stopped
        assert(self.state == .stopped);
    }

    /// Ask the guest to shut down cleanly via qemu-guest-agent. The VM
    /// stops through the normal guest-initiated poweroff path; callers
    /// keep stop() as the force fallback.
    pub fn requestGracefulShutdown(self: *VM) void {
        if (self.hw_machine) |hw| hw.requestGuestShutdown();
    }

    pub fn requestGuestReboot(self: *VM) void {
        if (self.hw_machine) |hw| hw.requestGuestReboot();
    }

    pub fn trimGuestFilesystems(self: *VM) void {
        if (self.hw_machine) |hw| hw.trimGuestFilesystems();
    }

    pub fn syncGuestTime(self: *VM) void {
        if (self.hw_machine) |hw| hw.syncGuestTime();
    }

    pub fn guestManagementReady(self: *const VM) bool {
        if (self.hw_machine) |hw| return hw.guestManagementReady();
        return false;
    }

    pub fn snapshotQuiesced(self: *VM, dir: []const u8) !void {
        const hw = self.hw_machine orelse return error.InvalidState;
        try hw.snapshotToQuiesced(dir);
    }

    pub fn guestToolsStatus(self: *const VM) machine.GuestToolsStatus {
        if (self.hw_machine) |hw| return hw.guestToolsStatus();
        return .disconnected;
    }

    pub fn guestToolsCapabilities(self: *const VM) u64 {
        if (self.hw_machine) |hw| return hw.guestToolsCapabilities();
        return 0;
    }

    pub fn sendFileToGuest(self: *VM, path: []const u8) !void {
        const hw = self.hw_machine orelse return error.InvalidState;
        try hw.sendFileToGuest(path);
    }

    /// Host clipboard changed: announce to every connected guest backend.
    /// The requesting backend then pulls data through read_clipboard.
    pub fn hostClipboardChanged(self: *VM) void {
        if (self.hw_machine) |hw| hw.hostClipboardGrab();
    }

    /// Guest copied text (vCPU thread): push to the system clipboard.
    fn guestClipboardCallback(text: []const u8, userdata: ?*anyopaque) void {
        const self: *VM = @ptrCast(@alignCast(userdata));
        const cb = self.app.runtime.write_clipboard orelse return;
        assert(clipboard_scratch_bytes > 0);
        assert(text.len < std.math.maxInt(usize));
        var stack_allocator = std.heap.stackFallback(clipboard_scratch_bytes, self.alloc);
        const temp_alloc = stack_allocator.get();
        const c = temp_alloc.dupeZ(u8, text) catch return;
        defer temp_alloc.free(c);
        cb(self.app.runtime.userdata, c.ptr);
    }

    /// Guest wants to paste (vCPU thread): pull the system clipboard and
    /// answer through the machine.
    fn requestHostClipboardCallback(userdata: ?*anyopaque) void {
        const self: *VM = @ptrCast(@alignCast(userdata));
        const read_cb = self.app.runtime.read_clipboard orelse return;
        var text: ?[*:0]u8 = null;
        if (!read_cb(self.app.runtime.userdata, &text)) return;
        const t = text orelse return;
        if (self.hw_machine) |hw| hw.sendHostClipboard(std.mem.span(t));
        if (self.app.runtime.free_clipboard) |free_cb| {
            free_cb(self.app.runtime.userdata, t);
        }
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
        vm.app.sendConsoleOutput(vm, data);
    }

    pub fn createSurface(
        self: *VM,
        mtl_device: *anyopaque,
        mtl_layer: *anyopaque,
        mtl_queue: *anyopaque,
    ) !*Surface {
        const surface = try Surface.create(self, mtl_device, mtl_layer, mtl_queue);

        surface.vm_next = self.surfaces_head;
        if (self.surfaces_head) |head| head.vm_prev = surface;
        self.surfaces_head = surface;
        self.surface_count += 1;

        // Post-condition: surface added
        assert(self.surfaces_head == surface);
        assert(self.surface_count > 0);

        return surface;
    }

    /// Remove surface from VM's list (called by Surface.destroy).
    fn removeSurface(self: *VM, surface: *Surface) void {
        assert(surface.vm == self);
        assert(self.surface_count > 0);
        if (surface.vm_prev) |previous| {
            previous.vm_next = surface.vm_next;
        } else {
            assert(self.surfaces_head == surface);
            self.surfaces_head = surface.vm_next;
        }
        if (surface.vm_next) |next| next.vm_prev = surface.vm_prev;
        surface.vm_prev = null;
        surface.vm_next = null;
        self.surface_count -= 1;
    }
};

/// Display surface.
/// Swift owns the NSView + CAMetalLayer. Zig owns all Metal rendering.
pub const Surface = struct {
    alloc: Allocator,
    vm: *VM,
    vm_prev: ?*Surface,
    vm_next: ?*Surface,
    mtl_device: *anyopaque,
    mtl_layer: *anyopaque,
    mtl_queue: *anyopaque,
    width: u32,
    height: u32,
    content_scale: ContentScale,
    focused: bool,
    render: renderer.Renderer,
    render_started: bool,
    presentation_generation_seen: u64,

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
            .vm_prev = null,
            .vm_next = null,
            .mtl_device = mtl_device,
            .mtl_layer = mtl_layer,
            .mtl_queue = mtl_queue,
            .width = 0,
            .height = 0,
            .content_scale = .{},
            .focused = false,
            .render = renderer.Renderer.init(vm.alloc, mtl_device, mtl_layer, mtl_queue),
            .render_started = false,
            .presentation_generation_seen = std.math.maxInt(u64),
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
            .src_x = view.src_x,
            .src_y = view.src_y,
            .full_width = view.full_width,
            .full_height = view.full_height,
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

    fn stopRenderer(self: *Surface) void {
        self.render.stop();
        self.render_started = false;
        self.presentation_generation_seen = std.math.maxInt(u64);
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
        if (self.vm.stopping.load(.acquire)) return;
        const hw = self.vm.hw_machine orelse return;
        const gpu = hw.gpu orelse return;
        const generation = gpu.presentationGeneration();
        if (generation == self.presentation_generation_seen) return;

        // Start renderer on first draw if not started
        if (!self.render_started) {
            self.startRenderer() catch return;
        }

        // Request frame from renderer thread
        self.presentation_generation_seen = generation;
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
        if (self.width == 0 or self.height == 0) return;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;

        const abs_x = pointerAxis(x, self.content_scale.x, self.width);
        const abs_y = pointerAxis(y, self.content_scale.y, self.height);
        hw.injectMousePosition(abs_x, abs_y);
    }

    pub fn handleMouseScroll(self: *Surface, dx: f64, dy: f64) void {
        const hw = self.vm.hw_machine orelse return;
        hw.injectScroll(@intFromFloat(dx), @intFromFloat(dy));
    }
};

fn pointerAxis(value: f64, content_scale: f64, surface_pixels: u32) i32 {
    assert(content_scale > 0.0);
    assert(surface_pixels > 0);

    const extent_points = @as(f64, @floatFromInt(surface_pixels)) / content_scale;
    const clamped = @max(0.0, @min(value, extent_points));
    const axis_max = 32767.0;
    return @intFromFloat(clamped * axis_max / extent_points);
}

// =============================================================================
// Tests
// =============================================================================

test "App lifecycle" {
    var runtime = RuntimeConfig{};

    const app = try App.create(&runtime);
    defer app.destroy();

    app.tick();
}

test "pointer axis maps view points through backing scale" {
    try std.testing.expectEqual(@as(i32, 0), pointerAxis(-20, 2, 2000));
    try std.testing.expectEqual(@as(i32, 16383), pointerAxis(500, 2, 2000));
    try std.testing.expectEqual(@as(i32, 32767), pointerAxis(1000, 2, 2000));
    try std.testing.expectEqual(@as(i32, 32767), pointerAxis(1200, 2, 2000));
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

    const invalid_share = VMConfig{
        .memory_bytes = 1024,
        .vcpu_count = 1,
        .shared_dir = "relative/path",
    };
    assert(!invalid_share.validate());
}

test "guest clipboard callback forwards text" {
    const Clipboard = struct {
        var calls: usize = 0;
        var length: usize = 0;

        fn write(_: ?*anyopaque, text: [*:0]const u8) callconv(.c) void {
            calls += 1;
            length = std.mem.len(text);
        }
    };
    Clipboard.calls = 0;
    Clipboard.length = 0;

    var runtime = RuntimeConfig{ .write_clipboard = Clipboard.write };
    const app = try App.create(&runtime);
    defer app.destroy();
    const cfg = VMConfig{ .memory_bytes = 1024, .vcpu_count = 1 };
    const vm = try app.createVM(&cfg);
    defer vm.destroy();

    const base_alloc = vm.alloc;
    defer vm.alloc = base_alloc;
    var counted = std.testing.FailingAllocator.init(base_alloc, .{});
    vm.alloc = counted.allocator();
    VM.guestClipboardCallback("clipboard text", vm);

    try std.testing.expectEqual(@as(usize, 0), counted.allocations);
    try std.testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), Clipboard.calls);
    try std.testing.expectEqual("clipboard text".len, Clipboard.length);

    const large: [clipboard_scratch_bytes]u8 = @splat('x');
    VM.guestClipboardCallback(&large, vm);
    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqual(@as(usize, clipboard_scratch_bytes + 1), counted.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 2), Clipboard.calls);
    try std.testing.expectEqual(large.len, Clipboard.length);
}

test "VMConfig owns strings in one allocation" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = counted.allocator();
    const cfg = VMConfig{
        .memory_bytes = 1024,
        .vcpu_count = 1,
        .firmware_path = "firmware.fd",
        .vars_path = "vars.fd",
        .kernel_path = "kernel",
        .initrd_path = "initrd",
        .cmdline = "console=hvc0",
        .disk_path = "disk.raw",
        .disk2_path = "install.iso",
        .shared_dir = "/Users/example/Shared",
    };

    var owned = try cfg.dupe(alloc);
    defer owned.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqualStrings("firmware.fd", owned.firmware_path.?);
    try std.testing.expectEqualStrings("console=hvc0", owned.cmdline.?);
    try std.testing.expectEqualStrings("install.iso", owned.disk2_path.?);
    try std.testing.expectEqualStrings("/Users/example/Shared", owned.shared_dir.?);
}

test "App VM registry does not allocate" {
    var runtime = RuntimeConfig{};
    const app = try App.create(&runtime);
    defer app.destroy();

    const base_alloc = app.alloc;
    var counted = std.testing.FailingAllocator.init(base_alloc, .{});
    app.alloc = counted.allocator();
    const cfg = VMConfig{ .memory_bytes = 1024, .vcpu_count = 1 };
    const vm = try app.createVM(&cfg);

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    vm.destroy();
    app.alloc = base_alloc;
}

test "VM object and configuration storage share one allocation" {
    var runtime = RuntimeConfig{};
    const app = try App.create(&runtime);
    defer app.destroy();

    const base_alloc = app.alloc;
    var counted = std.testing.FailingAllocator.init(base_alloc, .{});
    app.alloc = counted.allocator();
    const cfg = VMConfig{
        .memory_bytes = 1024,
        .vcpu_count = 1,
        .firmware_path = "firmware.fd",
        .vars_path = "vars.fd",
        .kernel_path = "kernel",
        .initrd_path = "initrd",
        .cmdline = "console=hvc0",
        .disk_path = "disk.raw",
        .disk2_path = "install.iso",
        .shared_dir = "/Users/example/Shared",
    };
    const string_bytes = "firmware.fd".len + "vars.fd".len + "kernel".len +
        "initrd".len + "console=hvc0".len + "disk.raw".len + "install.iso".len +
        "/Users/example/Shared".len;
    const vm = try app.createVM(&cfg);

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqual(@sizeOf(VM) + string_bytes, counted.allocated_bytes);
    try std.testing.expectEqualStrings("firmware.fd", vm.config.firmware_path.?);
    try std.testing.expectEqualStrings("console=hvc0", vm.config.cmdline.?);
    try std.testing.expectEqualStrings("install.iso", vm.config.disk2_path.?);
    try std.testing.expectEqualStrings("/Users/example/Shared", vm.config.shared_dir.?);
    vm.destroy();
    app.alloc = base_alloc;
}

test "App VM registry unlinks arbitrary entries" {
    var runtime = RuntimeConfig{};
    const app = try App.create(&runtime);
    defer app.destroy();
    const cfg = VMConfig{ .memory_bytes = 1024, .vcpu_count = 1 };

    const first = try app.createVM(&cfg);
    const middle = try app.createVM(&cfg);
    const last = try app.createVM(&cfg);
    try std.testing.expectEqual(@as(usize, 3), app.vm_count);

    middle.destroy();
    try std.testing.expectEqual(@as(usize, 2), app.vm_count);
    try std.testing.expect(last.app_next == first);
    try std.testing.expect(first.app_prev == last);

    first.destroy();
    last.destroy();
    try std.testing.expectEqual(@as(usize, 0), app.vm_count);
    try std.testing.expect(app.vms_head == null);
}

test "VM surface registry does not allocate" {
    var runtime = RuntimeConfig{};
    const app = try App.create(&runtime);
    defer app.destroy();
    const cfg = VMConfig{ .memory_bytes = 1024, .vcpu_count = 1 };
    const vm = try app.createVM(&cfg);

    const base_alloc = vm.alloc;
    var counted = std.testing.FailingAllocator.init(base_alloc, .{});
    vm.alloc = counted.allocator();
    const dummy: *anyopaque = @ptrFromInt(1);
    const surface = try vm.createSurface(dummy, dummy, dummy);

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    surface.destroy();
    vm.alloc = base_alloc;
}

test "VM surface registry unlinks arbitrary entries" {
    var runtime = RuntimeConfig{};
    const app = try App.create(&runtime);
    defer app.destroy();
    const cfg = VMConfig{ .memory_bytes = 1024, .vcpu_count = 1 };
    const vm = try app.createVM(&cfg);
    const dummy: *anyopaque = @ptrFromInt(1);

    const first = try vm.createSurface(dummy, dummy, dummy);
    const middle = try vm.createSurface(dummy, dummy, dummy);
    const last = try vm.createSurface(dummy, dummy, dummy);
    try std.testing.expectEqual(@as(usize, 3), vm.surface_count);

    middle.destroy();
    try std.testing.expectEqual(@as(usize, 2), vm.surface_count);
    try std.testing.expect(last.vm_next == first);
    try std.testing.expect(first.vm_prev == last);

    first.destroy();
    last.destroy();
    try std.testing.expectEqual(@as(usize, 0), vm.surface_count);
    try std.testing.expect(vm.surfaces_head == null);
}
