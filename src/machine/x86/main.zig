//! Minimal x86 PC machine for direct Linux boot on KVM.

const std = @import("std");
const callback_binding = @import("../../callback.zig");
const global = @import("../../global.zig");
const GuestMemory = @import("../../guest_memory.zig").GuestMemory;
const kvm = @import("../../hypervisor/kvm/main.zig");
const mininat = @import("../../net/mininat.zig");
const pci = @import("../../pci/main.zig");
const virtio = @import("../../virtio/main.zig");
const boot = @import("boot.zig");
const mps = @import("mps.zig");

const gdt_address: u64 = 0x500;
const pci_block_slot: u5 = 1;
const pci_block_irq: u32 = 11;
const pci_bar_initial: u32 = 0xd000_0000;
const pci_net_slot: u5 = 2;
const pci_net_irq: u32 = 10;
const pci_net_bar_initial: u32 = 0xd001_0000;
const serial_irq: u32 = 4;

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

const Serial = struct {
    const capacity: usize = 4096;

    rx: [capacity]u8 = undefined,
    rx_head: usize = 0,
    rx_len: usize = 0,
    interrupt_enable: u8 = 0,
    line_control: u8 = 0,
    modem_control: u8 = 0,
    scratch: u8 = 0,
    divisor_low: u8 = 1,
    divisor_high: u8 = 0,

    fn queue(self: *Serial, bytes: []const u8) usize {
        if (bytes.len > capacity - self.rx_len) return 0;
        for (bytes, 0..) |byte, index| {
            self.rx[(self.rx_head + self.rx_len + index) % capacity] = byte;
        }
        self.rx_len += bytes.len;
        return bytes.len;
    }

    fn pop(self: *Serial) ?u8 {
        if (self.rx_len == 0) return null;
        const byte = self.rx[self.rx_head];
        self.rx_head = (self.rx_head + 1) % capacity;
        self.rx_len -= 1;
        return byte;
    }

    fn receiveInterruptPending(self: *const Serial) bool {
        return self.rx_len > 0 and self.interrupt_enable & 0x01 != 0;
    }
};

