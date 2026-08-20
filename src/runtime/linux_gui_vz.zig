//! Virtualization.framework Linux backend for the native macOS application.
//!
//! This backend deliberately uses Apple's generic EFI platform and virtio
//! devices. It provides an interactive compatibility display, while the
//! custom Hypervisor.framework machine remains the accelerated 3D backend.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const runtime = @import("Runtime.zig");
const assert = @import("../quirks.zig").inlineAssert;

const Object = objc.Object;
const id = objc.c.id;
const BOOL = objc.c.BOOL;
const NSInteger = isize;
const NSUInteger = usize;
const ObjectError = error{FrameworkObjectCreationFailed};
const log = std.log.scoped(.linux_gui_vz);

pub const Config = extern struct {
    memory_bytes: u64,
    vcpu_count: u8,
    display_width: u32,
    display_height: u32,
    enable_net: bool,
    disk_read_only: bool,
    disk_path: ?[*:0]const u8,
    installer_path: ?[*:0]const u8,
    variable_store_path: ?[*:0]const u8,
    machine_id_path: ?[*:0]const u8,
    mac_address: ?[*:0]const u8,
};

const LinuxConfig = Config;

pub const Backend = struct {
    vm: Object,
    view: Object,

    pub const Config = LinuxConfig;
    pub const InitError = error{
        InvalidConfig,
        UnsupportedHost,
        FrameworkObjectCreationFailed,
        ConfigurationValidationFailed,
    };
    pub const StartError = error{ InvalidState, StartFailed };

    const CompletionBlock = objc.Block(struct {}, .{id}, void);

    pub fn init(config: *const LinuxConfig) InitError!Backend {
        if (comptime builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const configuration = createConfiguration(config) catch |err| {
            log.err("configuration creation failed: {s}", .{@errorName(err)});
            return err;
        };
        defer configuration.release();

        const vm_alloc = try allocObject("VZVirtualMachine");
        const vm = vm_alloc.msgSend(Object, "initWithConfiguration:", .{configuration.value});
        if (vm.value == null) return error.FrameworkObjectCreationFailed;
        errdefer vm.release();

        const view_alloc = try allocObject("VZVirtualMachineView");
        const view = view_alloc.msgSend(Object, "init", .{});
        if (view.value == null) return error.FrameworkObjectCreationFailed;
        view.msgSend(void, "setVirtualMachine:", .{vm.value});
        view.msgSend(void, "setCapturesSystemKeys:", .{boolParam(true)});
        if (respondsTo(view, "setAutomaticallyReconfiguresDisplay:")) {
            view.msgSend(void, "setAutomaticallyReconfiguresDisplay:", .{boolParam(true)});
        }
        return .{ .vm = vm, .view = view };
    }

    pub fn deinit(self: *Backend) void {
        assert(self.vm.value != null);
        assert(self.view.value != null);
        self.view.msgSend(void, "setVirtualMachine:", .{@as(id, null)});
        self.view.release();
        self.vm.release();
        self.* = undefined;
    }

    pub fn start(self: *Backend) StartError!void {
        if (!boolResult(self.vm.msgSend(BOOL, "canStart", .{}))) {
            return error.InvalidState;
        }
        var block = CompletionBlock.init(.{}, completion);
        self.vm.msgSend(void, "startWithCompletionHandler:", .{&block});
    }

    pub fn requestStop(self: *Backend) void {
        if (!boolResult(self.vm.msgSend(BOOL, "canStop", .{}))) return;
        self.perform("stopWithCompletionHandler:");
    }

    pub fn pause(self: *Backend) void {
        if (!boolResult(self.vm.msgSend(BOOL, "canPause", .{}))) return;
        self.perform("pauseWithCompletionHandler:");
    }

    pub fn resumeVM(self: *Backend) void {
        if (!boolResult(self.vm.msgSend(BOOL, "canResume", .{}))) return;
        self.perform("resumeWithCompletionHandler:");
    }

    pub fn tick(_: *Backend) void {}

    pub fn state(self: *Backend) ?runtime.State {
        return mapState(self.vm.msgSend(NSInteger, "state", .{}));
    }

    pub fn displayView(self: *Backend) ?*anyopaque {
        return @ptrCast(self.view.value);
    }

    fn perform(self: *Backend, comptime selector: [:0]const u8) void {
        var block = CompletionBlock.init(.{}, completion);
        self.vm.msgSend(void, selector, .{&block});
    }

    fn completion(_: *const CompletionBlock.Context, error_object: id) callconv(.c) void {
        if (error_object != null) logNSError("VM lifecycle operation failed", error_object);
    }
};

pub const LinuxGUIRuntime = runtime.Runtime(Backend);

fn createConfiguration(config: *const Config) Backend.InitError!Object {
    try validateConfig(config);
    const configuration = try newObject("VZVirtualMachineConfiguration");
    configuration.msgSend(void, "setBootLoader:", .{(try createBootLoader(config)).value});
    configuration.msgSend(void, "setPlatform:", .{(try createPlatform(config)).value});
    configureCompute(configuration, config);
    try configureStorage(configuration, config);
    try configureGraphicsAndInput(configuration, config);
    try configureNetwork(configuration, config);
    configuration.msgSend(void, "setEntropyDevices:", .{
        array(&.{try newObject("VZVirtioEntropyDeviceConfiguration")}).value,
    });

    var error_object: id = null;
    if (!boolResult(configuration.msgSend(BOOL, "validateWithError:", .{&error_object}))) {
        logNSError("configuration validation failed", error_object);
        return error.ConfigurationValidationFailed;
    }
    return configuration.retain();
}

fn validateConfig(config: *const Config) Backend.InitError!void {
    if (config.memory_bytes == 0 or config.vcpu_count == 0) return error.InvalidConfig;
    if (config.display_width == 0 or config.display_height == 0) return error.InvalidConfig;
    if (config.disk_path == null or config.variable_store_path == null) {
        return error.InvalidConfig;
    }
    if (config.machine_id_path == null or config.mac_address == null) {
        return error.InvalidConfig;
    }
}

fn createBootLoader(config: *const Config) Backend.InitError!Object {
    const variable_path = config.variable_store_path orelse return error.InvalidConfig;
    const variable_store = try createVariableStore(variable_path);
    const boot_loader = try newObject("VZEFIBootLoader");
    boot_loader.msgSend(void, "setVariableStore:", .{variable_store.value});
    return boot_loader;
}

fn createVariableStore(path: [*:0]const u8) ObjectError!Object {
    const url = try fileURL(path);
    if (std.c.access(path, 0) == 0) {
        return initObject("VZEFIVariableStore", "initWithURL:", .{url.value});
    }

    var error_object: id = null;
    const result = (try allocObject("VZEFIVariableStore")).msgSend(
        Object,
        "initCreatingVariableStoreAtURL:options:error:",
        .{ url.value, @as(NSUInteger, 0), &error_object },
    );
    if (result.value == null) {
        logNSError("EFI variable store creation failed", error_object);
        return error.FrameworkObjectCreationFailed;
    }
    return result.msgSend(Object, "autorelease", .{});
}

fn createPlatform(config: *const Config) Backend.InitError!Object {
    const machine_path = config.machine_id_path orelse return error.InvalidConfig;
    const platform = try newObject("VZGenericPlatformConfiguration");
    platform.msgSend(void, "setMachineIdentifier:", .{
        (try loadOrCreateMachineId(machine_path)).value,
    });
    return platform;
}

fn configureCompute(configuration: Object, config: *const Config) void {
    const class = objc.getClass("VZVirtualMachineConfiguration").?;
    const cpu_min = class.msgSend(NSUInteger, "minimumAllowedCPUCount", .{});
    const cpu_max = class.msgSend(NSUInteger, "maximumAllowedCPUCount", .{});
    const memory_min = class.msgSend(u64, "minimumAllowedMemorySize", .{});
    const memory_max = class.msgSend(u64, "maximumAllowedMemorySize", .{});
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

fn configureStorage(configuration: Object, config: *const Config) Backend.InitError!void {
    const disk_path = config.disk_path orelse return error.InvalidConfig;
    const disk_attachment = try createDiskAttachment(disk_path, config.disk_read_only);
    const disk = try initObject(
        "VZVirtioBlockDeviceConfiguration",
        "initWithAttachment:",
        .{disk_attachment.value},
    );

    if (config.installer_path) |installer_path| {
        const installer_attachment = try createDiskAttachment(installer_path, true);
        const installer = try initObject(
            "VZUSBMassStorageDeviceConfiguration",
            "initWithAttachment:",
            .{installer_attachment.value},
        );
        configuration.msgSend(void, "setStorageDevices:", .{array(&.{ disk, installer }).value});
        return;
    }
    configuration.msgSend(void, "setStorageDevices:", .{array(&.{disk}).value});
}

fn configureGraphicsAndInput(
    configuration: Object,
    config: *const Config,
) Backend.InitError!void {
    const scanout = try initObject(
        "VZVirtioGraphicsScanoutConfiguration",
        "initWithWidthInPixels:heightInPixels:",
        .{ @as(NSInteger, config.display_width), @as(NSInteger, config.display_height) },
    );
    const graphics = try newObject("VZVirtioGraphicsDeviceConfiguration");
    graphics.msgSend(void, "setScanouts:", .{array(&.{scanout}).value});
    configuration.msgSend(void, "setGraphicsDevices:", .{array(&.{graphics}).value});

    configuration.msgSend(void, "setKeyboards:", .{
        array(&.{try newObject("VZUSBKeyboardConfiguration")}).value,
    });
    configuration.msgSend(void, "setPointingDevices:", .{
        array(&.{try newObject("VZUSBScreenCoordinatePointingDeviceConfiguration")}).value,
    });
}

fn configureNetwork(configuration: Object, config: *const Config) Backend.InitError!void {
    if (!config.enable_net) return;
    const mac_string = config.mac_address orelse return error.InvalidConfig;
    const mac = try initObject("VZMACAddress", "initWithString:", .{string(mac_string).value});
    const network = try newObject("VZVirtioNetworkDeviceConfiguration");
    network.msgSend(void, "setAttachment:", .{
        (try newObject("VZNATNetworkDeviceAttachment")).value,
    });
    network.msgSend(void, "setMACAddress:", .{mac.value});
    configuration.msgSend(void, "setNetworkDevices:", .{array(&.{network}).value});
}

fn createDiskAttachment(path: [*:0]const u8, read_only: bool) ObjectError!Object {
    var error_object: id = null;
    const result = (try allocObject("VZDiskImageStorageDeviceAttachment")).msgSend(
        Object,
        "initWithURL:readOnly:error:",
        .{ (try fileURL(path)).value, boolParam(read_only), &error_object },
    );
    if (result.value == null) {
        logNSError("disk attachment creation failed", error_object);
        return error.FrameworkObjectCreationFailed;
    }
    return result.msgSend(Object, "autorelease", .{});
}

fn loadOrCreateMachineId(path: [*:0]const u8) ObjectError!Object {
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
    }))) return error.FrameworkObjectCreationFailed;
    return identifier;
}

fn respondsTo(object: Object, comptime selector: [:0]const u8) bool {
    return boolResult(object.msgSend(BOOL, "respondsToSelector:", .{objc.sel(selector)}));
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

test "GUI VZ backend rejects incomplete configuration" {
    const invalid = Config{
        .memory_bytes = 0,
        .vcpu_count = 0,
        .display_width = 0,
        .display_height = 0,
        .enable_net = false,
        .disk_read_only = false,
        .disk_path = null,
        .installer_path = null,
        .variable_store_path = null,
        .machine_id_path = null,
        .mac_address = null,
    };
    try std.testing.expectError(error.InvalidConfig, validateConfig(&invalid));
}
