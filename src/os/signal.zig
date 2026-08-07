//! Signal handling for graceful shutdown.
//!
//! Registers handlers for SIGINT/SIGTERM to ensure hypervisor cleanup.
//! Critical because Apple's Hypervisor.framework only allows one VM per process.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.signal);

/// Cleanup callback type.
pub const CleanupFn = *const fn () void;

/// Global cleanup function, set via registerCleanup.
var cleanup_fn: ?CleanupFn = null;

/// Whether signals have been registered.
var registered: bool = false;

/// Register a cleanup function to be called on SIGINT/SIGTERM.
/// Only one cleanup function can be registered at a time.
pub fn registerCleanup(callback: CleanupFn) void {
    cleanup_fn = callback;

    if (!registered) {
        installHandlers();
        registered = true;
    }
}

/// Unregister the cleanup function.
pub fn unregisterCleanup() void {
    cleanup_fn = null;
}

fn installHandlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &handler, null);
    posix.sigaction(posix.SIG.TERM, &handler, null);

    log.debug("signal handlers installed", .{});
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    const sig_name: []const u8 = switch (sig) {
        .INT => "SIGINT",
        .TERM => "SIGTERM",
        else => "unknown",
    };

    // Async-signal-safe: only call cleanup, don't log (logging isn't signal-safe)
    if (cleanup_fn) |cb| {
        cb();
    }

    // Re-raise the signal with default handler to get proper exit code
    const default_handler = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(sig, &default_handler, null);
    posix.raise(sig) catch {};

    // If we get here, just exit
    _ = sig_name;
    std.process.exit(128 + @as(u8, @intCast(@intFromEnum(sig))));
}
