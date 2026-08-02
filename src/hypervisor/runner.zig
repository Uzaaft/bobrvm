//! vCPU Run Loop.
//!
//! Manages vCPU execution threads and VM exit handling.
//! Dispatches MMIO accesses to registered device handlers.
//!
//! Architecture:
//! - One thread per vCPU
//! - MMIO exits dispatched to device handlers
//! - Virtual timer handling
//! - Coordinated shutdown via atomic flags

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");

/// zig 0.16 removed std.Thread.sleep in favor of the Io.Clock
/// abstraction; thin wrapper for these vCPU-loop sleeps.
fn sleepNs(ns: u64) void {
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = @intCast(ns) },
        .clock = .awake,
    }, global.io()) catch {};
}

fn monotonicMilliseconds() i64 {
    const nanoseconds = std.Io.Clock.awake.now(global.io()).nanoseconds;
    return @intCast(@divFloor(nanoseconds, std.time.ns_per_ms));
}

const c = @import("c.zig");
const Vcpu = @import("vcpu.zig").Vcpu;
const ExitInfo = @import("vcpu.zig").ExitInfo;
const ExceptionClass = @import("vcpu.zig").ExceptionClass;
const VM = @import("vm.zig").VM;

const enable_debug_logs = builtin.mode == .Debug;
const enable_verbose_debug = builtin.mode == .Debug and builtin.mode != .ReleaseFast;

/// MMIO access type.
pub const MmioAccess = struct {
    /// Guest physical address.
    address: u64,
    /// Access size in bytes (1, 2, 4, or 8).
    size: u8,
    /// True if write, false if read.
    is_write: bool,
    /// Data for writes, or buffer for reads.
    data: u64,
    /// Register number for the access (Rt field).
    reg: u5,
};

/// MMIO device handler interface.
pub const MmioHandler = struct {
    /// Opaque context pointer.
    context: *anyopaque,
    /// Base address of MMIO region.
    base: u64,
    /// Size of MMIO region.
    size: u64,
    /// Read callback. Returns data read from device.
    read: *const fn (context: *anyopaque, offset: u64, size: u8) u64,
    /// Write callback.
    write: *const fn (context: *anyopaque, offset: u64, size: u8, value: u64) void,

    /// Check if address falls within this handler's region.
    pub fn contains(self: *const MmioHandler, addr: u64) bool {
        return addr >= self.base and addr < self.base + self.size;
    }
};

/// Callback for vCPU setup after creation.
/// Called on the vCPU's thread after hv_vcpu_create succeeds.
pub const VcpuSetupFn = *const fn (vcpu: *Vcpu, id: u32, userdata: ?*anyopaque) Vcpu.Error!void;

