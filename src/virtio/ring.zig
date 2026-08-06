//! Guest-memory virtqueue (split ring) processing helpers.
//!
//! Devices process descriptor chains directly out of guest memory:
//! read the avail ring, walk descriptor chains, write the used ring.
//! All calls must happen on the vCPU thread.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const mmio = @import("mmio.zig");

pub const GetMemFn = *const fn (addr: u64, len: usize) ?[]u8;

fn guestAddress(base: u64, offset: u64, len: usize) ?u64 {
    const addr = std.math.add(u64, base, offset) catch return null;
    const len_u64 = std.math.cast(u64, len) orelse return null;
    _ = std.math.add(u64, addr, len_u64) catch return null;
    return addr;
}

fn indexedGuestAddress(
    base: u64,
    header_size: u64,
    index: u16,
    entry_size: u64,
    len: usize,
) ?u64 {
    const entry_offset = std.math.mul(u64, index, entry_size) catch return null;
    const offset = std.math.add(u64, header_size, entry_offset) catch return null;
    return guestAddress(base, offset, len);
}

/// A descriptor read out of guest memory.
pub const Desc = struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,

    pub const F_NEXT: u16 = 1;
    pub const F_WRITE: u16 = 2;

    pub fn isWrite(self: Desc) bool {
        return (self.flags & F_WRITE) != 0;
    }

    pub fn hasNext(self: Desc) bool {
        return (self.flags & F_NEXT) != 0;
    }
};

/// Read one descriptor from the descriptor table.
pub fn readDesc(qc: mmio.QueueConfig, idx: u16, get_mem: GetMemFn) ?Desc {
    if (idx >= qc.num) return null;
    const addr = indexedGuestAddress(qc.desc_addr, 0, idx, 16, 16) orelse return null;
    const mem = get_mem(addr, 16) orelse return null;
    return .{
        .addr = std.mem.readInt(u64, mem[0..8], .little),
        .len = std.mem.readInt(u32, mem[8..12], .little),
        .flags = std.mem.readInt(u16, mem[12..14], .little),
        .next = std.mem.readInt(u16, mem[14..16], .little),
    };
}

/// Read the avail ring index.
pub fn availIdx(qc: mmio.QueueConfig, get_mem: GetMemFn) ?u16 {
    if (qc.num == 0) return null;
    const addr = guestAddress(qc.driver_addr, 0, 6) orelse return null;
    const mem = get_mem(addr, 6) orelse return null;
    return std.mem.readInt(u16, mem[2..4], .little);
}

/// Read the descriptor index at an avail ring position.
pub fn availEntry(qc: mmio.QueueConfig, pos: u16, get_mem: GetMemFn) ?u16 {
    if (qc.num == 0) return null;
    const ring_idx = pos % qc.num;
    const addr = indexedGuestAddress(qc.driver_addr, 4, ring_idx, 2, 2) orelse return null;
    const mem = get_mem(addr, 2) orelse return null;
    return std.mem.readInt(u16, mem[0..2], .little);
}

/// Append an entry to the used ring and bump its index.
pub fn pushUsed(qc: mmio.QueueConfig, desc_idx: u16, len: u32, get_mem: GetMemFn) void {
    if (qc.num == 0 or desc_idx >= qc.num) return;
    const ring_addr = guestAddress(qc.device_addr, 0, 6) orelse return;
    const used_ring = get_mem(ring_addr, 6) orelse return;
    var used_idx = std.mem.readInt(u16, used_ring[2..4], .little);
    const pos = used_idx % qc.num;
    const entry_addr = indexedGuestAddress(qc.device_addr, 4, pos, 8, 8) orelse return;
    const entry = get_mem(entry_addr, 8) orelse return;
    std.mem.writeInt(u32, entry[0..4], desc_idx, .little);
    std.mem.writeInt(u32, entry[4..8], len, .little);
    used_idx +%= 1;
    std.mem.writeInt(u16, @ptrCast(used_ring[2..4]), used_idx, .little);
}

