const std = @import("std");
const testing = std.testing;
const gic_module = @import("gic/main.zig");

const Gic = gic_module.Gic;
const GICD = gic_module.GICD;
const GICR = gic_module.GICR;
const operations_max = 48;
const model_cpus_max = 4;

const Irq = struct {
    enabled: bool = false,
    pending: bool = false,
    active: bool = false,
    priority: u8 = 0xFF,
    config: u2 = 0,
    group: u1 = 1,
};

const BitmapField = enum { enabled, pending, active, group };
const BitmapAction = enum { assign, set, clear };

const Model = struct {
    num_cpus: u8,
    ctlr: u32,
    spis: [gic_module.MAX_SPI]Irq,
    redists: [model_cpus_max][32]Irq,
    wakers: [model_cpus_max]u32,

    fn init(num_cpus: u8) Model {
        var model = Model{
            .num_cpus = num_cpus,
            .ctlr = GICD.CTLR_ARE_S | GICD.CTLR_ARE_NS,
            .spis = @splat(.{}),
            .redists = @splat(@splat(.{})),
            .wakers = @splat(GICR.WAKER_CHILDREN_ASLEEP),
        };
        for (model.redists[0..num_cpus]) |*redist| {
            for (redist, 0..) |*irq, intid| {
                irq.priority = 0xA0;
                irq.config = if (intid < 16) 0b10 else 0;
            }
        }
        return model;
    }

    fn groupEnabled(self: *const Model, group: u1) bool {
        const bit = if (group == 0) GICD.CTLR_ENABLE_G0 else GICD.CTLR_ENABLE_G1NS;
        return self.ctlr & bit != 0;
    }

    fn hasDeliverable(self: *const Model, cpu_id: u8) bool {
        if (cpu_id >= self.num_cpus) return false;
        for (self.redists[cpu_id]) |irq| {
            if (self.deliverable(irq)) return true;
        }
        if (cpu_id != 0) return false;
        for (self.spis) |irq| {
            if (self.deliverable(irq)) return true;
        }
        return false;
    }

    fn deliverable(self: *const Model, irq: Irq) bool {
        return self.groupEnabled(irq.group) and irq.enabled and irq.pending and !irq.active;
    }

    fn ack(self: *Model, cpu_id: u8, group: ?u1, priority_mask: u8) u32 {
        const intid = self.highest(cpu_id, group, priority_mask);
        const irq = self.findIrq(cpu_id, intid) orelse return intid;
        irq.active = true;
        if (irq.config & 0b10 != 0) irq.pending = false;
        return intid;
    }

    fn end(self: *Model, cpu_id: u8, intid: u32) void {
        if (intid >= 1020) return;
        if (self.findIrq(cpu_id, intid)) |irq| irq.active = false;
    }

    fn highest(self: *const Model, cpu_id: u8, group: ?u1, priority_mask: u8) u32 {
        if (cpu_id >= self.num_cpus) return 1023;
        var best_intid: u32 = 1023;
        var best_priority = priority_mask;
        for (self.redists[cpu_id], 0..) |irq, intid| {
            if (candidate(self, irq, group, best_priority)) {
                best_priority = irq.priority;
                best_intid = @intCast(intid);
            }
        }
        if (cpu_id != 0) return best_intid;
        for (self.spis, 0..) |irq, index| {
            if (candidate(self, irq, group, best_priority)) {
                best_priority = irq.priority;
                best_intid = @as(u32, @intCast(index)) + 32;
            }
        }
        return best_intid;
    }

    fn candidate(self: *const Model, irq: Irq, group: ?u1, best_priority: u8) bool {
        return (group == null or irq.group == group.?) and self.deliverable(irq) and
            irq.priority < best_priority;
    }

    fn findIrq(self: *Model, cpu_id: u8, intid: u32) ?*Irq {
        if (intid < 32) {
            if (cpu_id >= self.num_cpus) return null;
            return &self.redists[cpu_id][intid];
        }
        if (intid >= gic_module.MAX_INTID) return null;
        return &self.spis[intid - 32];
    }
};

fn bitmapValue(irqs: []const Irq, field: BitmapField) u32 {
    var value: u32 = 0;
    for (irqs, 0..) |irq, bit| {
        const is_set = switch (field) {
            .enabled => irq.enabled,
            .pending => irq.pending,
            .active => irq.active,
            .group => irq.group == 1,
        };
        if (is_set) value |= @as(u32, 1) << @intCast(bit);
    }
    return value;
}

fn writeBitmap(irqs: []Irq, field: BitmapField, action: BitmapAction, value: u32) void {
    for (irqs, 0..) |*irq, bit| {
        const is_set = value >> @intCast(bit) & 1 != 0;
        if (action != .assign and !is_set) continue;
        const updated = switch (action) {
            .assign, .set => is_set,
            .clear => false,
        };
        switch (field) {
            .enabled => irq.enabled = updated,
            .pending => irq.pending = updated,
            .active => irq.active = updated,
            .group => irq.group = @intFromBool(updated),
        }
    }
}

