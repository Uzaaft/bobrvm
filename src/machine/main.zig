//! Virtual Machine abstraction.
//!
//! Ties together:
//! - Hypervisor VM and vCPUs
//! - Memory layout
//! - Virtio devices
//! - Boot loader
//!
//! This is the core "machine" that runs guest code.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

const hypervisor = @import("../hypervisor/main.zig");
const virtio = @import("../virtio/main.zig");
const gic = @import("../gic/main.zig");
const icc = @import("../gic/icc.zig");
const pci = @import("../pci/main.zig");
const dtb = @import("dtb.zig");

const log = std.log.scoped(.machine);
const enable_debug_logs = builtin.mode == .Debug;

/// Thread-local machine pointer for guest memory access.
/// Set before vCPU threads start, used by getGuestMemoryWrapper.
threadlocal var current_machine: ?*Machine = null;

/// Memory layout for ARM64 Linux VM.
/// Based on QEMU virt machine layout for UEFI compatibility.
pub const MemoryLayout = struct {
    /// Pflash CODE region (UEFI firmware, read-only)
    /// QEMU virt uses 0x0000_0000 for first pflash
    pub const PFLASH_CODE_BASE: u64 = 0x0000_0000;
    pub const PFLASH_CODE_SIZE: u64 = 64 * 1024 * 1024; // 64MB

    /// Pflash VARS region (UEFI variables, read-write)
    /// QEMU virt uses 0x0400_0000 for second pflash
    pub const PFLASH_VARS_BASE: u64 = 0x0400_0000;
    pub const PFLASH_VARS_SIZE: u64 = 64 * 1024 * 1024; // 64MB

    /// Legacy alias for compatibility
    pub const FLASH_BASE: u64 = PFLASH_CODE_BASE;
    pub const FLASH_SIZE: u64 = PFLASH_CODE_SIZE;

    /// GIC (interrupt controller) - not used directly but reserved
    pub const GIC_DIST_BASE: u64 = 0x0800_0000;
    pub const GIC_REDIST_BASE: u64 = 0x080A_0000;

    /// UART (PL011 compatible)
    pub const UART_BASE: u64 = 0x0900_0000;
    pub const UART_SIZE: u64 = 0x1000;

    /// RTC
    pub const RTC_BASE: u64 = 0x0901_0000;
    pub const RTC_SIZE: u64 = 0x1000;

    /// Virtio MMIO devices (16 slots)
    pub const VIRTIO_BASE: u64 = 0x0A00_0000;
    pub const VIRTIO_SIZE: u64 = 0x200; // Per device
    pub const VIRTIO_COUNT: u64 = 16;

    /// PCIe ECAM base (QEMU virt compatible)
    pub const ECAM_BASE: u64 = 0x3c00_0000;
    pub const ECAM_SIZE: u64 = 64 * 1024 * 1024; // 64MB

    /// PCIe MMIO region
    pub const PCI_MMIO_BASE: u64 = 0x1000_0000;
    pub const PCI_MMIO_SIZE: u64 = 0x2c00_0000; // 768MB

    /// RAM starts at 1GB
    pub const RAM_BASE: u64 = 0x4000_0000;

    /// Kernel load address (RAM + 2MB, must be 2MB aligned for ARM64)
    pub const KERNEL_BASE: u64 = RAM_BASE + 0x0020_0000;

    /// Initrd load address (after kernel, aligned to 1MB)
    pub const INITRD_BASE: u64 = RAM_BASE + 0x0800_0000; // RAM + 128MB

    /// DTB load address (end of RAM - 2MB)
    pub fn dtbBase(ram_size: u64) u64 {
        return RAM_BASE + ram_size - 2 * 1024 * 1024;
    }

    /// Get virtio device MMIO base for a given slot.
    pub fn virtioBase(slot: u32) u64 {
        assert(slot < VIRTIO_COUNT);
        return VIRTIO_BASE + @as(u64, slot) * VIRTIO_SIZE;
    }
};

/// Machine configuration.
pub const MachineConfig = struct {
    /// RAM size in bytes.
    ram_size: u64 = 512 * 1024 * 1024, // 512MB default

    /// Number of vCPUs.
    vcpu_count: u8 = 1,

    /// Path to UEFI firmware (e.g., QEMU_EFI.fd). If set, boots via firmware.
    firmware_path: ?[]const u8 = null,

    /// Path to UEFI variables file. Created if doesn't exist.
    vars_path: ?[]const u8 = null,

    /// Path to kernel (Image file). Used for direct boot (no firmware).
    kernel_path: ?[]const u8 = null,

    /// Path to initrd.
    initrd_path: ?[]const u8 = null,

    /// Kernel command line.
    cmdline: []const u8 = "console=hvc0 earlycon=pl011,0x09000000",

    /// Path to primary disk image (virtio slot 1).
    disk_path: ?[]const u8 = null,

    /// Whether the primary disk image is read-only.
    disk_read_only: bool = false,

    /// Path to secondary disk image (virtio slot 2, typically ISO).
    disk2_path: ?[]const u8 = null,

    /// Whether the secondary disk is read-only (typically true for ISO).
    disk2_read_only: bool = true,

    /// Count how many block devices are configured.
    pub fn blockDeviceCount(self: MachineConfig) u8 {
        var count: u8 = 0;
        if (self.disk_path != null) count += 1;
        if (self.disk2_path != null) count += 1;
        return count;
    }

    /// Check if firmware boot mode is enabled.
    pub fn isFirmwareBoot(self: MachineConfig) bool {
        if (self.firmware_path) |path| {
            return path.len > 0;
        }
        return false;
    }
};

