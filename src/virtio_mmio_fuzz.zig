const std = @import("std");
const testing = std.testing;
const mmio = @import("virtio/mmio.zig");

const Model = struct {
    device_features: u64,
    driver_features: u64 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    status: u8 = 0,
    queue_sel: u32 = 0,
    queues: [mmio.Transport.MAX_QUEUES]mmio.QueueConfig = @splat(.{}),
    queue_count: usize,
    interrupt_status: u32 = 0,
    config_generation: u32 = 0,
    shm_sel: u32 = 0,
    shm_region_id: u32,
    shm_region_base: u64,
    shm_region_len: u64,
    irq_level: bool = false,
    irq_calls: usize = 0,
    notifications: usize = 0,
    last_notification: u32 = 0,

    fn currentQueue(self: *Model) ?*mmio.QueueConfig {
        if (self.queue_sel >= self.queue_count) return null;
        return &self.queues[self.queue_sel];
    }

    fn reset(self: *Model) void {
        self.driver_features = 0;
        self.device_features_sel = 0;
        self.driver_features_sel = 0;
        self.status = 0;
        self.queue_sel = 0;
        self.interrupt_status = 0;
        self.irq_level = false;
        self.irq_calls += 1;
        @memset(self.queues[0..self.queue_count], mmio.QueueConfig{});
    }
};

const CallbackState = struct {
    irq_level: bool = false,
    irq_calls: usize = 0,
    notifications: usize = 0,
    last_notification: u32 = 0,

    fn irq(level: bool, userdata: ?*anyopaque) void {
        const self: *CallbackState = @ptrCast(@alignCast(userdata.?));
        self.irq_level = level;
        self.irq_calls += 1;
    }

    fn notify(queue: u32, userdata: ?*anyopaque) void {
        const self: *CallbackState = @ptrCast(@alignCast(userdata.?));
        self.notifications += 1;
        self.last_notification = queue;
    }
};

fn modelWrite(model: *Model, offset: u12, value: u32) void {
    switch (@as(mmio.Reg, @enumFromInt(offset))) {
        .device_features_sel => model.device_features_sel = value,
        .driver_features_sel => model.driver_features_sel = value,
        .driver_features => switch (model.driver_features_sel) {
            0 => model.driver_features = (model.driver_features & 0xFFFF_FFFF_0000_0000) | value,
            1 => model.driver_features =
                (model.driver_features & 0x0000_0000_FFFF_FFFF) | (@as(u64, value) << 32),
            else => {},
        },
        .queue_sel => model.queue_sel = value,
        .queue_num => {
            if (model.currentQueue()) |queue| queue.num = @truncate(value);
        },
        .queue_ready => {
            if (model.currentQueue()) |queue| queue.ready = value != 0;
        },
        .queue_notify => if (model.status & 0x0C == 0x0C) {
            model.notifications += 1;
            model.last_notification = value;
        },
        .interrupt_ack => {
            model.interrupt_status &= ~value;
            if (model.interrupt_status == 0) {
                model.irq_level = false;
                model.irq_calls += 1;
            }
        },
        .status => {
            const status: u8 = @truncate(value);
            if (status == 0) model.reset() else model.status = status & 0xCF;
        },
        .shm_sel => model.shm_sel = value,
        .queue_desc_low => if (model.currentQueue()) |queue| {
            queue.desc_addr = (queue.desc_addr & 0xFFFF_FFFF_0000_0000) | value;
        },
        .queue_desc_high => if (model.currentQueue()) |queue| {
            queue.desc_addr = (queue.desc_addr & 0x0000_0000_FFFF_FFFF) |
                (@as(u64, value) << 32);
        },
        .queue_driver_low => if (model.currentQueue()) |queue| {
            queue.driver_addr = (queue.driver_addr & 0xFFFF_FFFF_0000_0000) | value;
        },
        .queue_driver_high => if (model.currentQueue()) |queue| {
            queue.driver_addr = (queue.driver_addr & 0x0000_0000_FFFF_FFFF) |
                (@as(u64, value) << 32);
        },
        .queue_device_low => if (model.currentQueue()) |queue| {
            queue.device_addr = (queue.device_addr & 0xFFFF_FFFF_0000_0000) | value;
        },
        .queue_device_high => if (model.currentQueue()) |queue| {
            queue.device_addr = (queue.device_addr & 0x0000_0000_FFFF_FFFF) |
                (@as(u64, value) << 32);
        },
        else => {},
    }
}

