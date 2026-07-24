//! bobrvm - Linux virtualization for macOS
//!
//! Core library providing:
//! - Apple Hypervisor.framework bindings
//! - virtio device emulation
//! - OpenGL 4.3 / Vulkan → Metal translation
//! - High-performance renderer thread
//! - Dual logging (stderr + macOS unified logging)

const std = @import("std");
const builtin = @import("builtin");

pub const agent = @import("agent/main.zig");
pub const apprt = @import("apprt/main.zig");
pub const fs = @import("fs/main.zig");
pub const global = @import("global.zig");
pub const hypervisor = @import("hypervisor/main.zig");
pub const machine = @import("machine/main.zig");
pub const os = @import("os/main.zig");
pub const virtio = @import("virtio/main.zig");
pub const gpu = @import("gpu/main.zig");
pub const renderer = @import("renderer/main.zig");

pub const version: [:0]const u8 = "0.1.0";

test {
    _ = @import("std").testing.refAllDecls(@This());

    // Test all submodules
    _ = agent;
    _ = apprt;
    _ = fs;
    _ = global;
    _ = hypervisor;
    _ = machine;
    _ = os;
    _ = virtio;
    _ = gpu;
    _ = renderer;
}
