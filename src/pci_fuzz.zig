const std = @import("std");
const testing = std.testing;
const ecam = @import("pci/ecam.zig");
const virtio_pci = @import("pci/virtio_pci.zig");

const operations_max = 32;
const transport_features: u64 = 0x1122_3344_5566_7788 | (1 << 32);

fn accessSize(smith: *testing.Smith) u8 {
    return switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => 1,
        1 => 2,
        else => 4,
    };
}

fn readLittle(bytes: []const u8, offset: usize, size: u8) u64 {
    var value: u64 = 0;
    for (0..size) |index| value |= @as(u64, bytes[offset + index]) << @intCast(index * 8);
    return value;
}

fn writeLittle(bytes: []u8, offset: usize, size: u8, value: u64) void {
    for (0..size) |index| bytes[offset + index] = @truncate(value >> @intCast(index * 8));
}

fn modelPciRead(config: []const u8, offset: u12, size: u8) u64 {
    if (@as(usize, offset) + size > config.len) return 0xFFFF_FFFF;
    return readLittle(config, offset, size);
}

fn modelPciWrite(config: []u8, offset: u12, size: u8, value: u64) void {
    if (@as(usize, offset) + size > config.len) return;
    switch (offset) {
        @intFromEnum(ecam.ConfigReg.command) => writeLittle(config, offset, 2, value),
        @intFromEnum(ecam.ConfigReg.bar0),
        @intFromEnum(ecam.ConfigReg.bar1),
        @intFromEnum(ecam.ConfigReg.bar2),
        @intFromEnum(ecam.ConfigReg.bar3),
        @intFromEnum(ecam.ConfigReg.bar4),
        @intFromEnum(ecam.ConfigReg.bar5),
        => writeLittle(config, offset, 4, if (value == 0xFFFF_FFFF) 0xFFFF_F000 else value),
        else => writeLittle(config, offset, size, value),
    }
}

fn checkPciConfig(smith: *testing.Smith) !void {
    var device = ecam.PciDevice.initVirtioBlock(ecam.PCI_MMIO_BASE);
    var model = device.config;
    const operation_count = smith.valueRangeAtMost(u8, 1, operations_max);
    for (0..operation_count) |_| {
        const offset = smith.value(u12);
        const size = accessSize(smith);
        const value = smith.value(u64);
        if (smith.value(bool)) {
            device.write(offset, size, value);
            modelPciWrite(&model, offset, size, value);
        }
        try testing.expectEqual(modelPciRead(&model, offset, size), device.read(offset, size));
    }
    try testing.expectEqualSlices(u8, &model, &device.config);
}

const QueueModel = struct {
    size: u16 = virtio_pci.VirtioPciTransport.MAX_QUEUE_SIZE,
    enable: bool = false,
    desc_addr: u64 = 0,
    driver_addr: u64 = 0,
    device_addr: u64 = 0,
};

const CallbackState = struct {
    notifications: usize = 0,
    last_queue: u32 = 0,
    irqs: usize = 0,

    fn notify(queue: u32, userdata: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(userdata));
        self.notifications += 1;
        self.last_queue = queue;
    }

    fn irq(userdata: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(userdata));
        self.irqs += 1;
    }
};

const TransportModel = struct {
    driver_features: u64 = 0,
    device_feature_select: u32 = 0,
    driver_feature_select: u32 = 0,
    status: u8 = 0,
    queue_select: u16 = 0,
    queues: [2]QueueModel = .{ .{}, .{} },
    isr_status: u8 = 0,
    config_generation: u8 = 0,
    device_config: [256]u8 = @splat(0),
    callbacks: CallbackState = .{},

    fn reset(self: *TransportModel) void {
        self.driver_features = 0;
        self.device_feature_select = 0;
        self.driver_feature_select = 0;
        self.status = 0;
        self.queue_select = 0;
        self.queues = .{ .{}, .{} };
        self.isr_status = 0;
    }

    fn ready(self: *const TransportModel) bool {
        return self.status & 0x0C == 0x0C;
    }
};

fn writeCommon(
    transport: *virtio_pci.VirtioPciTransport,
    reg: virtio_pci.CommonCfgReg,
    size: u8,
    value: u32,
) void {
    transport.writeBar(@intFromEnum(reg), size, value);
}