/// Virtual Machine instance.
pub const Machine = struct {
    alloc: Allocator,
    config: MachineConfig,

    /// Hypervisor VM.
    hv_vm: ?*hypervisor.VM = null,

    /// vCPUs.
    vcpus: std.ArrayListUnmanaged(*hypervisor.Vcpu),

    /// VM runner (manages vCPU threads).
    runner: ?hypervisor.VMRunner = null,

    /// Guest RAM (host-mapped).
    ram: ?[]align(4096) u8 = null,

    /// Pflash CODE region (UEFI firmware, host-mapped).
    pflash_code: ?[]align(4096) u8 = null,

    /// Pflash VARS region (UEFI variables, host-mapped).
    pflash_vars: ?[]align(4096) u8 = null,

    /// Virtio console device.
    console: ?*virtio.Console = null,

    /// Virtio block device (primary, slot 1).
    block: ?*virtio.Block = null,

    /// Virtio block device (secondary, slot 2, typically ISO).
    block2: ?*virtio.Block = null,

    /// UART device (PL011 for earlycon).
    uart: ?*virtio.Uart = null,

    /// GIC (interrupt controller).
    gic_device: ?*gic.Gic = null,

    /// ICC (CPU interface) handler.
    icc_handler: ?*icc.IccHandler = null,

    /// PCIe ECAM host bridge (for UEFI boot).
    ecam_host: ?*pci.EcamHost = null,

    /// Virtio PCI block device (for UEFI boot).
    pci_block: ?*pci.VirtioPciDevice = null,

    /// Console output callback.
    console_output: ?*const fn ([]const u8, ?*anyopaque) void = null,
    console_userdata: ?*anyopaque = null,

    /// Initrd tracking (for DTB generation).
    initrd_start: u64 = 0,
    initrd_end: u64 = 0,

    /// Running state.
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Pending IRQ flag (set by GIC when interrupt should be injected).
    pending_irq: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Set when the guest EOIs the vtimer PPI; the vCPU loop unmasks HVF's
    /// vtimer so it can fire again.
    vtimer_unmask: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const Error = hypervisor.Error || Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.WriteError || std.Thread.SpawnError || error{
        KernelTooLarge,
        InitrdTooLarge,
        FirmwareTooLarge,
    };

    pub fn init(alloc: Allocator, config: MachineConfig) Error!*Machine {
        log.info("initializing machine: {}MB RAM, {} vCPUs", .{
            config.ram_size / (1024 * 1024),
            config.vcpu_count,
        });

        const machine = try alloc.create(Machine);
        errdefer alloc.destroy(machine);

        machine.* = .{
            .alloc = alloc,
            .config = config,
            .vcpus = .{},
        };

        return machine;
    }

    pub fn deinit(self: *Machine) void {
        self.stop();

        if (self.console) |console| {
            console.deinit();
        }

        if (self.block) |block| {
            block.deinit();
        }

        if (self.block2) |block2| {
            block2.deinit();
        }

        if (self.uart) |uart| {
            self.alloc.destroy(uart);
            self.uart = null;
        }

        if (self.icc_handler) |handler| {
            handler.deinit(self.alloc);
            self.icc_handler = null;
        }

        if (self.gic_device) |gic_dev| {
            gic_dev.deinit();
            self.gic_device = null;
        }

        if (self.pci_block) |pci_blk| {
            pci_blk.deinit();
            self.pci_block = null;
        }

        if (self.ecam_host) |ecam| {
            ecam.deinit();
            self.ecam_host = null;
        }

        if (self.runner) |*runner| {
            runner.deinit();
        }

        // Clean up hypervisor (vCPUs then VM)
        self.cleanupHypervisor();
        self.vcpus.deinit(self.alloc);

        self.alloc.destroy(self);
    }

    /// Inject host input into the guest consoles. Thread-safe: buffers
    /// are drained on the vCPU thread.
    pub fn injectConsoleInput(self: *Machine, data: []const u8) void {
        if (self.uart) |uart| uart.queueInput(data);
        if (self.console) |console| console.queueInput(data) catch {};
        self.pending_irq.store(true, .release);
    }

    /// Set console output callback.
    pub fn setConsoleOutput(
        self: *Machine,
        callback: *const fn ([]const u8, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.console_output = callback;
        self.console_userdata = userdata;
    }

    /// Start the machine.
    pub fn start(self: *Machine) Error!void {
        if (self.running.load(.acquire)) return;

        log.info("starting machine", .{});

        // Create hypervisor VM
        self.hv_vm = try hypervisor.VM.create(self.alloc);
        errdefer self.cleanupHypervisor();

        const vm = self.hv_vm.?;

        // Map pflash regions if firmware boot
        if (self.config.isFirmwareBoot()) {
            try self.mapPflashRegions(vm);
            try self.loadFirmware();
        }

        // Map guest RAM
        self.ram = try vm.map(
            MemoryLayout.RAM_BASE,
            self.config.ram_size,
            hypervisor.MEM_READ_WRITE_EXEC,
        );
        log.debug("mapped RAM: 0x{x} - 0x{x}", .{
            MemoryLayout.RAM_BASE,
            MemoryLayout.RAM_BASE + self.config.ram_size,
        });

        // Load kernel/initrd only for direct boot (not firmware)
        if (!self.config.isFirmwareBoot()) {
            if (self.config.kernel_path) |kernel_path| {
                try self.loadKernel(kernel_path);
            }
            if (self.config.initrd_path) |initrd_path| {
                try self.loadInitrd(initrd_path);
            }
        }

        // Generate and load DTB
        try self.generateDtb();

        // Initialize GIC (interrupt controller)
        try self.initGic();

        // Initialize virtio devices
        try self.initVirtioDevices();

        // Set current machine for guest memory access (used by vCPU threads)
        current_machine = self;

        // Create runner
        self.runner = hypervisor.VMRunner.init(self.alloc, vm);

        // Register MMIO handlers
        try self.registerMmioHandlers();

        // Add vCPU slots - vCPUs will be created on their own threads
        // (Apple Hypervisor requires hv_vcpu_create on the same thread as hv_vcpu_run)
        for (0..self.config.vcpu_count) |_| {
            try self.runner.?.addVcpuSlot(vcpuSetupCallback, self);
        }

        // Start execution (vCPUs created on their threads)
        try self.runner.?.start();

        self.running.store(true, .release);
        log.info("machine started", .{});
    }

    /// Callback to set up vCPU initial state.
    /// Called on each vCPU's thread after creation.
    fn vcpuSetupCallback(vcpu: *hypervisor.Vcpu, id: u32, userdata: ?*anyopaque) hypervisor.Vcpu.Error!void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        try self.setupVcpuState(vcpu, id);
    }

    /// Clean up hypervisor resources.
    /// VM.destroy() handles vCPU cleanup internally.
    fn cleanupHypervisor(self: *Machine) void {
        // Clear our vcpu references (VM.destroy handles actual cleanup)
        self.vcpus.clearRetainingCapacity();

        // Destroy the VM (this also destroys vCPUs and unmaps memory)
        if (self.hv_vm) |vm| {
            vm.destroy();
            self.hv_vm = null;
        }

        self.ram = null;
    }

    /// Stop the machine.
    pub fn stop(self: *Machine) void {
        if (!self.running.load(.acquire)) return;

        log.info("stopping machine", .{});

        if (self.runner) |*runner| {
            runner.stop();
        }

        // Clear current machine pointer
        current_machine = null;

        self.running.store(false, .release);
        log.info("machine stopped", .{});
    }

    /// Kick a specific vCPU to wake it from WFI/sleep.
    /// Injects an IRQ and forces an exit from hv_vcpu_run.
    pub fn kickVcpu(self: *Machine, vcpu_id: u32) void {
        if (self.runner) |*runner| {
            runner.kickVcpu(vcpu_id);
        }
    }

    /// Force all vCPUs to exit from hv_vcpu_run (for debugging).
    pub fn forceExitAllVcpus(self: *Machine) void {
        if (self.runner) |*runner| {
            runner.forceExitAll();
        }
    }

    /// Start and run the machine synchronously on the current thread.
    /// vCPU is created and run on the same thread (required by Apple Hypervisor).
    pub fn startSync(self: *Machine) Error!void {
        log.info("starting machine (sync)", .{});

        // Create hypervisor VM
        self.hv_vm = try hypervisor.VM.create(self.alloc);
        errdefer self.cleanupHypervisor();

        const vm = self.hv_vm.?;

        // Map pflash regions if firmware boot
        log.debug("isFirmwareBoot={}, firmware_path={?s}", .{
            self.config.isFirmwareBoot(),
            self.config.firmware_path,
        });
        if (self.config.isFirmwareBoot()) {
            try self.mapPflashRegions(vm);
            try self.loadFirmware();
        }

        // Map guest RAM
        self.ram = try vm.map(
            MemoryLayout.RAM_BASE,
            self.config.ram_size,
            hypervisor.MEM_READ_WRITE_EXEC,
        );
        log.debug("mapped RAM: 0x{x} - 0x{x}", .{
            MemoryLayout.RAM_BASE,
            MemoryLayout.RAM_BASE + self.config.ram_size,
        });

        // Load kernel/initrd only for direct boot (not firmware)
        if (!self.config.isFirmwareBoot()) {
            if (self.config.kernel_path) |kernel_path| {
                try self.loadKernel(kernel_path);
            }
            if (self.config.initrd_path) |initrd_path| {
                try self.loadInitrd(initrd_path);
            }
        }

        // Generate and load DTB
        try self.generateDtb();

        // Initialize GIC (interrupt controller)
        try self.initGic();

        // Initialize virtio devices
        try self.initVirtioDevices();

        // Set current machine for guest memory access
        current_machine = self;

        // Create vCPU on THIS thread (required by Apple Hypervisor)
        const vcpu = try vm.createVcpu();
        log.debug("created vCPU on main thread", .{});

        // Set up initial vCPU state (as vCPU 0 - the boot CPU)
        try self.setupVcpuState(vcpu, 0);

        self.running.store(true, .release);
        log.info("machine started, running vCPU loop", .{});

        // Run vCPU loop on this thread
        self.runVcpuLoop(vcpu) catch |err| {
            log.err("vCPU loop error: {}", .{err});
        };

        self.running.store(false, .release);
        current_machine = null;
        log.info("machine stopped", .{});
    }

    fn runVcpuLoop(self: *Machine, vcpu: *hypervisor.Vcpu) !void {
        var exit_count: u64 = 0;

        while (self.running.load(.acquire)) {
            // Check for pending IRQ before running
            if (self.pending_irq.swap(false, .acq_rel)) {
                try vcpu.setPendingInterrupt(.irq, true);
            }

            // Unmask the HVF vtimer once the guest has EOI'd PPI 27.
            if (self.vtimer_unmask.swap(false, .acq_rel)) {
                try vcpu.setVTimerMask(false);
            }

            // Poll virtio console queues on every exit (guest may use
            // notification suppression; host input arrives asynchronously).
            if (self.console) |console| {
                console.pollTransmit();
                console.pollReceive();
            }

            const exit_info = try vcpu.run();
            exit_count += 1;

            switch (exit_info.reason) {
                .canceled => {
                    log.info("vCPU canceled", .{});
                    break;
                },
                .exception => {
                    const ec = exit_info.exceptionClass();
                    switch (ec) {
                        .data_abort_lower, .data_abort_same => {
                            try self.handleMmio(vcpu, exit_info);
                        },
                        .wf_trapped => {
                            // Poll console queues while halted
                            if (self.console) |console| {
                                console.pollTransmit();
                                console.pollReceive();
                            }
                            try vcpu.advancePC(exit_info);
                            std.Thread.sleep(1_000_000); // 1ms
                        },
                        .hvc_aarch64, .smc_aarch64 => {
                            try self.handlePsci(vcpu, exit_info);
                        },
                        .msr_mrs_system => {
                            try self.handleSysReg(vcpu, exit_info);
                        },
                        else => {
                            log.warn("unhandled exception class: 0x{x}", .{@intFromEnum(ec)});
                            log.warn("syndrome: 0x{x}, VA: 0x{x}, PA: 0x{x}", .{
                                exit_info.syndrome,
                                exit_info.virtual_address,
                                exit_info.physical_address,
                            });
                            break;
                        },
                    }
                },
                .vtimer_activated => {
                    // Pend the virtual timer PPI (intid 27). HVF masks the
                    // vtimer on this exit; we unmask when the guest EOIs.
                    if (self.gic_device) |gic_dev| {
                        gic_dev.setPpiPending(0, 27, true);
                    }
                    try vcpu.setPendingInterrupt(.irq, true);
                },
                .unknown => {
                    log.warn("unknown exit reason", .{});
                    break;
                },
            }

            if (exit_count % 1_000_000 == 0) {
                log.debug("vCPU exits: {}", .{exit_count});
            }
        }

        log.info("vCPU loop finished after {} exits", .{exit_count});
    }

    fn handleMmio(self: *Machine, vcpu: *hypervisor.Vcpu, info: hypervisor.ExitInfo) !void {
        const iss = info.iss();
        const is_write = info.isWrite();
        const sas = info.accessSize();
        const size: u8 = @as(u8, 1) << sas;
        const srt: u5 = @truncate(iss >> 16);
        const addr = info.physical_address;

        // Note: ECAM-range logging disabled to reduce noise during UEFI boot

        // GIC Distributor (GICD)
        const gic_dist_end = MemoryLayout.GIC_DIST_BASE + 0x10000;
        if (addr >= MemoryLayout.GIC_DIST_BASE and addr < gic_dist_end) {
            if (self.gic_device) |gic_dev| {
                const offset = addr - MemoryLayout.GIC_DIST_BASE;
                if (is_write) {
                    const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                    gic_dev.distWrite(offset, size, value);
                } else {
                    const value = gic_dev.distRead(offset, size);
                    if (srt != 31) {
                        try vcpu.setReg(@enumFromInt(srt), value);
                    }
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // GIC Redistributor (GICR) - 128KB per CPU
        const gicr_size = @as(u64, gic.GICR_FRAME_SIZE) * self.config.vcpu_count;
        const gic_redist_end = MemoryLayout.GIC_REDIST_BASE + gicr_size;
        if (addr >= MemoryLayout.GIC_REDIST_BASE and addr < gic_redist_end) {
            if (self.gic_device) |gic_dev| {
                const offset = addr - MemoryLayout.GIC_REDIST_BASE;
                if (is_write) {
                    const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                    gic_dev.redistWrite(offset, size, value);
                } else {
                    const value = gic_dev.redistRead(offset, size);
                    if (srt != 31) {
                        try vcpu.setReg(@enumFromInt(srt), value);
                    }
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // UART (PL011)
        if (addr >= MemoryLayout.UART_BASE and addr < MemoryLayout.UART_BASE + MemoryLayout.UART_SIZE) {
            if (self.uart) |uart| {
                const offset: u12 = @truncate(addr - MemoryLayout.UART_BASE);
                if (is_write) {
                    const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                    uart.write(offset, @truncate(value));
                } else {
                    const value = uart.read(offset);
                    if (srt != 31) {
                        try vcpu.setReg(@enumFromInt(srt), value);
                    }
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // Virtio console
        if (addr >= MemoryLayout.virtioBase(0) and addr < MemoryLayout.virtioBase(0) + MemoryLayout.VIRTIO_SIZE) {
            if (self.console) |console| {
                const offset: u12 = @truncate(addr - MemoryLayout.virtioBase(0));
                if (is_write) {
                    const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                    console.write(offset, @truncate(value));
                } else {
                    const value = console.read(offset);
                    if (srt != 31) {
                        try vcpu.setReg(@enumFromInt(srt), value);
                    }
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // Virtio block devices (slots 1 and 2)
        inline for (.{ .{ 1, "block" }, .{ 2, "block2" } }) |slot| {
            const base = MemoryLayout.virtioBase(slot[0]);
            if (addr >= base and addr < base + MemoryLayout.VIRTIO_SIZE) {
                if (@field(self, slot[1])) |blk| {
                    const offset: u12 = @truncate(addr - base);
                    if (is_write) {
                        const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                        blk.write(offset, @truncate(value));
                    } else {
                        const value = blk.read(offset);
                        if (srt != 31) {
                            try vcpu.setReg(@enumFromInt(srt), value);
                        }
                    }
                }
                try vcpu.advancePC(info);
                return;
            }
        }

        // PCIe ECAM (configuration space)
        if (addr >= MemoryLayout.ECAM_BASE and addr < MemoryLayout.ECAM_BASE + MemoryLayout.ECAM_SIZE) {
            const ecam_addr = pci.EcamAddr.decode(addr);

            if (enable_debug_logs and ecam_addr.bus == 0 and ecam_addr.device == 0 and ecam_addr.reg < 0x40) {
                log.debug("ECAM access: bus={} dev={} func={} reg=0x{x} pci_block={}", .{
                    ecam_addr.bus, @as(u8, ecam_addr.device), @as(u8, ecam_addr.function), ecam_addr.reg, self.pci_block != null,
                });
            }

            // For device 0 (virtio-pci-blk), forward to VirtioPciDevice directly
            if (ecam_addr.bus == 0 and ecam_addr.device == 0 and ecam_addr.function == 0) {
                if (self.pci_block) |pci_blk| {
                    if (is_write) {
                        const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                        if (enable_debug_logs) {
                            log.debug("ECAM 00:00.0 write reg=0x{x} size={} value=0x{x}", .{ ecam_addr.reg, size, value });
                        }
                        pci_blk.writeConfig(ecam_addr.reg, size, value);
                        // Sync config back to ECAM host for reads
                        if (self.ecam_host) |ecam| {
                            const idx: usize = 0; // device 0, function 0
                            @memcpy(&ecam.devices[idx].config, &pci_blk.config);
                        }
                    } else {
                        const value = pci_blk.readConfig(ecam_addr.reg, size);
                        if (enable_debug_logs and ecam_addr.reg < 0x40) {
                            log.debug("ECAM 00:00.0 read reg=0x{x} size={} -> 0x{x}", .{ ecam_addr.reg, size, value });
                        }
                        if (srt != 31) {
                            try vcpu.setReg(@enumFromInt(srt), value);
                        }
                    }
                    try vcpu.advancePC(info);
                    return;
                }
            }

            // Other devices: use ECAM host
            if (self.ecam_host) |ecam| {
                if (is_write) {
                    const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                    ecam.write(addr, size, value);
                } else {
                    const value = ecam.read(addr, size);
                    if (srt != 31) {
                        try vcpu.setReg(@enumFromInt(srt), value);
                    }
                }
            } else {
                // No ECAM host - return 0xFFFFFFFF for reads (no device)
                if (!is_write and srt != 31) {
                    try vcpu.setReg(@enumFromInt(srt), 0xFFFFFFFF);
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // PCI MMIO region (BAR space) - virtio-pci devices
        if (addr >= MemoryLayout.PCI_MMIO_BASE and addr < MemoryLayout.PCI_MMIO_BASE + MemoryLayout.PCI_MMIO_SIZE) {
            if (self.pci_block) |pci_blk| {
                const bar0_addr: u64 = pci_blk.getBar0Addr();
                const bar0_size: u64 = pci.virtio_pci.BAR0_SIZE;
                if (bar0_addr != 0 and addr >= bar0_addr and addr < bar0_addr + bar0_size) {
                    const offset: u32 = @truncate(addr - bar0_addr);
                    if (is_write) {
                        const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                        pci_blk.writeBar0(offset, size, @truncate(value));
                        if (enable_debug_logs) {
                            log.debug("PCI BAR0 write: offset=0x{x} size={} value=0x{x}", .{ offset, size, value });
                        }
                    } else {
                        const value = pci_blk.readBar0(offset, size);
                        if (srt != 31) {
                            try vcpu.setReg(@enumFromInt(srt), value);
                        }
                        if (enable_debug_logs) {
                            log.debug("PCI BAR0 read: offset=0x{x} size={} -> 0x{x}", .{ offset, size, value });
                        }
                    }
                    try vcpu.advancePC(info);
                    return;
                }
            }
            if (enable_debug_logs) {
                log.debug("unhandled PCI MMIO {s} at 0x{x}", .{ if (is_write) "write" else "read", addr });
            }
            if (!is_write and srt != 31) {
                try vcpu.setReg(@enumFromInt(srt), 0xFFFFFFFF);
            }
            try vcpu.advancePC(info);
            return;
        }

        if (enable_debug_logs) {
            log.debug("unhandled MMIO {s} at 0x{x}", .{ if (is_write) "write" else "read", addr });
        }
        try vcpu.advancePC(info);
    }

    fn handlePsci(self: *Machine, vcpu: *hypervisor.Vcpu, _: hypervisor.ExitInfo) !void {
        const fn_id = try vcpu.getReg(.x0);

        const result: u64 = switch (fn_id) {
            // PSCI_VERSION - return v1.0
            0x84000000 => 0x00010000,

            // PSCI_FEATURES
            0x8400000A => blk: {
                const feature = try vcpu.getReg(.x1);
                break :blk switch (feature) {
                    0x84000000, 0x84000008, 0x84000009, 0x8400000A => 0,
                    else => 0xFFFFFFFF,
                };
            },

            // PSCI_SYSTEM_OFF
            0x84000008 => blk: {
                log.info("PSCI SYSTEM_OFF", .{});
                self.running.store(false, .release);
                break :blk 0;
            },

            // PSCI_SYSTEM_RESET
            0x84000009 => blk: {
                log.info("PSCI SYSTEM_RESET", .{});
                self.running.store(false, .release);
                break :blk 0;
            },

            else => blk: {
                log.debug("unknown PSCI fn=0x{x}", .{fn_id});
                break :blk 0xFFFFFFFF;
            },
        };

        try vcpu.setReg(.x0, result);
        // NOTE: Do NOT advance PC - for HVC/SMC, PC already points past the instruction
    }

    fn handleSysReg(self: *Machine, vcpu: *hypervisor.Vcpu, info: hypervisor.ExitInfo) !void {
        const iss = info.iss();
        const decoded = icc.IccHandler.decodeIss(iss);

        // Check if this is an ICC register
        if (self.icc_handler) |handler| {
            const cpu_id: u8 = 0; // TODO: get from vcpu

            if (decoded.is_read) {
                const value = handler.read(cpu_id, decoded.reg);
                if (decoded.rt != 31) {
                    try vcpu.setReg(@enumFromInt(decoded.rt), value);
                }
            } else {
                const value = if (decoded.rt == 31) 0 else try vcpu.getReg(@enumFromInt(decoded.rt));
                handler.write(cpu_id, decoded.reg, value);
            }
        }

        try vcpu.advancePC(info);
    }

    // =========================================================================
    // Private Methods
    // =========================================================================

    fn loadKernel(self: *Machine, path: []const u8) !void {
        log.info("loading kernel: {s}", .{path});

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const kernel_size = stat.size;

        if (kernel_size > self.config.ram_size / 2) {
            log.err("kernel too large: {} bytes", .{kernel_size});
            return error.KernelTooLarge;
        }

        // Calculate offset into RAM
        const ram_offset = MemoryLayout.KERNEL_BASE - MemoryLayout.RAM_BASE;
        const ram = self.ram.?;

        // Read kernel into RAM
        const bytes_read = try file.readAll(ram[ram_offset..]);
        log.info("loaded kernel: {} bytes at 0x{x}", .{ bytes_read, MemoryLayout.KERNEL_BASE });
    }

    fn loadInitrd(self: *Machine, path: []const u8) !void {
        log.info("loading initrd: {s}", .{path});

        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const initrd_size = stat.size;

        // Calculate offset into RAM
        const ram_offset = MemoryLayout.INITRD_BASE - MemoryLayout.RAM_BASE;
        const ram = self.ram.?;

        if (ram_offset + initrd_size > ram.len) {
            log.err("initrd too large: {} bytes", .{initrd_size});
            return error.InitrdTooLarge;
        }

        // Read initrd into RAM
        const bytes_read = try file.readAll(ram[ram_offset..]);

        // Track initrd location for DTB
        self.initrd_start = MemoryLayout.INITRD_BASE;
        self.initrd_end = MemoryLayout.INITRD_BASE + bytes_read;

        log.info("loaded initrd: {} bytes at 0x{x}-0x{x}", .{
            bytes_read,
            self.initrd_start,
            self.initrd_end,
        });
    }

    fn mapPflashRegions(self: *Machine, vm: *hypervisor.VM) !void {
        // Map CODE region (read-execute for firmware)
        self.pflash_code = try vm.map(
            MemoryLayout.PFLASH_CODE_BASE,
            MemoryLayout.PFLASH_CODE_SIZE,
            hypervisor.MEM_READ_EXEC,
        );
        log.debug("mapped pflash CODE: 0x{x} - 0x{x}", .{
            MemoryLayout.PFLASH_CODE_BASE,
            MemoryLayout.PFLASH_CODE_BASE + MemoryLayout.PFLASH_CODE_SIZE,
        });

        // Map VARS region (read-write for UEFI variables)
        self.pflash_vars = try vm.map(
            MemoryLayout.PFLASH_VARS_BASE,
            MemoryLayout.PFLASH_VARS_SIZE,
            hypervisor.MEM_READ_WRITE,
        );
        log.debug("mapped pflash VARS: 0x{x} - 0x{x}", .{
            MemoryLayout.PFLASH_VARS_BASE,
            MemoryLayout.PFLASH_VARS_BASE + MemoryLayout.PFLASH_VARS_SIZE,
        });
    }

    fn loadFirmware(self: *Machine) !void {
        const firmware_path = self.config.firmware_path orelse return;
        log.info("loading firmware: {s}", .{firmware_path});

        const file = try std.fs.cwd().openFile(firmware_path, .{});
        defer file.close();

        const stat = try file.stat();
        const firmware_size = stat.size;

        if (firmware_size > MemoryLayout.PFLASH_CODE_SIZE) {
            log.err("firmware too large: {} bytes (max {})", .{ firmware_size, MemoryLayout.PFLASH_CODE_SIZE });
            return error.FirmwareTooLarge;
        }

        const pflash = self.pflash_code.?;

        // Zero-fill the pflash region first (firmware may be smaller than region)
        @memset(pflash, 0xFF); // Flash is typically 0xFF when erased

        // Read firmware into pflash CODE region
        const bytes_read = try file.readAll(pflash);
        log.info("loaded firmware: {} bytes at 0x{x}", .{ bytes_read, MemoryLayout.PFLASH_CODE_BASE });

        // Load or create VARS file
        try self.loadOrCreateVars();
    }

    fn loadOrCreateVars(self: *Machine) !void {
        const pflash_vars = self.pflash_vars.?;

        // Initialize VARS region to 0xFF (erased flash)
        @memset(pflash_vars, 0xFF);

        // If vars_path is specified, try to load existing vars
        if (self.config.vars_path) |vars_path| {
            const file = std.fs.cwd().openFile(vars_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    log.info("UEFI vars file not found, will be created on shutdown: {s}", .{vars_path});
                    return;
                }
                return err;
            };
            defer file.close();

            const bytes_read = try file.readAll(pflash_vars);
            log.info("loaded UEFI vars: {} bytes from {s}", .{ bytes_read, vars_path });
        }
    }

    fn generateDtb(self: *Machine) !void {
        var builder = dtb.DtbBuilder.init(self.alloc);
        defer builder.deinit();

        // Count virtio devices: console (slot 0) + block devices (slots 1, 2)
        const virtio_count: u8 = 1 + self.config.blockDeviceCount();

        const config = dtb.DtbConfig{
            .ram_base = MemoryLayout.RAM_BASE,
            .ram_size = self.config.ram_size,
            .vcpu_count = self.config.vcpu_count,
            .cmdline = self.config.cmdline,
            .initrd_start = self.initrd_start,
            .initrd_end = self.initrd_end,
            .virtio_count = virtio_count,
            .virtio_base = MemoryLayout.VIRTIO_BASE,
            .virtio_size = MemoryLayout.VIRTIO_SIZE,
            .uart_base = MemoryLayout.UART_BASE,
            .gic_dist_base = MemoryLayout.GIC_DIST_BASE,
            .gic_redist_base = MemoryLayout.GIC_REDIST_BASE,
            .pcie_enabled = self.config.isFirmwareBoot(),
            .pcie_ecam_base = MemoryLayout.ECAM_BASE,
            .pcie_ecam_size = MemoryLayout.ECAM_SIZE,
            .pcie_mmio_base = MemoryLayout.PCI_MMIO_BASE,
            .pcie_mmio_size = MemoryLayout.PCI_MMIO_SIZE,
        };

        const dtb_data = try builder.generate(config);
        defer self.alloc.free(dtb_data);

        // Copy DTB to RAM at dtbBase
        const dtb_addr = MemoryLayout.dtbBase(self.config.ram_size);
        const ram_offset = dtb_addr - MemoryLayout.RAM_BASE;
        const ram = self.ram.?;

        if (ram_offset + dtb_data.len > ram.len) {
            log.err("DTB too large or wrong offset", .{});
            return error.InitrdTooLarge; // Reuse error
        }

        @memcpy(ram[ram_offset..][0..dtb_data.len], dtb_data);
        log.info("loaded DTB: {} bytes at 0x{x}", .{ dtb_data.len, dtb_addr });
    }

    fn initGic(self: *Machine) !void {
        // Initialize GIC
        self.gic_device = try gic.Gic.init(self.alloc, self.config.vcpu_count);
        // Set up IRQ injection callback
        self.gic_device.?.setInjectCallback(gicInjectIrqCallback, self);
        self.gic_device.?.setEoiCallback(gicEoiCallback, self);
        log.debug("initialized GIC at 0x{x}", .{MemoryLayout.GIC_DIST_BASE});

        // Initialize ICC handler
        self.icc_handler = try icc.IccHandler.init(self.alloc, self.gic_device.?, self.config.vcpu_count);
        log.debug("initialized ICC handler", .{});
    }

    fn initVirtioDevices(self: *Machine) !void {
        // Initialize UART (PL011 for earlycon)
        self.uart = try self.alloc.create(virtio.Uart);
        self.uart.?.* = virtio.Uart.init();
        if (self.console_output) |cb| {
            self.uart.?.setOutputCallback(cb, self.console_userdata);
        }
        self.uart.?.setIrqCallback(uartIrqCallback, self);
        log.debug("initialized UART at 0x{x}", .{MemoryLayout.UART_BASE});

        // Initialize console (slot 0)
        self.console = try virtio.Console.init(self.alloc);
        if (self.console_output) |cb| {
            self.console.?.setOutputCallback(cb, self.console_userdata);
        }
        self.console.?.setGuestMemory(getGuestMemoryWrapper);
        // Set up IRQ callback - virtio console is SPI 32 (intid 32)
        self.console.?.transport.setIrqCallback(consoleIrqCallback, self);
        log.debug("initialized virtio-console at 0x{x}", .{MemoryLayout.virtioBase(0)});

        // Initialize primary block device (slot 1) if disk_path is set
        if (self.config.disk_path) |disk_path| {
            self.block = try virtio.Block.init(self.alloc);
            try self.block.?.attachDisk(disk_path, self.config.disk_read_only);
            self.block.?.setGuestMemory(getGuestMemoryWrapper);
            self.block.?.transport.setIrqCallback(blk1IrqCallback, self);
            log.debug("initialized virtio-blk at 0x{x} with disk: {s}", .{
                MemoryLayout.virtioBase(1),
                disk_path,
            });
        }

        // Initialize secondary block device (slot 2) if disk2_path is set (typically ISO)
        if (self.config.disk2_path) |disk2_path| {
            log.debug("attaching disk2: {s} (len={})", .{ disk2_path, disk2_path.len });
            self.block2 = try virtio.Block.init(self.alloc);
            self.block2.?.attachDisk(disk2_path, self.config.disk2_read_only) catch |err| {
                log.err("failed to attach disk2 '{s}': {}", .{ disk2_path, err });
                return err;
            };
            self.block2.?.setGuestMemory(getGuestMemoryWrapper);
            self.block2.?.transport.setIrqCallback(blk2IrqCallback, self);
            log.debug("initialized virtio-blk2 at 0x{x} with disk: {s} (read-only: {})", .{
                MemoryLayout.virtioBase(2),
                disk2_path,
                self.config.disk2_read_only,
            });
        }

        // Initialize PCIe ECAM host bridge for UEFI boot
        if (self.config.isFirmwareBoot()) {
            try self.initEcam();
        }
    }

    fn initEcam(self: *Machine) !void {
        self.ecam_host = try pci.EcamHost.init(self.alloc);
        log.debug("initialized PCIe ECAM at 0x{x}-0x{x}", .{
            MemoryLayout.ECAM_BASE,
            MemoryLayout.ECAM_BASE + MemoryLayout.ECAM_SIZE,
        });

        // Create virtio-pci block device if disk is configured
        if (self.config.disk_path) |_| {
            // Create virtio-pci device (device_id=2 for block)
            // Use virtio-blk config size (56 bytes for basic config)
            const blk_features = virtio.blk.Features.SIZE_MAX |
                virtio.blk.Features.SEG_MAX |
                virtio.blk.Features.BLK_SIZE |
                virtio.blk.Features.FLUSH;

            self.pci_block = try pci.VirtioPciDevice.init(
                self.alloc,
                2, // block device
                0x0002, // subsystem ID
                blk_features,
                1, // num_queues
                @sizeOf(virtio.blk.Config), // device config size
            );

            // Set BAR0 address in PCI MMIO region
            const bar0_addr: u32 = @truncate(MemoryLayout.PCI_MMIO_BASE);
            self.pci_block.?.bar0_addr = bar0_addr;

            // Copy block config from the MMIO block device if available
            if (self.block) |blk| {
                const config_bytes = std.mem.asBytes(&blk.config);
                self.pci_block.?.transport.setDeviceConfig(config_bytes);
            }

            // Set up notification callback
            self.pci_block.?.transport.setNotifyCallback(pciBlockNotify, self);
            self.pci_block.?.transport.setIrqCallback(pciBlockIrq, self);

            // Register with ECAM host at device 0, function 0
            // Create a PciDevice wrapper that forwards to our VirtioPciDevice
            const ecam_dev = pci.PciDevice{
                .config = self.pci_block.?.config,
                .present = true,
            };
            self.ecam_host.?.addDevice(0, 0, ecam_dev);

            log.info("initialized virtio-pci-blk at PCI 00:00.0, BAR0=0x{x}", .{bar0_addr});
        }
    }

    fn pciBlockNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        if (self.block) |blk| {
            _ = queue_idx;
            blk.transport.queues[0].ready = self.pci_block.?.transport.queues[0].enable;
            blk.transport.queues[0].desc_addr = self.pci_block.?.transport.queues[0].desc_addr;
            blk.transport.queues[0].driver_addr = self.pci_block.?.transport.queues[0].driver_addr;
            blk.transport.queues[0].device_addr = self.pci_block.?.transport.queues[0].device_addr;
        }
    }

    fn pciBlockIrq(userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        // DTB routes PCI INTx to GIC_SPI 48-51 → intid 80-83.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(80, true);
        }
        self.pending_irq.store(true, .release);
    }

    fn registerMmioHandlers(self: *Machine) !void {
        var runner = &self.runner.?;

        // Register GIC Distributor MMIO handler
        if (self.gic_device) |gic_dev| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(gic_dev),
                .base = MemoryLayout.GIC_DIST_BASE,
                .size = 0x10000, // 64KB for distributor
                .read = gic.distMmioRead,
                .write = gic.distMmioWrite,
            });

            // Register GIC Redistributor MMIO handler
            // Size depends on number of CPUs: 2 * 64KB per CPU
            const redist_size = @as(u64, self.config.vcpu_count) * 2 * 0x10000;
            try runner.registerMmioHandler(.{
                .context = @ptrCast(gic_dev),
                .base = MemoryLayout.GIC_REDIST_BASE,
                .size = redist_size,
                .read = gic.redistMmioRead,
                .write = gic.redistMmioWrite,
            });
        }

        // Register UART MMIO handler (PL011)
        if (self.uart) |uart| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(uart),
                .base = MemoryLayout.UART_BASE,
                .size = MemoryLayout.UART_SIZE,
                .read = virtio.uart.mmioRead,
                .write = virtio.uart.mmioWrite,
            });
        }

        // Register console MMIO handler (slot 0)
        if (self.console) |console| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(console),
                .base = MemoryLayout.virtioBase(0),
                .size = MemoryLayout.VIRTIO_SIZE,
                .read = consoleMmioRead,
                .write = consoleMmioWrite,
            });
        }

        // Register block MMIO handler (slot 1)
        if (self.block) |block| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(block),
                .base = MemoryLayout.virtioBase(1),
                .size = MemoryLayout.VIRTIO_SIZE,
                .read = blockMmioRead,
                .write = blockMmioWrite,
            });
        }

        // Register block2 MMIO handler (slot 2)
        if (self.block2) |block2| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(block2),
                .base = MemoryLayout.virtioBase(2),
                .size = MemoryLayout.VIRTIO_SIZE,
                .read = blockMmioRead,
                .write = blockMmioWrite,
            });
        }

        // Register PCIe ECAM MMIO handler
        if (self.ecam_host != null or self.pci_block != null) {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(self),
                .base = MemoryLayout.ECAM_BASE,
                .size = MemoryLayout.ECAM_SIZE,
                .read = ecamMmioRead,
                .write = ecamMmioWrite,
            });
        }

        // Register PCI BAR0 MMIO handler (virtio-pci devices)
        if (self.pci_block) |_| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(self),
                .base = MemoryLayout.PCI_MMIO_BASE,
                .size = MemoryLayout.PCI_MMIO_SIZE,
                .read = pciBarMmioRead,
                .write = pciBarMmioWrite,
            });
        }
    }

    fn ecamMmioRead(ctx: *anyopaque, offset: u64, size: u8) u64 {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        const addr = MemoryLayout.ECAM_BASE + offset;
        const ecam_addr = pci.EcamAddr.decode(addr);

        // PCI config space only supports 1/2/4 byte accesses
        // For 8-byte reads, do two 4-byte reads (if within bounds)
        if (size == 8) {
            const reg_offset = ecam_addr.reg;
            var result: u64 = 0xFFFFFFFF_FFFFFFFF;
            if (reg_offset + 4 < 4096) {
                result = (result & 0xFFFFFFFF_00000000) | ecamMmioRead(ctx, offset, 4);
            }
            if (reg_offset + 8 <= 4096 and offset + 4 < MemoryLayout.ECAM_SIZE) {
                result = (result & 0x00000000_FFFFFFFF) | (ecamMmioRead(ctx, offset + 4, 4) << 32);
            }
            return result;
        }

        // For device 0 (virtio-pci-blk), use VirtioPciDevice directly
        if (ecam_addr.bus == 0 and ecam_addr.device == 0 and ecam_addr.function == 0) {
            if (self.pci_block) |pci_blk| {
                const value = pci_blk.readConfig(ecam_addr.reg, size);
                if (ecam_addr.reg < 0x40) {
                    log.debug("ECAM 00:00.0 read reg=0x{x} size={} -> 0x{x}", .{ ecam_addr.reg, size, value });
                }
                return value;
            }
        }

        // Other devices: use ECAM host
        if (self.ecam_host) |ecam| {
            return ecam.read(addr, size);
        }

        return 0xFFFFFFFF;
    }

    fn ecamMmioWrite(ctx: *anyopaque, offset: u64, size: u8, value: u64) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        const addr = MemoryLayout.ECAM_BASE + offset;
        const ecam_addr = pci.EcamAddr.decode(addr);

        // PCI config space only supports 1/2/4 byte accesses
        // For 8-byte writes, do two 4-byte writes (if within bounds)
        if (size == 8) {
            // Check if second half would be out of bounds for this function's config space
            const reg_offset = ecam_addr.reg;
            if (reg_offset + 4 < 4096) {
                ecamMmioWrite(ctx, offset, 4, value & 0xFFFFFFFF);
            }
            if (reg_offset + 8 <= 4096 and offset + 4 < MemoryLayout.ECAM_SIZE) {
                ecamMmioWrite(ctx, offset + 4, 4, value >> 32);
            }
            return;
        }

        // For device 0 (virtio-pci-blk), use VirtioPciDevice directly
        if (ecam_addr.bus == 0 and ecam_addr.device == 0 and ecam_addr.function == 0) {
            if (self.pci_block) |pci_blk| {
                log.debug("ECAM 00:00.0 write reg=0x{x} size={} value=0x{x}", .{ ecam_addr.reg, size, value });
                pci_blk.writeConfig(ecam_addr.reg, size, value);
                // Sync config back to ECAM host for reads
                if (self.ecam_host) |ecam| {
                    const idx: usize = 0;
                    @memcpy(&ecam.devices[idx].config, &pci_blk.config);
                }
                return;
            }
        }

        // Other devices: use ECAM host
        if (self.ecam_host) |ecam| {
            ecam.write(addr, size, value);
        }
    }

    fn pciBarMmioRead(ctx: *anyopaque, offset: u64, size: u8) u64 {
        const self: *Machine = @ptrCast(@alignCast(ctx));

        if (self.pci_block) |pci_blk| {
            const bar0_addr: u64 = pci_blk.getBar0Addr();
            const bar0_size: u64 = pci.virtio_pci.BAR0_SIZE;
            const addr = MemoryLayout.PCI_MMIO_BASE + offset;

            if (bar0_addr != 0 and addr >= bar0_addr and addr < bar0_addr + bar0_size) {
                const bar_offset: u32 = @truncate(addr - bar0_addr);
                return pci_blk.readBar0(bar_offset, size);
            }
        }

        return 0xFFFFFFFF;
    }

    fn pciBarMmioWrite(ctx: *anyopaque, offset: u64, size: u8, value: u64) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));

        if (self.pci_block) |pci_blk| {
            const bar0_addr: u64 = pci_blk.getBar0Addr();
            const bar0_size: u64 = pci.virtio_pci.BAR0_SIZE;
            const addr = MemoryLayout.PCI_MMIO_BASE + offset;

            if (bar0_addr != 0 and addr >= bar0_addr and addr < bar0_addr + bar0_size) {
                const bar_offset: u32 = @truncate(addr - bar0_addr);
                pci_blk.writeBar0(bar_offset, size, @truncate(value));
                log.debug("PCI BAR0 write: offset=0x{x} size={} value=0x{x}", .{ bar_offset, size, value });
            }
        }
    }

    /// Set up initial state for a single vCPU.
    /// Only vCPU 0 gets the boot configuration; others wait for IPI.
    fn setupVcpuState(self: *Machine, vcpu: *hypervisor.Vcpu, id: u32) !void {
        // Enable FP/SIMD for all vCPUs (CPACR_EL1.FPEN = 0b11)
        try vcpu.setSysReg(.cpacr_el1, 3 << 20);

        // Set up SP_EL0 and SP_EL1 to valid addresses (per-vCPU)
        const stack_base = MemoryLayout.RAM_BASE + 0x10000 + @as(u64, id) * 0x20000;
        try vcpu.setSysReg(.sp_el0, stack_base);
        try vcpu.setSysReg(.sp_el1, stack_base + 0x10000);

        // VBAR_EL1 - Vector Base Address
        try vcpu.setSysReg(.vbar_el1, MemoryLayout.RAM_BASE);

        // Set up SCTLR_EL1 (MMU off, caches off)
        try vcpu.setSysReg(.sctlr_el1, 0);

        // Set up CPSR for EL1t
        try vcpu.setReg(.cpsr, 0x3c4);

        if (id == 0) {
            // Primary vCPU boot configuration
            const boot_pc = if (self.config.isFirmwareBoot())
                MemoryLayout.PFLASH_CODE_BASE // UEFI firmware entry
            else
                MemoryLayout.KERNEL_BASE; // Direct kernel boot

            try vcpu.setPC(boot_pc);

            // x0 = DTB address (used by both firmware and kernel)
            try vcpu.setReg(.x0, MemoryLayout.dtbBase(self.config.ram_size));

            // x1, x2, x3 = 0 (reserved)
            try vcpu.setReg(.x1, 0);
            try vcpu.setReg(.x2, 0);
            try vcpu.setReg(.x3, 0);

            if (self.config.isFirmwareBoot()) {
                log.debug("vCPU 0: firmware boot PC=0x{x}", .{boot_pc});
            } else {
                log.debug("vCPU 0: direct boot PC=0x{x}", .{boot_pc});
            }
        } else {
            // Secondary vCPUs: start halted, waiting for PSCI CPU_ON
            // Write a WFI loop at a per-vCPU location in RAM
            const wfi_offset = 0x1000 * @as(u64, id);
            const wfi_addr = MemoryLayout.RAM_BASE + wfi_offset;

            // Write WFI loop: wfi; b -4 (loop back to wfi)
            // WFI = 0xD503207F, B #-4 = 0x17FFFFFF
            const ram = self.ram.?;
            const wfi_code = [_]u8{
                0x7F, 0x20, 0x03, 0xD5, // wfi
                0xFF, 0xFF, 0xFF, 0x17, // b #-4
            };
            @memcpy(ram[wfi_offset..][0..wfi_code.len], &wfi_code);

            try vcpu.setPC(wfi_addr);
            try vcpu.setReg(.x0, 0);

            log.debug("vCPU {}: secondary state at 0x{x} (waiting for PSCI CPU_ON)", .{ id, wfi_addr });
        }
    }

    // =========================================================================
    // MMIO Callbacks
    // =========================================================================

    fn consoleMmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
        const console: *virtio.Console = @ptrCast(@alignCast(context));
        _ = size;
        return console.read(@truncate(offset));
    }

    fn consoleMmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
        const console: *virtio.Console = @ptrCast(@alignCast(context));
        _ = size;
        console.write(@truncate(offset), @truncate(value));
    }

    fn blockMmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
        const block: *virtio.Block = @ptrCast(@alignCast(context));
        _ = size;
        return block.read(@truncate(offset));
    }

    fn blockMmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
        const block: *virtio.Block = @ptrCast(@alignCast(context));
        _ = size;
        block.write(@truncate(offset), @truncate(value));
    }

    fn getGuestMemoryWrapper(addr: u64, len: usize) ?[]u8 {
        const machine = current_machine orelse return null;
        const ram = machine.ram orelse return null;

        // Check if address is within RAM region
        if (addr < MemoryLayout.RAM_BASE) return null;
        const ram_offset = addr - MemoryLayout.RAM_BASE;
        if (ram_offset + len > ram.len) return null;

        return ram[ram_offset..][0..len];
    }

    fn consoleIrqCallback(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        // DTB declares virtio slot 0 as GIC_SPI 32 → intid 32 + 32 = 64.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64, level);
        }
    }

    fn blk1IrqCallback(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        // DTB declares virtio slot 1 as GIC_SPI 33 → intid 32 + 33 = 65.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(65, level);
        }
    }

    fn blk2IrqCallback(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        // DTB declares virtio slot 2 as GIC_SPI 34 → intid 32 + 34 = 66.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(66, level);
        }
    }

    fn uartIrqCallback(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        // DTB declares the PL011 as GIC_SPI 1 → intid 32 + 1 = 33.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(33, level);
        }
    }

    fn gicEoiCallback(cpu_id: u8, intid: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        if (intid == 27) {
            // vtimer PPI: drop the (level) pending state and unmask HVF's
            // vtimer. If the timer condition still holds, HVF exits again
            // with vtimer_activated and we re-pend.
            if (self.gic_device) |gic_dev| {
                gic_dev.setPpiPending(cpu_id, 27, false);
            }
            self.vtimer_unmask.store(true, .release);
        }
    }

    fn gicInjectIrqCallback(cpu_id: u8, userdata: ?*anyopaque) void {
        _ = cpu_id;
        const self: *Machine = @ptrCast(@alignCast(userdata));
        // For sync mode, we need to set a pending IRQ flag
        // The vCPU loop will check this and inject the IRQ
        self.pending_irq.store(true, .release);
    }
};

