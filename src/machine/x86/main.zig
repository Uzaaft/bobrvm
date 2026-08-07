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
const pci_block_slot: u5 = 2;
const pci_block_irq: u32 = 11;
const pci_block_bar_initial: u32 = 0xd000_0000;
const pci_block2_slot: u5 = 3;
const pci_block2_irq: u32 = 10;
const pci_block2_bar_initial: u32 = 0xd001_0000;
const pci_net_slot: u5 = 4;
const pci_net_irq: u32 = 9;
const pci_net_bar_initial: u32 = 0xd002_0000;
const pci_gpu_slot: u5 = 5;
const pci_gpu_irq: u32 = 5;
const pci_gpu_bar_initial: u32 = 0xd003_0000;
const pci_keyboard_slot: u5 = 6;
const pci_keyboard_irq: u32 = 6;
const pci_keyboard_bar_initial: u32 = 0xd004_0000;
const pci_tablet_slot: u5 = 7;
const pci_tablet_irq: u32 = 7;
const pci_tablet_bar_initial: u32 = 0xd005_0000;
const serial_irq: u32 = 4;
const ovmf_debug_port: u16 = 0x402;
const piix4_pm_function: u3 = 3;
const piix4_pmba_offset: usize = 0x40;
const piix4_pmregmisc_offset: usize = 0x80;
const piix4_pmio_enable: u8 = 1;
const acpi_timer_offset: u16 = 8;
const acpi_timer_frequency_hz: u64 = 3_579_545;
const acpi_timer_mask: u32 = 0x00ff_ffff;
const firmware_address_end: u64 = 0x1_0000_0000;
const firmware_bytes_max: usize = 16 * 1024 * 1024;

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
    exit_lock: std.Io.Mutex = .init,
    pci_config: pci.x86_config.LegacyConfig = .{},
    pci_config_reads: u64 = 0,
    pci_device_reads: [32]u64 = @splat(0),
    chipset_config: [2][4][256]u8 = initChipsetConfig(),
    serial: Serial = .{},
    serial_lock: std.Io.Mutex = .init,
    serial_irq_injected: bool = false,
    cmos_index: u7 = 0,
    cmos_nmi_disabled: bool = false,
    cmos_data: [128]u8 = initCmosData(),
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
    block2: ?*virtio.Block = null,
    pci_block2: ?*pci.VirtioPciDevice = null,
    block2_irq_desired: bool = false,
    block2_irq_injected: bool = false,
    block2_notifications: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    net: ?*virtio.Net = null,
    pci_net: ?*pci.VirtioPciDevice = null,
    nat: mininat.MiniNat = undefined,
    net_enabled: bool = false,
    net_wakeup: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    net_irq_desired: bool = false,
    net_irq_injected: bool = false,
    gpu: ?*virtio.Gpu = null,
    pci_gpu: ?*pci.VirtioPciDevice = null,
    gpu_irq_desired: bool = false,
    gpu_irq_injected: bool = false,
    keyboard: ?*virtio.Input = null,
    pci_keyboard: ?*pci.VirtioPciDevice = null,
    keyboard_irq_desired: bool = false,
    keyboard_irq_injected: bool = false,
    tablet: ?*virtio.Input = null,
    pci_tablet: ?*pci.VirtioPciDevice = null,
    tablet_irq_desired: bool = false,
    tablet_irq_injected: bool = false,
    input_wakeup: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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

    const AttachedInput = struct {
        input: *virtio.Input,
        device: *pci.VirtioPciDevice,
    };

    const RunState = enum(u8) {
        idle,
        running,
        guest_shutdown,
        stopped,
        failed,
    };

    pub const InitError = kvm.OpenError || kvm.CreateError || boot.LoadError ||
        mps.WriteError || std.mem.Allocator.Error || error{
        InvalidFirmware,
        InvalidVcpuCount,
    };
    pub const AttachDiskError = virtio.Block.Error || std.Io.File.StatError ||
        kvm.FastPathError || std.Thread.SpawnError;
    pub const AttachNetworkError = virtio.Net.Error || std.Thread.SpawnError;
    pub const AttachDisplayError = virtio.Gpu.Error;
    pub const AttachInputError = virtio.Input.Error;
    pub const InputError = error{InputUnavailable};
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

    pub const MmioExitStats = struct {
        total: u64,
        last: ?u64,
    };

    pub const Scanout = struct {
        width: u32,
        height: u32,
        generation: u64,
        bytes: usize,
    };

    pub const RunOutcome = enum {
        guest_shutdown,
        stopped,
    };

    pub const BootSource = union(enum) {
        linux: struct {
            image: boot.Image,
            command_line: []const u8,
            initrd: ?[]const u8,
        },
        firmware: []const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        memory_bytes: usize,
        vcpu_count: u8,
        boot_source: BootSource,
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

        const linux_layout: ?boot.Layout = switch (boot_source) {
            .linux => |linux| try linux.image.load(
                memory,
                linux.command_line,
                linux.initrd,
            ),
            .firmware => |firmware| firmware_boot: {
                if (firmware.len == 0 or firmware.len > firmware_bytes_max or
                    firmware.len % std.heap.page_size_min != 0)
                {
                    return error.InvalidFirmware;
                }
                const address = firmware_address_end - firmware.len;
                const mapped = try vm.mapMemory(1, address, firmware.len);
                @memcpy(mapped, firmware);
                break :firmware_boot null;
            },
        };
        if (linux_layout != null) writeGdt(memory);
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
                if (linux_layout) |layout| {
                    vcpu.setProtectedModeEntry(
                        layout.entry_address,
                        layout.boot_params_address,
                        gdt_address,
                    ) catch |err| {
                        vcpu.deinit();
                        return err;
                    };
                } else vcpu.setFirmwareReset() catch |err| {
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
        };
    }

    pub fn deinit(self: *Machine) void {
        self.stopBlockFastPath();
        if (self.net_enabled) self.nat.stop();
        if (self.pci_tablet) |device| device.deinit();
        if (self.tablet) |input| input.deinit();
        if (self.pci_keyboard) |device| device.deinit();
        if (self.keyboard) |input| input.deinit();
        if (self.pci_gpu) |device| device.deinit();
        if (self.gpu) |gpu| gpu.deinit();
        if (self.pci_net) |device| device.deinit();
        if (self.net) |net| net.deinit();
        if (self.pci_block2) |device| device.deinit();
        if (self.block2) |block| block.deinit();
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
            block.transport.device_features,
            1,
            @sizeOf(virtio.blk.Config),
        );
        errdefer device.deinit();
        device.writeConfig(0x10, 4, pci_block_bar_initial);
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

    /// Attach read-mostly installation media as the second virtio block device.
    pub fn attachDisk2(
        self: *Machine,
        allocator: std.mem.Allocator,
        path: []const u8,
        read_only: bool,
    ) AttachDiskError!void {
        std.debug.assert(self.block2 == null);
        std.debug.assert(self.pci_block2 == null);

        const block = try virtio.Block.init(allocator);
        errdefer block.deinit();
        try block.attachDisk(path, read_only);

        const device = try pci.VirtioPciDevice.init(
            allocator,
            2,
            block.transport.device_features,
            1,
            @sizeOf(virtio.blk.Config),
        );
        errdefer device.deinit();
        device.writeConfig(0x10, 4, pci_block2_bar_initial);
        device.config[0x3c] = pci_block2_irq;
        device.config[0x3d] = 1;
        device.transport.setDeviceConfig(std.mem.asBytes(&block.config));
        device.transport.setNotifyCallback(block2Notify, self);
        block.setGuestMemory(GuestMemory.bind(Machine, self, getGuestMemory));
        block.setIrqCallback(virtio.mmio.Irq.initRaw(block2Irq, self));
        self.block2 = block;
        self.pci_block2 = device;
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

    /// Attach a 2D virtio-GPU whose scanout can be consumed by the host UI.
    pub fn attachDisplay(
        self: *Machine,
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
    ) AttachDisplayError!void {
        std.debug.assert(self.gpu == null);
        std.debug.assert(self.pci_gpu == null);

        const gpu = try virtio.Gpu.init(allocator, false);
        errdefer gpu.deinit();
        gpu.setDisplaySize(width, height);
        gpu.setGuestMemory(GuestMemory.bind(Machine, self, getGuestMemory));
        gpu.setIrqCallback(virtio.mmio.Irq.initRaw(gpuIrq, self));

        const device = try pci.VirtioPciDevice.init(
            allocator,
            16,
            gpu.transport.device_features,
            2,
            @sizeOf(virtio.gpu.Config),
        );
        errdefer device.deinit();
        device.writeConfig(0x10, 4, pci_gpu_bar_initial);
        device.config[0x3c] = pci_gpu_irq;
        device.config[0x3d] = 1;
        device.transport.setDeviceConfig(std.mem.asBytes(&gpu.config));
        device.transport.setNotifyCallback(gpuNotify, self);

        self.gpu = gpu;
        self.pci_gpu = device;
    }

    pub fn attachInputDevices(self: *Machine, allocator: std.mem.Allocator) AttachInputError!void {
        std.debug.assert(self.keyboard == null);
        std.debug.assert(self.tablet == null);
        const keyboard = try self.createInputDevice(
            allocator,
            .keyboard,
            pci_keyboard_irq,
            pci_keyboard_bar_initial,
            keyboardNotify,
            keyboardIrq,
        );
        errdefer {
            keyboard.device.deinit();
            keyboard.input.deinit();
        }
        const tablet = try self.createInputDevice(
            allocator,
            .tablet,
            pci_tablet_irq,
            pci_tablet_bar_initial,
            tabletNotify,
            tabletIrq,
        );
        self.keyboard = keyboard.input;
        self.pci_keyboard = keyboard.device;
        self.tablet = tablet.input;
        self.pci_tablet = tablet.device;
    }

    fn createInputDevice(
        self: *Machine,
        allocator: std.mem.Allocator,
        subtype: virtio.input.Subtype,
        irq: u32,
        bar_address: u32,
        notify: *const fn (u32, ?*anyopaque) void,
        irq_callback: *const fn (bool, ?*anyopaque) void,
    ) AttachInputError!AttachedInput {
        const input = try virtio.Input.init(allocator, subtype);
        errdefer input.deinit();
        input.setGuestMemory(GuestMemory.bind(Machine, self, getGuestMemory));
        input.setIrqCallback(virtio.mmio.Irq.initRaw(irq_callback, self));
        const device = try pci.VirtioPciDevice.init(
            allocator,
            18,
            input.transport.device_features,
            2,
            @sizeOf(virtio.input.Config),
        );
        errdefer device.deinit();
        device.writeConfig(0x10, 4, bar_address);
        device.config[0x3c] = @intCast(irq);
        device.config[0x3d] = 1;
        device.transport.setDeviceConfig(std.mem.asBytes(&input.config));
        device.transport.setNotifyCallback(notify, self);
        return .{ .input = input, .device = device };
    }

    pub fn injectKey(self: *Machine, keycode: u16, pressed: bool) InputError!void {
        const keyboard = self.keyboard orelse return error.InputUnavailable;
        keyboard.injectKey(keycode, pressed) catch unreachable;
        self.wakeInput();
    }

    pub fn injectPointer(self: *Machine, x: i32, y: i32) InputError!void {
        const tablet = self.tablet orelse return error.InputUnavailable;
        tablet.injectAbsolute(x, y) catch unreachable;
        self.wakeInput();
    }

    pub fn injectButton(self: *Machine, button: u16, pressed: bool) InputError!void {
        const tablet = self.tablet orelse return error.InputUnavailable;
        tablet.injectButton(button, pressed) catch unreachable;
        self.wakeInput();
    }

    pub fn injectScroll(self: *Machine, x: i32, y: i32) InputError!void {
        const tablet = self.tablet orelse return error.InputUnavailable;
        tablet.injectScroll(x, y) catch unreachable;
        self.wakeInput();
    }

    pub fn copyScanout(self: *Machine, destination: []u8) ?Scanout {
        const gpu = self.gpu orelse return null;
        const view = gpu.lockScanout() orelse return null;
        defer gpu.unlockScanout();
        const row_bytes = @as(usize, view.width) * 4;
        const bytes = row_bytes * view.height;
        if (destination.len < bytes) return null;
        const source_stride = @as(usize, view.full_width) * 4;
        const source_x = @as(usize, view.src_x) * 4;
        var row: usize = 0;
        while (row < view.height) : (row += 1) {
            const source_offset = (@as(usize, view.src_y) + row) * source_stride + source_x;
            const target_offset = row * row_bytes;
            @memcpy(
                destination[target_offset..][0..row_bytes],
                view.data[source_offset..][0..row_bytes],
            );
        }
        return .{
            .width = view.width,
            .height = view.height,
            .generation = view.generation,
            .bytes = bytes,
        };
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
            try self.syncBlock2Irq();
            if (self.net_wakeup.swap(false, .acq_rel)) self.processNet();
            try self.syncNetIrq();
            try self.syncGpuIrq();
            if (self.input_wakeup.swap(false, .acq_rel)) self.processInput();
            try self.syncInputIrqs();
        }
    }

    fn processAsyncDevices(self: *Machine) RunError!void {
        const network = self.net_wakeup.swap(false, .acq_rel);
        const input = self.input_wakeup.swap(false, .acq_rel);
        if (!network and !input) return;
        self.exit_lock.lockUncancelable(global.io());
        defer self.exit_lock.unlock(global.io());
        if (network) {
            self.processNet();
            try self.syncNetIrq();
        }
        if (input) {
            self.processInput();
            try self.syncInputIrqs();
        }
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

    pub fn secondaryBlockNotifications(self: *const Machine) u64 {
        return self.block2_notifications.load(.acquire);
    }

    pub fn pciConfigReads(self: *const Machine) u64 {
        return self.pci_config_reads;
    }

    pub fn pciDeviceReads(self: *const Machine) [32]u64 {
        return self.pci_device_reads;
    }

    pub fn mmioExitStats(self: *const Machine) MmioExitStats {
        return .{
            .total = self.mmio_exits_total.load(.acquire),
            .last = self.last_mmio_address,
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
        if (access.size == 1 and
            (access.port == 0xe9 or access.port == ovmf_debug_port))
        {
            self.writeDebugOutput(vcpu_index, access.data, serial);
        }

        if (access.count != 1) return;
        const value = readIoValue(access.data) orelse return;
        if (access.size == 1 and access.port >= 0x3f8 and access.port <= 0x3ff) {
            try self.writeSerialRegister(access.port, @truncate(value), serial);
            return;
        }
        if (access.size == 1 and access.port == 0x70) {
            self.cmos_index = @truncate(value & 0x7f);
            self.cmos_nmi_disabled = value & 0x80 != 0;
            return;
        }
        if (access.size == 1 and access.port == 0x71) {
            self.writeCmos(@truncate(value));
            return;
        }
        if (access.size == 1 and access.port == 0x92) return;
        if (self.pci_config.writeAddress(access.port, access.size, value)) return;
        const address = self.pci_config.dataAddress(access.port, access.size) orelse return;
        if (self.chipsetConfigWrite(address, access.size, value)) return;
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
        if (access.size == 1 and access.port == 0x70) {
            const nmi = @as(u8, @intFromBool(self.cmos_nmi_disabled)) << 7;
            @memset(access.data, @as(u8, self.cmos_index) | nmi);
            return;
        }
        if (access.size == 1 and access.port == 0x71) {
            @memset(access.data, self.readCmos());
            return;
        }
        if (access.size == 1 and access.port == 0x92) {
            @memset(access.data, 0x02);
            return;
        }
        if (access.size == 4 and self.acpiTimerPort() == access.port) {
            writeIoValue(access.data, acpiTimerTick());
            return;
        }
        if (self.pci_config.dataAddress(access.port, access.size)) |address| {
            self.pci_config_reads += 1;
            self.pci_device_reads[address.device] += 1;
            if (self.chipsetConfigRead(address, access.size)) |value| {
                writeIoValue(access.data, value);
                return;
            }
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
                if (self.handleBlockPciBar(
                    device,
                    block,
                    access,
                    &self.block_irq_desired,
                    self.block_fast_enabled,
                )) return true;
            }
        }
        if (self.pci_block2) |device| {
            if (self.block2) |block| {
                if (self.handleBlockPciBar(
                    device,
                    block,
                    access,
                    &self.block2_irq_desired,
                    false,
                )) return true;
            }
        }
        if (self.pci_net) |device| {
            if (self.net) |net| return self.handleNetPciBar(device, net, access);
        }
        if (self.pci_gpu) |device| {
            if (self.gpu) |gpu| return self.handleGpuPciBar(device, gpu, access);
        }
        if (self.pci_keyboard) |device| {
            if (self.keyboard) |input| return self.handleInputPciBar(device, input, access);
        }
        if (self.pci_tablet) |device| {
            if (self.tablet) |input| return self.handleInputPciBar(device, input, access);
        }
        return false;
    }

    fn handleBlockPciBar(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        block: *virtio.Block,
        access: kvm.MmioExit,
        irq_desired: *bool,
        fast_path: bool,
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
            if (fast_path) self.block_notify_mmio_exits += 1;
        }

        if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
            offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE and
            access.direction == .read)
        {
            self.readBlockIsr(device, block, access, offset, irq_desired, fast_path);
            return true;
        }

        if (fast_path) self.block_lock.lockUncancelable(global.io());
        defer if (fast_path) self.block_lock.unlock(global.io());

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

    fn handleGpuPciBar(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        gpu: *virtio.Gpu,
        access: kvm.MmioExit,
    ) bool {
        _ = self;
        const bar_address: u64 = device.getBar0Addr();
        if (bar_address == 0 or access.address < bar_address) return false;
        const offset_u64 = access.address - bar_address;
        if (offset_u64 >= pci.virtio_pci.BAR0_SIZE) return false;
        const value = readIoValue(access.data) orelse return false;
        const offset: u32 = @intCast(offset_u64);

        if (access.direction == .read) {
            if (offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET) {
                device.transport.setDeviceConfig(std.mem.asBytes(&gpu.config));
            }
            const result = device.readBar0(offset, @intCast(access.data.len));
            writeIoValue(access.data, result);
            if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
                offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE)
            {
                gpu.transport.write(@intFromEnum(virtio.mmio.Reg.interrupt_ack), result);
            }
        } else {
            device.writeBar0(offset, @intCast(access.data.len), value);
        }
        return true;
    }

    fn handleInputPciBar(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        input: *virtio.Input,
        access: kvm.MmioExit,
    ) bool {
        _ = self;
        const bar_address: u64 = device.getBar0Addr();
        if (bar_address == 0 or access.address < bar_address) return false;
        const offset_u64 = access.address - bar_address;
        if (offset_u64 >= pci.virtio_pci.BAR0_SIZE) return false;
        const value = readIoValue(access.data) orelse return false;
        const offset: u32 = @intCast(offset_u64);
        const device_config = offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET;

        if (access.direction == .read) {
            if (device_config) {
                _ = input.read(@intFromEnum(virtio.mmio.Reg.config));
                device.transport.setDeviceConfig(std.mem.asBytes(&input.config));
            }
            const result = device.readBar0(offset, @intCast(access.data.len));
            writeIoValue(access.data, result);
            if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
                offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE)
            {
                input.transport.write(@intFromEnum(virtio.mmio.Reg.interrupt_ack), result);
            }
        } else {
            device.writeBar0(offset, @intCast(access.data.len), value);
            if (device_config) {
                const config = device.transport.device_config;
                input.write(@intFromEnum(virtio.mmio.Reg.config), config[0]);
                input.write(@intFromEnum(virtio.mmio.Reg.config) + 1, config[1]);
            }
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
            pci_block2_slot => self.pci_block2,
            pci_net_slot => self.pci_net,
            pci_gpu_slot => self.pci_gpu,
            pci_keyboard_slot => self.pci_keyboard,
            pci_tablet_slot => self.pci_tablet,
            else => null,
        };
    }

    fn chipsetConfigRead(
        self: *const Machine,
        address: pci.x86_config.ConfigAddress,
        size: u8,
    ) ?u32 {
        const config = self.chipsetConfig(address) orelse return null;
        const offset: usize = address.register;
        if (offset >= config.len or size > config.len - offset) return 0;
        return readIoValue(config[offset..][0..size]) orelse 0;
    }

    fn chipsetConfigWrite(
        self: *Machine,
        address: pci.x86_config.ConfigAddress,
        size: u8,
        value: u32,
    ) bool {
        const config = self.chipsetConfigMutable(address) orelse return false;
        const offset: usize = address.register;
        if (offset >= config.len or size > config.len - offset) return true;
        if (offset < 4 or (offset >= 8 and offset < 16)) return true;
        if ((offset >= 0x10 and offset < 0x28) or
            (offset >= 0x30 and offset < 0x34)) return true;
        writeIoValue(config[offset..][0..size], value);
        return true;
    }

    fn chipsetConfig(
        self: *const Machine,
        address: pci.x86_config.ConfigAddress,
    ) ?[]const u8 {
        if (address.bus != 0 or address.device > 1) return null;
        if (address.device == 0) {
            if (address.function != 0) return null;
            return &self.chipset_config[0][0];
        }
        if (address.function != 0 and address.function != piix4_pm_function) return null;
        return &self.chipset_config[1][address.function];
    }

    fn chipsetConfigMutable(
        self: *Machine,
        address: pci.x86_config.ConfigAddress,
    ) ?[]u8 {
        if (address.bus != 0 or address.device > 1) return null;
        if (address.device == 0) {
            if (address.function != 0) return null;
            return &self.chipset_config[0][0];
        }
        if (address.function != 0 and address.function != piix4_pm_function) return null;
        return &self.chipset_config[1][address.function];
    }

    fn acpiTimerPort(self: *const Machine) u16 {
        const pm = &self.chipset_config[1][piix4_pm_function];
        const base = std.mem.readInt(u32, pm[piix4_pmba_offset..][0..4], .little) & ~@as(u32, 1);
        return @truncate(base + acpi_timer_offset);
    }

    fn acpiTimerTick() u32 {
        const nanoseconds: u64 = @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
        const ticks = @as(u128, nanoseconds) * acpi_timer_frequency_hz / std.time.ns_per_s;
        return @truncate(ticks & acpi_timer_mask);
    }

    fn initChipsetConfig() [2][4][256]u8 {
        var config: [2][4][256]u8 = @splat(@splat(@splat(0xff)));
        @memset(&config[0][0], 0);
        @memset(&config[1][0], 0);
        @memset(&config[1][piix4_pm_function], 0);
        std.mem.writeInt(u16, config[0][0][0..2], 0x8086, .little);
        std.mem.writeInt(u16, config[0][0][2..4], 0x1237, .little);
        config[0][0][8] = 0x02;
        config[0][0][11] = 0x06;

        std.mem.writeInt(u16, config[1][0][0..2], 0x8086, .little);
        std.mem.writeInt(u16, config[1][0][2..4], 0x7000, .little);
        config[1][0][0x0e] = 0x80;
        std.mem.writeInt(u16, config[1][piix4_pm_function][0..2], 0x8086, .little);
        std.mem.writeInt(u16, config[1][piix4_pm_function][2..4], 0x7113, .little);
        config[1][piix4_pm_function][8] = 0x03;
        config[1][piix4_pm_function][10] = 0x80;
        config[1][piix4_pm_function][11] = 0x06;
        config[1][piix4_pm_function][0x0e] = 0x00;
        std.mem.writeInt(
            u32,
            config[1][piix4_pm_function][piix4_pmba_offset..][0..4],
            0xb001,
            .little,
        );
        config[1][piix4_pm_function][piix4_pmregmisc_offset] = piix4_pmio_enable;
        return config;
    }

    fn initCmosData() [128]u8 {
        var data = [_]u8{0} ** 128;
        data[0x0a] = 0x26;
        data[0x0b] = 0x02;
        data[0x0d] = 0x80;
        return data;
    }

    fn readCmos(self: *Machine) u8 {
        return switch (self.cmos_index) {
            0x0a => self.cmos_data[0x0a] & 0x7f,
            0x0c => 0,
            0x0d => 0x80,
            0x14,
            0x15,
            0x16,
            0x17,
            0x18,
            0x30,
            0x31,
            0x34,
            0x35,
            0x3d,
            0x5b,
            0x5c,
            0x5d,
            => cmosByte(self.memory.len, self.cmos_index),
            else => self.cmos_data[self.cmos_index],
        };
    }

    fn writeCmos(self: *Machine, value: u8) void {
        switch (self.cmos_index) {
            0x0c, 0x0d => {},
            else => self.cmos_data[self.cmos_index] = value,
        }
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
        processBlockDevice(device, block);
    }

    fn block2Notify(queue_index: u32, userdata: ?*anyopaque) void {
        if (queue_index != 0) return;
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        _ = self.block2_notifications.fetchAdd(1, .release);
        const device = self.pci_block2 orelse return;
        const block = self.block2 orelse return;
        processBlockDevice(device, block);
    }

    fn processBlockDevice(device: *pci.VirtioPciDevice, block: *virtio.Block) void {
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

    fn gpuNotify(queue_index: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        const device = self.pci_gpu orelse return;
        const gpu = self.gpu orelse return;
        if (queue_index >= device.transport.queues.len or
            queue_index >= gpu.transport.queues.len) return;
        const source = device.transport.queues[queue_index];
        const target = &gpu.transport.queues[queue_index];
        target.num = source.size;
        target.ready = source.enable;
        target.desc_addr = source.desc_addr;
        target.driver_addr = source.driver_addr;
        target.device_addr = source.device_addr;
        gpu.poll();
    }

    fn gpuIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        const device = self.pci_gpu orelse return;
        const gpu = self.gpu orelse return;
        device.transport.isr_status.queue_interrupt =
            gpu.transport.interrupt_status.used_buffer;
        device.transport.isr_status.config_change =
            gpu.transport.interrupt_status.config_change;
        self.gpu_irq_desired = level;
    }

    fn syncGpuIrq(self: *Machine) kvm.InterruptError!void {
        if (self.gpu_irq_desired == self.gpu_irq_injected) return;
        try self.vm.setIrqLine(pci_gpu_irq, self.gpu_irq_desired);
        self.gpu_irq_injected = self.gpu_irq_desired;
    }

    fn keyboardNotify(queue_index: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        syncInputQueue(self.pci_keyboard, self.keyboard, queue_index);
    }

    fn tabletNotify(queue_index: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        syncInputQueue(self.pci_tablet, self.tablet, queue_index);
    }

    fn syncInputQueue(
        device_optional: ?*pci.VirtioPciDevice,
        input_optional: ?*virtio.Input,
        queue_index: u32,
    ) void {
        const device = device_optional orelse return;
        const input = input_optional orelse return;
        if (queue_index >= device.transport.queues.len or
            queue_index >= input.transport.queues.len) return;
        const source = device.transport.queues[queue_index];
        const target = &input.transport.queues[queue_index];
        target.num = source.size;
        target.ready = source.enable;
        target.desc_addr = source.desc_addr;
        target.driver_addr = source.driver_addr;
        target.device_addr = source.device_addr;
        input.pollEvents();
    }

    fn keyboardIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        syncInputInterrupt(self.pci_keyboard, self.keyboard);
        self.keyboard_irq_desired = level;
    }

    fn tabletIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        syncInputInterrupt(self.pci_tablet, self.tablet);
        self.tablet_irq_desired = level;
    }

    fn syncInputInterrupt(
        device_optional: ?*pci.VirtioPciDevice,
        input_optional: ?*virtio.Input,
    ) void {
        const device = device_optional orelse return;
        const input = input_optional orelse return;
        device.transport.isr_status.queue_interrupt =
            input.transport.interrupt_status.used_buffer;
        device.transport.isr_status.config_change =
            input.transport.interrupt_status.config_change;
    }

    fn processInput(self: *Machine) void {
        if (self.keyboard) |input| input.pollEvents();
        if (self.tablet) |input| input.pollEvents();
    }

    fn syncInputIrqs(self: *Machine) kvm.InterruptError!void {
        if (self.keyboard_irq_desired != self.keyboard_irq_injected) {
            try self.vm.setIrqLine(pci_keyboard_irq, self.keyboard_irq_desired);
            self.keyboard_irq_injected = self.keyboard_irq_desired;
        }
        if (self.tablet_irq_desired != self.tablet_irq_injected) {
            try self.vm.setIrqLine(pci_tablet_irq, self.tablet_irq_desired);
            self.tablet_irq_injected = self.tablet_irq_desired;
        }
    }

    fn wakeInput(self: *Machine) void {
        self.input_wakeup.store(true, .release);
        const primary = &self.vcpus[0];
        const thread_id = primary.thread_id.load(.acquire);
        if (thread_id == 0 or thread_id == @as(u32, @intCast(std.Thread.getCurrentId()))) return;
        primary.vcpu.requestExit();
        kvm.interruptThread(thread_id);
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

    fn block2Irq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata orelse return));
        const device = self.pci_block2 orelse return;
        const block = self.block2 orelse return;
        device.transport.isr_status.queue_interrupt =
            block.transport.interrupt_status.used_buffer;
        device.transport.isr_status.config_change =
            block.transport.interrupt_status.config_change;
        self.block2_irq_desired = level;
    }

    fn syncBlock2Irq(self: *Machine) kvm.InterruptError!void {
        if (self.block2_irq_desired == self.block2_irq_injected) return;
        try self.vm.setIrqLine(pci_block2_irq, self.block2_irq_desired);
        self.block2_irq_injected = self.block2_irq_desired;
    }

    fn readBlockIsr(
        self: *Machine,
        device: *pci.VirtioPciDevice,
        block: *virtio.Block,
        access: kvm.MmioExit,
        offset: u32,
        irq_desired: *bool,
        fast_path: bool,
    ) void {
        if (fast_path) self.block_lock.lockUncancelable(global.io());
        defer if (fast_path) self.block_lock.unlock(global.io());

        const result = device.readBar0(offset, @intCast(access.data.len));
        writeIoValue(access.data, result);
        const current: u32 = @bitCast(block.transport.interrupt_status);
        block.transport.interrupt_status = @bitCast(current & ~result);
        if (@as(u32, @bitCast(block.transport.interrupt_status)) == 0) {
            irq_desired.* = false;
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

    fn cmosByte(memory_bytes: usize, index: u7) u8 {
        const kib: u64 = 1024;
        const mib: u64 = 1024 * kib;
        const size: u64 = @intCast(memory_bytes);
        const base_kib: u16 = @intCast(@min(size / kib, 640));
        const extended_kib: u16 = @intCast(@min(
            if (size > mib) (size - mib) / kib else 0,
            std.math.maxInt(u16),
        ));
        const large_chunks: u16 = @intCast(@min(
            if (size > 16 * mib) (size - 16 * mib) / (64 * kib) else 0,
            std.math.maxInt(u16),
        ));
        return switch (index) {
            0x14 => 0x02,
            0x15 => @truncate(base_kib),
            0x16 => @truncate(base_kib >> 8),
            0x17, 0x30 => @truncate(extended_kib),
            0x18, 0x31 => @truncate(extended_kib >> 8),
            0x34 => @truncate(large_chunks),
            0x35 => @truncate(large_chunks >> 8),
            0x3d => 0x23,
            0x5b, 0x5c, 0x5d => 0,
            else => 0,
        };
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

test "CMOS reports low memory without inventing RAM above four GiB" {
    try std.testing.expectEqual(@as(u8, 0x80), Machine.cmosByte(512 * 1024 * 1024, 0x15));
    try std.testing.expectEqual(@as(u8, 0x02), Machine.cmosByte(512 * 1024 * 1024, 0x16));
    try std.testing.expectEqual(@as(u8, 0x00), Machine.cmosByte(512 * 1024 * 1024, 0x34));
    try std.testing.expectEqual(@as(u8, 0x1f), Machine.cmosByte(512 * 1024 * 1024, 0x35));
    try std.testing.expectEqual(@as(u8, 0), Machine.cmosByte(512 * 1024 * 1024, 0x5b));
}

test "PCI chipset identifies i440FX and PIIX3 bridges" {
    const config = Machine.initChipsetConfig();
    try std.testing.expectEqual(
        @as(u32, 0x1237_8086),
        std.mem.readInt(u32, config[0][0][0..4], .little),
    );
    try std.testing.expectEqual(
        @as(u32, 0x7000_8086),
        std.mem.readInt(u32, config[1][0][0..4], .little),
    );
    try std.testing.expectEqual(
        @as(u32, 0x7113_8086),
        std.mem.readInt(u32, config[1][piix4_pm_function][0..4], .little),
    );
}
