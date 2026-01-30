//! Global state for bobrvm.
//!
//! Contains logging configuration and other cross-cutting concerns.
//! Pattern follows Ghostty's src/global.zig.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const os = @import("os/main.zig");
const apprt = @import("apprt/main.zig");

/// Global state singleton.
/// Initialized at library startup via init().
pub var state: GlobalState = .{};

pub const GlobalState = struct {
    /// Logging configuration. Defaults based on build mode and platform.
    logging: Logging = .{},

    /// Whether global state has been initialized.
    initialized: bool = false,

    /// Active app instance for signal handler cleanup.
    /// Only one app per process.
    active_app: ?*apprt.App = null,

    /// Initialize global state.
    /// Called once at library startup.
    pub fn init(self: *GlobalState) void {
        if (self.initialized) return;

        // Parse BOBRVM_LOG environment variable if set
        if (std.posix.getenv("BOBRVM_LOG")) |env_value| {
            self.logging = parseLoggingConfig(env_value);
        }

        // Register signal handlers for graceful shutdown
        os.signal.registerCleanup(signalCleanup);

        self.initialized = true;
    }

    /// Deinitialize global state.
    pub fn deinit(self: *GlobalState) void {
        os.signal.unregisterCleanup();
        self.active_app = null;
        self.initialized = false;
    }

    /// Register the active app for signal cleanup.
    pub fn setActiveApp(self: *GlobalState, app: ?*apprt.App) void {
        self.active_app = app;
    }
};

/// Signal cleanup callback - destroys the active app.
fn signalCleanup() void {
    if (state.active_app) |app| {
        app.destroy();
        state.active_app = null;
    }
}

/// Logging configuration.
/// Controls where log messages are routed.
pub const Logging = packed struct {
    /// Whether to log to stderr.
    /// Enabled by default in debug builds or when running from terminal.
    stderr: bool = switch (builtin.mode) {
        .Debug => true,
        else => false,
    },

    /// Whether to log to macOS unified logging (os_log).
    /// Enabled by default on macOS.
    macos: bool = builtin.os.tag.isDarwin(),
};

/// Parse "key=value,..." logging config from environment variable.
/// Supports formats:
///   - "true" / "false" - enable/disable all
///   - "stderr=true,macos=false" - individual control
fn parseLoggingConfig(value: []const u8) Logging {
    var result = Logging{};

    // Handle simple true/false for all destinations
    if (std.mem.eql(u8, value, "true")) {
        result.stderr = true;
        result.macos = true;
        return result;
    }
    if (std.mem.eql(u8, value, "false")) {
        result.stderr = false;
        result.macos = false;
        return result;
    }

    // Parse key=value pairs
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            const enabled = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");

            if (std.mem.eql(u8, key, "stderr")) {
                result.stderr = enabled;
            } else if (std.mem.eql(u8, key, "macos")) {
                result.macos = enabled;
            }
        }
    }

    return result;
}

test "parseLoggingConfig" {
    const testing = std.testing;

    // All enabled
    {
        const cfg = parseLoggingConfig("true");
        try testing.expect(cfg.stderr);
        try testing.expect(cfg.macos);
    }

    // All disabled
    {
        const cfg = parseLoggingConfig("false");
        try testing.expect(!cfg.stderr);
        try testing.expect(!cfg.macos);
    }

    // Individual settings
    {
        const cfg = parseLoggingConfig("stderr=true,macos=false");
        try testing.expect(cfg.stderr);
        try testing.expect(!cfg.macos);
    }
}