fn writePriorities(irqs: []Irq, value: u32) void {
    for (irqs, 0..) |*irq, index| irq.priority = @truncate(value >> @intCast(index * 8));
}

fn priorityValue(irqs: []const Irq) u32 {
    var value: u32 = 0;
    for (irqs, 0..) |irq, index| value |= @as(u32, irq.priority) << @intCast(index * 8);
    return value;
}

fn writeConfigs(irqs: []Irq, value: u32, sgi_read_only: bool) void {
    for (irqs, 0..) |*irq, index| {
        if (sgi_read_only and index < 16) continue;
        irq.config = @as(u2, @truncate(value >> @intCast(index * 2))) & 0b10;
    }
}

fn configValue(irqs: []const Irq) u32 {
    var value: u32 = 0;
    for (irqs, 0..) |irq, index| value |= @as(u32, irq.config) << @intCast(index * 2);
    return value;
}

fn applyDistBitmap(actual: *Gic, model: *Model, smith: *testing.Smith, operation: u8) void {
    const block = smith.valueRangeAtMost(u8, 0, 3);
    const value = smith.value(u32);
    const register_block = @as(u16, block) + 1;
    const slice = model.spis[@as(usize, block) * 32 ..][0..32];
    switch (operation) {
        0 => {
            actual.distWrite(GICD.IGROUPR + register_block * 4, 4, value);
            writeBitmap(slice, .group, .assign, value);
        },
        1 => applySetClear(actual, slice, GICD.ISENABLER, register_block, value, .enabled, .set),
        2 => applySetClear(actual, slice, GICD.ICENABLER, register_block, value, .enabled, .clear),
        3 => applySetClear(actual, slice, GICD.ISPENDR, register_block, value, .pending, .set),
        4 => applySetClear(actual, slice, GICD.ICPENDR, register_block, value, .pending, .clear),
        5 => applySetClear(actual, slice, GICD.ISACTIVER, register_block, value, .active, .set),
        6 => applySetClear(actual, slice, GICD.ICACTIVER, register_block, value, .active, .clear),
        else => unreachable,
    }
}

fn applySetClear(
    actual: *Gic,
    irqs: []Irq,
    base: u16,
    block: u16,
    value: u32,
    field: BitmapField,
    action: BitmapAction,
) void {
    actual.distWrite(base + block * 4, 4, value);
    writeBitmap(irqs, field, action, value);
}

fn applyDistWords(actual: *Gic, model: *Model, smith: *testing.Smith, config: bool) void {
    const value = smith.value(u32);
    if (config) {
        const word = smith.valueRangeAtMost(u8, 0, 7);
        const start = @as(usize, word) * 16;
        actual.distWrite(GICD.ICFGR + 8 + @as(u16, word) * 4, 4, value);
        writeConfigs(model.spis[start..][0..16], value, false);
    } else {
        const word = smith.valueRangeAtMost(u8, 0, 31);
        const start = @as(usize, word) * 4;
        actual.distWrite(GICD.IPRIORITYR + 32 + @as(u16, word) * 4, 4, value);
        writePriorities(model.spis[start..][0..4], value);
    }
}

fn redistBase(cpu_id: u8) u64 {
    return @as(u64, cpu_id) * gic_module.GICR_FRAME_SIZE + GICR.SGI_OFFSET;
}

fn applyRedistBitmap(actual: *Gic, model: *Model, smith: *testing.Smith, operation: u8) void {
    const cpu_id = smith.valueRangeAtMost(u8, 0, model.num_cpus - 1);
    const value = smith.value(u32);
    const irqs = &model.redists[cpu_id];
    const base = redistBase(cpu_id);
    const register, const field, const action: BitmapAction = switch (operation) {
        0 => .{ GICR.IGROUPR0, BitmapField.group, .assign },
        1 => .{ GICR.ISENABLER0, BitmapField.enabled, .set },
        2 => .{ GICR.ICENABLER0, BitmapField.enabled, .clear },
        3 => .{ GICR.ISPENDR0, BitmapField.pending, .set },
        4 => .{ GICR.ICPENDR0, BitmapField.pending, .clear },
        5 => .{ GICR.ISACTIVER0, BitmapField.active, .set },
        6 => .{ GICR.ICACTIVER0, BitmapField.active, .clear },
        else => unreachable,
    };
    actual.redistWrite(base + register, 4, value);
    writeBitmap(irqs, field, action, value);
}

