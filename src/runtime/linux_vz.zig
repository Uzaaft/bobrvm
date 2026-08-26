//! Virtualization.framework Linux-guest backend — the "lite" engine.
//!
//! Where the custom Hypervisor.framework machine owns every device,
//! this backend lets the OS provide them: VZLinuxBootLoader boots the
//! kernel, the guest console is a virtio-console wired to host file
//! descriptors, and state save/restore comes from the framework
//! (macOS 14+, SMP included). No GPU, no custom devices — projects
//! that need the full machine use the native engine.
//!
//! Threading: the VM is created with initWithConfiguration:, which
//! binds it to the main dispatch queue, so every call here must run on
//! the main thread and progress requires pumping the main run loop
//! (pump()/waitFlag() do that).

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const mininat = @import("../net/mininat.zig");
const vz_mininat = @import("vz_mininat.zig");
const vz_process_policy = @import("vz_process_policy.zig");
const vz_vsock = @import("vz_vsock.zig");

const Object = objc.Object;
const id = objc.c.id;
const BOOL = objc.c.BOOL;
const NSInteger = isize;
const NSUInteger = usize;
const ObjectError = error{FrameworkObjectCreationFailed};
const log = std.log.scoped(.vz);

const DiskCachingMode = enum(NSInteger) {
    automatic = 0,
    cached = 2,
};

const DiskSynchronizationMode = enum(NSInteger) {
    full = 1,
    fsync = 2,
};

extern "c" fn CFRunLoopRunInMode(mode: ?*anyopaque, seconds: f64, return_after_source: u8) i32;
extern "c" var kCFRunLoopDefaultMode: ?*anyopaque;

pub const Config = struct {
    kernel_path: [:0]const u8,
    initrd_path: ?[:0]const u8,
    cmdline: [:0]const u8,
    memory_bytes: u64,
    vcpu_count: u8,
    /// Host fds wired to the guest console (guest input is read from
    /// console_in, guest output is written to console_out).
    console_in: i32,
    console_out: i32,
    disk_path: ?[:0]const u8 = null,
    disk_read_only: bool = false,
    disk2_path: ?[:0]const u8 = null,
    disk2_read_only: bool = true,
    enable_net: bool = false,
    forwards: []const mininat.Forward = &.{},
    docker_socket_path: ?[]const u8 = null,
    docker_vsock: bool = false,
    shared_dir: ?[:0]const u8 = null,
    share_read_only: bool = false,
    /// Persisted VZGenericMachineIdentifier (created on first use).
    /// Restore validates the identifier embedded in the saved state
    /// against the machine's, so it must survive across processes.
    machine_id_path: ?[:0]const u8 = null,
};

pub const State = enum(NSInteger) {
    stopped = 0,
    running = 1,
    paused = 2,
    @"error" = 3,
    starting = 4,
    pausing = 5,
    resuming = 6,
    stopping = 7,
    saving = 8,
    restoring = 9,
    _,
};

