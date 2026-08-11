//! Linux virtualization for macOS.

const std = @import("std");
const builtin = @import("builtin");

pub const agent = @import("agent/main.zig");
pub const apprt = @import("apprt/main.zig");
pub const config = @import("config.zig");
pub const console = @import("console/main.zig");
pub const disk = @import("disk.zig");
pub const fs = @import("fs/main.zig");
pub const global = @import("global.zig");
pub const guest_memory = @import("guest_memory.zig");
pub const hypervisor = @import("hypervisor/platform.zig");
pub const machine = @import("machine/main.zig");
pub const os = @import("os/main.zig");
pub const virtio = @import("virtio/main.zig");
pub const worker = @import("worker/main.zig");
pub const gpu = @import("gpu/main.zig");
pub const renderer = @import("renderer/main.zig");
pub const runtime = @import("runtime/main.zig");

pub const version: [:0]const u8 = "0.1.0";

test {
    if (builtin.os.tag == .linux) {
        _ = std.testing.refAllDecls(agent);
        _ = std.testing.refAllDecls(config);
        _ = std.testing.refAllDecls(console);
        _ = std.testing.refAllDecls(disk);
        _ = std.testing.refAllDecls(fs);
        _ = std.testing.refAllDecls(guest_memory);
        _ = std.testing.refAllDecls(hypervisor);
        _ = std.testing.refAllDecls(@import("machine/x86/boot.zig"));
        _ = std.testing.refAllDecls(@import("machine/x86/main.zig"));
        _ = @import("linux/VM.zig");
        _ = @import("linux/AppConfig.zig");
        _ = @import("linux/Preferences.zig");
        _ = std.testing.refAllDecls(@import("pci/virtio_pci.zig"));
        _ = std.testing.refAllDecls(@import("pci/x86_config.zig"));
        _ = std.testing.refAllDecls(worker);
        _ = std.testing.refAllDecls(@import("virtio/queue.zig"));
        _ = std.testing.refAllDecls(@import("virtio/mmio.zig"));
        _ = std.testing.refAllDecls(@import("virtio/console.zig"));
        _ = std.testing.refAllDecls(@import("virtio/blk.zig"));
        _ = std.testing.refAllDecls(@import("virtio/input.zig"));
        _ = std.testing.refAllDecls(@import("virtio/net.zig"));
        _ = std.testing.refAllDecls(@import("virtio/uart.zig"));
        _ = std.testing.refAllDecls(@import("virtio/rtc.zig"));
        _ = std.testing.refAllDecls(@import("virtio/rng.zig"));
        _ = std.testing.refAllDecls(@import("virtio/balloon.zig"));
        _ = std.testing.refAllDecls(@import("virtio/snd.zig"));
        _ = std.testing.refAllDecls(@import("virtio/p9.zig"));
        _ = @import("cli/Config.zig");
        return;
    }

    _ = std.testing.refAllDecls(@This());

    _ = agent;
    _ = apprt;
    _ = config;
    _ = console;
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
    _ = @import("cli/runner.zig");
    _ = @import("compat/file.zig");
    _ = @import("compat/thread.zig");
}