fn applyRedistWords(actual: *Gic, model: *Model, smith: *testing.Smith, config: bool) void {
    const cpu_id = smith.valueRangeAtMost(u8, 0, model.num_cpus - 1);
    const value = smith.value(u32);
    const base = redistBase(cpu_id);
    if (config) {
        const half = smith.valueRangeAtMost(u8, 0, 1);
        const start = @as(usize, half) * 16;
        actual.redistWrite(base + GICR.ICFGR0 + @as(u16, half) * 4, 4, value);
        writeConfigs(model.redists[cpu_id][start..][0..16], value, half == 0);
    } else {
        const word = smith.valueRangeAtMost(u8, 0, 7);
        const start = @as(usize, word) * 4;
        actual.redistWrite(base + GICR.IPRIORITYR + @as(u16, word) * 4, 4, value);
        writePriorities(model.redists[cpu_id][start..][0..4], value);
    }
}

fn applyTransition(actual: *Gic, model: *Model, smith: *testing.Smith, operation: u8) !void {
    switch (operation) {
        0 => {
            const intid = smith.valueRangeAtMost(u32, 32, gic_module.MAX_INTID - 1);
            const pending = smith.value(bool);
            actual.setSpiPending(intid, pending);
            model.spis[intid - 32].pending = pending;
        },
        1 => {
            const cpu_id = smith.valueRangeAtMost(u8, 0, model.num_cpus - 1);
            const intid = smith.valueRangeAtMost(u32, 0, 31);
            const pending = smith.value(bool);
            actual.setPpiPending(cpu_id, intid, pending);
            model.redists[cpu_id][intid].pending = pending;
        },
        2 => try applyAck(actual, model, smith),
        3 => {
            const cpu_id = smith.valueRangeAtMost(u8, 0, model.num_cpus - 1);
            const intid = smith.valueRangeAtMost(u32, 0, 1023);
            actual.endInterrupt(cpu_id, intid);
            model.end(cpu_id, intid);
        },
        4 => applySgi(actual, model, smith),
        else => unreachable,
    }
}

fn applyAck(actual: *Gic, model: *Model, smith: *testing.Smith) !void {
    const cpu_id = smith.valueRangeAtMost(u8, 0, model.num_cpus - 1);
    const priority_mask = smith.value(u8);
    if (smith.value(bool)) {
        const group: u1 = @truncate(smith.value(u8));
        const expected = model.ack(cpu_id, group, priority_mask);
        try testing.expectEqual(
            expected,
            actual.ackInterruptForGroup(cpu_id, group, priority_mask),
        );
    } else {
        const expected = model.ack(cpu_id, null, 0xFF);
        try testing.expectEqual(expected, actual.ackInterrupt(cpu_id));
    }
}

fn applySgi(actual: *Gic, model: *Model, smith: *testing.Smith) void {
    const source = smith.valueRangeAtMost(u8, 0, model.num_cpus - 1);
    const intid = smith.valueRangeAtMost(u32, 0, 15);
    const targets = smith.value(u16);
    const all_but_self = smith.value(bool);
    actual.sendSgi(source, intid, targets, all_but_self);
    for (model.redists[0..model.num_cpus], 0..) |*redist, cpu_id| {
        const selected = if (all_but_self)
            cpu_id != source
        else
            targets >> @intCast(cpu_id) & 1 != 0;
        if (selected) redist[intid].pending = true;
    }
}

fn applyMisc(actual: *Gic, model: *Model, smith: *testing.Smith, waker: bool) !void {
    if (waker) {
        const cpu_id = smith.valueRangeAtMost(u8, 0, model.num_cpus - 1);
        const value = smith.value(u32);
        const offset = @as(u64, cpu_id) * gic_module.GICR_FRAME_SIZE + GICR.WAKER;
        actual.redistWrite(offset, 4, value);
        model.wakers[cpu_id] = if (value & GICR.WAKER_PROCESSOR_SLEEP == 0)
            value & ~GICR.WAKER_CHILDREN_ASLEEP
        else
            value | GICR.WAKER_CHILDREN_ASLEEP;
        return;
    }
    try testing.expectEqual(@as(u64, 0), actual.distRead(std.math.maxInt(u64), 8));
    try testing.expectEqual(@as(u64, 0), actual.redistRead(std.math.maxInt(u64), 8));
    actual.distWrite(std.math.maxInt(u64), 8, smith.value(u64));
    actual.redistWrite(std.math.maxInt(u64), 8, smith.value(u64));
    actual.setPpiPending(model.num_cpus, 0, smith.value(bool));
}