pub const Machine = struct {
    vm: Object,
    network: ?*vz_mininat.Bridge,
    docker: ?*vz_vsock.Bridge,
    performance_policy: ?*vz_process_policy.Controller,
    startup_started_ns: u64,
    startup_profile: StartupProfile,

    const StartupProfile = struct {
        boot_loader_ns: u64 = 0,
        configuration_ns: u64 = 0,
        console_ns: u64 = 0,
        storage_ns: u64 = 0,
        network_ns: u64 = 0,
        share_ns: u64 = 0,
        platform_ns: u64 = 0,
        validation_ns: u64 = 0,
        save_restore_validation_ns: u64 = 0,
        vm_ns: u64 = 0,
        start_ns: u64 = 0,
        total_ns: u64 = 0,
    };

    pub const InitError = error{
        UnsupportedHost,
        FrameworkObjectCreationFailed,
        ConfigurationValidationFailed,
        DockerSetupFailed,
        NetworkSetupFailed,
    };

    const FlagBlock = objc.Block(struct {
        done: *std.atomic.Value(bool),
        ok: *std.atomic.Value(bool),
    }, .{id}, void);

    pub fn init(config: *const Config) InitError!Machine {
        if (comptime builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
        const startup_started_ns = monotonicNs();
        var profile = StartupProfile{};
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const performance_policy = if (config.docker_vsock)
            vz_process_policy.Controller.create(std.heap.c_allocator) catch |err| blk: {
                log.warn("VZ process policy unavailable: {}", .{err});
                break :blk null;
            }
        else
            null;
        errdefer if (performance_policy) |policy| policy.destroy();

        const docker = if (config.docker_vsock)
            vz_vsock.Bridge.create(
                std.heap.c_allocator,
                config.docker_socket_path orelse return error.DockerSetupFailed,
                performance_policy,
            ) catch |err| {
                log.err("VZ Docker socket setup failed: {}", .{err});
                return error.DockerSetupFailed;
            }
        else
            null;
        errdefer if (docker) |bridge| bridge.destroy();

        const network = if (config.enable_net)
            vz_mininat.Bridge.create(std.heap.c_allocator, .{
                .forwards = config.forwards,
                .docker_socket_path = if (config.docker_vsock)
                    null
                else
                    config.docker_socket_path,
                .performance_policy = performance_policy,
            }) catch |err| {
                log.err("VZ network setup failed: {}", .{err});
                return error.NetworkSetupFailed;
            }
        else
            null;
        errdefer if (network) |bridge| bridge.destroy();

        const configuration = try createConfiguration(config, network, &profile);
        defer configuration.release();

        const vm_started_ns = monotonicNs();
        const vm = (try allocObject("VZVirtualMachine")).msgSend(
            Object,
            "initWithConfiguration:",
            .{configuration.value},
        );
        if (vm.value == null) return error.FrameworkObjectCreationFailed;
        if (docker) |bridge| bridge.setSocketDevice(firstSocketDevice(vm));
        if (performance_policy) |policy| policy.discover();
        profile.vm_ns = monotonicNs() - vm_started_ns;
        return .{
            .vm = vm,
            .network = network,
            .docker = docker,
            .performance_policy = performance_policy,
            .startup_started_ns = startup_started_ns,
            .startup_profile = profile,
        };
    }

    pub fn deinit(self: *Machine) void {
        if (self.docker) |docker| docker.destroy();
        self.vm.release();
        if (self.network) |network| network.destroy();
        if (self.performance_policy) |policy| policy.destroy();
        self.* = undefined;
    }

    pub fn state(self: *const Machine) State {
        return @enumFromInt(self.vm.msgSend(NSInteger, "state", .{}));
    }

    pub fn start(self: *Machine) !void {
        const started_ns = monotonicNs();
        try self.performFlag("startWithCompletionHandler:", .{});
        const finished_ns = monotonicNs();
        self.startup_profile.start_ns = finished_ns - started_ns;
        self.startup_profile.total_ns = finished_ns - self.startup_started_ns;
        if (self.performance_policy) |policy| policy.discover();
    }

    pub fn logStartupProfile(self: *const Machine) void {
        const profile = self.startup_profile;
        log.info(
            "startup profile (Virtualization.framework): total={}us boot-loader={}us " ++
                "configuration={}us console={}us storage={}us network={}us",
            .{
                profile.total_ns / std.time.ns_per_us,
                profile.boot_loader_ns / std.time.ns_per_us,
                profile.configuration_ns / std.time.ns_per_us,
                profile.console_ns / std.time.ns_per_us,
                profile.storage_ns / std.time.ns_per_us,
                profile.network_ns / std.time.ns_per_us,
            },
        );
        log.info(
            "startup profile (Virtualization.framework): share={}us platform={}us validate={}us " ++
                "save-restore-validate={}us " ++
                "vm={}us start={}us",
            .{
                profile.share_ns / std.time.ns_per_us,
                profile.platform_ns / std.time.ns_per_us,
                profile.validation_ns / std.time.ns_per_us,
                profile.save_restore_validation_ns / std.time.ns_per_us,
                profile.vm_ns / std.time.ns_per_us,
                profile.start_ns / std.time.ns_per_us,
            },
        );
    }

    pub fn pause(self: *Machine) !void {
        try self.performFlag("pauseWithCompletionHandler:", .{});
    }

    pub fn resumeVM(self: *Machine) !void {
        try self.performFlag("resumeWithCompletionHandler:", .{});
        if (self.performance_policy) |policy| policy.discover();
    }

    pub fn dockerConnectionCount(self: *const Machine) u32 {
        const docker = self.docker orelse return 0;
        return docker.connectionCount();
    }

    pub fn tickPerformancePolicy(self: *Machine) void {
        const policy = self.performance_policy orelse return;
        policy.tick(self.dockerConnectionCount());
    }

    pub fn stop(self: *Machine) !void {
        try self.performFlag("stopWithCompletionHandler:", .{});
    }

    /// Save the paused machine's complete state (macOS 14+).
    pub fn saveTo(self: *Machine, path: [:0]const u8) !void {
        const url = fileURL(path) catch return error.SaveFailed;
        try self.performFlag("saveMachineStateToURL:completionHandler:", .{url.value});
    }

    /// Load a saved state into a freshly created, stopped machine with
    /// an identical configuration; follow with resumeVM().
    pub fn restoreFrom(self: *Machine, path: [:0]const u8) !void {
        const url = fileURL(path) catch return error.RestoreFailed;
        try self.performFlag("restoreMachineStateFromURL:completionHandler:", .{url.value});
    }

    /// Run one VM-queue operation whose completion handler reports an
    /// optional NSError, pumping the main run loop until it fires.
    fn performFlag(self: *Machine, comptime selector: [:0]const u8, extra_args: anytype) !void {
        var done = std.atomic.Value(bool).init(false);
        var ok = std.atomic.Value(bool).init(false);
        var block = FlagBlock.init(.{ .done = &done, .ok = &ok }, flagCompletion);
        self.vm.msgSend(void, selector, extra_args ++ .{&block});
        while (!done.load(.acquire)) pump();
        if (!ok.load(.acquire)) return error.OperationFailed;
    }

    fn flagCompletion(block: *const FlagBlock.Context, error_object: id) callconv(.c) void {
        if (error_object != null) logNSError("VZ operation failed", error_object);
        block.ok.store(error_object == null, .release);
        block.done.store(true, .release);
    }
};

/// Pump the main run loop briefly; VZ completion handlers and device
/// work are dispatched onto it.
pub fn pump() void {
    pumpFor(0.05);
}

pub fn pumpFor(seconds: f64) void {
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, 1);
}

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

