//! Apple Virtualization.framework guest backend.
//!
//! Zig owns every framework object. Swift receives only an opaque NSView.

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

    pub const Config = MacOSConfig;
    pub const InitError = error{
        InvalidConfig,
        UnsupportedHost,
        FrameworkObjectCreationFailed,
        ConfigurationValidationFailed,
    };
    pub const StartError = error{ InvalidState, StartFailed };

    const CompletionBlock = objc.Block(struct {}, .{id}, void);

    pub fn init(config: *const Config) InitError!Backend {
        if (comptime builtin.cpu.arch != .aarch64) return error.UnsupportedHost;
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const configuration = try createConfiguration(config);
        defer configuration.release();

        const vm_alloc = try allocObject("VZVirtualMachine");
        const vm = vm_alloc.msgSend(Object, "initWithConfiguration:", .{configuration.value});
        if (vm.value == null) return error.FrameworkObjectCreationFailed;

        const view_alloc = try allocObject("VZVirtualMachineView");
        const view = view_alloc.msgSend(Object, "init", .{});
        if (view.value == null) {
            vm.release();
            return error.FrameworkObjectCreationFailed;
        }
        view.msgSend(void, "setVirtualMachine:", .{vm.value});
        view.msgSend(void, "setCapturesSystemKeys:", .{boolParam(true)});
        if (view.getClass().?.respondsToSelector(objc.sel("setAutomaticallyReconfiguresDisplay:"))) {
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
        if (!boolResult(self.vm.msgSend(BOOL, "canStart", .{}))) return error.InvalidState;
        self.perform("startWithCompletionHandler:", .running);
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

    fn perform(self: *Backend, comptime selector: [:0]const u8, _: runtime.State) void {
        var block = CompletionBlock.init(.{}, completion);
        self.vm.msgSend(void, selector, .{&block});
    }

    fn completion(_: *const CompletionBlock.Context, _: id) callconv(.c) void {}
};

pub const MacRuntime = runtime.Runtime(Backend);

fn createConfiguration(config: *const MacOSConfig) Backend.InitError!Object {
    const disk_path = config.disk_path orelse return error.InvalidConfig;
    const auxiliary_path = config.auxiliary_storage_path orelse return error.InvalidConfig;
    const hardware_base64 = config.hardware_model_base64 orelse return error.InvalidConfig;
    const identifier_base64 = config.machine_identifier_base64 orelse return error.InvalidConfig;
    const mac_string = config.mac_address orelse return error.InvalidConfig;
    if (config.memory_bytes == 0 or config.vcpu_count == 0) return error.InvalidConfig;

    const hardware_data = try dataFromBase64(hardware_base64);
    const identifier_data = try dataFromBase64(identifier_base64);
    const hardware = try initObject("VZMacHardwareModel", "initWithDataRepresentation:", .{hardware_data.value});
    const identifier = try initObject("VZMacMachineIdentifier", "initWithDataRepresentation:", .{identifier_data.value});
    const auxiliary_url = try fileURL(auxiliary_path);
    const auxiliary = try initObject("VZMacAuxiliaryStorage", "initWithURL:", .{auxiliary_url.value});
    const mac = try initObject("VZMACAddress", "initWithString:", .{string(mac_string).value});

    const platform = try newObject("VZMacPlatformConfiguration");
    platform.msgSend(void, "setHardwareModel:", .{hardware.value});
    platform.msgSend(void, "setMachineIdentifier:", .{identifier.value});
    platform.msgSend(void, "setAuxiliaryStorage:", .{auxiliary.value});

    const configuration = try newObject("VZVirtualMachineConfiguration");
    configuration.msgSend(void, "setBootLoader:", .{(try newObject("VZMacOSBootLoader")).value});
    configuration.msgSend(void, "setPlatform:", .{platform.value});
    configuration.msgSend(void, "setCPUCount:", .{@as(NSUInteger, config.vcpu_count)});
    configuration.msgSend(void, "setMemorySize:", .{config.memory_bytes});

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

    const keyboard = try newObject("VZUSBKeyboardConfiguration");
    configuration.msgSend(void, "setKeyboards:", .{array(&.{keyboard}).value});
    const pointer = try newObject("VZUSBScreenCoordinatePointingDeviceConfiguration");
    const trackpad = try newObject("VZMacTrackpadConfiguration");
    configuration.msgSend(void, "setPointingDevices:", .{array(&.{ pointer, trackpad }).value});

    const network = try newObject("VZVirtioNetworkDeviceConfiguration");
    network.msgSend(void, "setAttachment:", .{(try newObject("VZNATNetworkDeviceAttachment")).value});
    network.msgSend(void, "setMACAddress:", .{mac.value});
    configuration.msgSend(void, "setNetworkDevices:", .{array(&.{network}).value});
    configuration.msgSend(void, "setEntropyDevices:", .{array(&.{try newObject("VZVirtioEntropyDeviceConfiguration")}).value});

    var error_object: id = null;
    if (!boolResult(configuration.msgSend(BOOL, "validateWithError:", .{&error_object}))) {
        return error.ConfigurationValidationFailed;
    }
    return configuration.retain();
}

fn createDiskAttachment(path: [*:0]const u8) Backend.InitError!Object {
    var error_object: id = null;
    const result = (try allocObject("VZDiskImageStorageDeviceAttachment")).msgSend(
        Object,
        "initWithURL:readOnly:error:",
        .{ (try fileURL(path)).value, boolParam(false), &error_object },
    );
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result;
}

fn dataFromBase64(value: [*:0]const u8) Backend.InitError!Object {
    return initObject("NSData", "initWithBase64EncodedString:options:", .{
        string(value).value,
        @as(NSUInteger, 0),
    });
}

fn string(value: [*:0]const u8) Object {
    return objc.getClass("NSString").?.msgSend(Object, "stringWithUTF8String:", .{value});
}

fn fileURL(path: [*:0]const u8) Backend.InitError!Object {
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

fn allocObject(comptime name: [:0]const u8) Backend.InitError!Object {
    const class = objc.getClass(name) orelse return error.FrameworkObjectCreationFailed;
    const result = class.msgSend(Object, "alloc", .{});
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result;
}

fn newObject(comptime name: [:0]const u8) Backend.InitError!Object {
    const result = (try allocObject(name)).msgSend(Object, "init", .{});
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result.msgSend(Object, "autorelease", .{});
}

fn initObject(
    comptime name: [:0]const u8,
    comptime selector: [:0]const u8,
    args: anytype,
) Backend.InitError!Object {
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

test "Virtualization framework reports host support" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const class = objc.getClass("VZVirtualMachine") orelse return error.TestUnexpectedResult;
    try std.testing.expect(boolResult(class.msgSend(BOOL, "isSupported", .{})));
}
