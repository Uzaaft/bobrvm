const std = @import("std");
const testing = std.testing;
const mmio = @import("virtio/mmio.zig");
const ring = @import("virtio/ring.zig");

const guest_base: u64 = 0x1000;
const guest_size: usize = 0x6000;
const desc_addr: u64 = 0x1000;
const driver_addr: u64 = 0x2000;
const device_addr: u64 = 0x2400;
const buffer_addr: u64 = 0x3000;
const descriptor_count = 96;

const Access = struct {
    addr: u64,
    len: usize,
};

const Trace = struct {
    items: [ring.Chain.MAX_CHAIN + 8]Access = undefined,
    count: usize = 0,

    fn append(self: *Trace, addr: u64, len: usize) void {
        std.debug.assert(self.count < self.items.len);
        self.items[self.count] = .{ .addr = addr, .len = len };
        self.count += 1;
    }

    fn slice(self: *const Trace) []const Access {
        return self.items[0..self.count];
    }
};

const Case = struct {
    qc: mmio.QueueConfig,
    head: u16 = 0,
    avail_pos: u16 = 0,
    used_head: u16 = 0,
    used_len: u32 = 0,
};

const ModelDesc = struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const ModelChain = struct {
    descs: [ring.Chain.MAX_CHAIN]ModelDesc = undefined,
    count: usize = 0,

    fn slice(self: *const ModelChain) []const ModelDesc {
        return self.descs[0..self.count];
    }
};

var guest_mem: [guest_size]u8 = undefined;
var actual_trace: Trace = .{};

fn checkedAddress(base: u64, offset: u64, len: usize) ?u64 {
    const addr = std.math.add(u64, base, offset) catch return null;
    const len_u64 = std.math.cast(u64, len) orelse return null;
    _ = std.math.add(u64, addr, len_u64) catch return null;
    return addr;
}

fn indexedAddress(base: u64, header: u64, index: u16, stride: u64, len: usize) ?u64 {
    const entry_offset = std.math.mul(u64, index, stride) catch return null;
    const offset = std.math.add(u64, header, entry_offset) catch return null;
    return checkedAddress(base, offset, len);
}

fn mapMemory(mem: *[guest_size]u8, addr: u64, len: usize) ?[]u8 {
    if (addr < guest_base) return null;
    const offset = std.math.cast(usize, addr - guest_base) orelse return null;
    if (offset > mem.len or len > mem.len - offset) return null;
    return mem[offset..][0..len];
}

fn getMemory(addr: u64, len: usize) ?[]u8 {
    actual_trace.append(addr, len);
    return mapMemory(&guest_mem, addr, len);
}

fn writeDescriptor(index: usize, desc: ModelDesc) void {
    std.debug.assert(index < descriptor_count);
    const offset = index * 16;
    std.mem.writeInt(u64, guest_mem[offset..][0..8], desc.addr, .little);
    std.mem.writeInt(u32, guest_mem[offset + 8 ..][0..4], desc.len, .little);
    std.mem.writeInt(u16, guest_mem[offset + 12 ..][0..2], desc.flags, .little);
    std.mem.writeInt(u16, guest_mem[offset + 14 ..][0..2], desc.next, .little);
}

fn descriptor(index: usize, flags: u16, next: u16) ModelDesc {
    return .{
        .addr = buffer_addr + index * 16,
        .len = 8,
        .flags = flags,
        .next = next,
    };
}

fn setChain(count: usize) void {
    std.debug.assert(count <= descriptor_count);
    for (0..count) |index| {
        const has_next = index + 1 < count;
        const flags: u16 = if (has_next) ring.Desc.F_NEXT else 0;
        writeDescriptor(index, descriptor(index, flags, @intCast(index + 1)));
    }
}

fn writeRingIndices(avail_idx: u16, used_idx: u16) void {
    const driver_offset: usize = @intCast(driver_addr - guest_base);
    const device_offset: usize = @intCast(device_addr - guest_base);
    std.mem.writeInt(u16, guest_mem[driver_offset + 2 ..][0..2], avail_idx, .little);
    std.mem.writeInt(u16, guest_mem[device_offset + 2 ..][0..2], used_idx, .little);
}

fn defaultCase() Case {
    @memset(&guest_mem, 0);
    for (0..descriptor_count) |index| writeDescriptor(index, descriptor(index, 0, 0));
    writeRingIndices(7, 0);
    return .{ .qc = .{
        .num = 8,
        .ready = true,
        .desc_addr = desc_addr,
        .driver_addr = driver_addr,
        .device_addr = device_addr,
    } };
}

