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
