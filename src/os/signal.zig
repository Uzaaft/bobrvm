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

var previous_sigint: posix.Sigaction = undefined;
var previous_sigterm: posix.Sigaction = undefined;

/// Register an async-signal-safe cleanup function for SIGINT/SIGTERM.
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
    if (!registered) return;
    posix.sigaction(posix.SIG.INT, &previous_sigint, null);
    posix.sigaction(posix.SIG.TERM, &previous_sigterm, null);
    registered = false;
}

fn installHandlers() void {
    const handler = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = 0,
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &handler, &previous_sigint);
    posix.sigaction(posix.SIG.TERM, &handler, &previous_sigterm);

    log.debug("signal handlers installed", .{});
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    // Async-signal-safe: only call cleanup, don't log (logging isn't signal-safe)
    if (cleanup_fn) |cb| {
        cb();
    }

    // Re-raise the signal with default handler to get proper exit code
    const default_handler = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = 0,
        .flags = 0,
    };

    posix.sigaction(sig, &default_handler, null);
    posix.raise(sig) catch {
        std.process.exit(128 + @as(u8, @intCast(@intFromEnum(sig))));
    };
}
