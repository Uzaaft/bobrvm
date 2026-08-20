//! Process-wide runtime state.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub var state: GlobalState = .{};

pub const GlobalState = struct {
    logging: Logging = .{},

    initialized: bool = false,

    pub fn init(self: *GlobalState) void {
        self.initWithLogging(.{});
    }

    pub fn initWithLogging(self: *GlobalState, defaults: Logging) void {
        if (self.initialized) return;

        self.logging = defaults;

        if (std.c.getenv("BOBRVM_LOG")) |env_value| {
            self.logging = parseLoggingConfig(defaults, std.mem.span(env_value));
        }

        self.initialized = true;
    }

    /// Deinitialize global state.
    pub fn deinit(self: *GlobalState) void {
        self.initialized = false;
    }
};

/// The process-wide Io implementation backing every std.Io.Mutex/Condition
/// lock/wait in bobrvm. We're a plain multi-threaded (not async) program —
/// every vCPU/renderer/NAT-poll thread is a real std.Thread.spawn thread —
/// so Zig's built-in "single threaded" Threaded instance is the right fit:
/// Mutex/Condition futex ops only special-case on the target's
/// builtin.single_threaded (false for us), so they still use real OS futex
/// syscalls here; this preset only skips the async/concurrent worker pool
/// we never use. Being a static value (no init() call required) also means
/// it's safe from unit tests that construct components directly, without
/// going through GlobalState.init().
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Logging = packed struct {
    /// The embedding library follows Ghostty and keeps stderr quiet unless
    /// explicitly enabled. CLI initialization overrides this default.
    stderr: bool = false,

    macos: bool = builtin.os.tag.isDarwin(),
};

/// Parse the Ghostty-style destination list used by BOBRVM_LOG. Legacy
/// key=value entries remain accepted so existing developer scripts keep working.
fn parseLoggingConfig(defaults: Logging, value: []const u8) Logging {
    var result = defaults;

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

    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |entry| {
        const value_trimmed = std.mem.trim(u8, entry, " \t");
        if (value_trimmed.len == 0) continue;

        if (std.mem.eql(u8, value_trimmed, "stderr")) result.stderr = true;
        if (std.mem.eql(u8, value_trimmed, "macos")) result.macos = true;
        if (std.mem.eql(u8, value_trimmed, "no-stderr")) result.stderr = false;
        if (std.mem.eql(u8, value_trimmed, "no-macos")) result.macos = false;
        parseLegacyLoggingEntry(&result, value_trimmed);
    }

    return result;
}

fn parseLegacyLoggingEntry(result: *Logging, entry: []const u8) void {
    const separator = std.mem.indexOfScalar(u8, entry, '=') orelse return;
    const key = std.mem.trim(u8, entry[0..separator], " \t");
    const value = std.mem.trim(u8, entry[separator + 1 ..], " \t");
    const enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");

    if (std.mem.eql(u8, key, "stderr")) result.stderr = enabled;
    if (std.mem.eql(u8, key, "macos")) result.macos = enabled;
}

test "parseLoggingConfig" {
    const testing = std.testing;

    {
        const cfg = parseLoggingConfig(.{}, "true");
        try testing.expect(cfg.stderr);
        try testing.expect(cfg.macos);
    }

    {
        const cfg = parseLoggingConfig(.{}, "false");
        try testing.expect(!cfg.stderr);
        try testing.expect(!cfg.macos);
    }

    {
        const cfg = parseLoggingConfig(.{}, "stderr=true,macos=false");
        try testing.expect(cfg.stderr);
        try testing.expect(!cfg.macos);
    }

    {
        const cfg = parseLoggingConfig(.{}, "stderr,macos");
        try testing.expect(cfg.stderr);
        try testing.expect(cfg.macos);
    }

    {
        const cfg = parseLoggingConfig(.{ .stderr = true, .macos = true }, "no-stderr");
        try testing.expect(!cfg.stderr);
        try testing.expect(cfg.macos);
    }
}
