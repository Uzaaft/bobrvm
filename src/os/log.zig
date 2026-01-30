//! macOS Unified Logging (os_log) bindings.
//!
//! Provides Zig wrappers around Apple's os/log.h API for integration
//! with the macOS unified logging system.
//!
//! Pattern follows Ghostty's pkg/macos/os/log.zig.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// C function declarations for os_log.
const c = struct {
    extern fn os_log_create(subsystem: [*:0]const u8, category: [*:0]const u8) ?*Log;
    extern fn os_log_type_enabled(log: *Log, log_type: LogType) bool;
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
    ) ?*Log {
        return c.os_log_create(subsystem.ptr, category.ptr);
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
        // Format the message with sentinel terminator
        const str = nosuspend std.fmt.allocPrint(alloc, format ++ .{0}, args) catch return;
        defer alloc.free(str);

        bobrvm_os_log_with_type(self, log_type, @ptrCast(str.ptr));
    }

    /// Log a message without formatting (just a string literal).
    pub fn logLiteral(self: *Log, log_type: LogType, message: [:0]const u8) void {
        bobrvm_os_log_with_type(self, log_type, message.ptr);
    }
};

/// Log type corresponding to os_log_type_t.
pub const LogType = enum(u8) {
    default = 0x00,
    info = 0x01,
    debug = 0x02,
    @"error" = 0x10,
    fault = 0x11,

    /// Convert from Zig std.log.Level.
    pub fn fromStdLevel(level: std.log.Level) LogType {
        return switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .@"error",
            .err => .fault,
        };
    }
};

/// Library subsystem identifier for os_log.
pub const lib_subsystem: [:0]const u8 = "com.bobrvm.lib";

/// Get or create a logger for the given scope.
///
/// Uses comptime to create a cached static logger per scope.
pub fn scopedLogger(comptime scope: @TypeOf(.EnumLiteral)) ?*Log {
    const S = struct {
        var cached: ?*Log = null;
        var once: bool = false;
    };

    if (!S.once) {
        S.cached = Log.create(lib_subsystem, @tagName(scope));
        S.once = true;
    }
    return S.cached;
}