fn applyFeatureOperation(
    transport: *virtio_pci.VirtioPciTransport,
    model: *TransportModel,
    operation: u8,
    value: u32,
) !void {
    switch (operation) {
        0 => {
            writeCommon(transport, .device_feature_select, 4, value);
            model.device_feature_select = value;
            const expected: u32 = switch (value) {
                0 => @truncate(transport_features),
                1 => @truncate(transport_features >> 32),
                else => 0,
            };
            try testing.expectEqual(expected, transport.readBar(0x04, 4));
        },
        1 => {
            writeCommon(transport, .driver_feature_select, 4, value);
            model.driver_feature_select = value;
        },
        2 => {
            writeCommon(transport, .driver_feature, 4, value);
            switch (model.driver_feature_select) {
                0 => model.driver_features =
                    (model.driver_features & 0xFFFF_FFFF_0000_0000) | value,
                1 => model.driver_features =
                    (model.driver_features & 0x0000_0000_FFFF_FFFF) | (@as(u64, value) << 32),
                else => {},
            }
        },
        else => unreachable,
    }
}

fn applyQueueOperation(
    transport: *virtio_pci.VirtioPciTransport,
    model: *TransportModel,
    operation: u8,
    value: u32,
) void {
    const regs = [_]virtio_pci.CommonCfgReg{
        .queue_size,
        .queue_enable,
        .queue_desc_lo,
        .queue_desc_hi,
        .queue_driver_lo,
        .queue_driver_hi,
        .queue_device_lo,
        .queue_device_hi,
    };
    writeCommon(transport, regs[operation], if (operation < 2) 2 else 4, value);
    const queue = &model.queues[model.queue_select];
    switch (operation) {
        0 => queue.size = @truncate(value),
        1 => queue.enable = value != 0,
        2 => queue.desc_addr = (queue.desc_addr & 0xFFFF_FFFF_0000_0000) | value,
        3 => queue.desc_addr =
            (queue.desc_addr & 0x0000_0000_FFFF_FFFF) | (@as(u64, value) << 32),
        4 => queue.driver_addr = (queue.driver_addr & 0xFFFF_FFFF_0000_0000) | value,
        5 => queue.driver_addr =
            (queue.driver_addr & 0x0000_0000_FFFF_FFFF) | (@as(u64, value) << 32),
        6 => queue.device_addr = (queue.device_addr & 0xFFFF_FFFF_0000_0000) | value,
        7 => queue.device_addr =
            (queue.device_addr & 0x0000_0000_FFFF_FFFF) | (@as(u64, value) << 32),
        else => unreachable,
    }
}

fn applyDeviceConfigOperation(
    transport: *virtio_pci.VirtioPciTransport,
    model: *TransportModel,
    smith: *testing.Smith,
    write: bool,
) !void {
    const offset = smith.value(u8);
    const size = accessSize(smith);
    const value = smith.value(u32);
    const bar_offset = virtio_pci.BAR_DEVICE_CFG_OFFSET + offset;
    const fits = @as(usize, offset) + size <= model.device_config.len;
    if (write) {
        transport.writeBar(bar_offset, size, value);
        if (fits) writeLittle(&model.device_config, offset, size, value);
    } else {
        const expected = if (fits) readLittle(&model.device_config, offset, size) else 0;
        try testing.expectEqual(@as(u32, @truncate(expected)), transport.readBar(bar_offset, size));
    }
}