fn modelRead(model: *const Model, offset: u12) u32 {
    const queue = if (model.queue_sel < model.queue_count)
        &model.queues[model.queue_sel]
    else
        null;
    const shm_exists = model.shm_sel == model.shm_region_id and model.shm_region_len != 0;
    return switch (@as(mmio.Reg, @enumFromInt(offset))) {
        .magic => mmio.MAGIC,
        .version => mmio.VERSION,
        .device_id => 7,
        .vendor_id => 0x554D4551,
        .device_features => switch (model.device_features_sel) {
            0 => @truncate(model.device_features),
            1 => @truncate(model.device_features >> 32),
            else => 0,
        },
        .queue_num_max => if (queue != null) 256 else 0,
        .queue_ready => if (queue) |selected| @intFromBool(selected.ready) else 0,
        .interrupt_status => model.interrupt_status,
        .status => model.status,
        .config_generation => model.config_generation,
        .shm_len_low => if (shm_exists) @truncate(model.shm_region_len) else 0xFFFF_FFFF,
        .shm_len_high => if (shm_exists) @truncate(model.shm_region_len >> 32) else 0xFFFF_FFFF,
        .shm_base_low => if (shm_exists) @truncate(model.shm_region_base) else 0,
        .shm_base_high => if (shm_exists) @truncate(model.shm_region_base >> 32) else 0,
        else => 0,
    };
}

fn expectState(transport: *mmio.Transport, model: *const Model, callbacks: CallbackState) !void {
    const read_offsets = [_]mmio.Reg{
        .magic,           .version,           .device_id,   .vendor_id,
        .device_features, .queue_num_max,     .queue_ready, .interrupt_status,
        .status,          .config_generation, .shm_len_low, .shm_len_high,
        .shm_base_low,    .shm_base_high,
    };
    for (read_offsets) |reg| {
        const offset: u12 = @intFromEnum(reg);
        try testing.expectEqual(modelRead(model, offset), transport.read(offset));
    }
    try testing.expectEqual(model.driver_features, transport.driver_features);
    try testing.expectEqual(model.queue_sel, transport.queue_sel);
    try testing.expectEqualSlices(
        mmio.QueueConfig,
        model.queues[0..model.queue_count],
        transport.queues,
    );
    try testing.expectEqual(model.irq_level, callbacks.irq_level);
    try testing.expectEqual(model.irq_calls, callbacks.irq_calls);
    try testing.expectEqual(model.notifications, callbacks.notifications);
    try testing.expectEqual(model.last_notification, callbacks.last_notification);
}

fn checkTransport(_: void, smith: *testing.Smith) !void {
    const queue_count = smith.valueRangeAtMost(u8, 1, mmio.Transport.MAX_QUEUES);
    const features = smith.value(u64);
    const shm_id = smith.value(u32);
    const shm_base = smith.value(u64);
    const shm_len = smith.value(u64);
    var queues: [mmio.Transport.MAX_QUEUES]mmio.QueueConfig = undefined;
    var transport: mmio.Transport = undefined;
    transport.initEmbedded(7, features, queues[0..queue_count]);
    transport.setShmRegion(shm_id, shm_base, shm_len);
    var callbacks = CallbackState{};
    transport.setIrqCallback(mmio.Irq.initRaw(CallbackState.irq, &callbacks));
    transport.setNotifyCallback(mmio.Notify.initRaw(CallbackState.notify, &callbacks));
    var model = Model{
        .device_features = features,
        .queue_count = queue_count,
        .shm_region_id = shm_id,
        .shm_region_base = shm_base,
        .shm_region_len = shm_len,
    };

    const operation_count = smith.valueRangeAtMost(u8, 1, 64);
    for (0..operation_count) |_| {
        switch (smith.valueRangeAtMost(u8, 0, 4)) {
            0, 1 => {
                const offset = smith.value(u12);
                const value = smith.value(u32);
                transport.write(offset, value);
                modelWrite(&model, offset, value);
            },
            2 => {
                transport.signalUsedBuffer();
                model.interrupt_status |= 1;
                model.irq_level = true;
                model.irq_calls += 1;
            },
            3 => {
                transport.signalConfigChange();
                model.interrupt_status |= 2;
                model.config_generation +%= 1;
                model.irq_level = true;
                model.irq_calls += 1;
            },
            4 => {
                transport.reset();
                model.reset();
            },
            else => unreachable,
        }
        try expectState(&transport, &model, callbacks);
    }
}

const seed_zero: [64]u8 = @splat(0);
const seed_ones: [64]u8 = @splat(0xFF);

test "virtio MMIO transport state properties" {
    return testing.fuzz({}, checkTransport, .{ .corpus = &.{ &seed_zero, &seed_ones } });
}
