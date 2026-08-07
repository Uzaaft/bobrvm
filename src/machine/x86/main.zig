//! Minimal x86 PC machine for direct Linux boot on KVM.

const std = @import("std");
const global = @import("../../global.zig");
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
    block_lock: std.Io.Mutex = .init,
    block_kick_event: ?kvm.EventFd = null,
    block_irq_event: ?kvm.EventFd = null,
    block_resample_event: ?kvm.EventFd = null,
    block_stop_event: ?kvm.EventFd = null,
    block_worker: ?std.Thread = null,
    block_fast_enabled: bool = false,
    block_worker_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    block_worker_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    block_kicks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    block_interrupts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    block_irq_desired: bool = false,
    block_irq_injected: bool = false,
    block_notify_mmio_exits: u64 = 0,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vcpu_thread_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    exits_total: u64 = 0,
    mmio_exits_total: u64 = 0,
    last_mmio_address: ?u64 = null,

    pub const InitError = kvm.OpenError || kvm.CreateError || boot.LoadError;
    pub const AttachDiskError = virtio.Block.Error || std.Io.File.StatError ||
        kvm.FastPathError || std.Thread.SpawnError;
    pub const RunError = kvm.RunError || kvm.FastPathError || kvm.InterruptError || error{
        ExitLimitReached,
        InternalError,
        InvalidIoExit,
        InvalidMmioExit,
        UnknownExit,
        FastDevicePathFailed,
    };

    pub const FastBlockStats = struct {
        enabled: bool,
        worker_failed: bool,
        kicks: u64,
        interrupts: u64,
        notify_mmio_exits: u64,
    };

    pub const RunOutcome = enum {
        guest_shutdown,
        stopped,
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
        self.stopBlockFastPath();
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
        block.setGuestMemory(GuestMemory.bind(Machine, self, getGuestMemory));
        block.setIrqCallback(virtio.mmio.Irq.initRaw(blockIrq, self));
        self.block = block;
        self.pci_block = device;
        errdefer {
            self.block = null;
            self.pci_block = null;
        }

        if (self.host.capabilities.supportsFastDevicePath()) {
            try self.startBlockFastPath();
        } else {
            device.transport.setNotifyCallback(blockNotify, self);
        }
    }

    pub fn run(self: *Machine, serial: SerialSink, exits_max: u64) RunError!RunOutcome {
        self.vcpu_thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
        defer self.vcpu_thread_id.store(0, .release);

        while (self.exits_total < exits_max) {
            self.vcpu.clearExitRequest();
            if (self.stop_requested.load(.acquire)) return .stopped;
            if (self.block_worker_failed.load(.acquire)) {
                return error.FastDevicePathFailed;
            }
            self.exits_total += 1;
            const exit = self.vcpu.runOnce() catch |err| switch (err) {
                error.Interrupted => if (self.stop_requested.load(.acquire))
                    return .stopped
                else
                    return err,
                else => return err,
            };
            switch (exit) {
                .io => try self.handleIo(serial),
                .halted, .interrupted => continue,
                .shutdown => return .guest_shutdown,
                .internal_error => return error.InternalError,
                .mmio => try self.handleMmio(),
                .unknown => return error.UnknownExit,
            }
            try self.syncBlockIrq();
        }
        return error.ExitLimitReached;
    }

    /// Stop a running vCPU from another thread without waiting for another VM exit.
    pub fn requestStop(self: *Machine) void {
        self.stop_requested.store(true, .release);
        self.vcpu.requestExit();
        const thread_id = self.vcpu_thread_id.load(.acquire);
        if (thread_id != 0) kvm.interruptThread(thread_id);
    }

    pub fn fastBlockStats(self: *const Machine) FastBlockStats {
        return .{
            .enabled = self.block_fast_enabled,
            .worker_failed = self.block_worker_failed.load(.acquire),
            .kicks = self.block_kicks.load(.acquire),
            .interrupts = self.block_interrupts.load(.acquire),
            .notify_mmio_exits = self.block_notify_mmio_exits,
        };
    }

    fn handleIo(self: *Machine, serial: SerialSink) RunError!void {
        const access = self.vcpu.ioExit() orelse return error.InvalidIoExit;
        switch (access.direction) {
            .write => try self.handleIoWrite(access, serial),
            .read => self.handleIoRead(access),
        }
    }

    fn handleIoWrite(
        self: *Machine,
        access: kvm.IoExit,
        serial: SerialSink,
    ) kvm.FastPathError!void {
        if (access.size == 1 and (access.port == 0x3f8 or access.port == 0xe9)) {
            serial.write(access.data);
        }

        if (access.count != 1) return;
        const value = readIoValue(access.data) orelse return;
        if (self.pci_config.writeAddress(access.port, access.size, value)) return;
        const address = self.pci_config.dataAddress(access.port, access.size) orelse return;
        const device = self.pciDevice(address) orelse return;
        const old_bar_address = device.getBar0Addr();
        device.writeConfig(address.register, access.size, value);
        const new_bar_address = device.getBar0Addr();
        self.rebindBlockIoEvent(old_bar_address, new_bar_address) catch |err| {
            device.writeConfig(0x10, 4, old_bar_address);
            return err;
        };
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

        if (offset >= pci.virtio_pci.BAR_NOTIFY_OFFSET and
            offset < pci.virtio_pci.BAR_NOTIFY_OFFSET + pci.virtio_pci.BAR_NOTIFY_SIZE)
        {
            self.block_notify_mmio_exits += 1;
        }

        if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
            offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE and
            access.direction == .read)
        {
            self.readBlockIsr(device, block, access, offset);
            return true;
        }

        if (self.block_fast_enabled) self.block_lock.lockUncancelable(global.io());
        defer if (self.block_fast_enabled) self.block_lock.unlock(global.io());

        if (access.direction == .read) {
            if (offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET) {
                device.transport.setDeviceConfig(std.mem.asBytes(&block.config));
            }
            const result = device.readBar0(offset, @intCast(access.data.len));
            writeIoValue(access.data, result);
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
        self.processBlockQueue();
    }

    fn processBlockQueue(self: *Machine) void {
        const device = self.pci_block orelse return;
        const block = self.block orelse return;

        if (self.block_fast_enabled) self.block_lock.lockUncancelable(global.io());
        defer if (self.block_fast_enabled) self.block_lock.unlock(global.io());
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
        // The fast-path worker holds block_lock across queue processing. The slow path
        // runs entirely on the vCPU thread and therefore needs no synchronization.
        device.transport.isr_status.queue_interrupt =
            block.transport.interrupt_status.used_buffer;
        device.transport.isr_status.config_change =
            block.transport.interrupt_status.config_change;
        self.block_irq_desired = level;
        if (self.block_fast_enabled and level) self.signalBlockIrq();
    }

    fn syncBlockIrq(self: *Machine) kvm.InterruptError!void {
        if (self.block_fast_enabled) return;
        if (self.block_irq_desired == self.block_irq_injected) return;
        try self.vm.setIrqLine(pci_block_irq, self.block_irq_desired);
        self.block_irq_injected = self.block_irq_desired;
    }

    fn readBlockIsr(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        block: *virtio.Block,
        access: kvm.MmioExit,
        offset: u32,
    ) void {
        self.block_lock.lockUncancelable(global.io());
        defer self.block_lock.unlock(global.io());

        const result = device.readBar0(offset, @intCast(access.data.len));
        writeIoValue(access.data, result);
        const current: u32 = @bitCast(block.transport.interrupt_status);
        block.transport.interrupt_status = @bitCast(current & ~result);
        if (@as(u32, @bitCast(block.transport.interrupt_status)) == 0) {
            self.block_irq_desired = false;
        }
    }

    fn startBlockFastPath(self: *Machine) (kvm.FastPathError || std.Thread.SpawnError)!void {
        std.debug.assert(!self.block_fast_enabled);
        const device = self.pci_block orelse unreachable;
        const notify_address = blockNotifyAddress(device.getBar0Addr()) orelse unreachable;

        var kick = try kvm.EventFd.init();
        var transferred = false;
        errdefer if (!transferred) kick.deinit();
        var irq = try kvm.EventFd.init();
        errdefer if (!transferred) irq.deinit();
        var resample = try kvm.EventFd.init();
        errdefer if (!transferred) resample.deinit();
        var stop = try kvm.EventFd.init();
        errdefer if (!transferred) stop.deinit();

        try self.vm.registerIoEvent(kick, notify_address);
        errdefer self.vm.unregisterIoEvent(kick, notify_address);
        try self.vm.registerIrqFd(irq, resample, pci_block_irq);
        errdefer self.vm.unregisterIrqFd(irq, resample, pci_block_irq);

        self.block_kick_event = kick;
        self.block_irq_event = irq;
        self.block_resample_event = resample;
        self.block_stop_event = stop;
        self.block_fast_enabled = true;
        transferred = true;
        self.block_worker = std.Thread.spawn(.{}, blockWorkerMain, .{self}) catch |err| {
            self.stopBlockFastPath();
            return err;
        };
    }

    fn stopBlockFastPath(self: *Machine) void {
        if (!self.block_fast_enabled) return;
        const device = self.pci_block orelse unreachable;
        if (blockNotifyAddress(device.getBar0Addr())) |notify_address| {
            self.vm.unregisterIoEvent(self.block_kick_event.?, notify_address);
        }
        self.block_worker_stop.store(true, .release);
        _ = self.block_stop_event.?.signal();
        if (self.block_worker) |thread| thread.join();
        self.block_worker = null;
        self.vm.unregisterIrqFd(
            self.block_irq_event.?,
            self.block_resample_event.?,
            pci_block_irq,
        );
        if (self.block_stop_event) |*event| event.deinit();
        if (self.block_resample_event) |*event| event.deinit();
        if (self.block_irq_event) |*event| event.deinit();
        if (self.block_kick_event) |*event| event.deinit();
        self.block_stop_event = null;
        self.block_resample_event = null;
        self.block_irq_event = null;
        self.block_kick_event = null;
        self.block_fast_enabled = false;
    }

    fn rebindBlockIoEvent(
        self: *Machine,
        old_bar_address: u32,
        new_bar_address: u32,
    ) kvm.FastPathError!void {
        if (!self.block_fast_enabled or old_bar_address == new_bar_address) return;
        const event = self.block_kick_event orelse unreachable;
        if (blockNotifyAddress(new_bar_address)) |new_notify_address| {
            try self.vm.registerIoEvent(event, new_notify_address);
        }
        if (blockNotifyAddress(old_bar_address)) |old_notify_address| {
            self.vm.unregisterIoEvent(event, old_notify_address);
        }
    }

    fn blockNotifyAddress(bar_address: u32) ?u64 {
        if (bar_address == 0) return null;
        return @as(u64, bar_address) + pci.virtio_pci.BAR_NOTIFY_OFFSET;
    }

    fn blockWorkerMain(self: *Machine) void {
        const kick = self.block_kick_event orelse return self.failBlockWorker();
        const resample = self.block_resample_event orelse return self.failBlockWorker();
        const stop = self.block_stop_event orelse return self.failBlockWorker();
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = kick.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = resample.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = stop.fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        while (!self.block_worker_stop.load(.acquire)) {
            _ = std.posix.poll(&poll_fds, -1) catch return self.failBlockWorker();
            const invalid = std.posix.POLL.ERR | std.posix.POLL.NVAL;
            for (poll_fds) |poll_fd| {
                if (poll_fd.revents & invalid != 0) return self.failBlockWorker();
            }
            if (poll_fds[2].revents & std.posix.POLL.IN != 0) return;
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) self.resampleBlockIrq();
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) self.processBlockKick();
        }
    }

    fn processBlockKick(self: *Machine) void {
        const kicks = self.block_kick_event.?.consume() orelse return self.failBlockWorker();
        _ = self.block_kicks.fetchAdd(kicks, .release);
        self.processBlockQueue();
    }

    fn resampleBlockIrq(self: *Machine) void {
        _ = self.block_resample_event.?.consume() orelse return self.failBlockWorker();
        self.block_lock.lockUncancelable(global.io());
        defer self.block_lock.unlock(global.io());
        if (self.block_irq_desired) self.signalBlockIrq();
    }

    fn signalBlockIrq(self: *Machine) void {
        if (self.block_irq_event.?.signal()) {
            _ = self.block_interrupts.fetchAdd(1, .release);
        } else {
            self.failBlockWorker();
        }
    }

    fn failBlockWorker(self: *Machine) void {
        self.block_worker_failed.store(true, .release);
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

test "block notification address follows PCI BAR relocation" {
    try std.testing.expectEqual(@as(?u64, null), Machine.blockNotifyAddress(0));
    try std.testing.expectEqual(
        @as(?u64, 0xe000_0044),
        Machine.blockNotifyAddress(0xe000_0000),
    );
}
