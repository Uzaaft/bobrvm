//! Apple Virtualization.framework guest backend.
//!
//! Zig owns every framework object. Swift receives only an opaque NSView.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const runtime = @import("Runtime.zig");
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");

const Object = objc.Object;
const id = objc.c.id;
const BOOL = objc.c.BOOL;
const NSInteger = isize;
const NSUInteger = usize;
const ObjectError = error{FrameworkObjectCreationFailed};
const log = std.log.scoped(.macos_runtime);

pub const MacOSConfig = extern struct {
    memory_bytes: u64,
    vcpu_count: u8,
    display_width: u32,
    display_height: u32,
    retina: bool,
    disk_path: ?[*:0]const u8,
    auxiliary_storage_path: ?[*:0]const u8,
    hardware_model_base64: ?[*:0]const u8,
    machine_identifier_base64: ?[*:0]const u8,
    mac_address: ?[*:0]const u8,
};

pub const Backend = struct {
    vm: Object,
    view: Object,
    installer: ?Object = null,
    startup_started_ns: u64,
    startup_profile: StartupProfile,

    const StartupProfile = extern struct {
        platform_ns: u64 = 0,
        configuration_ns: u64 = 0,
        storage_graphics_ns: u64 = 0,
        input_network_ns: u64 = 0,
        audio_ns: u64 = 0,
        validation_ns: u64 = 0,
        vm_ns: u64 = 0,
        view_ns: u64 = 0,
        start_ns: u64 = 0,
        total_ns: u64 = 0,
    };

    pub const Config = MacOSConfig;
    pub const InitError = error{
        InvalidConfig,
        UnsupportedHost,
        FrameworkObjectCreationFailed,
        ConfigurationValidationFailed,
    };
    pub const StartError = error{ InvalidState, StartFailed };
    pub const InstallError = error{ InvalidState, FrameworkObjectCreationFailed };
    pub const InstallCallback = *const fn (?*anyopaque, bool) callconv(.c) void;

    const CompletionBlock = objc.Block(struct {}, .{id}, void);
    const StartCompletionBlock = objc.Block(struct {
        startup_started_ns: u64,
        start_started_ns: u64,
        profile: StartupProfile,
    }, .{id}, void);
    const InstallCompletionBlock = objc.Block(struct {
        userdata: ?*anyopaque,
        callback: InstallCallback,
    }, .{id}, void);

    pub fn init(config: *const Config) InitError!Backend {
        if (comptime builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
        const startup_started_ns = monotonicNs();
        var profile = StartupProfile{};
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const configuration = createConfiguration(config, &profile) catch |err| {
            log.err("configuration creation failed: {s}", .{@errorName(err)});
            return err;
        };
        defer configuration.release();

        const vm_started_ns = monotonicNs();
        const vm_alloc = try allocObject("VZVirtualMachine");
        const vm = vm_alloc.msgSend(Object, "initWithConfiguration:", .{configuration.value});
        if (vm.value == null) {
            log.err("VZVirtualMachine initialization returned nil", .{});
            return error.FrameworkObjectCreationFailed;
        }
        profile.vm_ns = monotonicNs() - vm_started_ns;

        const view_started_ns = monotonicNs();
        const view_alloc = try allocObject("VZVirtualMachineView");
        const view = view_alloc.msgSend(Object, "init", .{});
        if (view.value == null) {
            vm.release();
            return error.FrameworkObjectCreationFailed;
        }
        view.msgSend(void, "setVirtualMachine:", .{vm.value});
        view.msgSend(void, "setCapturesSystemKeys:", .{boolParam(true)});
        if (boolResult(view.msgSend(BOOL, "respondsToSelector:", .{
            objc.sel("setAutomaticallyReconfiguresDisplay:"),
        }))) {
            view.msgSend(void, "setAutomaticallyReconfiguresDisplay:", .{boolParam(true)});
        }
        profile.view_ns = monotonicNs() - view_started_ns;

        return .{
            .vm = vm,
            .view = view,
            .startup_started_ns = startup_started_ns,
            .startup_profile = profile,
        };
    }

    pub fn deinit(self: *Backend) void {
        assert(self.vm.value != null);
        assert(self.view.value != null);
        self.view.msgSend(void, "setVirtualMachine:", .{@as(id, null)});
        if (self.installer) |installer| installer.release();
        self.view.release();
        self.vm.release();
        self.* = undefined;
    }

    pub fn start(self: *Backend) StartError!void {
        if (!boolResult(self.vm.msgSend(BOOL, "canStart", .{}))) {
            log.err("VZVirtualMachine rejected start in state {d}", .{
                self.vm.msgSend(NSInteger, "state", .{}),
            });
            return error.InvalidState;
        }
        var block = StartCompletionBlock.init(.{
            .startup_started_ns = self.startup_started_ns,
            .start_started_ns = monotonicNs(),
            .profile = self.startup_profile,
        }, startCompletion);
        self.vm.msgSend(void, "startWithCompletionHandler:", .{&block});
    }

    pub fn requestStop(self: *Backend) void {
        if (!boolResult(self.vm.msgSend(BOOL, "canStop", .{}))) return;
        self.perform("stopWithCompletionHandler:", .stopped);
    }

    pub fn pause(self: *Backend) void {
        if (!boolResult(self.vm.msgSend(BOOL, "canPause", .{}))) return;
        self.perform("pauseWithCompletionHandler:", .paused);
    }

    pub fn resumeVM(self: *Backend) void {
        if (!boolResult(self.vm.msgSend(BOOL, "canResume", .{}))) return;
        self.perform("resumeWithCompletionHandler:", .running);
    }

    pub fn tick(_: *Backend) void {}

    pub fn state(self: *Backend) ?runtime.State {
        return mapState(self.vm.msgSend(NSInteger, "state", .{}));
    }

    pub fn displayView(self: *Backend) ?*anyopaque {
        return @ptrCast(self.view.value);
    }

    pub fn install(
        self: *Backend,
        restore_path: [*:0]const u8,
        userdata: ?*anyopaque,
        callback: InstallCallback,
    ) InstallError!void {
        if (self.installer != null) return error.InvalidState;
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const restore_url = fileURL(restore_path) catch return error.FrameworkObjectCreationFailed;
        const installer = try initObject(
            "VZMacOSInstaller",
            "initWithVirtualMachine:restoringFromImageAtURL:",
            .{ self.vm.value, restore_url.value },
        );
        self.installer = installer.retain();
        var block = InstallCompletionBlock.init(.{
            .userdata = userdata,
            .callback = callback,
        }, installCompletion);
        installer.msgSend(void, "installWithCompletionHandler:", .{&block});
    }

    pub fn installProgress(self: *const Backend) f64 {
        const installer = self.installer orelse return 0;
        const progress = installer.msgSend(Object, "progress", .{});
        if (progress.value == null) return 0;
        return progress.msgSend(f64, "fractionCompleted", .{});
    }

    fn perform(self: *Backend, comptime selector: [:0]const u8, _: runtime.State) void {
        var block = CompletionBlock.init(.{}, completion);
        self.vm.msgSend(void, selector, .{&block});
    }

    fn completion(_: *const CompletionBlock.Context, error_object: id) callconv(.c) void {
        if (error_object != null) logNSError("VM lifecycle operation failed", error_object);
    }

    fn startCompletion(
        block: *const StartCompletionBlock.Context,
        error_object: id,
    ) callconv(.c) void {
        if (error_object != null) {
            logNSError("VM start failed", error_object);
            return;
        }
        const finished_ns = monotonicNs();
        var profile = block.profile;
        profile.start_ns = finished_ns - block.start_started_ns;
        profile.total_ns = finished_ns - block.startup_started_ns;
        logStartupProfile(profile);
    }

    fn installCompletion(block: *const InstallCompletionBlock.Context, error_object: id) callconv(.c) void {
        block.callback(block.userdata, error_object == null);
    }
};

pub const MacRuntime = runtime.Runtime(Backend);

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

fn finishStartupStep(field: *u64, step_started_ns: *u64) void {
    const now_ns = monotonicNs();
    field.* = now_ns - step_started_ns.*;
    step_started_ns.* = now_ns;
}

fn createConfiguration(
    config: *const MacOSConfig,
    profile: *Backend.StartupProfile,
) Backend.InitError!Object {
    if (config.memory_bytes == 0 or config.vcpu_count == 0) return error.InvalidConfig;
    if (config.display_width == 0 or config.display_height == 0) return error.InvalidConfig;
    var step_started_ns = monotonicNs();

    const platform = try createPlatform(config);
    finishStartupStep(&profile.platform_ns, &step_started_ns);
    const configuration = try newObject("VZVirtualMachineConfiguration");
    configuration.msgSend(void, "setBootLoader:", .{(try newObject("VZMacOSBootLoader")).value});
    configuration.msgSend(void, "setPlatform:", .{platform.value});
    configureCompute(configuration, config);
    finishStartupStep(&profile.configuration_ns, &step_started_ns);
    try configureStorageAndGraphics(configuration, config);
    finishStartupStep(&profile.storage_graphics_ns, &step_started_ns);
    try configureInputAndNetwork(configuration, config);
    finishStartupStep(&profile.input_network_ns, &step_started_ns);
    try configureAudio(configuration);
    finishStartupStep(&profile.audio_ns, &step_started_ns);

    var error_object: id = null;
    if (!boolResult(configuration.msgSend(BOOL, "validateWithError:", .{&error_object}))) {
        logNSError("configuration validation failed", error_object);
        return error.ConfigurationValidationFailed;
    }
    finishStartupStep(&profile.validation_ns, &step_started_ns);
    return configuration.retain();
}

fn logStartupProfile(profile: Backend.StartupProfile) void {
    log.info(
        "startup profile (Virtualization.framework/macOS): total={}us platform={}us " ++
            "configuration={}us storage-graphics={}us input-network={}us",
        .{
            profile.total_ns / std.time.ns_per_us,
            profile.platform_ns / std.time.ns_per_us,
            profile.configuration_ns / std.time.ns_per_us,
            profile.storage_graphics_ns / std.time.ns_per_us,
            profile.input_network_ns / std.time.ns_per_us,
        },
    );
    log.info(
        "startup profile (Virtualization.framework/macOS): audio={}us validate={}us " ++
            "vm={}us view={}us start={}us",
        .{
            profile.audio_ns / std.time.ns_per_us,
            profile.validation_ns / std.time.ns_per_us,
            profile.vm_ns / std.time.ns_per_us,
            profile.view_ns / std.time.ns_per_us,
            profile.start_ns / std.time.ns_per_us,
        },
    );
}

fn createPlatform(config: *const MacOSConfig) Backend.InitError!Object {
    const auxiliary_path = config.auxiliary_storage_path orelse return error.InvalidConfig;
    const hardware_base64 = config.hardware_model_base64 orelse return error.InvalidConfig;
    const identifier_base64 = config.machine_identifier_base64 orelse return error.InvalidConfig;
    const hardware_data = try dataFromBase64(hardware_base64);
    const identifier_data = try dataFromBase64(identifier_base64);
    const hardware = try initObject("VZMacHardwareModel", "initWithDataRepresentation:", .{hardware_data.value});
    if (!boolResult(hardware.msgSend(BOOL, "isSupported", .{}))) return error.InvalidConfig;
    const identifier = try initObject("VZMacMachineIdentifier", "initWithDataRepresentation:", .{identifier_data.value});
    const auxiliary_url = try fileURL(auxiliary_path);
    const auxiliary = try initObject("VZMacAuxiliaryStorage", "initWithURL:", .{auxiliary_url.value});
    const platform = try newObject("VZMacPlatformConfiguration");
    platform.msgSend(void, "setHardwareModel:", .{hardware.value});
    platform.msgSend(void, "setMachineIdentifier:", .{identifier.value});
    platform.msgSend(void, "setAuxiliaryStorage:", .{auxiliary.value});
    return platform;
}

fn configureCompute(configuration: Object, config: *const MacOSConfig) void {
    const configuration_class = objc.getClass("VZVirtualMachineConfiguration").?;
    const cpu_min = configuration_class.msgSend(NSUInteger, "minimumAllowedCPUCount", .{});
    const cpu_max = configuration_class.msgSend(NSUInteger, "maximumAllowedCPUCount", .{});
    const memory_min = configuration_class.msgSend(u64, "minimumAllowedMemorySize", .{});
    const memory_max = configuration_class.msgSend(u64, "maximumAllowedMemorySize", .{});
    configuration.msgSend(void, "setCPUCount:", .{std.math.clamp(
        @as(NSUInteger, config.vcpu_count),
        cpu_min,
        cpu_max,
    )});
    configuration.msgSend(void, "setMemorySize:", .{std.math.clamp(
        config.memory_bytes,
        memory_min,
        memory_max,
    )});
}

fn configureStorageAndGraphics(configuration: Object, config: *const MacOSConfig) Backend.InitError!void {
    const disk_path = config.disk_path orelse return error.InvalidConfig;
    const disk_attachment = try createDiskAttachment(disk_path);
    const disk = try initObject("VZVirtioBlockDeviceConfiguration", "initWithAttachment:", .{disk_attachment.value});
    configuration.msgSend(void, "setStorageDevices:", .{array(&.{disk}).value});

    const display = try initObject("VZMacGraphicsDisplayConfiguration", "initWithWidthInPixels:heightInPixels:pixelsPerInch:", .{
        @as(NSInteger, config.display_width),
        @as(NSInteger, config.display_height),
        @as(NSInteger, if (config.retina) 144 else 80),
    });
    const graphics = try newObject("VZMacGraphicsDeviceConfiguration");
    graphics.msgSend(void, "setDisplays:", .{array(&.{display}).value});
    configuration.msgSend(void, "setGraphicsDevices:", .{array(&.{graphics}).value});
}

fn configureInputAndNetwork(configuration: Object, config: *const MacOSConfig) Backend.InitError!void {
    const keyboard = try newObject("VZUSBKeyboardConfiguration");
    if (objc.getClass("VZMacKeyboardConfiguration")) |_| {
        const mac_keyboard = try newObject("VZMacKeyboardConfiguration");
        configuration.msgSend(void, "setKeyboards:", .{array(&.{ keyboard, mac_keyboard }).value});
    } else {
        configuration.msgSend(void, "setKeyboards:", .{array(&.{keyboard}).value});
    }
    const pointer = try newObject("VZUSBScreenCoordinatePointingDeviceConfiguration");
    const trackpad = try newObject("VZMacTrackpadConfiguration");
    configuration.msgSend(void, "setPointingDevices:", .{array(&.{ pointer, trackpad }).value});

    const mac_string = config.mac_address orelse return error.InvalidConfig;
    const mac = try initObject("VZMACAddress", "initWithString:", .{string(mac_string).value});
    const network = try newObject("VZVirtioNetworkDeviceConfiguration");
    network.msgSend(void, "setAttachment:", .{(try newObject("VZNATNetworkDeviceAttachment")).value});
    network.msgSend(void, "setMACAddress:", .{mac.value});
    configuration.msgSend(void, "setNetworkDevices:", .{array(&.{network}).value});
    configuration.msgSend(void, "setEntropyDevices:", .{array(&.{try newObject("VZVirtioEntropyDeviceConfiguration")}).value});
}

fn configureAudio(configuration: Object) Backend.InitError!void {
    const input = try newObject("VZVirtioSoundDeviceInputStreamConfiguration");
    input.msgSend(void, "setSource:", .{(try newObject("VZHostAudioInputStreamSource")).value});

    const output = try newObject("VZVirtioSoundDeviceOutputStreamConfiguration");
    output.msgSend(void, "setSink:", .{(try newObject("VZHostAudioOutputStreamSink")).value});

    const sound = try newObject("VZVirtioSoundDeviceConfiguration");
    sound.msgSend(void, "setStreams:", .{array(&.{ input, output }).value});
    configuration.msgSend(void, "setAudioDevices:", .{array(&.{sound}).value});
}

fn createDiskAttachment(path: [*:0]const u8) ObjectError!Object {
    var error_object: id = null;
    const result = (try allocObject("VZDiskImageStorageDeviceAttachment")).msgSend(
        Object,
        "initWithURL:readOnly:error:",
        .{ (try fileURL(path)).value, boolParam(false), &error_object },
    );
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result.msgSend(Object, "autorelease", .{});
}

fn dataFromBase64(value: [*:0]const u8) ObjectError!Object {
    return initObject("NSData", "initWithBase64EncodedString:options:", .{
        string(value).value,
        @as(NSUInteger, 0),
    });
}

fn string(value: [*:0]const u8) Object {
    return objc.getClass("NSString").?.msgSend(Object, "stringWithUTF8String:", .{value});
}

fn fileURL(path: [*:0]const u8) ObjectError!Object {
    const result = objc.getClass("NSURL").?.msgSend(Object, "fileURLWithPath:", .{string(path).value});
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result;
}

fn array(objects: []const Object) Object {
    var values: [16]id = undefined;
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

fn mapState(value: NSInteger) runtime.State {
    return switch (value) {
        0 => .stopped,
        1 => .running,
        2 => .paused,
        3 => .failed,
        4, 6 => .starting,
        5 => .pausing,
        7 => .stopping,
        else => .failed,
    };
}

fn boolParam(value: bool) BOOL {
    return switch (BOOL) {
        bool => value,
        i8 => @intFromBool(value),
        else => @compileError("unexpected Objective-C BOOL type"),
    };
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

test "Virtualization framework exposes host support query" {
    const class = objc.getClass("VZVirtualMachine") orelse return error.TestUnexpectedResult;
    try std.testing.expect(boolResult(class.msgSend(BOOL, "respondsToSelector:", .{
        objc.sel("isSupported"),
    })));
}