fn finishStartupStep(field: *u64, step_started_ns: *u64) void {
    const now_ns = monotonicNs();
    field.* = now_ns - step_started_ns.*;
    step_started_ns.* = now_ns;
}

fn createConfiguration(
    config: *const Config,
    network: ?*vz_mininat.Bridge,
    profile: *Machine.StartupProfile,
) Machine.InitError!Object {
    if (config.memory_bytes == 0 or config.vcpu_count == 0) {
        return error.ConfigurationValidationFailed;
    }
    var step_started_ns = monotonicNs();

    const boot_loader = try initObject(
        "VZLinuxBootLoader",
        "initWithKernelURL:",
        .{(try fileURL(config.kernel_path)).value},
    );
    boot_loader.msgSend(void, "setCommandLine:", .{string(config.cmdline).value});
    if (config.initrd_path) |initrd| {
        boot_loader.msgSend(void, "setInitialRamdiskURL:", .{(try fileURL(initrd)).value});
    }
    finishStartupStep(&profile.boot_loader_ns, &step_started_ns);

    const configuration = try newObject("VZVirtualMachineConfiguration");
    configuration.msgSend(void, "setBootLoader:", .{boot_loader.value});
    configuration.msgSend(void, "setCPUCount:", .{@as(NSUInteger, config.vcpu_count)});
    configuration.msgSend(void, "setMemorySize:", .{config.memory_bytes});
    finishStartupStep(&profile.configuration_ns, &step_started_ns);

    // Guest console on host file descriptors: the attachment reads
    // guest input from console_in and writes guest output to
    // console_out.
    const read_handle = try initObject(
        "NSFileHandle",
        "initWithFileDescriptor:closeOnDealloc:",
        .{ @as(c_int, config.console_in), boolParam(false) },
    );
    const write_handle = try initObject(
        "NSFileHandle",
        "initWithFileDescriptor:closeOnDealloc:",
        .{ @as(c_int, config.console_out), boolParam(false) },
    );
    const attachment = try initObject(
        "VZFileHandleSerialPortAttachment",
        "initWithFileHandleForReading:fileHandleForWriting:",
        .{ read_handle.value, write_handle.value },
    );
    const console = try newObject("VZVirtioConsoleDeviceSerialPortConfiguration");
    console.msgSend(void, "setAttachment:", .{attachment.value});
    configuration.msgSend(void, "setSerialPorts:", .{array(&.{console}).value});
    finishStartupStep(&profile.console_ns, &step_started_ns);

    var storage_devices: [2]Object = undefined;
    var storage_count: usize = 0;
    const disk_caching_mode: DiskCachingMode = if (config.docker_vsock)
        .cached
    else
        .automatic;
    const disk_synchronization_mode: DiskSynchronizationMode = if (config.docker_vsock)
        .fsync
    else
        .full;
    if (config.disk_path) |path| {
        storage_devices[storage_count] = try createDiskDevice(
            path,
            config.disk_read_only,
            disk_caching_mode,
            disk_synchronization_mode,
        );
        storage_count += 1;
    }
    if (config.disk2_path) |path| {
        storage_devices[storage_count] = try createDiskDevice(
            path,
            config.disk2_read_only,
            disk_caching_mode,
            disk_synchronization_mode,
        );
        storage_count += 1;
    }
    if (storage_count > 0) configuration.msgSend(
        void,
        "setStorageDevices:",
        .{array(storage_devices[0..storage_count]).value},
    );
    finishStartupStep(&profile.storage_ns, &step_started_ns);

    if (network) |bridge| {
        const handle = try initObject(
            "NSFileHandle",
            "initWithFileDescriptor:closeOnDealloc:",
            .{ @as(c_int, bridge.vz_fd), boolParam(false) },
        );
        const network_attachment = try initObject(
            "VZFileHandleNetworkDeviceAttachment",
            "initWithFileHandle:",
            .{handle.value},
        );
        const device = try newObject("VZVirtioNetworkDeviceConfiguration");
        device.msgSend(void, "setAttachment:", .{network_attachment.value});
        device.msgSend(void, "setMACAddress:", .{(try initObject(
            "VZMACAddress",
            "initWithString:",
            .{string("52:54:00:12:34:56").value},
        )).value});
        configuration.msgSend(void, "setNetworkDevices:", .{array(&.{device}).value});
    }
    finishStartupStep(&profile.network_ns, &step_started_ns);

    if (config.docker_vsock) {
        configuration.msgSend(void, "setSocketDevices:", .{
            array(&.{try newObject("VZVirtioSocketDeviceConfiguration")}).value,
        });
    }

    if (config.shared_dir) |path| {
        const directory = try initObject(
            "VZSharedDirectory",
            "initWithURL:readOnly:",
            .{ (try fileURL(path)).value, boolParam(config.share_read_only) },
        );
        const share = try initObject(
            "VZSingleDirectoryShare",
            "initWithDirectory:",
            .{directory.value},
        );
        const device = try initObject(
            "VZVirtioFileSystemDeviceConfiguration",
            "initWithTag:",
            .{string("host").value},
        );
        device.msgSend(void, "setShare:", .{share.value});
        configuration.msgSend(void, "setDirectorySharingDevices:", .{array(&.{device}).value});
    }
    finishStartupStep(&profile.share_ns, &step_started_ns);

    configuration.msgSend(void, "setEntropyDevices:", .{
        array(&.{try newObject("VZVirtioEntropyDeviceConfiguration")}).value,
    });
    configuration.msgSend(void, "setMemoryBalloonDevices:", .{
        array(&.{try newObject("VZVirtioTraditionalMemoryBalloonDeviceConfiguration")}).value,
    });

    if (config.machine_id_path) |path| {
        const platform = try newObject("VZGenericPlatformConfiguration");
        platform.msgSend(void, "setMachineIdentifier:", .{
            (try loadOrCreateMachineId(path)).value,
        });
        configuration.msgSend(void, "setPlatform:", .{platform.value});
    }
    finishStartupStep(&profile.platform_ns, &step_started_ns);

    var error_object: id = null;
    if (!boolResult(configuration.msgSend(BOOL, "validateWithError:", .{&error_object}))) {
        logNSError("VZ configuration validation failed", error_object);
        return error.ConfigurationValidationFailed;
    }
    finishStartupStep(&profile.validation_ns, &step_started_ns);
    // Save/restore support depends on the device set; surface problems
    // at configuration time rather than at the first save.
    if (!boolResult(configuration.msgSend(
        BOOL,
        "validateSaveRestoreSupportWithError:",
        .{&error_object},
    ))) {
        logNSError("VZ save/restore unsupported for this configuration", error_object);
    }
    finishStartupStep(&profile.save_restore_validation_ns, &step_started_ns);
    return configuration.retain();
}