fn randomQueueSize(smith: *testing.Smith) u16 {
    return smith.valueWeighted(u16, &.{
        .value(u16, 0, 4),
        .value(u16, 1, 4),
        .rangeAtMost(u16, 2, descriptor_count, 8),
        .value(u16, 64, 4),
        .value(u16, 65, 4),
        .value(u16, std.math.maxInt(u16), 1),
    });
}

fn randomQueueAddress(smith: *testing.Smith, valid: u64) u64 {
    return switch (smith.valueRangeAtMost(u8, 0, 4)) {
        0 => valid,
        1 => 0,
        2 => guest_base + guest_size - 1,
        3 => std.math.maxInt(u64) - 3,
        4 => valid + 1,
        else => unreachable,
    };
}

fn configureRandom(smith: *testing.Smith, case: *Case) void {
    case.qc.num = randomQueueSize(smith);
    case.qc.desc_addr = randomQueueAddress(smith, desc_addr);
    case.qc.driver_addr = randomQueueAddress(smith, driver_addr);
    case.qc.device_addr = randomQueueAddress(smith, device_addr);
    case.head = smith.value(u16);
    case.avail_pos = smith.value(u16);
    case.used_head = smith.value(u16);
    case.used_len = smith.value(u32);

    smith.bytes(guest_mem[0 .. descriptor_count * 16]);
    smith.bytes(guest_mem[@intCast(buffer_addr - guest_base)..][0..512]);
    writeRingIndices(smith.value(u16), smith.value(u16));
}

fn configureLookupCase(case: *Case) void {
    case.qc.num = 4;
    writeDescriptor(0, .{
        .addr = 0,
        .len = std.math.maxInt(u32),
        .flags = ring.Desc.F_NEXT,
        .next = 1,
    });
    writeDescriptor(1, .{
        .addr = buffer_addr,
        .len = 0,
        .flags = ring.Desc.F_NEXT,
        .next = 2,
    });
    writeDescriptor(2, .{
        .addr = std.math.maxInt(u64),
        .len = std.math.maxInt(u32),
        .flags = ring.Desc.F_NEXT | ring.Desc.F_WRITE,
        .next = 3,
    });
    writeDescriptor(3, descriptor(3, ring.Desc.F_WRITE, 0));
}

fn configureScenario(selector: u8, case: *Case) void {
    switch (selector) {
        1 => case.qc.num = 0,
        2 => {
            case.qc.num = 1;
            writeDescriptor(0, descriptor(0, ring.Desc.F_NEXT, 0));
        },
        3 => {
            case.qc.num = 64;
            setChain(64);
        },
        4 => case.head = case.qc.num,
        5 => writeDescriptor(0, descriptor(0, ring.Desc.F_NEXT, case.qc.num)),
        6 => writeDescriptor(0, descriptor(0, ring.Desc.F_NEXT, 0)),
        7 => {
            writeDescriptor(0, descriptor(0, ring.Desc.F_NEXT, 1));
            writeDescriptor(1, descriptor(1, ring.Desc.F_NEXT, 2));
            writeDescriptor(2, descriptor(2, ring.Desc.F_NEXT, 1));
        },
        8 => {
            case.qc.num = 3;
            setChain(4);
        },
        9 => {
            case.qc.num = 65;
            setChain(65);
        },
        10 => configureLookupCase(case),
        11 => {
            case.qc.driver_addr = std.math.maxInt(u64) - 3;
            case.qc.device_addr = std.math.maxInt(u64) - 3;
            writeDescriptor(0, .{
                .addr = std.math.maxInt(u64),
                .len = std.math.maxInt(u32),
                .flags = 0,
                .next = 0,
            });
        },
        12 => {
            case.qc.num = 2;
            writeDescriptor(0, .{
                .addr = 0,
                .len = 8,
                .flags = ring.Desc.F_NEXT,
                .next = 1,
            });
            writeDescriptor(1, descriptor(1, 0, 0));
        },
        13 => {
            case.qc.num = 2;
            writeDescriptor(0, descriptor(0, 0x8000 | ring.Desc.F_NEXT, 1));
            writeDescriptor(1, descriptor(1, 0x4000 | ring.Desc.F_WRITE, 0));
        },
        14 => writeRingIndices(7, std.math.maxInt(u16)),
        15 => {
            case.qc.desc_addr = std.math.maxInt(u64) - 8;
            case.head = 1;
        },
        else => unreachable,
    }
}

