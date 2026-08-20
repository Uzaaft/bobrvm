//! Linux-host unit test root.

const std = @import("std");

test {
    _ = std.testing.refAllDecls(@import("agent/main.zig"));
    _ = std.testing.refAllDecls(@import("config.zig"));
    _ = std.testing.refAllDecls(@import("console/main.zig"));
    _ = std.testing.refAllDecls(@import("disk.zig"));
    _ = std.testing.refAllDecls(@import("fs/main.zig"));
    _ = std.testing.refAllDecls(@import("guest_memory.zig"));
    _ = std.testing.refAllDecls(@import("hypervisor/platform.zig"));
    _ = std.testing.refAllDecls(@import("machine/x86/boot.zig"));
    _ = std.testing.refAllDecls(@import("machine/x86/main.zig"));
    _ = @import("linux/VM.zig");
    _ = @import("linux/AppConfig.zig");
    _ = @import("linux/Preferences.zig");
    _ = std.testing.refAllDecls(@import("pci/virtio_pci.zig"));
    _ = std.testing.refAllDecls(@import("pci/x86_config.zig"));
    _ = std.testing.refAllDecls(@import("worker/main.zig"));
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
}