fn expectTransport(
    transport: *virtio_pci.VirtioPciTransport,
    model: *const TransportModel,
    callbacks: *const CallbackState,
) !void {
    try testing.expectEqual(model.driver_features, transport.driver_features);
    try testing.expectEqual(model.device_feature_select, transport.device_feature_select);
    try testing.expectEqual(model.driver_feature_select, transport.driver_feature_select);
    try testing.expectEqual(model.queue_select, transport.queue_select);
    try testing.expectEqual(
        @as(u32, model.status),
        transport.readBar(@intFromEnum(virtio_pci.CommonCfgReg.device_status), 1),
    );
    try testing.expectEqual(model.isr_status, @as(u8, @bitCast(transport.isr_status)));
    try testing.expectEqual(model.config_generation, transport.config_generation);
    try testing.expectEqualSlices(u8, &model.device_config, transport.device_config);
    for (model.queues, transport.queues) |expected, actual| {
        try testing.expectEqual(expected.size, actual.size);
        try testing.expectEqual(expected.enable, actual.enable);
        try testing.expectEqual(expected.desc_addr, actual.desc_addr);
        try testing.expectEqual(expected.driver_addr, actual.driver_addr);
        try testing.expectEqual(expected.device_addr, actual.device_addr);
    }
    try testing.expectEqual(model.callbacks.notifications, callbacks.notifications);
    try testing.expectEqual(model.callbacks.last_queue, callbacks.last_queue);
    try testing.expectEqual(model.callbacks.irqs, callbacks.irqs);
}

fn applyTransportOperation(
    transport: *virtio_pci.VirtioPciTransport,
    model: *TransportModel,
    smith: *testing.Smith,
) !void {
    const operation = smith.valueRangeAtMost(u8, 0, 20);
    const value = smith.value(u32);
    switch (operation) {
        0...2 => try applyFeatureOperation(transport, model, operation, value),
        3 => {
            writeCommon(transport, .device_status, 1, value);
            if (@as(u8, @truncate(value)) == 0) {
                model.reset();
            } else {
                model.status = @as(u8, @truncate(value)) & 0xCF;
            }
        },
        4 => {
            writeCommon(transport, .queue_select, 2, value);
            if (value < model.queues.len) model.queue_select = @truncate(value);
        },
        5...12 => applyQueueOperation(transport, model, operation - 5, value),
        13 => {
            writeCommon(transport, .queue_reset, 2, value);
            if (value != 0) model.queues[model.queue_select] = .{};
        },
        14 => {
            transport.writeBar(virtio_pci.BAR_NOTIFY_OFFSET, 4, value);
            if (model.ready()) {
                model.callbacks.notifications += 1;
                model.callbacks.last_queue = value;
            }
        },
        15 => try applyDeviceConfigOperation(transport, model, smith, true),
        16 => try applyDeviceConfigOperation(transport, model, smith, false),
        17 => {
            transport.signalUsedBuffer();
            model.isr_status |= 1;
            model.callbacks.irqs += 1;
        },
        18 => {
            try testing.expectEqual(@as(u32, model.isr_status), transport.readBar(0x40, 1));
            model.isr_status = 0;
        },
        19 => {
            transport.signalConfigChange();
            model.isr_status |= 2;
            model.config_generation +%= 1;
            model.callbacks.irqs += 1;
        },
        20 => {
            const outside = @as(u32, 0x200) + value % (virtio_pci.BAR0_SIZE - 0x200);
            try testing.expectEqual(@as(u32, 0xFFFF_FFFF), transport.readBar(outside, 4));
            transport.writeBar(outside, 4, value);
        },
        else => unreachable,
    }
}

fn checkTransport(smith: *testing.Smith) !void {
    const transport = try virtio_pci.VirtioPciTransport.init(
        testing.allocator,
        2,
        transport_features & ~(@as(u64, 1) << 32),
        2,
        256,
    );
    defer transport.deinit();
    var model = TransportModel{};
    var callbacks = CallbackState{};
    transport.setNotifyCallback(CallbackState.notify, &callbacks);
    transport.setIrqCallback(CallbackState.irq, &callbacks);

    const operation_count = smith.valueRangeAtMost(u8, 1, operations_max);
    for (0..operation_count) |_| {
        try applyTransportOperation(transport, &model, smith);
        try expectTransport(transport, &model, &callbacks);
    }
}

fn checkPci(_: void, smith: *testing.Smith) !void {
    try checkPciConfig(smith);
    try checkTransport(smith);
}

const seed_zero: [128]u8 = @splat(0);
const seed_ones: [128]u8 = @splat(0xFF);
const seed_incrementing: [128]u8 = seed: {
    var bytes: [128]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index);
    break :seed bytes;
};

test "PCI configuration and transport properties" {
    return testing.fuzz(
        {},
        checkPci,
        .{ .corpus = &.{ &seed_zero, &seed_ones, &seed_incrementing } },
    );
}
