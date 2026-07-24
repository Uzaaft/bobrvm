//! Virtio device implementations.
//!
//! Implements the virtio 1.2 specification for:
//! - virtio-console: Serial console I/O
//! - virtio-gpu: Graphics with virgl/venus 3D support (future)
//! - virtio-input: Keyboard and mouse (future)
//! - virtio-fs: File sharing (virtiofs) (future)
//! - virtio-net: Networking (future)
//! - virtio-blk: Block storage (future)
//!
//! Transport: MMIO (virtio-mmio)

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;

// Core components
pub const Queue = @import("queue.zig");
pub const mmio = @import("mmio.zig");

// Devices
pub const Console = @import("console.zig").Console;
pub const Block = @import("blk.zig").Block;
pub const blk = @import("blk.zig");
pub const Input = @import("input.zig").Input;
pub const input = @import("input.zig");
pub const Gpu = @import("gpu.zig").Gpu;
pub const Net = @import("net.zig").Net;
pub const gpu = @import("gpu.zig");
pub const Uart = @import("uart.zig").Uart;
pub const uart = @import("uart.zig");
pub const Rng = @import("rng.zig").Rng;
pub const rng = @import("rng.zig");
pub const P9 = @import("p9.zig").P9;
pub const p9 = @import("p9.zig");
// pub const Fs = @import("fs.zig");

// Re-export commonly used types
pub const VirtQueue = Queue.VirtQueue;
pub const Desc = Queue.Desc;
pub const DescFlags = Queue.DescFlags;
pub const DescChain = Queue.DescChain;
pub const Transport = mmio.Transport;

/// Virtio device IDs.
pub const DeviceId = enum(u32) {
    reserved = 0,
    net = 1,
    block = 2,
    console = 3,
    entropy = 4,
    balloon = 5,
    scsi = 8,
    gpu = 16,
    input = 18,
    vsock = 19,
    crypto = 20,
    fs = 26,
};

/// Virtio feature bits (common).
pub const Features = struct {
    /// Negotiating this feature indicates that the driver can use descriptors
    /// with the VIRTQ_DESC_F_INDIRECT flag set.
    pub const INDIRECT_DESC: u64 = 1 << 28;
    /// This feature enables the used_event and avail_event fields.
    pub const EVENT_IDX: u64 = 1 << 29;
    /// Indicates compliance with virtio 1.0+ spec.
    pub const VERSION_1: u64 = 1 << 32;
    /// This feature indicates that the device can be used on a platform
    /// where device access to data in memory is limited and/or translated.
    pub const ACCESS_PLATFORM: u64 = 1 << 33;
    /// This feature indicates support for the packed virtqueue layout.
    pub const RING_PACKED: u64 = 1 << 34;
    /// This feature indicates that memory accesses by the driver and the
    /// device are ordered in a way described by the platform.
    pub const IN_ORDER: u64 = 1 << 35;
    /// This feature indicates that the device supports read-only buffers.
    pub const ORDER_PLATFORM: u64 = 1 << 36;
    /// This feature indicates that the driver passes extra data (besides
    /// identifying the virtqueue) in its device notifications.
    pub const NOTIFICATION_DATA: u64 = 1 << 38;
};

test {
    _ = Queue;
    _ = mmio;
    _ = @import("console.zig");
    _ = @import("blk.zig");
    _ = @import("input.zig");
    _ = @import("gpu.zig");
    _ = @import("net.zig");
}

test "DeviceId values" {
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(DeviceId.console));
    try std.testing.expectEqual(@as(u32, 16), @intFromEnum(DeviceId.gpu));
    try std.testing.expectEqual(@as(u32, 26), @intFromEnum(DeviceId.fs));
}
