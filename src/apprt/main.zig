//! Application runtime abstraction.
//!
//! Provides platform-agnostic interfaces for:
//! - App lifecycle management
//! - VM instance management
//! - Surface (display) management
//! - Input event handling
//!
//! This module re-exports the embedded runtime for macOS/Swift integration.

pub const embedded = @import("embedded.zig");

// Re-export core types for convenience
pub const App = embedded.App;
pub const VM = embedded.VM;
pub const Surface = embedded.Surface;
pub const RuntimeConfig = embedded.RuntimeConfig;
pub const VMConfig = embedded.VMConfig;
pub const KeyEvent = embedded.KeyEvent;
pub const MouseButton = embedded.MouseButton;
pub const ContentScale = embedded.ContentScale;
pub const contentScaleValid = embedded.contentScaleValid;

test {
    _ = embedded;
    _ = @import("keymap.zig");
}
