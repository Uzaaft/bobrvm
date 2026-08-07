const std = @import("std");
const apprt = @import("apprt/main.zig");
const macos_runtime = @import("runtime/macos.zig");
const c = @cImport({
    @cInclude("bobrvm.h");
});

fn expectStructLayout(comptime Zig: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Zig));
    try std.testing.expectEqual(@alignOf(C), @alignOf(Zig));
    const zig_fields = std.meta.fields(Zig);
    const c_fields = std.meta.fields(C);
    try std.testing.expectEqual(zig_fields.len, c_fields.len);
    inline for (zig_fields) |field| {
        if (!@hasField(C, field.name)) {
            @compileError("C ABI struct is missing field '" ++ field.name ++ "'");
        }
        try std.testing.expectEqual(
            @offsetOf(C, field.name),
            @offsetOf(Zig, field.name),
        );
        try std.testing.expectEqual(
            @sizeOf(@FieldType(C, field.name)),
            @sizeOf(field.type),
        );
    }
}

test "C ABI shared struct layouts match Zig" {
    try expectStructLayout(apprt.RuntimeConfig, c.bobrvm_runtime_config_s);
    try expectStructLayout(apprt.VMConfig, c.bobrvm_vm_config_s);
    try expectStructLayout(apprt.KeyEvent, c.bobrvm_key_event_s);
    try expectStructLayout(apprt.ContentScale, c.bobrvm_point_s);
    try expectStructLayout(macos_runtime.MacOSConfig, c.bobrvm_macos_vm_config_s);
}

test "C ABI enum values match Zig" {
    try std.testing.expectEqual(@as(c_int, @intFromEnum(apprt.MouseButton.left)), c.BOBRVM_MOUSE_LEFT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(apprt.MouseButton.right)), c.BOBRVM_MOUSE_RIGHT);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(apprt.MouseButton.middle)), c.BOBRVM_MOUSE_MIDDLE);
    try std.testing.expectEqual(@as(c_int, 0), c.BOBRVM_BUILD_MODE_DEBUG);
    try std.testing.expectEqual(@as(c_int, 3), c.BOBRVM_BUILD_MODE_RELEASE_SMALL);
    try std.testing.expectEqual(@as(c_int, 0), c.BOBRVM_OK);
    try std.testing.expectEqual(@as(c_int, 13), c.BOBRVM_ERROR_INVALID_STATE);
    try std.testing.expectEqual(@as(c_int, 0), c.BOBRVM_VM_STATE_STOPPED);
    try std.testing.expectEqual(@as(c_int, 6), c.BOBRVM_VM_STATE_FAILED);
}
