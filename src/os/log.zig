//! macOS Unified Logging (os_log) bindings.
//!
//! Provides Zig wrappers around Apple's os/log.h API for integration
//! with the macOS unified logging system.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// C function declarations for os_log.
const c = struct {
    extern fn os_log_create(subsystem: [*:0]const u8, category: [*:0]const u8) ?*Log;
    extern fn os_log_type_enabled(log: *Log, log_type: LogType) bool;
    extern fn os_release(object: *Log) void;
};

/// Helper C function we implement to call os_log_with_type.
/// Defined in os/log.c because os_log is a macro.
extern fn bobrvm_os_log_with_type(log: *Log, log_type: LogType, message: [*:0]const u8) void;

/// Opaque os_log_t handle.
pub const Log = opaque {
    /// Create a new logger with subsystem and category.
    ///
    /// subsystem: Reverse-DNS identifier (e.g., "com.bobrvm.app")
    /// category: Log category for filtering (e.g., "renderer", "hypervisor")
    pub fn create(
        subsystem: [:0]const u8,
        category: [:0]const u8,
    ) *Log {
        return c.os_log_create(subsystem.ptr, category.ptr).?;
    }

    pub fn release(self: *Log) void {
        c.os_release(self);
    }

    /// Check if a given log type is enabled.
    pub fn typeEnabled(self: *Log, log_type: LogType) bool {
        return c.os_log_type_enabled(self, log_type);
    }

    /// Log a message with the given type.
    ///
    /// Uses a temporary allocation to format the message.
    pub fn log(
        self: *Log,
        alloc: Allocator,
        log_type: LogType,
        comptime format: []const u8,
        args: anytype,
    ) void {
        const str = nosuspend std.fmt.allocPrintSentinel(alloc, format, args, 0) catch return;
        defer alloc.free(str);

        bobrvm_os_log_with_type(self, log_type, @ptrCast(str.ptr));
    }
};

/// Log type corresponding to os_log_type_t.
pub const LogType = enum(u8) {
    default = 0x00,
    info = 0x01,
    debug = 0x02,
    err = 0x10,
    fault = 0x11,
};

test "unified logger accepts formatted messages" {
    const logger = Log.create("com.bobrvm.app", "test");
    defer logger.release();

    try std.testing.expect(logger.typeEnabled(.fault));
    logger.log(std.testing.allocator, .debug, "test value={}", .{12});
}
