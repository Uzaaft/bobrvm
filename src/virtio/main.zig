//! Virtio 1.2 devices and the MMIO transport.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;

pub const Queue = @import("queue.zig");
pub const mmio = @import("mmio.zig");

pub const Console = @import("console.zig").Console;
pub const console = @import("console.zig");
pub const Block = @import("blk.zig").Block;
pub const blk = @import("blk.zig");
pub const Input = @import("input.zig").Input;
pub const input = @import("input.zig");
pub const Gpu = @import("gpu.zig").Gpu;
pub const Net = @import("net.zig").Net;
pub const gpu = @import("gpu.zig");
pub const Uart = @import("uart.zig").Uart;
pub const uart = @import("uart.zig");
pub const Rtc = @import("rtc.zig").Rtc;
pub const rtc = @import("rtc.zig");
pub const Rng = @import("rng.zig").Rng;
pub const rng = @import("rng.zig");
pub const Balloon = @import("balloon.zig").Balloon;
pub const balloon = @import("balloon.zig");
pub const Snd = @import("snd.zig").Snd;
pub const snd = @import("snd.zig");
pub const P9 = @import("p9.zig").P9;
pub const p9 = @import("p9.zig");
// pub const Fs = @import("fs.zig");

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
    sound = 25,
    fs = 26,
};

/// Virtio feature bits (common).
pub const Features = struct {
    pub const INDIRECT_DESC: u64 = 1 << 28;
    pub const EVENT_IDX: u64 = 1 << 29;
    pub const VERSION_1: u64 = 1 << 32;
    pub const ACCESS_PLATFORM: u64 = 1 << 33;
    pub const RING_PACKED: u64 = 1 << 34;
    pub const IN_ORDER: u64 = 1 << 35;
    pub const ORDER_PLATFORM: u64 = 1 << 36;
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
    _ = @import("uart.zig");
    _ = @import("balloon.zig");
    _ = @import("snd.zig");
    _ = @import("rtc.zig");
    _ = @import("rng.zig");
    _ = @import("p9.zig");
    _ = @import("ring.zig");
}

test "DeviceId values" {
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(DeviceId.console));
    try std.testing.expectEqual(@as(u32, 16), @intFromEnum(DeviceId.gpu));
    try std.testing.expectEqual(@as(u32, 26), @intFromEnum(DeviceId.fs));
}