// Custom errors
const MachineError = error{
    KernelTooLarge,
    InitrdTooLarge,
};

test {
    _ = MemoryLayout;
}

test "MemoryLayout constants" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0x4000_0000), MemoryLayout.RAM_BASE);
    try testing.expectEqual(@as(u64, 0x4020_0000), MemoryLayout.KERNEL_BASE); // 2MB aligned
    try testing.expectEqual(@as(u64, 0x0A00_0000), MemoryLayout.virtioBase(0));
    try testing.expectEqual(@as(u64, 0x0A00_0200), MemoryLayout.virtioBase(1));
}

test "MachineConfig.isFirmwareBoot" {
    const testing = std.testing;

    // Direct kernel boot: no firmware_path
    const direct_boot = MachineConfig{
        .kernel_path = "/path/to/Image",
        .initrd_path = "/path/to/initrd",
    };
    try testing.expect(!direct_boot.isFirmwareBoot());

    // Firmware boot: firmware_path set
    const firmware_boot = MachineConfig{
        .firmware_path = "/path/to/QEMU_EFI.fd",
    };
    try testing.expect(firmware_boot.isFirmwareBoot());

    // Empty firmware_path is not firmware boot
    const empty_firmware = MachineConfig{
        .firmware_path = "",
    };
    try testing.expect(!empty_firmware.isFirmwareBoot());
}

test "MachineConfig.blockDeviceCount" {
    const testing = std.testing;

    const no_disks = MachineConfig{};
    try testing.expectEqual(@as(u8, 0), no_disks.blockDeviceCount());

    const one_disk = MachineConfig{ .disk_path = "/disk1" };
    try testing.expectEqual(@as(u8, 1), one_disk.blockDeviceCount());

    const two_disks = MachineConfig{
        .disk_path = "/disk1",
        .disk2_path = "/disk2",
    };
    try testing.expectEqual(@as(u8, 2), two_disks.blockDeviceCount());
}
