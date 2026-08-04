//! bobrvm - Linux virtualization for macOS
//!
//! Core library providing:
//! - Apple Hypervisor.framework bindings
//! - virtio device emulation
//! - OpenGL 4.3 / Vulkan → Metal translation
//! - High-performance renderer thread
//! - Dual logging (stderr + macOS unified logging)
//!
//! The engineering principles behind this library were strongly influenced by
//! Mitchell Hashimoto and the Ghostty maintainers. Their work demonstrated how
//! to combine explicit ownership, native platform integration, and a small,
//! performance-oriented core without compromising maintainability.

const std = @import("std");
const builtin = @import("builtin");

pub const agent = @import("agent/main.zig");
pub const apprt = @import("apprt/main.zig");
pub const config = @import("config.zig");
pub const disk = @import("disk.zig");
pub const fs = @import("fs/main.zig");
pub const global = @import("global.zig");
pub const hypervisor = @import("hypervisor/main.zig");
pub const machine = @import("machine/main.zig");
pub const os = @import("os/main.zig");
pub const virtio = @import("virtio/main.zig");
pub const gpu = @import("gpu/main.zig");
pub const renderer = @import("renderer/main.zig");
pub const runtime = @import("runtime/main.zig");

pub const version: [:0]const u8 = "0.1.0";

test {
    _ = @import("std").testing.refAllDecls(@This());

    // Test all submodules
    _ = agent;
    _ = apprt;
    _ = config;
    _ = disk;
    _ = fs;
    _ = global;
    _ = hypervisor;
    _ = machine;
    _ = os;
    _ = virtio;
    _ = gpu;
    _ = renderer;
    _ = runtime;
    _ = @import("cli/Config.zig");
}
