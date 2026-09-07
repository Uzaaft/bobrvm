//! Shared Objective-C boundary for Virtualization.framework backends.

const std = @import("std");
const objc = @import("objc");
const runtime = @import("Runtime.zig");
const assert = @import("../quirks.zig").inlineAssert;

pub const Object = objc.Object;
pub const id = objc.c.id;
pub const BOOL = objc.c.BOOL;
pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const ObjectError = error{FrameworkObjectCreationFailed};

pub fn boolParam(value: bool) BOOL {
    return switch (BOOL) {
        bool => value,
        i8 => @intFromBool(value),
        else => @compileError("unexpected Objective-C BOOL type"),
    };
}

pub fn boolResult(value: BOOL) bool {
    return switch (BOOL) {
        bool => value,
        i8 => value == 1,
        else => @compileError("unexpected Objective-C BOOL type"),
    };
}

pub fn string(value: [*:0]const u8) Object {
    return objc.getClass("NSString").?.msgSend(Object, "stringWithUTF8String:", .{value});
}

pub fn fileURL(path: [*:0]const u8) ObjectError!Object {
    const result = objc.getClass("NSURL").?.msgSend(
        Object,
        "fileURLWithPath:",
        .{string(path).value},
    );
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result;
}

pub fn array(objects: []const Object) Object {
    var values: [16]id = undefined;
    assert(objects.len <= values.len);
    for (objects, 0..) |object, index| values[index] = object.value;
    return objc.getClass("NSArray").?.msgSend(Object, "arrayWithObjects:count:", .{
        values[0..objects.len].ptr,
        objects.len,
    });
}

pub fn allocObject(comptime name: [:0]const u8) ObjectError!Object {
    const class = objc.getClass(name) orelse return error.FrameworkObjectCreationFailed;
    const result = class.msgSend(Object, "alloc", .{});
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result;
}

pub fn newObject(comptime name: [:0]const u8) ObjectError!Object {
    const result = (try allocObject(name)).msgSend(Object, "init", .{});
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result.msgSend(Object, "autorelease", .{});
}

pub fn initObject(
    comptime name: [:0]const u8,
    comptime selector: [:0]const u8,
    args: anytype,
) ObjectError!Object {
    const result = (try allocObject(name)).msgSend(Object, selector, args);
    if (result.value == null) return error.FrameworkObjectCreationFailed;
    return result.msgSend(Object, "autorelease", .{});
}

pub fn respondsTo(object: Object, comptime selector: [:0]const u8) bool {
    return boolResult(object.msgSend(BOOL, "respondsToSelector:", .{objc.sel(selector)}));
}

pub fn mapState(value: NSInteger) runtime.State {
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

pub fn logNSError(
    comptime scope: anytype,
    message: []const u8,
    error_object: id,
) void {
    const log = std.log.scoped(scope);
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

test "VZ Objective-C boundary normalizes framework values" {
    try std.testing.expect(!boolResult(boolParam(false)));
    try std.testing.expect(boolResult(boolParam(true)));
    try std.testing.expectEqual(runtime.State.stopped, mapState(0));
    try std.testing.expectEqual(runtime.State.starting, mapState(4));
    try std.testing.expectEqual(runtime.State.starting, mapState(6));
    try std.testing.expectEqual(runtime.State.failed, mapState(99));
}

/// The identifier is autoreleased. A failed write still returns a usable
/// identifier so the caller can decide whether persistence is mandatory.
pub const MachineIdentifier = struct {
    object: Object,
    persisted: bool,
};

/// Load an existing identifier or generate and atomically persist a new one.
pub fn loadOrCreateMachineId(path: [*:0]const u8) ObjectError!MachineIdentifier {
    const existing = objc.getClass("NSData").?.msgSend(
        Object,
        "dataWithContentsOfFile:",
        .{string(path).value},
    );
    if (existing.value != null) {
        return .{
            .object = try initObject(
                "VZGenericMachineIdentifier",
                "initWithDataRepresentation:",
                .{existing.value},
            ),
            .persisted = true,
        };
    }
    const identifier = try newObject("VZGenericMachineIdentifier");
    const data = identifier.msgSend(Object, "dataRepresentation", .{});
    if (data.value == null) return error.FrameworkObjectCreationFailed;
    return .{
        .object = identifier,
        .persisted = boolResult(data.msgSend(BOOL, "writeToFile:atomically:", .{
            string(path).value,
            boolParam(true),
        })),
    };
}

/// Apply GUI resource limits reported by Virtualization.framework.
pub fn configureCompute(configuration: Object, vcpu_count: u32, memory_bytes: u64) void {
    const class = objc.getClass("VZVirtualMachineConfiguration").?;
    const cpu_min = class.msgSend(NSUInteger, "minimumAllowedCPUCount", .{});
    const cpu_max = class.msgSend(NSUInteger, "maximumAllowedCPUCount", .{});
    const memory_min = class.msgSend(u64, "minimumAllowedMemorySize", .{});
    const memory_max = class.msgSend(u64, "maximumAllowedMemorySize", .{});
    configuration.msgSend(void, "setCPUCount:", .{std.math.clamp(
        @as(NSUInteger, vcpu_count),
        cpu_min,
        cpu_max,
    )});
    configuration.msgSend(void, "setMemorySize:", .{std.math.clamp(
        memory_bytes,
        memory_min,
        memory_max,
    )});
}

test "VZ machine identifier survives reload and reports persistence failure" {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/machine-id", .{directory});

    const created = try loadOrCreateMachineId(path);
    try std.testing.expect(created.persisted);
    const loaded = try loadOrCreateMachineId(path);
    try std.testing.expect(loaded.persisted);
    const created_data = created.object.msgSend(Object, "dataRepresentation", .{});
    const loaded_data = loaded.object.msgSend(Object, "dataRepresentation", .{});
    try std.testing.expect(boolResult(created_data.msgSend(BOOL, "isEqualToData:", .{
        loaded_data.value,
    })));

    const missing_parent = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing/id", .{directory});
    const unpersisted = try loadOrCreateMachineId(missing_parent);
    try std.testing.expect(!unpersisted.persisted);
    try std.testing.expect(unpersisted.object.value != null);
}