/// A descriptor chain collected from guest memory.
pub const Chain = struct {
    descs: [MAX_CHAIN]Desc = undefined,
    count: usize = 0,

    pub const MAX_CHAIN: usize = 64;

    /// Collect the chain starting at head. Bounded by MAX_CHAIN.
    pub fn collect(qc: mmio.QueueConfig, head: u16, get_mem: GetMemFn) Chain {
        var chain: Chain = .{};
        var idx = head;
        const limit = @min(@as(usize, qc.num), MAX_CHAIN);
        while (chain.count < limit) {
            const desc = readDesc(qc, idx, get_mem) orelse break;
            chain.descs[chain.count] = desc;
            chain.count += 1;
            if (!desc.hasNext()) break;
            idx = desc.next;
        }
        return chain;
    }

    pub fn slice(self: *const Chain) []const Desc {
        return self.descs[0..self.count];
    }

    /// First device-readable descriptor's guest memory (the request).
    pub fn request(self: *const Chain, get_mem: GetMemFn) ?[]u8 {
        for (self.slice()) |d| {
            if (!d.isWrite() and guestAddress(d.addr, 0, d.len) != null) {
                if (get_mem(d.addr, d.len)) |mem| return mem;
            }
        }
        return null;
    }

    /// First device-writable descriptor's guest memory (the response).
    pub fn response(self: *const Chain, get_mem: GetMemFn) ?[]u8 {
        for (self.slice()) |d| {
            if (d.isWrite() and guestAddress(d.addr, 0, d.len) != null) {
                if (get_mem(d.addr, d.len)) |mem| return mem;
            }
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Test guest memory: a flat buffer starting at address 0x1000.
var test_mem: [8192]u8 = undefined;

fn testGetMem(addr: u64, len: usize) ?[]u8 {
    if (addr < 0x1000) return null;
    const off = std.math.cast(usize, addr - 0x1000) orelse return null;
    if (off > test_mem.len or len > test_mem.len - off) return null;
    return test_mem[off..][0..len];
}

test "ring: desc read and chain collection" {
    @memset(&test_mem, 0);

    // Descriptor table at 0x1000: desc0 -> desc1 (write)
    // desc0: addr=0x1800 len=16 flags=NEXT next=1
    std.mem.writeInt(u64, test_mem[0..8], 0x1800, .little);
    std.mem.writeInt(u32, test_mem[8..12], 16, .little);
    std.mem.writeInt(u16, test_mem[12..14], Desc.F_NEXT, .little);
    std.mem.writeInt(u16, test_mem[14..16], 1, .little);
    // desc1: addr=0x1900 len=8 flags=WRITE
    std.mem.writeInt(u64, test_mem[16..24], 0x1900, .little);
    std.mem.writeInt(u32, test_mem[24..28], 8, .little);
    std.mem.writeInt(u16, test_mem[28..30], Desc.F_WRITE, .little);

    const qc = mmio.QueueConfig{
        .num = 8,
        .ready = true,
        .desc_addr = 0x1000,
        .driver_addr = 0x1400,
        .device_addr = 0x1600,
    };

    const chain = Chain.collect(qc, 0, testGetMem);
    try testing.expectEqual(@as(usize, 2), chain.count);
    try testing.expect(!chain.descs[0].isWrite());
    try testing.expect(chain.descs[1].isWrite());

    const req = chain.request(testGetMem).?;
    try testing.expectEqual(@as(usize, 16), req.len);
    const resp = chain.response(testGetMem).?;
    try testing.expectEqual(@as(usize, 8), resp.len);
}

test "ring: used ring push" {
    @memset(&test_mem, 0);
    const qc = mmio.QueueConfig{
        .num = 8,
        .ready = true,
        .desc_addr = 0x1000,
        .driver_addr = 0x1400,
        .device_addr = 0x1600,
    };

    pushUsed(qc, 3, 24, testGetMem);
    // used idx at 0x1600+2
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, test_mem[0x602..0x604], .little));
    // entry 0: id at 0x1604, len at 0x1608
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, test_mem[0x604..0x608], .little));
    try testing.expectEqual(@as(u32, 24), std.mem.readInt(u32, test_mem[0x608..0x60c], .little));
}