pub const Machine = struct {
    allocator: std.mem.Allocator,
    host: kvm.Kvm,
    vm: kvm.VM,
    vcpus: []VcpuSlot,
    memory: []align(std.heap.page_size_min) u8,
    layout: boot.Layout,
    exit_lock: std.Io.Mutex = .init,
    pci_config: pci.x86_config.LegacyConfig = .{},
    serial: Serial = .{},
    serial_lock: std.Io.Mutex = .init,
    serial_irq_injected: bool = false,
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
    net: ?*virtio.Net = null,
    pci_net: ?*pci.VirtioPciDevice = null,
    nat: mininat.MiniNat = undefined,
    net_enabled: bool = false,
    net_wakeup: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    net_irq_desired: bool = false,
    net_irq_injected: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    run_state: std.atomic.Value(RunState) = std.atomic.Value(RunState).init(.idle),
    exits_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mmio_exits_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_mmio_address: ?u64 = null,

    const VcpuSlot = struct {
        vcpu: kvm.Vcpu,
        debug_line: [128]u8 = undefined,
        debug_line_len: usize = 0,
        thread: ?std.Thread = null,
        thread_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        run_error: ?RunError = null,
    };

    const RunState = enum(u8) {
        idle,
        running,
        guest_shutdown,
        stopped,
        failed,
    };

    pub const InitError = kvm.OpenError || kvm.CreateError || boot.LoadError ||
        mps.WriteError || std.mem.Allocator.Error || error{InvalidVcpuCount};
    pub const AttachDiskError = virtio.Block.Error || std.Io.File.StatError ||
        kvm.FastPathError || std.Thread.SpawnError;
    pub const AttachNetworkError = virtio.Net.Error || std.Thread.SpawnError;
    pub const SerialInputError = kvm.InterruptError;
    pub const RunError = kvm.RunError || kvm.FastPathError || kvm.InterruptError ||
        std.Thread.SpawnError || error{
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
        allocator: std.mem.Allocator,
        memory_bytes: usize,
        vcpu_count: u8,
        image: boot.Image,
        command_line: []const u8,
        initrd: ?[]const u8,
    ) InitError!Machine {
        var host = try kvm.Kvm.open();
        errdefer host.deinit();
        var vm = try host.createVm();
        errdefer vm.deinit();
        const limits = host.vcpuLimits();
        if (vcpu_count == 0 or vcpu_count > mps.cpu_count_max or
            vcpu_count > limits.maximum or vcpu_count > limits.id_max)
        {
            return error.InvalidVcpuCount;
        }
        const memory = try vm.mapMemory(0, 0, memory_bytes);
        try vm.createPcInterrupts();

        const layout = try image.load(memory, command_line, initrd);
        writeGdt(memory);
        if (mps.table_address + mps.bytes_max > memory.len) return error.BufferTooSmall;
        const table_offset: usize = @intCast(mps.table_address);
        _ = try mps.write(memory[table_offset..][0..mps.bytes_max], vcpu_count);
        const cpuid = try host.supportedCpuid();
        const vcpus = try allocator.alloc(VcpuSlot, vcpu_count);
        errdefer allocator.free(vcpus);
        var initialized: usize = 0;
        errdefer for (vcpus[0..initialized]) |*slot| slot.vcpu.deinit();
        for (vcpus, 0..) |*slot, index| {
            var vcpu = try vm.createVcpu(@intCast(index));
            var vcpu_cpuid = cpuid;
            vcpu_cpuid.setTopology(@intCast(index), vcpu_count);
            vcpu.setCpuid(&vcpu_cpuid) catch |err| {
                vcpu.deinit();
                return err;
            };
            if (index == 0) {
                vcpu.setProtectedModeEntry(
                    layout.entry_address,
                    layout.boot_params_address,
                    gdt_address,
                ) catch |err| {
                    vcpu.deinit();
                    return err;
                };
            } else {
                vcpu.setApplicationProcessorState() catch |err| {
                    vcpu.deinit();
                    return err;
                };
            }
            slot.* = .{ .vcpu = vcpu };
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .host = host,
            .vm = vm,
            .vcpus = vcpus,
            .memory = memory,
            .layout = layout,
        };
    }

    pub fn deinit(self: *Machine) void {
        self.stopBlockFastPath();
        if (self.net_enabled) self.nat.stop();
        if (self.pci_net) |device| device.deinit();
        if (self.net) |net| net.deinit();
        if (self.pci_block) |device| device.deinit();
        if (self.block) |block| block.deinit();
        for (self.vcpus) |*slot| slot.vcpu.deinit();
        self.allocator.free(self.vcpus);
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
        device.config[0x3d] = 1;
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

    /// The machine address must remain stable until deinit because callbacks retain it.
    pub fn attachNetwork(self: *Machine, allocator: std.mem.Allocator) AttachNetworkError!void {
        std.debug.assert(self.net == null);
        std.debug.assert(self.pci_net == null);
        std.debug.assert(!self.net_enabled);

        const net = try virtio.Net.init(allocator);
        errdefer net.deinit();
        const device = try pci.VirtioPciDevice.init(
            allocator,
            1,
            0x0001,
            net.transport.device_features,
            2,
            @sizeOf(virtio.net.Config),
        );
        errdefer device.deinit();
        device.writeConfig(0x10, 4, pci_net_bar_initial);
        device.config[0x3c] = pci_net_irq;
        device.config[0x3d] = 1;
        device.transport.setDeviceConfig(std.mem.asBytes(&net.config));
        device.transport.setNotifyCallback(netNotify, self);
        net.setGuestMemory(GuestMemory.bind(Machine, self, getGuestMemory));
        net.setIrqCallback(virtio.mmio.Irq.initRaw(netIrq, self));

        self.net = net;
        self.pci_net = device;
        errdefer {
            self.net = null;
            self.pci_net = null;
        }
        self.nat = mininat.MiniNat.init(
            allocator,
            callback_binding.Handler1(Machine, []const u8, void, natReply).bind(self),
        );
        self.nat.setReplyLease(
            callback_binding.Handler1(
                Machine,
                usize,
                ?mininat.ReplyLease,
                natReplyReserve,
            ).bind(self),
            callback_binding.Handler1(
                Machine,
                mininat.ReplyLease,
                void,
                natReplyCommit,
            ).bind(self),
        );
        self.nat.setRxReady(
            callback_binding.Handler0(Machine, bool, natRxReady).bind(self),
        );
        self.nat.start() catch |err| {
            self.nat.stop();
            return err;
        };
        self.net_enabled = true;
        net.setTxCallback(
            callback_binding.Handler1(Machine, []const u8, void, netTx).bind(self),
        );
    }

    pub fn run(self: *Machine, serial: SerialSink, exits_max: u64) RunError!RunOutcome {
        if (self.run_state.cmpxchgStrong(.idle, .running, .acq_rel, .acquire) != null) {
            return error.InternalError;
        }
        for (self.vcpus[1..], 1..) |*slot, index| {
            if (self.run_state.load(.acquire) != .running) break;
            slot.thread = std.Thread.spawn(.{}, vcpuThreadMain, .{
                self,
                index,
                serial,
                exits_max,
            }) catch |err| {
                slot.run_error = err;
                self.finishRun(.failed);
                self.joinVcpuThreads();
                return err;
            };
        }

        if (self.run_state.load(.acquire) == .running) {
            const result = self.runVcpu(0, serial, exits_max);
            if (result) |outcome| {
                self.finishRun(runState(outcome));
            } else |err| {
                self.vcpus[0].run_error = err;
                self.finishRun(.failed);
            }
        }
        self.joinVcpuThreads();
        for (self.vcpus) |slot| if (slot.run_error) |err| return err;
        return switch (self.run_state.load(.acquire)) {
            .guest_shutdown => .guest_shutdown,
            .stopped => .stopped,
            else => error.InternalError,
        };
    }

    /// Stop every running vCPU from another thread without waiting for another VM exit.
    pub fn requestStop(self: *Machine) void {
        self.stop_requested.store(true, .release);
        self.finishRun(.stopped);
    }

    fn vcpuThreadMain(
        self: *Machine,
        index: usize,
        serial: SerialSink,
        exits_max: u64,
    ) void {
        const result = self.runVcpu(index, serial, exits_max);
        if (result) |outcome| {
            self.finishRun(runState(outcome));
        } else |err| {
            self.vcpus[index].run_error = err;
            self.finishRun(.failed);
        }
    }

    fn runVcpu(
        self: *Machine,
        index: usize,
        serial: SerialSink,
        exits_max: u64,
    ) RunError!RunOutcome {
        const slot = &self.vcpus[index];
        slot.thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
        defer slot.thread_id.store(0, .release);

        while (true) {
            slot.vcpu.clearExitRequest();
            switch (self.run_state.load(.acquire)) {
                .running => {},
                .guest_shutdown => return .guest_shutdown,
                .stopped, .failed => return .stopped,
                .idle => return error.InternalError,
            }
            if (self.stop_requested.load(.acquire)) return .stopped;
            try self.processAsyncDevices();
            if (self.block_worker_failed.load(.acquire)) return error.FastDevicePathFailed;

            const exit = slot.vcpu.runOnce() catch |err| switch (err) {
                error.Interrupted => continue,
                error.WouldBlock => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return err,
            };
            if (self.exits_total.fetchAdd(1, .monotonic) >= exits_max) {
                return error.ExitLimitReached;
            }
            if (exit == .halted or exit == .interrupted) continue;
            if (exit == .shutdown) return .guest_shutdown;

            self.exit_lock.lockUncancelable(global.io());
            defer self.exit_lock.unlock(global.io());
            switch (exit) {
                .io => try self.handleIo(&slot.vcpu, index, serial),
                .mmio => try self.handleMmio(&slot.vcpu),
                .internal_error => return error.InternalError,
                .unknown => return error.UnknownExit,
                .halted, .interrupted, .shutdown => unreachable,
            }
            try self.syncBlockIrq();
            if (self.net_wakeup.swap(false, .acq_rel)) self.processNet();
            try self.syncNetIrq();
        }
    }

    fn processAsyncDevices(self: *Machine) RunError!void {
        if (!self.net_wakeup.swap(false, .acq_rel)) return;
        self.exit_lock.lockUncancelable(global.io());
        defer self.exit_lock.unlock(global.io());
        self.processNet();
        try self.syncNetIrq();
    }

    fn finishRun(self: *Machine, state: RunState) void {
        if (self.run_state.cmpxchgStrong(.running, state, .acq_rel, .acquire) != null) return;
        const current_id: u32 = @intCast(std.Thread.getCurrentId());
        for (self.vcpus) |*slot| {
            slot.vcpu.requestExit();
            const thread_id = slot.thread_id.load(.acquire);
            if (thread_id != 0 and thread_id != current_id) kvm.interruptThread(thread_id);
        }
    }

    fn joinVcpuThreads(self: *Machine) void {
        for (self.vcpus[1..]) |*slot| {
            if (slot.thread) |thread| thread.join();
            slot.thread = null;
        }
    }

    fn runState(outcome: RunOutcome) RunState {
        return switch (outcome) {
            .guest_shutdown => .guest_shutdown,
            .stopped => .stopped,
        };
    }

    /// Queue host input for the guest's 16550 receive register.
    pub fn queueSerialInput(self: *Machine, bytes: []const u8) SerialInputError!usize {
        self.serial_lock.lockUncancelable(global.io());
        defer self.serial_lock.unlock(global.io());
        const written = self.serial.queue(bytes);
        try self.updateSerialIrqLocked();
        return written;
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

    fn handleIo(
        self: *Machine,
        vcpu: *kvm.Vcpu,
        vcpu_index: usize,
        serial: SerialSink,
    ) RunError!void {
        const access = vcpu.ioExit() orelse return error.InvalidIoExit;
        switch (access.direction) {
            .write => try self.handleIoWrite(access, vcpu_index, serial),
            .read => try self.handleIoRead(access),
        }
    }

    fn handleIoWrite(
        self: *Machine,
        access: kvm.IoExit,
        vcpu_index: usize,
        serial: SerialSink,
    ) (kvm.FastPathError || kvm.InterruptError)!void {
        if (access.size == 1 and access.port == 0xe9) {
            self.writeDebugOutput(vcpu_index, access.data, serial);
        }

        if (access.count != 1) return;
        const value = readIoValue(access.data) orelse return;
        if (access.size == 1 and access.port >= 0x3f8 and access.port <= 0x3ff) {
            try self.writeSerialRegister(access.port, @truncate(value), serial);
            return;
        }
        if (self.pci_config.writeAddress(access.port, access.size, value)) return;
        const address = self.pci_config.dataAddress(access.port, access.size) orelse return;
        const device = self.pciDevice(address) orelse return;
        const old_bar_address = device.getBar0Addr();
        device.writeConfig(address.register, access.size, value);
        const new_bar_address = device.getBar0Addr();
        if (address.device != pci_block_slot) return;
        self.rebindBlockIoEvent(old_bar_address, new_bar_address) catch |err| {
            device.writeConfig(0x10, 4, old_bar_address);
            return err;
        };
    }

    fn handleIoRead(self: *Machine, access: kvm.IoExit) kvm.InterruptError!void {
        @memset(access.data, 0xff);
        if (access.count != 1) return;
        if (self.pci_config.readAddress(access.port, access.size)) |value| {
            writeIoValue(access.data, value);
            return;
        }
        if (access.count == 1 and access.size == 1 and
            access.port >= 0x3f8 and access.port <= 0x3ff)
        {
            @memset(access.data, try self.readSerialRegister(access.port));
            return;
        }
        if (self.pci_config.dataAddress(access.port, access.size)) |address| {
            const device = self.pciDevice(address) orelse return;
            writeIoValue(access.data, @truncate(device.readConfig(address.register, access.size)));
            return;
        }
        if (access.size != 1) return;
    }

    fn writeSerialRegister(
        self: *Machine,
        port: u16,
        value: u8,
        sink: SerialSink,
    ) kvm.InterruptError!void {
        self.serial_lock.lockUncancelable(global.io());
        defer self.serial_lock.unlock(global.io());
        switch (port - 0x3f8) {
            0 => if (self.serial.line_control & 0x80 != 0) {
                self.serial.divisor_low = value;
            } else {
                sink.write(&.{value});
            },
            1 => if (self.serial.line_control & 0x80 != 0) {
                self.serial.divisor_high = value;
            } else {
                self.serial.interrupt_enable = value & 0x0f;
            },
            3 => self.serial.line_control = value,
            4 => self.serial.modem_control = value & 0x1f,
            7 => self.serial.scratch = value,
            else => {},
        }
        try self.updateSerialIrqLocked();
    }

    fn readSerialRegister(self: *Machine, port: u16) kvm.InterruptError!u8 {
        self.serial_lock.lockUncancelable(global.io());
        defer self.serial_lock.unlock(global.io());
        const value: u8 = switch (port - 0x3f8) {
            0 => if (self.serial.line_control & 0x80 != 0)
                self.serial.divisor_low
            else
                self.serial.pop() orelse 0,
            1 => if (self.serial.line_control & 0x80 != 0)
                self.serial.divisor_high
            else
                self.serial.interrupt_enable,
            2 => if (self.serial.receiveInterruptPending()) 0x04 else 0x01,
            3 => self.serial.line_control,
            4 => self.serial.modem_control,
            5 => 0x60 | @as(u8, @intFromBool(self.serial.rx_len > 0)),
            6 => 0xb0,
            7 => self.serial.scratch,
            else => 0,
        };
        try self.updateSerialIrqLocked();
        return value;
    }

    fn updateSerialIrqLocked(self: *Machine) kvm.InterruptError!void {
        const desired = self.serial.receiveInterruptPending();
        if (desired == self.serial_irq_injected) return;
        try self.vm.setIrqLine(serial_irq, desired);
        self.serial_irq_injected = desired;
    }

    fn handleMmio(self: *Machine, vcpu: *kvm.Vcpu) RunError!void {
        const access = vcpu.mmioExit() orelse return error.InvalidMmioExit;
        _ = self.mmio_exits_total.fetchAdd(1, .monotonic);
        self.last_mmio_address = access.address;
        if (self.handlePciBar(access)) return;
        handleAbsentMmio(access);
    }

    fn handleAbsentMmio(access: kvm.MmioExit) void {
        if (access.direction == .read) @memset(access.data, 0xff);
    }

    fn handlePciBar(self: *Machine, access: kvm.MmioExit) bool {
        if (self.pci_block) |device| {
            if (self.block) |block| {
                if (self.handleBlockPciBar(device, block, access)) return true;
            }
        }
        if (self.pci_net) |device| {
            if (self.net) |net| return self.handleNetPciBar(device, net, access);
        }
        return false;
    }

    fn handleBlockPciBar(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        block: *virtio.Block,
        access: kvm.MmioExit,
    ) bool {
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

    fn handleNetPciBar(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        net: *virtio.Net,
        access: kvm.MmioExit,
    ) bool {
        const bar_address: u64 = device.getBar0Addr();
        if (bar_address == 0 or access.address < bar_address) return false;
        const offset_u64 = access.address - bar_address;
        if (offset_u64 >= pci.virtio_pci.BAR0_SIZE) return false;
        const value = readIoValue(access.data) orelse return false;
        const offset: u32 = @intCast(offset_u64);

        if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
            offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE and
            access.direction == .read)
        {
            self.readNetIsr(device, net, access, offset);
            return true;
        }
        if (access.direction == .read) {
            if (offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET) {
                device.transport.setDeviceConfig(std.mem.asBytes(&net.config));
            }
            writeIoValue(access.data, device.readBar0(offset, @intCast(access.data.len)));
        } else {
            device.writeBar0(offset, @intCast(access.data.len), value);
        }
        return true;
    }

    fn pciDevice(
        self: *Machine,
        address: pci.x86_config.ConfigAddress,
    ) ?*pci.VirtioPciDevice {
        if (address.bus != 0 or address.function != 0) return null;
        return switch (address.device) {
            pci_block_slot => self.pci_block,
            pci_net_slot => self.pci_net,
            else => null,
        };
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

    fn netNotify(queue_index: u32, userdata: ?*anyopaque) void {
        if (queue_index >= 2) return;
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        self.processNet();
    }

    fn processNet(self: *Machine) void {
        const device = self.pci_net orelse return;
        const net = self.net orelse return;
        for (device.transport.queues, 0..) |source, queue_index| {
            const target = &net.transport.queues[queue_index];
            target.num = source.size;
            target.ready = source.enable;
            target.desc_addr = source.desc_addr;
            target.driver_addr = source.driver_addr;
            target.device_addr = source.device_addr;
        }
        net.poll();
    }

    fn netIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        const device = self.pci_net orelse return;
        const net = self.net orelse return;
        device.transport.isr_status.queue_interrupt =
            net.transport.interrupt_status.used_buffer;
        device.transport.isr_status.config_change =
            net.transport.interrupt_status.config_change;
        self.net_irq_desired = level;
    }

    fn syncNetIrq(self: *Machine) kvm.InterruptError!void {
        if (self.net_irq_desired == self.net_irq_injected) return;
        try self.vm.setIrqLine(pci_net_irq, self.net_irq_desired);
        self.net_irq_injected = self.net_irq_desired;
    }

    fn netTx(self: *Machine, frame: []const u8) void {
        self.nat.handleFrame(frame);
    }

    fn natReply(self: *Machine, frame: []const u8) void {
        const net = self.net orelse return;
        net.queueRxFrame(frame);
        self.wakeNet();
    }

    fn natReplyReserve(self: *Machine, frame_len: usize) ?mininat.ReplyLease {
        const net = self.net orelse return null;
        const reservation = net.reserveRxFrame(frame_len) orelse return null;
        return .{ .frame = reservation.bytes, .token = reservation.storage_index };
    }

    fn natReplyCommit(self: *Machine, lease: mininat.ReplyLease) void {
        const net = self.net orelse return;
        net.commitRxFrame(.{
            .bytes = lease.frame,
            .storage_index = @intCast(lease.token),
        });
        self.wakeNet();
    }

    fn natRxReady(self: *Machine) bool {
        const net = self.net orelse return false;
        return net.rxReady();
    }

    fn wakeNet(self: *Machine) void {
        self.net_wakeup.store(true, .release);
        const primary = &self.vcpus[0];
        const thread_id = primary.thread_id.load(.acquire);
        if (thread_id == 0 or thread_id == @as(u32, @intCast(std.Thread.getCurrentId()))) return;
        primary.vcpu.requestExit();
        kvm.interruptThread(thread_id);
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

    fn writeDebugOutput(
        self: *Machine,
        vcpu_index: usize,
        bytes: []const u8,
        serial: SerialSink,
    ) void {
        const slot = &self.vcpus[vcpu_index];
        for (bytes) |byte| {
            if (slot.debug_line_len == slot.debug_line.len) {
                serial.write(&slot.debug_line);
                slot.debug_line_len = 0;
            }
            slot.debug_line[slot.debug_line_len] = byte;
            slot.debug_line_len += 1;
            if (byte != '\n') continue;
            serial.write(slot.debug_line[0..slot.debug_line_len]);
            slot.debug_line_len = 0;
        }
    }

    fn readNetIsr(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        net: *virtio.Net,
        access: kvm.MmioExit,
        offset: u32,
    ) void {
        const result = device.readBar0(offset, @intCast(access.data.len));
        writeIoValue(access.data, result);
        const current: u32 = @bitCast(net.transport.interrupt_status);
        net.transport.interrupt_status = @bitCast(current & ~result);
        if (@as(u32, @bitCast(net.transport.interrupt_status)) == 0) {
            self.net_irq_desired = false;
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

test "serial receive queue is bounded and preserves FIFO order" {
    var serial = Serial{};
    var input: [Serial.capacity]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index);

    try std.testing.expectEqual(Serial.capacity, serial.queue(&input));
    try std.testing.expectEqual(@as(usize, 0), serial.queue("overflow"));
    for (input[0..100]) |expected| {
        try std.testing.expectEqual(expected, serial.pop().?);
    }
    try std.testing.expectEqual(@as(usize, 100), serial.queue(input[0..100]));
    for (input[100..Serial.capacity]) |expected| {
        try std.testing.expectEqual(expected, serial.pop().?);
    }
    for (input[0..100]) |expected| {
        try std.testing.expectEqual(expected, serial.pop().?);
    }
    try std.testing.expectEqual(@as(?u8, null), serial.pop());
}

test "serial receive interrupt follows buffered input and IER" {
    var serial = Serial{};
    try std.testing.expectEqual(@as(usize, 1), serial.queue("a"));
    try std.testing.expect(!serial.receiveInterruptPending());

    serial.interrupt_enable = 1;
    try std.testing.expect(serial.receiveInterruptPending());
    try std.testing.expectEqual(@as(?u8, 'a'), serial.pop());
    try std.testing.expect(!serial.receiveInterruptPending());
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