fn generateCase(smith: *testing.Smith) Case {
    var case = defaultCase();
    const selector = smith.valueRangeAtMost(u8, 0, 15);
    if (selector == 0) configureRandom(smith, &case) else configureScenario(selector, &case);
    return case;
}

fn modelReadDesc(
    mem: *[guest_size]u8,
    qc: mmio.QueueConfig,
    index: u16,
    trace: *Trace,
) ?ModelDesc {
    if (index >= qc.num) return null;
    const addr = indexedAddress(qc.desc_addr, 0, index, 16, 16) orelse return null;
    trace.append(addr, 16);
    const bytes = mapMemory(mem, addr, 16) orelse return null;
    return .{
        .addr = std.mem.readInt(u64, bytes[0..8], .little),
        .len = std.mem.readInt(u32, bytes[8..12], .little),
        .flags = std.mem.readInt(u16, bytes[12..14], .little),
        .next = std.mem.readInt(u16, bytes[14..16], .little),
    };
}

fn modelCollect(mem: *[guest_size]u8, qc: mmio.QueueConfig, head: u16, trace: *Trace) ModelChain {
    var chain: ModelChain = .{};
    var index = head;
    const limit = @min(@as(usize, qc.num), ring.Chain.MAX_CHAIN);
    while (chain.count < limit) {
        const desc = modelReadDesc(mem, qc, index, trace) orelse break;
        chain.descs[chain.count] = desc;
        chain.count += 1;
        if ((desc.flags & ring.Desc.F_NEXT) == 0) break;
        index = desc.next;
    }
    return chain;
}

fn modelLookup(chain: *const ModelChain, writable: bool, trace: *Trace) ?[]u8 {
    for (chain.slice()) |desc| {
        if (((desc.flags & ring.Desc.F_WRITE) != 0) != writable) continue;
        _ = checkedAddress(desc.addr, 0, desc.len) orelse continue;
        trace.append(desc.addr, desc.len);
        if (mapMemory(&guest_mem, desc.addr, desc.len)) |mem| return mem;
    }
    return null;
}

fn modelAvailIdx(qc: mmio.QueueConfig, trace: *Trace) ?u16 {
    if (qc.num == 0) return null;
    const addr = checkedAddress(qc.driver_addr, 0, 6) orelse return null;
    trace.append(addr, 6);
    const mem = mapMemory(&guest_mem, addr, 6) orelse return null;
    return std.mem.readInt(u16, mem[2..4], .little);
}

fn modelAvailEntry(qc: mmio.QueueConfig, pos: u16, trace: *Trace) ?u16 {
    if (qc.num == 0) return null;
    const ring_index = pos % qc.num;
    const addr = indexedAddress(qc.driver_addr, 4, ring_index, 2, 2) orelse return null;
    trace.append(addr, 2);
    const mem = mapMemory(&guest_mem, addr, 2) orelse return null;
    return std.mem.readInt(u16, mem[0..2], .little);
}

fn modelPushUsed(mem: *[guest_size]u8, case: Case, trace: *Trace) void {
    if (case.qc.num == 0 or case.used_head >= case.qc.num) return;
    const ring_addr = checkedAddress(case.qc.device_addr, 0, 6) orelse return;
    trace.append(ring_addr, 6);
    const used_ring = mapMemory(mem, ring_addr, 6) orelse return;
    var used_idx = std.mem.readInt(u16, used_ring[2..4], .little);
    const pos = used_idx % case.qc.num;
    const entry_addr = indexedAddress(case.qc.device_addr, 4, pos, 8, 8) orelse return;
    trace.append(entry_addr, 8);
    const entry = mapMemory(mem, entry_addr, 8) orelse return;
    std.mem.writeInt(u32, entry[0..4], case.used_head, .little);
    std.mem.writeInt(u32, entry[4..8], case.used_len, .little);
    used_idx +%= 1;
    std.mem.writeInt(u16, @ptrCast(used_ring[2..4]), used_idx, .little);
}

fn expectTrace(expected: *const Trace) !void {
    try testing.expectEqual(expected.count, actual_trace.count);
    for (expected.slice(), actual_trace.slice()) |want, got| {
        try testing.expectEqual(want.addr, got.addr);
        try testing.expectEqual(want.len, got.len);
    }
}

