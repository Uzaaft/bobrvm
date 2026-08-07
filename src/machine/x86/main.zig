//! Minimal x86 PC machine for direct Linux boot on KVM.

const std = @import("std");
const GuestMemory = @import("../../guest_memory.zig").GuestMemory;
const kvm = @import("../../hypervisor/kvm/main.zig");
const pci = @import("../../pci/main.zig");
const virtio = @import("../../virtio/main.zig");
const boot = @import("boot.zig");

const gdt_address: u64 = 0x500;
const pci_block_slot: u5 = 1;
const pci_block_irq: u32 = 11;
const pci_bar_initial: u32 = 0xd000_0000;

pub const SerialSink = struct {
    userdata: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) void,

    pub fn bind(
        comptime Context: type,
        context: *Context,
        comptime write_fn: *const fn (*Context, []const u8) void,
    ) SerialSink {
        const Adapter = struct {
            fn write(userdata: *anyopaque, bytes: []const u8) void {
                const typed: *Context = @ptrCast(@alignCast(userdata));
                write_fn(typed, bytes);
            }
        };
        return .{ .userdata = context, .write_fn = Adapter.write };
    }

    pub fn write(self: SerialSink, bytes: []const u8) void {
        self.write_fn(self.userdata, bytes);
    }
};

pub const Machine = struct {
    host: kvm.Kvm,
    vm: kvm.VM,
    vcpu: kvm.Vcpu,
    memory: []align(std.heap.page_size_min) u8,
    layout: boot.Layout,
    pci_config: pci.x86_config.LegacyConfig = .{},
    block: ?*virtio.Block = null,
    pci_block: ?*pci.VirtioPciDevice = null,
    block_irq_desired: bool = false,
    block_irq_injected: bool = false,
    exits_total: u64 = 0,
    mmio_exits_total: u64 = 0,
    last_mmio_address: ?u64 = null,

    pub const InitError = kvm.OpenError || kvm.CreateError || boot.LoadError;
    pub const AttachDiskError = virtio.Block.Error || std.Io.File.StatError;
    pub const RunError = kvm.RunError || kvm.InterruptError || error{
        ExitLimitReached,
        InternalError,
        InvalidIoExit,
        InvalidMmioExit,
        UnknownExit,
    };

    pub fn init(
        memory_bytes: usize,
        image: boot.Image,
        command_line: []const u8,
        initrd: ?[]const u8,
    ) InitError!Machine {
        var host = try kvm.Kvm.open();
        errdefer host.deinit();
        var vm = try host.createVm();
        errdefer vm.deinit();
        const memory = try vm.mapMemory(0, 0, memory_bytes);
        try vm.createPcInterrupts();

        const layout = try image.load(memory, command_line, initrd);
        writeGdt(memory);
        var cpuid = try host.supportedCpuid();
        var vcpu = try vm.createVcpu(0);
        errdefer vcpu.deinit();
        try vcpu.setCpuid(&cpuid);
        try vcpu.setProtectedModeEntry(
            layout.entry_address,
            layout.boot_params_address,
            gdt_address,
        );

        return .{
            .host = host,
            .vm = vm,
            .vcpu = vcpu,
            .memory = memory,
            .layout = layout,
        };
    }

    pub fn deinit(self: *Machine) void {
        if (self.pci_block) |device| device.deinit();
        if (self.block) |block| block.deinit();
        self.vcpu.deinit();
        self.vm.deinit();
        self.host.deinit();
        self.memory = undefined;
    }

    /// The machine address must remain stable until deinit because device callbacks retain it.
    pub fn attachDisk(
        self: *Machine,
        allocator: std.mem.Allocator,
        path: []const u8,
        read_only: bool,
    ) AttachDiskError!void {
        std.debug.assert(self.block == null);
        std.debug.assert(self.pci_block == null);

        const block = try virtio.Block.init(allocator);
        errdefer block.deinit();
        try block.attachDisk(path, read_only);

        const device = try pci.VirtioPciDevice.init(
            allocator,
            2,
            0x0002,
            block.transport.device_features,
            1,
            @sizeOf(virtio.blk.Config),
        );
        errdefer device.deinit();
        device.writeConfig(0x10, 4, pci_bar_initial);
        device.config[0x3c] = pci_block_irq;
        device.transport.setDeviceConfig(std.mem.asBytes(&block.config));
        device.transport.setNotifyCallback(blockNotify, self);

        block.setGuestMemory(GuestMemory.bind(Machine, self, getGuestMemory));
        block.setIrqCallback(virtio.mmio.Irq.initRaw(blockIrq, self));
        self.block = block;
        self.pci_block = device;
    }

    pub fn run(self: *Machine, serial: SerialSink, exits_max: u64) RunError!void {
        while (self.exits_total < exits_max) {
            self.exits_total += 1;
            switch (try self.vcpu.runOnce()) {
                .io => try self.handleIo(serial),
                .halted, .interrupted => continue,
                .shutdown => return,
                .internal_error => return error.InternalError,
                .mmio => try self.handleMmio(),
                .unknown => return error.UnknownExit,
            }
            try self.syncBlockIrq();
        }
        return error.ExitLimitReached;
    }

    fn handleIo(self: *Machine, serial: SerialSink) RunError!void {
        const access = self.vcpu.ioExit() orelse return error.InvalidIoExit;
        switch (access.direction) {
            .write => self.handleIoWrite(access, serial),
            .read => self.handleIoRead(access),
        }
    }

    fn handleIoWrite(self: *Machine, access: kvm.IoExit, serial: SerialSink) void {
        if (access.size == 1 and (access.port == 0x3f8 or access.port == 0xe9)) {
            serial.write(access.data);
        }

        if (access.count != 1) return;
        const value = readIoValue(access.data) orelse return;
        if (self.pci_config.writeAddress(access.port, access.size, value)) return;
        const address = self.pci_config.dataAddress(access.port, access.size) orelse return;
        const device = self.pciDevice(address) orelse return;
        device.writeConfig(address.register, access.size, value);
    }

    fn handleIoRead(self: *Machine, access: kvm.IoExit) void {
        @memset(access.data, 0xff);
        if (access.count != 1) return;
        if (self.pci_config.readAddress(access.port, access.size)) |value| {
            writeIoValue(access.data, value);
            return;
        }
        if (self.pci_config.dataAddress(access.port, access.size)) |address| {
            const device = self.pciDevice(address) orelse return;
            writeIoValue(access.data, @truncate(device.readConfig(address.register, access.size)));
            return;
        }
        if (access.size != 1) return;
        const value: u8 = switch (access.port) {
            0x3f8 => 0x00,
            0x3fa => 0x01,
            0x3fd => 0x60,
            0x3fe => 0xb0,
            else => return,
        };
        @memset(access.data, value);
    }

    fn handleMmio(self: *Machine) RunError!void {
        const access = self.vcpu.mmioExit() orelse return error.InvalidMmioExit;
        self.mmio_exits_total += 1;
        self.last_mmio_address = access.address;
        if (self.handlePciBar(access)) return;
        handleAbsentMmio(access);
    }

    fn handleAbsentMmio(access: kvm.MmioExit) void {
        if (access.direction == .read) @memset(access.data, 0xff);
    }

    fn handlePciBar(self: *Machine, access: kvm.MmioExit) bool {
        const device = self.pci_block orelse return false;
        const block = self.block orelse return false;
        const bar_address: u64 = device.getBar0Addr();
        if (bar_address == 0 or access.address < bar_address) return false;
        const offset_u64 = access.address - bar_address;
        if (offset_u64 >= pci.virtio_pci.BAR0_SIZE) return false;
        const value = readIoValue(access.data) orelse return false;
        const offset: u32 = @intCast(offset_u64);

        if (access.direction == .read) {
            if (offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET) {
                device.transport.setDeviceConfig(std.mem.asBytes(&block.config));
            }
            const result = device.readBar0(offset, @intCast(access.data.len));
            writeIoValue(access.data, result);
            if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
                offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE)
            {
                block.transport.write(@intFromEnum(virtio.mmio.Reg.interrupt_ack), result);
            }
        } else {
            device.writeBar0(offset, @intCast(access.data.len), value);
        }
        return true;
    }

    fn pciDevice(
        self: *Machine,
        address: pci.x86_config.ConfigAddress,
    ) ?*pci.VirtioPciDevice {
        if (address.bus != 0 or address.device != pci_block_slot or address.function != 0) {
            return null;
        }
        return self.pci_block;
    }

    fn getGuestMemory(self: *Machine, address: u64, length: usize) ?[]u8 {
        if (address > self.memory.len) return null;
        const offset: usize = @intCast(address);
        if (length > self.memory.len - offset) return null;
        return self.memory[offset..][0..length];
    }

    fn blockNotify(queue_index: u32, userdata: ?*anyopaque) void {
        if (queue_index != 0) return;
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        const device = self.pci_block orelse return;
        const block = self.block orelse return;
        const source = device.transport.queues[0];
        const target = &block.transport.queues[0];
        target.num = source.size;
        target.ready = source.enable;
        target.desc_addr = source.desc_addr;
        target.driver_addr = source.driver_addr;
        target.device_addr = source.device_addr;
        block.pollRequests();
    }

    fn blockIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        const device = self.pci_block orelse return;
        const block = self.block orelse return;
        device.transport.isr_status.queue_interrupt =
            block.transport.interrupt_status.used_buffer;
        device.transport.isr_status.config_change =
            block.transport.interrupt_status.config_change;
        self.block_irq_desired = level;
    }

    fn syncBlockIrq(self: *Machine) kvm.InterruptError!void {
        if (self.block_irq_desired == self.block_irq_injected) return;
        try self.vm.setIrqLine(pci_block_irq, self.block_irq_desired);
        self.block_irq_injected = self.block_irq_desired;
    }

    fn readIoValue(data: []const u8) ?u32 {
        return switch (data.len) {
            1 => data[0],
            2 => std.mem.readInt(u16, data[0..2], .little),
            4 => std.mem.readInt(u32, data[0..4], .little),
            else => null,
        };
    }

    fn writeIoValue(data: []u8, value: u32) void {
        switch (data.len) {
            1 => data[0] = @truncate(value),
            2 => std.mem.writeInt(u16, data[0..2], @truncate(value), .little),
            4 => std.mem.writeInt(u32, data[0..4], value, .little),
            else => {},
        }
    }

    fn writeGdt(memory: []u8) void {
        const descriptors = [_]u64{
            0,
            0x00cf_9b00_0000_ffff,
            0x00cf_9300_0000_ffff,
        };
        for (descriptors, 0..) |descriptor, index| {
            const offset = @as(usize, gdt_address) + index * 8;
            std.mem.writeInt(u64, memory[offset..][0..8], descriptor, .little);
        }
    }
};

test "x86 machine GDT contains flat code and data segments" {
    var memory = [_]u8{0} ** 4096;
    Machine.writeGdt(&memory);
    try std.testing.expectEqual(
        @as(u64, 0x00cf_9b00_0000_ffff),
        std.mem.readInt(u64, memory[gdt_address + 8 ..][0..8], .little),
    );
    try std.testing.expectEqual(
        @as(u64, 0x00cf_9300_0000_ffff),
        std.mem.readInt(u64, memory[gdt_address + 16 ..][0..8], .little),
    );
}

test "absent MMIO reads return all bits set" {
    var data = [_]u8{ 0, 0, 0, 0 };
    const access = kvm.MmioExit{
        .direction = .read,
        .address = 0xfed0_0000,
        .data = &data,
    };

    Machine.handleAbsentMmio(access);

    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, &data);
}

test "absent MMIO writes preserve exit data" {
    var data = [_]u8{ 0x12, 0x34 };
    const access = kvm.MmioExit{
        .direction = .write,
        .address = 0xfed0_0000,
        .data = &data,
    };

    Machine.handleAbsentMmio(access);

    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, &data);
}