fn firstSocketDevice(vm: Object) Object {
    const devices = vm.msgSend(Object, "socketDevices", .{});
    return devices.msgSend(Object, "objectAtIndex:", .{@as(NSUInteger, 0)});
}

fn createDiskDevice(
    path: [:0]const u8,
    read_only: bool,
    caching_mode: DiskCachingMode,
    synchronization_mode: DiskSynchronizationMode,
) ObjectError!Object {
    var error_object: id = null;
    const attachment = (try allocObject("VZDiskImageStorageDeviceAttachment")).msgSend(
        Object,
        "initWithURL:readOnly:cachingMode:synchronizationMode:error:",
        .{
            (try fileURL(path)).value,
            boolParam(read_only),
            @intFromEnum(caching_mode),
            @intFromEnum(synchronization_mode),
            &error_object,
        },
    );
    if (attachment.value == null) {
        logNSError("VZ disk attachment failed", error_object);
        return error.FrameworkObjectCreationFailed;
    }
    return initObject(
        "VZVirtioBlockDeviceConfiguration",
        "initWithAttachment:",
        .{attachment.msgSend(Object, "autorelease", .{}).value},
    );
}

/// Load the persisted machine identifier, creating and persisting a
/// fresh one on first use.
fn loadOrCreateMachineId(path: [:0]const u8) ObjectError!Object {
    const existing = objc.getClass("NSData").?.msgSend(
        Object,
        "dataWithContentsOfFile:",
        .{string(path).value},
    );
    if (existing.value != null) {
        return initObject(
            "VZGenericMachineIdentifier",
            "initWithDataRepresentation:",
            .{existing.value},
        );
    }
    const identifier = try newObject("VZGenericMachineIdentifier");
    const data = identifier.msgSend(Object, "dataRepresentation", .{});
    if (data.value == null) return error.FrameworkObjectCreationFailed;
    if (!boolResult(data.msgSend(BOOL, "writeToFile:atomically:", .{
        string(path).value,
        boolParam(true),
    }))) {
        log.warn("could not persist machine identifier to {s}", .{path});
    }
    return identifier;
}