fn applyOperation(actual: *Gic, model: *Model, smith: *testing.Smith) !void {
    const operation = smith.valueRangeAtMost(u8, 0, 24);
    switch (operation) {
        0 => {
            const value = smith.value(u32);
            actual.distWrite(GICD.CTLR, 4, value);
            model.ctlr = value & (GICD.CTLR_ENABLE_G0 | GICD.CTLR_ENABLE_G1NS |
                GICD.CTLR_ENABLE_G1S | GICD.CTLR_ARE_S | GICD.CTLR_ARE_NS | GICD.CTLR_DS);
        },
        1...7 => applyDistBitmap(actual, model, smith, operation - 1),
        8 => applyDistWords(actual, model, smith, false),
        9 => applyDistWords(actual, model, smith, true),
        10...16 => applyRedistBitmap(actual, model, smith, operation - 10),
        17 => applyRedistWords(actual, model, smith, false),
        18 => applyRedistWords(actual, model, smith, true),
        19...23 => try applyTransition(actual, model, smith, operation - 19),
        24 => try applyMisc(actual, model, smith, smith.value(bool)),
        else => unreachable,
    }
}

fn expectDistributor(actual: *Gic, model: *const Model) !void {
    try testing.expectEqual(@as(u64, model.ctlr), actual.distRead(GICD.CTLR, 4));
    for (0..4) |block| {
        const register_block: u16 = @intCast(block + 1);
        const irqs = model.spis[block * 32 ..][0..32];
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .group)),
            actual.distRead(GICD.IGROUPR + register_block * 4, 4),
        );
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .enabled)),
            actual.distRead(GICD.ISENABLER + register_block * 4, 4),
        );
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .pending)),
            actual.distRead(GICD.ISPENDR + register_block * 4, 4),
        );
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .active)),
            actual.distRead(GICD.ISACTIVER + register_block * 4, 4),
        );
    }
    for (0..32) |word| {
        const irqs = model.spis[word * 4 ..][0..4];
        try testing.expectEqual(
            @as(u64, priorityValue(irqs)),
            actual.distRead(GICD.IPRIORITYR + 32 + @as(u16, @intCast(word)) * 4, 4),
        );
    }
    for (0..8) |word| {
        const irqs = model.spis[word * 16 ..][0..16];
        try testing.expectEqual(
            @as(u64, configValue(irqs)),
            actual.distRead(GICD.ICFGR + 8 + @as(u16, @intCast(word)) * 4, 4),
        );
    }
}

fn expectRedistributors(actual: *Gic, model: *const Model) !void {
    for (0..model.num_cpus) |cpu_id| {
        const base = redistBase(@intCast(cpu_id));
        const irqs = &model.redists[cpu_id];
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .group)),
            actual.redistRead(base + GICR.IGROUPR0, 4),
        );
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .enabled)),
            actual.redistRead(base + GICR.ISENABLER0, 4),
        );
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .pending)),
            actual.redistRead(base + GICR.ISPENDR0, 4),
        );
        try testing.expectEqual(
            @as(u64, bitmapValue(irqs, .active)),
            actual.redistRead(base + GICR.ISACTIVER0, 4),
        );
        for (0..8) |word| {
            try testing.expectEqual(
                @as(u64, priorityValue(irqs[word * 4 ..][0..4])),
                actual.redistRead(
                    base + GICR.IPRIORITYR + @as(u16, @intCast(word)) * 4,
                    4,
                ),
            );
        }
        try testing.expectEqual(
            @as(u64, configValue(irqs[0..16])),
            actual.redistRead(base + GICR.ICFGR0, 4),
        );
        try testing.expectEqual(
            @as(u64, configValue(irqs[16..32])),
            actual.redistRead(base + GICR.ICFGR1, 4),
        );
        const waker_offset = @as(u64, @intCast(cpu_id)) * gic_module.GICR_FRAME_SIZE + GICR.WAKER;
        try testing.expectEqual(@as(u64, model.wakers[cpu_id]), actual.redistRead(waker_offset, 4));
        try testing.expectEqual(
            model.hasDeliverable(@intCast(cpu_id)),
            actual.hasDeliverableIrq(@intCast(cpu_id)),
        );
    }
}

fn checkGic(_: void, smith: *testing.Smith) !void {
    const num_cpus = smith.valueRangeAtMost(u8, 1, model_cpus_max);
    const actual = try Gic.init(testing.allocator, num_cpus);
    defer actual.deinit();
    var model = Model.init(num_cpus);
    const operation_count = smith.valueRangeAtMost(u8, 1, operations_max);
    for (0..operation_count) |_| {
        try applyOperation(actual, &model, smith);
        try expectDistributor(actual, &model);
        try expectRedistributors(actual, &model);
    }
}

const seed_zero: [256]u8 = @splat(0);
const seed_ones: [256]u8 = @splat(0xFF);
const seed_incrementing: [256]u8 = seed: {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index);
    break :seed bytes;
};

test "GIC distributor and redistributor properties" {
    return testing.fuzz(
        {},
        checkGic,
        .{ .corpus = &.{ &seed_zero, &seed_ones, &seed_incrementing } },
    );
}