fn expectMappedSlice(expected: ?[]u8, actual: ?[]u8) !void {
    try testing.expectEqual(expected == null, actual == null);
    if (expected) |want| {
        const got = actual.?;
        try testing.expectEqual(want.len, got.len);
        try testing.expectEqual(@intFromPtr(want.ptr), @intFromPtr(got.ptr));
    }
}

fn checkChain(case: Case) !struct { ring.Chain, ModelChain } {
    var expected_trace: Trace = .{};
    const expected = modelCollect(&guest_mem, case.qc, case.head, &expected_trace);
    actual_trace = .{};
    const actual = ring.Chain.collect(case.qc, case.head, getMemory);

    try testing.expect(actual.count <= @min(@as(usize, case.qc.num), ring.Chain.MAX_CHAIN));
    try testing.expectEqual(expected.count, actual.count);
    try expectTrace(&expected_trace);
    for (expected.slice(), actual.slice()) |want, got| {
        try testing.expectEqual(want.addr, got.addr);
        try testing.expectEqual(want.len, got.len);
        try testing.expectEqual(want.flags, got.flags);
        try testing.expectEqual(want.next, got.next);
    }
    return .{ actual, expected };
}

fn checkLookup(actual: *const ring.Chain, expected: *const ModelChain, writable: bool) !void {
    var expected_trace: Trace = .{};
    const want = modelLookup(expected, writable, &expected_trace);
    actual_trace = .{};
    const got = if (writable) actual.response(getMemory) else actual.request(getMemory);
    try expectMappedSlice(want, got);
    try expectTrace(&expected_trace);
}

fn checkAvailable(case: Case) !void {
    var expected_trace: Trace = .{};
    const want_idx = modelAvailIdx(case.qc, &expected_trace);
    actual_trace = .{};
    try testing.expectEqual(want_idx, ring.availIdx(case.qc, getMemory));
    try expectTrace(&expected_trace);

    expected_trace = .{};
    const want_entry = modelAvailEntry(case.qc, case.avail_pos, &expected_trace);
    actual_trace = .{};
    try testing.expectEqual(want_entry, ring.availEntry(case.qc, case.avail_pos, getMemory));
    try expectTrace(&expected_trace);
}

fn checkPushUsed(case: Case) !void {
    var expected_mem = guest_mem;
    var expected_trace: Trace = .{};
    modelPushUsed(&expected_mem, case, &expected_trace);
    actual_trace = .{};
    ring.pushUsed(case.qc, case.used_head, case.used_len, getMemory);
    try testing.expectEqualSlices(u8, &expected_mem, &guest_mem);
    try expectTrace(&expected_trace);
}

fn checkVirtqueue(_: void, smith: *testing.Smith) !void {
    const case = generateCase(smith);
    const chains = try checkChain(case);
    try checkLookup(&chains[0], &chains[1], false);
    try checkLookup(&chains[0], &chains[1], true);
    try checkAvailable(case);
    try checkPushUsed(case);
}

const seed_0 = std.mem.toBytes(@as(u64, 0));
const seed_1 = std.mem.toBytes(@as(u64, 1));
const seed_2 = std.mem.toBytes(@as(u64, 2));
const seed_3 = std.mem.toBytes(@as(u64, 3));
const seed_4 = std.mem.toBytes(@as(u64, 4));
const seed_5 = std.mem.toBytes(@as(u64, 5));
const seed_6 = std.mem.toBytes(@as(u64, 6));
const seed_7 = std.mem.toBytes(@as(u64, 7));
const seed_8 = std.mem.toBytes(@as(u64, 8));
const seed_9 = std.mem.toBytes(@as(u64, 9));
const seed_10 = std.mem.toBytes(@as(u64, 10));
const seed_11 = std.mem.toBytes(@as(u64, 11));
const seed_12 = std.mem.toBytes(@as(u64, 12));
const seed_13 = std.mem.toBytes(@as(u64, 13));
const seed_14 = std.mem.toBytes(@as(u64, 14));
const seed_15 = std.mem.toBytes(@as(u64, 15));

test "virtqueue split ring properties" {
    return testing.fuzz({}, checkVirtqueue, .{ .corpus = &.{
        &seed_0,  &seed_1,  &seed_2,  &seed_3,
        &seed_4,  &seed_5,  &seed_6,  &seed_7,
        &seed_8,  &seed_9,  &seed_10, &seed_11,
        &seed_12, &seed_13, &seed_14, &seed_15,
    } });
}