/// vCPU runner state.
/// Creates and runs a vCPU on its own thread (required by Apple Hypervisor).
pub const VcpuRunner = struct {
    alloc: Allocator,
    vcpu: ?*Vcpu = null, // Created on thread start
    vm: *VM,
    id: u32,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    halted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    init_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Track last exit time to detect stuck vCPUs
    last_exit_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // MMIO handlers (shared across all runners)
    mmio_handlers: []const MmioHandler,

    // vCPU setup callback (for initial register state)
    setup_fn: ?VcpuSetupFn = null,
    setup_userdata: ?*anyopaque = null,

    // Statistics
    exit_count: u64 = 0,
    mmio_count: u64 = 0,
    wfi_count: u64 = 0,
    hvc_count: u64 = 0,
    sysreg_count: u64 = 0,
    vtimer_count: u64 = 0,
    uart_count: u64 = 0,
    virtio_count: u64 = 0,
    pci_count: u64 = 0,
    other_mmio_count: u64 = 0,

    pub const Error = Vcpu.Error || std.Thread.SpawnError;

    pub fn init(
        alloc: Allocator,
        vm: *VM,
        id: u32,
        mmio_handlers: []const MmioHandler,
    ) VcpuRunner {
        return .{
            .alloc = alloc,
            .vm = vm,
            .id = id,
            .mmio_handlers = mmio_handlers,
        };
    }

    /// Set callback for vCPU initial state setup.
    pub fn setSetupCallback(self: *VcpuRunner, setup_fn: VcpuSetupFn, userdata: ?*anyopaque) void {
        self.setup_fn = setup_fn;
        self.setup_userdata = userdata;
    }

    /// Start the vCPU thread.
    /// vCPU is created inside the thread (Apple Hypervisor requirement).
    pub fn start(self: *VcpuRunner) !void {
        assert(!self.running.load(.acquire));

        self.running.store(true, .release);
        self.halted.store(false, .release);
        self.init_error.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Stop the vCPU thread.
    pub fn stop(self: *VcpuRunner) void {
        self.running.store(false, .release);

        // TODO: Send IPI to kick vCPU out of WFI if halted

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // Destroy vCPU (must be done on creating thread, but join ensures thread is done)
        if (self.vcpu) |vcpu| {
            vcpu.destroy();
            self.vcpu = null;
        }
    }

    /// Check if vCPU is halted (WFI).
    pub fn isHalted(self: *const VcpuRunner) bool {
        return self.halted.load(.acquire);
    }

    /// Check if initialization failed.
    pub fn hasInitError(self: *const VcpuRunner) bool {
        return self.init_error.load(.acquire);
    }

    /// Wake up a halted vCPU (e.g., for interrupt injection).
    pub fn wakeup(self: *VcpuRunner) void {
        self.halted.store(false, .release);
        // Force vCPU out of hv_vcpu_run if it's stuck
        if (self.vcpu) |vcpu| {
            vcpu.forceExit() catch {};
        }
    }

    /// Check if vCPU appears stuck in hv_vcpu_run.
    /// Returns time in ms since last exit, or 0 if not running.
    pub fn getTimeSinceLastExit(self: *const VcpuRunner) i64 {
        const last = self.last_exit_time.load(.acquire);
        if (last == 0) return 0;
        return monotonicMilliseconds() - last;
    }

    /// Force the vCPU to exit from hv_vcpu_run.
    /// Safe to call from any thread.
    pub fn forceExit(self: *VcpuRunner) void {
        if (self.vcpu) |vcpu| {
            vcpu.forceExit() catch {};
        }
    }

    // =========================================================================
    // Run Loop
    // =========================================================================

    fn runLoop(self: *VcpuRunner) void {
        self.runLoopInner() catch |err| {
            std.log.err("vcpu {} error: {}", .{ self.id, err });
            self.init_error.store(true, .release);
        };
    }

    fn runLoopInner(self: *VcpuRunner) !void {
        // Create vCPU on this thread (Apple Hypervisor requirement)
        self.vcpu = try Vcpu.create(self.alloc);
        errdefer {
            if (self.vcpu) |vcpu| {
                vcpu.destroy();
                self.vcpu = null;
            }
        }

        std.log.debug("vcpu {}: created on thread", .{self.id});

        // Run setup callback to configure initial state
        if (self.setup_fn) |setup_fn| {
            try setup_fn(self.vcpu.?, self.id, self.setup_userdata);
        }

        // Main run loop
        var last_heartbeat: i64 = monotonicMilliseconds();

        while (self.running.load(.acquire)) {
            // Check if halted (WFI)
            if (self.halted.load(.acquire)) {
                sleepNs(1_000_000); // 1ms
                continue;
            }

            // Run vCPU until exit
            if (self.exit_count == 0) {
                std.log.info("vcpu {}: first hv_vcpu_run starting", .{self.id});
            }

            // Track time before hv_vcpu_run to detect hangs
            const run_start = monotonicMilliseconds();
            if (run_start - last_heartbeat > 5000) {
                std.log.info("vcpu {}: exits={} mmio={} gic={} uart={} pci={} vtimer={} wfi={} sysreg={}", .{
                    self.id,
                    self.exit_count,
                    self.mmio_count,
                    self.other_mmio_count,
                    self.uart_count,
                    self.pci_count,
                    self.vtimer_count,
                    self.wfi_count,
                    self.sysreg_count,
                });
                last_heartbeat = run_start;
            }
            self.last_exit_time.store(run_start, .release);
            const exit_info = try self.vcpu.?.run();
            const run_end = monotonicMilliseconds();
            const run_duration = run_end - run_start;
            self.last_exit_time.store(run_end, .release);

            self.exit_count += 1;

            // Log exits for debugging (first 10, then every 100k, or if run took >1s)
            if (self.exit_count <= 10 or self.exit_count % 100000 == 0 or run_duration > 1000) {
                const pc = self.vcpu.?.getReg(.pc) catch 0;
                const lr = self.vcpu.?.getReg(.lr) catch 0;
                std.log.info("vcpu {}: exit #{} ec=0x{x} addr=0x{x} pc=0x{x} lr=0x{x} (run={d}ms)", .{
                    self.id,
                    self.exit_count,
                    @intFromEnum(exit_info.exceptionClass()),
                    exit_info.physical_address,
                    pc,
                    lr,
                    run_duration,
                });
            }

            // If exit was .canceled, log diagnostic info
            if (exit_info.reason == .canceled) {
                const pc = self.vcpu.?.getReg(.pc) catch 0;
                const lr = self.vcpu.?.getReg(.lr) catch 0;
                const sp = self.vcpu.?.getSysReg(.sp_el1) catch 0;
                std.log.warn("vcpu {}: CANCELED exit at pc=0x{x} lr=0x{x} sp=0x{x}", .{
                    self.id,
                    pc,
                    lr,
                    sp,
                });
            }

            // Handle exit
            try self.handleExit(exit_info);
        }
    }

    fn handleExit(self: *VcpuRunner, info: ExitInfo) !void {
        switch (info.reason) {
            .canceled => {
                // vCPU was canceled (e.g., by hv_vcpu_exit)
                return;
            },

            .exception => {
                try self.handleException(info);
            },

            .vtimer_activated => {
                // Virtual timer fired - inject interrupt
                self.vtimer_count += 1;
                try self.vcpu.?.setPendingInterrupt(.irq, true);
            },

            .unknown => {
                std.log.warn("vcpu {}: unknown exit reason", .{self.id});
            },
        }
    }

    fn handleException(self: *VcpuRunner, info: ExitInfo) !void {
        const ec = info.exceptionClass();

        switch (ec) {
            .data_abort_lower, .data_abort_same => {
                // MMIO access
                try self.handleDataAbort(info);
            },

            .wf_trapped => {
                // WFI/WFE - halt until interrupt
                self.wfi_count += 1;
                self.halted.store(true, .release);
                try self.vcpu.?.advancePC(info);
            },

            .hvc_aarch64 => {
                // Hypervisor call - used for paravirt
                self.hvc_count += 1;
                try self.handleHvc(info);
            },

            .smc_aarch64 => {
                // Secure monitor call - handle same as HVC for PSCI
                self.hvc_count += 1;
                try self.handleHvc(info);
            },

            .msr_mrs_system => {
                // System register access trap
                self.sysreg_count += 1;
                try self.handleSysRegTrap(info);
            },

            else => {
                std.log.warn("vcpu {}: unhandled exception class 0x{x}", .{
                    self.id,
                    @intFromEnum(ec),
                });
                // Inject undefined instruction exception to guest
                // For now, just advance PC
                try self.vcpu.?.advancePC(info);
            },
        }
    }

    fn handleDataAbort(self: *VcpuRunner, info: ExitInfo) !void {
        self.mmio_count += 1;

        const iss = info.iss();
        const isv = (iss >> 24) & 1 != 0; // ISV bit - instruction syndrome valid
        const addr = info.physical_address;

        // When ISV=0, syndrome fields are invalid - must decode instruction
        var is_write: bool = undefined;
        var size: u8 = undefined;
        var srt: u5 = undefined;

        if (isv) {
            is_write = info.isWrite();
            const sas = info.accessSize();
            size = @as(u8, 1) << sas;
            srt = @truncate(iss >> 16);
        } else {
            // ISV=0: Decode instruction to get access info
            const pc = try self.vcpu.?.getReg(.pc);
            const instr = self.readGuestMemory32(pc) catch |err| {
                std.log.err("Failed to read instruction at PC=0x{x}: {}", .{ pc, err });
                try self.vcpu.?.advancePC(info);
                return;
            };

            // Decode AArch64 load/store instruction
            const decoded = decodeLoadStore(instr);
            switch (decoded) {
                .load_store => |ls| {
                    is_write = ls.is_write;
                    size = ls.size;
                    srt = ls.rt;

                    // Handle post/pre-indexed writeback
                    if (ls.writeback_rn) |wb_rn| {
                        const base_val = try self.vcpu.?.getReg(@enumFromInt(wb_rn));
                        const new_base = if (ls.writeback_imm >= 0)
                            base_val +% @as(u64, @intCast(ls.writeback_imm))
                        else
                            base_val -% @as(u64, @intCast(-ls.writeback_imm));
                        try self.vcpu.?.setReg(@enumFromInt(wb_rn), new_base);
                    }

                    if (enable_verbose_debug and addr >= 0x3c000000 and
                        (addr < 0x3c001000 or self.exit_count % 100000 == 0))
                    {
                        std.log.debug("MMIO ISV=0 load_store: pc=0x{x} addr=0x{x} instr=0x{x} is_write={} size={} rt={} wb={?}", .{
                            pc, addr, instr, is_write, size, srt, ls.writeback_rn,
                        });
                    }
                },
                .cache_op => {
                    // Cache maintenance instruction - just advance PC and continue
                    // Log if we see lots of cache ops at same address (potential loop)
                    if (enable_verbose_debug and self.exit_count % 100000 == 0 and addr >= 0x3c000000) {
                        std.log.debug("cache_op at pc=0x{x} addr=0x{x} instr=0x{x}", .{ pc, addr, instr });
                    }
                    try self.vcpu.?.advancePC(info);
                    return;
                },
                .unknown => {
                    // Log first occurrence at each unique PC
                    if (enable_debug_logs) {
                        std.log.warn("ISV=0 unknown instruction at pc=0x{x} addr=0x{x}: 0x{x}", .{ pc, addr, instr });
                    }
                    // For unknown instructions, assume it's a read and return 0xFFFFFFFF
                    if (enable_verbose_debug and self.exit_count < 20) {
                        std.log.debug("Treating unknown as read, returning 0xFFFFFFFF", .{});
                    }
                    // Set result register to 0xFFFFFFFF and advance
                    const guess_rt: u5 = @truncate(instr); // Rt is usually in bits 4:0
                    if (guess_rt != 31) {
                        try self.vcpu.?.setReg(@enumFromInt(guess_rt), 0xFFFFFFFF);
                    }
                    try self.vcpu.?.advancePC(info);
                    return;
                },
            }
        }

        // Categorize MMIO address early for tracking
        const is_gic = addr >= 0x08000000 and addr < 0x080C0000;
        const is_uart_addr = addr >= 0x09000000 and addr < 0x09010000;
        const is_virtio_addr = addr >= 0x0a000000 and addr < 0x0a010000;
        const is_pci_addr = addr >= 0x10000000 and addr < 0x40000000;

        if (is_gic) {
            self.other_mmio_count += 1; // Reuse for GIC for now
        } else if (is_uart_addr) {
            self.uart_count += 1;
        } else if (is_virtio_addr) {
            self.virtio_count += 1;
        } else if (is_pci_addr) {
            self.pci_count += 1;
        }

        // Find handler for this address
        for (self.mmio_handlers) |handler| {
            if (handler.contains(addr)) {
                const offset = addr - handler.base;

                if (is_write) {
                    // Get value from register
                    const value = if (srt == 31)
                        0 // XZR
                    else
                        try self.vcpu.?.getReg(@enumFromInt(srt));

                    handler.write(handler.context, offset, size, value);
                } else {
                    // Read from device
                    const value = handler.read(handler.context, offset, size);

                    // Write to register
                    if (srt != 31) {
                        try self.vcpu.?.setReg(@enumFromInt(srt), value);
                    }
                }

                try self.vcpu.?.advancePC(info);
                return;
            }
        }

        // Categorize and count MMIO by region
        const uart_start: u64 = 0x09000000;
        const uart_end: u64 = 0x09010000;
        const virtio_start: u64 = 0x0a000000;
        const virtio_end: u64 = 0x0a010000;
        const pci_ecam_start: u64 = 0x3c000000;
        const pci_ecam_end: u64 = 0x40000000;
        const pci_mmio_start: u64 = 0x10000000;
        const pci_mmio_end: u64 = 0x3c000000;
        const rtc_start: u64 = 0x09010000;
        const rtc_end: u64 = 0x09020000;

        const is_uart = addr >= uart_start and addr < uart_end;
        const is_virtio = addr >= virtio_start and addr < virtio_end;
        const is_pci_ecam = addr >= pci_ecam_start and addr < pci_ecam_end;
        const is_pci_mmio = addr >= pci_mmio_start and addr < pci_mmio_end;
        const is_rtc = addr >= rtc_start and addr < rtc_end;
        const is_known_probe = is_pci_ecam or is_pci_mmio or is_rtc;

        if (!is_known_probe and !is_uart and !is_virtio) {
            std.log.warn("vcpu {}: unhandled MMIO {s} at 0x{x}", .{
                self.id,
                if (is_write) "write" else "read",
                addr,
            });
        }

        // For reads, return appropriate value to destination register
        if (!is_write and srt != 31) {
            // PCI ECAM reads return 0xFFFFFFFF (no device present)
            // Other reads return 0
            const value: u64 = if (is_pci_ecam) 0xFFFFFFFF else 0;
            try self.vcpu.?.setReg(@enumFromInt(srt), value);
        }

        try self.vcpu.?.advancePC(info);
    }

    fn handleHvc(self: *VcpuRunner, _: ExitInfo) !void {
        const vcpu = self.vcpu.?;

        // Get function ID from x0
        const fn_id = try vcpu.getReg(.x0);

        // Handle PSCI calls
        const result = switch (fn_id) {
            // PSCI_VERSION - return v1.0 (0x00010000)
            0x84000000 => @as(u64, 0x00010000),

            // PSCI_FEATURES - return supported for known functions
            0x8400000A => blk: {
                const feature = try vcpu.getReg(.x1);
                break :blk switch (feature) {
                    0x84000000, // VERSION
                    0x84000008, // SYSTEM_OFF
                    0x84000009, // SYSTEM_RESET
                    0x8400000A, // FEATURES
                    => @as(u64, 0), // SUCCESS
                    else => @as(u64, 0xFFFFFFFF), // NOT_SUPPORTED
                };
            },

            // PSCI_SYSTEM_OFF
            0x84000008 => blk: {
                std.log.info("vcpu {}: PSCI SYSTEM_OFF", .{self.id});
                self.running.store(false, .release);
                break :blk @as(u64, 0);
            },

            // PSCI_SYSTEM_RESET
            0x84000009 => blk: {
                std.log.info("vcpu {}: PSCI SYSTEM_RESET", .{self.id});
                self.running.store(false, .release);
                break :blk @as(u64, 0);
            },

            // PSCI_CPU_ON (64-bit: 0xC4000003, 32-bit: 0x84000003)
            0xC4000003, 0x84000003 => blk: {
                const target_cpu = try vcpu.getReg(.x1);
                const entry = try vcpu.getReg(.x2);
                std.log.debug("vcpu {}: PSCI CPU_ON cpu={} entry=0x{x}", .{ self.id, target_cpu, entry });
                // TODO: Wake secondary CPU
                break :blk @as(u64, 0xFFFFFFFFFFFFFFFE); // INVALID_PARAMETERS for now
            },

            // PSCI_AFFINITY_INFO
            0xC4000004, 0x84000004 => @as(u64, 0), // ON

            // Unknown - return NOT_SUPPORTED
            else => blk: {
                std.log.debug("vcpu {}: unknown PSCI fn=0x{x}", .{ self.id, fn_id });
                break :blk @as(u64, 0xFFFFFFFF); // NOT_SUPPORTED
            },
        };

        try vcpu.setReg(.x0, result);
        // NOTE: Do NOT advance PC - for HVC/SMC, PC already points past the instruction
    }

    fn handleSysRegTrap(self: *VcpuRunner, info: ExitInfo) !void {
        // System register access that trapped
        // ISS encoding for MSR/MRS: Op0, Op1, CRn, CRm, Op2, Rt, direction
        const iss = info.iss();
        const is_read = (iss & 1) != 0; // Direction: 1=read (MRS), 0=write (MSR)
        const rt: u5 = @truncate(iss >> 5); // Target register
        const crm: u4 = @truncate(iss >> 1);
        const crn: u4 = @truncate(iss >> 10);
        const op1: u3 = @truncate(iss >> 14);
        const op2: u3 = @truncate(iss >> 17);
        const op0: u2 = @truncate(iss >> 20);

        // For now, return 0 for reads, ignore writes
        if (is_read and rt != 31) {
            try self.vcpu.?.setReg(@enumFromInt(rt), 0);
        }

        std.log.debug("vcpu {}: sysreg trap op0={} op1={} crn={} crm={} op2={} rt={} {s}", .{
            self.id, op0, op1, crn, crm, op2, rt, if (is_read) "read" else "write",
        });

        try self.vcpu.?.advancePC(info);
    }

    /// Read 32-bit value from guest memory at given address
    fn readGuestMemory32(self: *VcpuRunner, addr: u64) !u32 {
        // Access guest memory via the VM's mapped memory
        // For firmware in flash (0x0 - 0x4000000), we need to read from mapped region
        const ptr = self.vm.guestToHost(addr) orelse return error.InvalidAddress;
        return @as(*align(1) const u32, @ptrCast(ptr)).*;
    }
};

/// Decoded load/store instruction info
const LoadStoreInfo = struct {
    is_write: bool,
    size: u8,
    rt: u5,
    // For post-indexed addressing: base register and increment
    writeback_rn: ?u5 = null,
    writeback_imm: i64 = 0,
};

/// Result of instruction decode
const DecodeResult = union(enum) {
    load_store: LoadStoreInfo,
    cache_op, // DC CIVAC, etc. - skip
    unknown,
};

/// Decode AArch64 load/store instruction to determine access type
fn decodeLoadStore(instr: u32) DecodeResult {
    // Check for system instructions first (MSR/MRS/DC/IC/etc.)
    // System instructions: 1101 0101 xxxx xxxx xxxx xxxx xxxx xxxx
    if ((instr >> 24) & 0xFF == 0xD5) {
        // This is a system instruction (cache maintenance, MSR, etc.)
        // Not a real load/store - just skip it
        return .cache_op;
    }

    const rt: u5 = @truncate(instr);
    const rn: u5 = @truncate(instr >> 5);
    const size_bits: u2 = @truncate(instr >> 30);
    const size: u8 = @as(u8, 1) << size_bits;

    // Check if it's a load or store
    const op0 = (instr >> 28) & 0xF; // bits 31:28
    const op1 = (instr >> 26) & 0x1; // bit 26

    // Load/store unsigned immediate: op0=1x1x, op1=1
    // For these: bit 22 = 0 means store, bit 22 = 1 means load
    if ((op0 & 0x5) == 0x5 and op1 == 1) {
        // Unsigned offset encoding - no writeback
        const is_load = (instr >> 22) & 1 != 0;
        return .{ .load_store = .{ .is_write = !is_load, .size = size, .rt = rt } };
    }

    // Load/store register (unscaled, post-indexed, pre-indexed)
    // op0=1x1x, op1=0
    if ((op0 & 0x5) == 0x5 and op1 == 0) {
        const opc = (instr >> 22) & 0x3;
        const is_load = (opc & 1) != 0;

        // Check for post-indexed or pre-indexed (bits 11:10)
        // 00 = unscaled, 01 = post-indexed, 10 = unprivileged, 11 = pre-indexed
        const idx_mode = (instr >> 10) & 0x3;
        if (idx_mode == 0x1 or idx_mode == 0x3) {
            // Post-indexed or pre-indexed - has writeback
            // imm9 is in bits 20:12 (signed)
            const imm9_raw: u9 = @truncate(instr >> 12);
            const imm9: i64 = @as(i64, @as(i9, @bitCast(imm9_raw)));
            return .{ .load_store = .{
                .is_write = !is_load,
                .size = size,
                .rt = rt,
                .writeback_rn = rn,
                .writeback_imm = imm9,
            } };
        }

        return .{ .load_store = .{ .is_write = !is_load, .size = size, .rt = rt } };
    }

    // Load/store pair
    if (op0 == 0x2 or op0 == 0x6 or op0 == 0xA or op0 == 0xE) {
        // bit 22 = L bit: 0=store, 1=load
        const is_load = (instr >> 22) & 1 != 0;
        return .{ .load_store = .{ .is_write = !is_load, .size = size, .rt = rt } };
    }

    // Default: unknown
    if (enable_debug_logs) {
        std.log.warn("Unknown instruction: 0x{x}", .{instr});
    }
    return .unknown;
}

/// VM runner coordinating multiple vCPUs.
pub const VMRunner = struct {
    alloc: Allocator,
    vm: *VM,
    vcpu_runners: std.ArrayListUnmanaged(VcpuRunner),
    mmio_handlers: std.ArrayListUnmanaged(MmioHandler),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Kick thread for waking stuck vCPUs
    kick_thread: ?std.Thread = null,

    pub const Error = VcpuRunner.Error || Allocator.Error;

    pub fn init(alloc: Allocator, vm: *VM) VMRunner {
        return .{
            .alloc = alloc,
            .vm = vm,
            .vcpu_runners = .empty,
            .mmio_handlers = .empty,
        };
    }

    pub fn deinit(self: *VMRunner) void {
        self.stop();
        if (self.kick_thread) |t| {
            t.join();
            self.kick_thread = null;
        }
        self.vcpu_runners.deinit(self.alloc);
        self.mmio_handlers.deinit(self.alloc);
    }

    /// Register an MMIO handler.
    pub fn registerMmioHandler(self: *VMRunner, handler: MmioHandler) !void {
        // Pre-condition: not running
        assert(!self.running.load(.acquire));

        try self.mmio_handlers.append(self.alloc, handler);
    }

    pub fn reserveMmioHandlers(self: *VMRunner, count: usize) !void {
        assert(!self.running.load(.acquire));
        assert(count >= self.mmio_handlers.items.len);
        try self.mmio_handlers.ensureTotalCapacityPrecise(self.alloc, count);
    }

    /// Add a vCPU slot to the runner.
    /// The vCPU will be created on its own thread when start() is called.
    pub fn addVcpuSlot(self: *VMRunner, setup_fn: ?VcpuSetupFn, userdata: ?*anyopaque) !void {
        // Pre-condition: not running
        assert(!self.running.load(.acquire));

        const id: u32 = @intCast(self.vcpu_runners.items.len);
        var runner = VcpuRunner.init(
            self.alloc,
            self.vm,
            id,
            self.mmio_handlers.items,
        );
        if (setup_fn) |f| {
            runner.setSetupCallback(f, userdata);
        }
        try self.vcpu_runners.append(self.alloc, runner);
    }

    /// Start all vCPU threads.
    /// Each thread creates its own vCPU (Apple Hypervisor requirement).
    pub fn start(self: *VMRunner) !void {
        assert(!self.running.load(.acquire));
        assert(self.vcpu_runners.items.len > 0);

        self.running.store(true, .release);

        for (self.vcpu_runners.items) |*runner| {
            try runner.start();
        }

        // Start kick thread to wake stuck vCPUs
        // This is needed because Apple Hypervisor doesn't trap WFI by default
        self.kick_thread = try std.Thread.spawn(.{}, kickLoop, .{self});
    }

    /// Kick loop: periodically forces vCPUs out of hv_vcpu_run to handle interrupts.
    /// This works around Apple Hypervisor not trapping WFI.
    fn kickLoop(self: *VMRunner) void {
        const kick_interval_ms: u64 = 100; // Check every 100ms
        const stuck_threshold_ms: i64 = 500; // Consider stuck after 500ms

        while (self.running.load(.acquire)) {
            sleepNs(kick_interval_ms * 1_000_000); // Convert to ns

            for (self.vcpu_runners.items) |*runner| {
                const time_since_exit = runner.getTimeSinceLastExit();
                if (time_since_exit > stuck_threshold_ms) {
                    // vCPU has been in hv_vcpu_run for too long, kick it
                    std.log.debug("kick: vcpu {} stuck for {}ms, forcing exit", .{
                        runner.id,
                        time_since_exit,
                    });
                    runner.forceExit();
                }
            }
        }
    }

    /// Stop all vCPU threads.
    pub fn stop(self: *VMRunner) void {
        self.running.store(false, .release);

        for (self.vcpu_runners.items) |*runner| {
            runner.stop();
        }
    }

    /// Inject IRQ to a vCPU.
    pub fn injectIrq(self: *VMRunner, vcpu_id: u32) !void {
        if (vcpu_id < self.vcpu_runners.items.len) {
            const runner = &self.vcpu_runners.items[vcpu_id];
            if (runner.vcpu) |vcpu| {
                try vcpu.setPendingInterrupt(.irq, true);
            }
            runner.wakeup();
        }
    }

    /// Get total exit count across all vCPUs.
    pub fn getTotalExitCount(self: *const VMRunner) u64 {
        var total: u64 = 0;
        for (self.vcpu_runners.items) |runner| {
            total += runner.exit_count;
        }
        return total;
    }

    /// Force all vCPUs to exit from hv_vcpu_run (for debugging stuck vCPUs).
    /// This can be called from another thread.
    pub fn forceExitAll(self: *VMRunner) void {
        var handles: [16]c.hv_vcpu_t = undefined;
        var count: u32 = 0;

        for (self.vcpu_runners.items) |*runner| {
            if (runner.vcpu) |vcpu| {
                if (count < handles.len) {
                    handles[count] = vcpu.getHandle();
                    count += 1;
                }
            }
        }

        if (count > 0) {
            const ret = c.hv_vcpus_exit(&handles, count);
            if (ret != c.HV_SUCCESS) {
                std.log.warn("hv_vcpus_exit failed: 0x{x}", .{ret});
            }
        }
    }

    /// Kick a specific vCPU by injecting a timer interrupt.
    /// This wakes the vCPU from WFI/WFE.
    pub fn kickVcpu(self: *VMRunner, vcpu_id: u32) void {
        if (vcpu_id < self.vcpu_runners.items.len) {
            const runner = &self.vcpu_runners.items[vcpu_id];
            if (runner.vcpu) |vcpu| {
                // Inject pending IRQ to wake from WFI
                vcpu.setPendingInterrupt(.irq, true) catch {};
                // Force exit to ensure run() returns
                vcpu.forceExit() catch {};
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MmioHandler.contains" {
    const handler = MmioHandler{
        .context = undefined,
        .base = 0x1000,
        .size = 0x100,
        .read = undefined,
        .write = undefined,
    };

    try std.testing.expect(handler.contains(0x1000));
    try std.testing.expect(handler.contains(0x10FF));
    try std.testing.expect(!handler.contains(0x0FFF));
    try std.testing.expect(!handler.contains(0x1100));
}

test "MmioAccess struct" {
    const access = MmioAccess{
        .address = 0x40000000,
        .size = 4,
        .is_write = true,
        .data = 0x12345678,
        .reg = 5,
    };

    try std.testing.expectEqual(@as(u64, 0x40000000), access.address);
    try std.testing.expectEqual(@as(u8, 4), access.size);
    try std.testing.expect(access.is_write);
}

test "MMIO handler registration reserves startup capacity" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var runner = VMRunner.init(counted.allocator(), undefined);
    defer runner.deinit();
    try runner.reserveMmioHandlers(8);

    for (0..8) |index| {
        try runner.registerMmioHandler(.{
            .context = undefined,
            .base = index * 0x1000,
            .size = 0x1000,
            .read = undefined,
            .write = undefined,
        });
    }

    try std.testing.expectEqual(@as(usize, 1), counted.allocations);
    try std.testing.expectEqual(@as(usize, 320), counted.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), counted.resize_index);
}