fn boolParam(value: bool) BOOL {
    return switch (BOOL) {
        bool => value,
        i8 => @intFromBool(value),
        else => @compileError("unexpected Objective-C BOOL type"),
    };
}

fn string(value: [*:0]const u8) Object {
    return objc.getClass("NSString").?.msgSend(Object, "stringWithUTF8String:", .{value});
}

fn fileURL(path: [*:0]const u8) ObjectError!Object {
    const result = objc.getClass("NSURL").?.msgSend(
        Object,
        "fileURLWithPath:",
        .{string(path).value},
    );
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result;
}

fn array(objects: []const Object) Object {
    var values: [8]id = undefined;
    assert(objects.len <= values.len);
    for (objects, 0..) |object, index| values[index] = object.value;
    return objc.getClass("NSArray").?.msgSend(Object, "arrayWithObjects:count:", .{
        values[0..objects.len].ptr,
        objects.len,
    });
}

fn allocObject(comptime name: [:0]const u8) ObjectError!Object {
    const class = objc.getClass(name) orelse return error.FrameworkObjectCreationFailed;
    const result = class.msgSend(Object, "alloc", .{});
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result;
}

fn newObject(comptime name: [:0]const u8) ObjectError!Object {
    const result = (try allocObject(name)).msgSend(Object, "init", .{});
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result.msgSend(Object, "autorelease", .{});
}

fn initObject(
    comptime name: [:0]const u8,
    comptime selector: [:0]const u8,
    args: anytype,
) ObjectError!Object {
    const result = (try allocObject(name)).msgSend(Object, selector, args);
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result.msgSend(Object, "autorelease", .{});
}

fn boolResult(value: BOOL) bool {
    return switch (BOOL) {
        bool => value,
        i8 => value == 1,
        else => @compileError("unexpected Objective-C BOOL type"),
    };
}

fn logNSError(message: []const u8, error_object: id) void {
    if (error_object == null) {
        log.err("{s}: unknown framework error", .{message});
        return;
    }
    const error_value = Object.fromId(error_object);
    const description = error_value.msgSend(Object, "localizedDescription", .{});
    const bytes = description.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse {
        log.err("{s}: NSError has no description", .{message});
        return;
    };
    log.err("{s}: {s}", .{ message, std.mem.span(bytes) });
}
