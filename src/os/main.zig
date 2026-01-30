//! OS-level utilities and bindings.
//!
//! Provides platform-specific functionality for macOS:
//! - Unified logging (os_log)
//! - Signal handling for graceful shutdown

pub const log = @import("log.zig");
pub const signal = @import("signal.zig");
