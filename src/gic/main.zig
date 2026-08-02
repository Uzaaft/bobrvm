//! GICv3 (Generic Interrupt Controller v3) Emulation.
//!
//! Implements the ARM GICv3 interrupt controller for virtual machines.
//! Consists of:
//! - Distributor (GICD): Manages Shared Peripheral Interrupts (SPIs)
//! - Redistributor (GICR): Per-CPU, manages SGIs/PPIs
//! - CPU Interface: Via ICC_* system registers
//!
//! References:
//! - ARM GICv3 Architecture Specification (IHI0069)
//! - Linux kernel drivers/irqchip/irq-gic-v3.c

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.gic);

/// GICv3 register offsets for Distributor (GICD).
pub const GICD = struct {
    pub const CTLR: u16 = 0x0000; // Control Register
    pub const TYPER: u16 = 0x0004; // Interrupt Controller Type
    pub const IIDR: u16 = 0x0008; // Implementer Identification
    pub const TYPER2: u16 = 0x000C; // Interrupt Controller Type 2
    pub const STATUSR: u16 = 0x0010; // Status Register
    pub const SETSPI_NSR: u16 = 0x0040; // Set SPI pending (non-secure)
    pub const CLRSPI_NSR: u16 = 0x0048; // Clear SPI pending (non-secure)

    // Banked per-interrupt registers (32 interrupts per register)
    pub const IGROUPR: u16 = 0x0080; // Interrupt Group (0x80-0xFC)
    pub const ISENABLER: u16 = 0x0100; // Set-Enable (0x100-0x17C)
    pub const ICENABLER: u16 = 0x0180; // Clear-Enable (0x180-0x1FC)
    pub const ISPENDR: u16 = 0x0200; // Set-Pending (0x200-0x27C)
    pub const ICPENDR: u16 = 0x0280; // Clear-Pending (0x280-0x2FC)
    pub const ISACTIVER: u16 = 0x0300; // Set-Active (0x300-0x37C)
    pub const ICACTIVER: u16 = 0x0380; // Clear-Active (0x380-0x3FC)

    // 8-bit per-interrupt registers
    pub const IPRIORITYR: u16 = 0x0400; // Priority (0x400-0x7FC)

    // 8-bit per-interrupt target (GICv2 compat, not used in GICv3 affinity routing)
    pub const ITARGETSR: u16 = 0x0800; // Target (0x800-0xBFC)

    // 2-bit per-interrupt configuration
    pub const ICFGR: u16 = 0x0C00; // Configuration (0xC00-0xCFC)

    // Identification registers
    pub const PIDR2: u16 = 0xFFE8; // Peripheral ID2

    // CTLR bits
    pub const CTLR_ENABLE_G0: u32 = 1 << 0;
    pub const CTLR_ENABLE_G1NS: u32 = 1 << 1;
    pub const CTLR_ENABLE_G1S: u32 = 1 << 2;
    pub const CTLR_ARE_S: u32 = 1 << 4;
    pub const CTLR_ARE_NS: u32 = 1 << 5;
    pub const CTLR_DS: u32 = 1 << 6;
};

/// GICv3 Redistributor (GICR) register offsets.
/// Each redistributor has two 64KB frames: RD_base and SGI_base.
pub const GICR = struct {
    // RD_base frame (frame 0)
    pub const CTLR: u16 = 0x0000;
    pub const IIDR: u16 = 0x0004;
    pub const TYPER: u16 = 0x0008; // 64-bit
    pub const STATUSR: u16 = 0x0010;
    pub const WAKER: u16 = 0x0014;
    pub const PIDR2: u16 = 0xFFE8;

    // SGI_base frame (frame 1, offset 0x10000)
    pub const SGI_OFFSET: u32 = 0x10000;
    pub const IGROUPR0: u16 = 0x0080;
    pub const ISENABLER0: u16 = 0x0100;
    pub const ICENABLER0: u16 = 0x0180;
    pub const ISPENDR0: u16 = 0x0200;
    pub const ICPENDR0: u16 = 0x0280;
    pub const ISACTIVER0: u16 = 0x0300;
    pub const ICACTIVER0: u16 = 0x0380;
    pub const IPRIORITYR: u16 = 0x0400; // 0x400-0x41F (32 bytes for 32 interrupts)
    pub const ICFGR0: u16 = 0x0C00;
    pub const ICFGR1: u16 = 0x0C04;

    // WAKER bits
    pub const WAKER_PROCESSOR_SLEEP: u32 = 1 << 1;
    pub const WAKER_CHILDREN_ASLEEP: u32 = 1 << 2;

    // TYPER bits
    pub const TYPER_LAST: u64 = 1 << 4;
};

/// Maximum number of SPIs (Shared Peripheral Interrupts).
/// SPIs are numbered 32-1019.
pub const MAX_SPI: u32 = 128; // Support 128 SPIs (32-159)
pub const MAX_INTID: u32 = 32 + MAX_SPI;

/// Number of vCPUs supported.
pub const MAX_VCPUS: u8 = 8;

/// Redistributor frame size (2 x 64KB frames per CPU).
pub const GICR_FRAME_SIZE: u32 = 0x20000; // 128KB per redistributor

/// Per-interrupt state.
const InterruptState = struct {
    enabled: bool = false,
    pending: bool = false,
    active: bool = false,
    priority: u8 = 0xFF, // Lowest priority
    config: u2 = 0, // 0=level, 1=edge
    group: u1 = 1, // Group 1 (non-secure)
    target_cpu: u8 = 0, // Target CPU for SPI
};

/// Per-CPU redistributor state.
const RedistState = struct {
    waker: u32 = GICR.WAKER_CHILDREN_ASLEEP,
    /// SGIs (0-15) and PPIs (16-31) state
    sgi_ppi: [32]InterruptState = [_]InterruptState{.{}} ** 32,
};

/// GICv3 emulator state.
pub const Gic = struct {
    alloc: Allocator,

    /// Distributor control register.
    ctlr: u32 = GICD.CTLR_ARE_S | GICD.CTLR_ARE_NS,

    /// SPI state (interrupts 32+).
    spis: []InterruptState,

    /// Per-CPU redistributor state.
    redists: []RedistState,

    /// Number of CPUs.
    num_cpus: u8,

    /// Callback to inject IRQ to vCPU.
    inject_irq: ?*const fn (cpu_id: u8, userdata: ?*anyopaque) void = null,
    inject_userdata: ?*anyopaque = null,

    /// Callback invoked when the guest EOIs an interrupt (e.g. to unmask
    /// the HVF vtimer after the guest acknowledges PPI 27).
    eoi_callback: ?*const fn (cpu_id: u8, intid: u32, userdata: ?*anyopaque) void = null,
    eoi_userdata: ?*anyopaque = null,

    pub const Error = Allocator.Error;

    const AllocationLayout = struct {
        spis_offset: usize,
        redists_offset: usize,
        size: usize,

        fn init(num_cpus: usize) AllocationLayout {
            assert(num_cpus > 0);
            assert(num_cpus <= MAX_VCPUS);

            const spis_offset = std.mem.alignForward(
                usize,
                @sizeOf(Gic),
                @alignOf(InterruptState),
            );
            const redists_offset = std.mem.alignForward(
                usize,
                spis_offset + @sizeOf(InterruptState) * MAX_SPI,
                @alignOf(RedistState),
            );
            return .{
                .spis_offset = spis_offset,
                .redists_offset = redists_offset,
                .size = redists_offset + @sizeOf(RedistState) * num_cpus,
            };
        }
    };

    pub fn init(alloc: Allocator, num_cpus: u8) Error!*Gic {
        assert(num_cpus > 0 and num_cpus <= MAX_VCPUS);

        comptime assert(@alignOf(Gic) >= @alignOf(InterruptState));
        comptime assert(@alignOf(Gic) >= @alignOf(RedistState));
        const layout = AllocationLayout.init(num_cpus);
        const allocation = try alloc.alignedAlloc(u8, .of(Gic), layout.size);

        const gic: *Gic = @ptrCast(allocation.ptr);
        const spis_ptr: [*]InterruptState = @ptrCast(
            @alignCast(allocation.ptr + layout.spis_offset),
        );
        const redists_ptr: [*]RedistState = @ptrCast(
            @alignCast(allocation.ptr + layout.redists_offset),
        );

        gic.* = .{
            .alloc = alloc,
            .spis = spis_ptr[0..MAX_SPI],
            .redists = redists_ptr[0..num_cpus],
            .num_cpus = num_cpus,
        };

        // Initialize SPI state
        for (gic.spis) |*spi| {
            spi.* = .{};
        }

        // Initialize redistributor state
        for (gic.redists) |*redist| {
            redist.* = .{};
            for (&redist.sgi_ppi, 0..) |*irq, intid| {
                irq.priority = 0xA0; // Default priority
                // SGIs (0-15) are always edge-triggered; PPIs (16-31)
                // are level-triggered.
                irq.config = if (intid < 16) 1 else 0;
            }
        }

        log.info("initialized GICv3: {} CPUs, {} SPIs", .{ num_cpus, MAX_SPI });
        return gic;
    }

    pub fn deinit(self: *Gic) void {
        assert(self.num_cpus > 0);
        assert(self.num_cpus <= MAX_VCPUS);

        const alloc = self.alloc;
        const layout = AllocationLayout.init(self.num_cpus);
        const allocation_ptr: [*]align(@alignOf(Gic)) u8 = @ptrCast(self);
        alloc.free(allocation_ptr[0..layout.size]);
    }

    /// Set callback for IRQ injection.
    pub fn setInjectCallback(
        self: *Gic,
        callback: *const fn (cpu_id: u8, userdata: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.inject_irq = callback;
        self.inject_userdata = userdata;
    }

    /// Set callback for EOI notification.
    pub fn setEoiCallback(
        self: *Gic,
        callback: *const fn (cpu_id: u8, intid: u32, userdata: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.eoi_callback = callback;
        self.eoi_userdata = userdata;
    }

    /// Set an SPI pending (called by devices).
    pub fn setSpiPending(self: *Gic, intid: u32, pending: bool) void {
        if (intid < 32 or intid >= MAX_INTID) {
            log.warn("invalid SPI: {}", .{intid});
            return;
        }

        const idx = intid - 32;
        const spi = &self.spis[idx];
        const was_pending = spi.pending;
        spi.pending = pending;

        // If newly pending and enabled, signal the target CPU
        if (pending and !was_pending and spi.enabled) {
            self.checkPendingIrq(spi.target_cpu);
        }
    }

    /// Deliver a Software Generated Interrupt (ICC_SGI1R write).
    /// With all_but_self, targets every CPU except the source; otherwise
    /// targets the CPUs in target_list (affinity 0 bitmap).
    pub fn sendSgi(
        self: *Gic,
        source_cpu: u8,
        intid: u32,
        target_list: u16,
        all_but_self: bool,
    ) void {
        assert(intid < 16);
        assert(source_cpu < self.num_cpus);

        var cpu: u8 = 0;
        while (cpu < self.num_cpus) : (cpu += 1) {
            if (all_but_self) {
                if (cpu == source_cpu) continue;
            } else {
                if (cpu >= 16 or (target_list >> @intCast(cpu)) & 1 == 0) continue;
            }
            self.setPpiPending(cpu, intid, true);
        }
    }

    /// Set a PPI pending (per-CPU).
    pub fn setPpiPending(self: *Gic, cpu_id: u8, intid: u32, pending: bool) void {
        if (cpu_id >= self.num_cpus or intid >= 32) return;

        const irq = &self.redists[cpu_id].sgi_ppi[intid];
        const was_pending = irq.pending;
        irq.pending = pending;

        if (pending and !was_pending and irq.enabled) {
            self.checkPendingIrq(cpu_id);
        }
    }

    /// Check if any interrupt is pending for a CPU and inject if needed.
    fn checkPendingIrq(self: *Gic, cpu_id: u8) void {
        if (cpu_id >= self.num_cpus) return;
        if ((self.ctlr & (GICD.CTLR_ENABLE_G0 | GICD.CTLR_ENABLE_G1NS)) == 0) return;

        // Check SGIs/PPIs
        const redist = &self.redists[cpu_id];
        for (redist.sgi_ppi) |irq| {
            if (irq.pending and irq.enabled and !irq.active) {
                self.injectIrq(cpu_id);
                return;
            }
        }

        // Check SPIs targeted at this CPU
        for (self.spis) |spi| {
            if (spi.pending and spi.enabled and !spi.active and spi.target_cpu == cpu_id) {
                self.injectIrq(cpu_id);
                return;
            }
        }
    }

    fn injectIrq(self: *Gic, cpu_id: u8) void {
        if (self.inject_irq) |cb| {
            cb(cpu_id, self.inject_userdata);
        }
    }

    /// True when any interrupt is pending+enabled+inactive for this CPU
    /// (the state of the CPU's IRQ line). No side effects.
    pub fn hasDeliverableIrq(self: *const Gic, cpu_id: u8) bool {
        if (cpu_id >= self.num_cpus) return false;
        if ((self.ctlr & (GICD.CTLR_ENABLE_G0 | GICD.CTLR_ENABLE_G1NS)) == 0) return false;

        for (self.redists[cpu_id].sgi_ppi) |irq| {
            if (irq.pending and irq.enabled and !irq.active) return true;
        }
        for (self.spis) |spi| {
            if (spi.pending and spi.enabled and !spi.active and spi.target_cpu == cpu_id) {
                return true;
            }
        }
        return false;
    }

    /// Get highest priority pending interrupt for a CPU (for IAR read).
    pub fn ackInterrupt(self: *Gic, cpu_id: u8) u32 {
        if (cpu_id >= self.num_cpus) return 1023; // Spurious

        var best_intid: u32 = 1023;
        var best_priority: u8 = 0xFF;

        // Check SGIs/PPIs
        const redist = &self.redists[cpu_id];
        for (redist.sgi_ppi, 0..) |irq, i| {
            if (irq.pending and irq.enabled and !irq.active and irq.priority < best_priority) {
                best_priority = irq.priority;
                best_intid = @intCast(i);
            }
        }

        // Check SPIs
        for (self.spis, 0..) |spi, i| {
            if (spi.pending and spi.enabled and !spi.active and spi.target_cpu == cpu_id and spi.priority < best_priority) {
                best_priority = spi.priority;
                best_intid = @as(u32, @intCast(i)) + 32;
            }
        }

        // Mark as active, clear pending (for edge-triggered)
        if (best_intid < 32) {
            const irq = &self.redists[cpu_id].sgi_ppi[best_intid];
            irq.active = true;
            if (irq.config == 1) irq.pending = false; // Edge-triggered
        } else if (best_intid < MAX_INTID) {
            const spi = &self.spis[best_intid - 32];
            spi.active = true;
            if (spi.config == 1) spi.pending = false; // Edge-triggered
        }

        return best_intid;
    }

    /// End of interrupt (EOIR write).
    pub fn endInterrupt(self: *Gic, cpu_id: u8, intid: u32) void {
        if (intid >= 1020) return; // Spurious

        if (intid < 32) {
            if (cpu_id < self.num_cpus) {
                self.redists[cpu_id].sgi_ppi[intid].active = false;
            }
        } else if (intid < MAX_INTID) {
            self.spis[intid - 32].active = false;
        }

        if (self.eoi_callback) |cb| {
            cb(cpu_id, intid, self.eoi_userdata);
        }

        // Check for more pending interrupts
        self.checkPendingIrq(cpu_id);
    }

    // =========================================================================
    // MMIO: Distributor (GICD)
    // =========================================================================

    pub fn distRead(self: *Gic, offset: u64, size: u8) u64 {
        _ = size;
        const off: u16 = @truncate(offset);

        return switch (off) {
            GICD.CTLR => self.ctlr,
            GICD.TYPER => self.readTyper(),
            GICD.IIDR => 0x0100_043B, // ARM GICv3
            GICD.TYPER2 => 0,
            GICD.PIDR2 => 0x3B, // GICv3

            // IGROUPR: 1 bit per interrupt
            GICD.IGROUPR...GICD.IGROUPR + 0x7C => self.readBitmap(off, GICD.IGROUPR, .group),
            // ISENABLER/ICENABLER
            GICD.ISENABLER...GICD.ISENABLER + 0x7C => self.readBitmap(off, GICD.ISENABLER, .enabled),
            GICD.ICENABLER...GICD.ICENABLER + 0x7C => self.readBitmap(off, GICD.ICENABLER, .enabled),
            // ISPENDR/ICPENDR
            GICD.ISPENDR...GICD.ISPENDR + 0x7C => self.readBitmap(off, GICD.ISPENDR, .pending),
            GICD.ICPENDR...GICD.ICPENDR + 0x7C => self.readBitmap(off, GICD.ICPENDR, .pending),
            // ISACTIVER/ICACTIVER
            GICD.ISACTIVER...GICD.ISACTIVER + 0x7C => self.readBitmap(off, GICD.ISACTIVER, .active),
            GICD.ICACTIVER...GICD.ICACTIVER + 0x7C => self.readBitmap(off, GICD.ICACTIVER, .active),

            // IPRIORITYR: 8 bits per interrupt
            GICD.IPRIORITYR...GICD.IPRIORITYR + 0x3FC => self.readPriority(off - GICD.IPRIORITYR),

            // ICFGR: 2 bits per interrupt
            GICD.ICFGR...GICD.ICFGR + 0xFC => self.readConfig(off - GICD.ICFGR),

            else => 0,
        };
    }

    pub fn distWrite(self: *Gic, offset: u64, size: u8, value: u64) void {
        _ = size;
        const off: u16 = @truncate(offset);
        const val: u32 = @truncate(value);

        switch (off) {
            GICD.CTLR => {
                self.ctlr = val & (GICD.CTLR_ENABLE_G0 | GICD.CTLR_ENABLE_G1NS | GICD.CTLR_ENABLE_G1S | GICD.CTLR_ARE_S | GICD.CTLR_ARE_NS | GICD.CTLR_DS);
                log.debug("GICD_CTLR = 0x{x}", .{self.ctlr});
            },
            GICD.SETSPI_NSR => self.setSpiPending(val & 0x3FF, true),
            GICD.CLRSPI_NSR => self.setSpiPending(val & 0x3FF, false),

            // IGROUPR
            GICD.IGROUPR...GICD.IGROUPR + 0x7C => self.writeBitmap(off, GICD.IGROUPR, val, .group),
            // ISENABLER
            GICD.ISENABLER...GICD.ISENABLER + 0x7C => self.writeBitmapSet(off, GICD.ISENABLER, val, .enabled),
            // ICENABLER
            GICD.ICENABLER...GICD.ICENABLER + 0x7C => self.writeBitmapClear(off, GICD.ICENABLER, val, .enabled),
            // ISPENDR
            GICD.ISPENDR...GICD.ISPENDR + 0x7C => self.writeBitmapSet(off, GICD.ISPENDR, val, .pending),
            // ICPENDR
            GICD.ICPENDR...GICD.ICPENDR + 0x7C => self.writeBitmapClear(off, GICD.ICPENDR, val, .pending),
            // ISACTIVER
            GICD.ISACTIVER...GICD.ISACTIVER + 0x7C => self.writeBitmapSet(off, GICD.ISACTIVER, val, .active),
            // ICACTIVER
            GICD.ICACTIVER...GICD.ICACTIVER + 0x7C => self.writeBitmapClear(off, GICD.ICACTIVER, val, .active),

            // IPRIORITYR
            GICD.IPRIORITYR...GICD.IPRIORITYR + 0x3FC => self.writePriority(off - GICD.IPRIORITYR, val),

            // ICFGR
            GICD.ICFGR...GICD.ICFGR + 0xFC => self.writeConfig(off - GICD.ICFGR, val),

            else => {},
        }
    }

    fn readTyper(self: *const Gic) u32 {
        // ITLinesNumber: (MAX_SPI / 32) - 1
        const it_lines: u32 = (MAX_SPI / 32);
        // CPUNumber: num_cpus - 1 (in bits 5-7)
        const cpu_num: u32 = @as(u32, self.num_cpus - 1) << 5;
        // SecurityExtn = 0, MBIS = 0, LPIS = 0
        return it_lines | cpu_num;
    }

    const BitmapField = enum { enabled, pending, active, group };

    fn readBitmap(self: *const Gic, offset: u16, base: u16, field: BitmapField) u32 {
        const reg_idx = (offset - base) / 4;
        const start_intid = reg_idx * 32;
        var result: u32 = 0;

        for (0..32) |i| {
            const intid = start_intid + @as(u32, @intCast(i));
            if (intid >= MAX_INTID) break;

            const val: bool = if (intid < 32)
                false // SGIs/PPIs handled by redistributor
            else blk: {
                const spi = &self.spis[intid - 32];
                break :blk switch (field) {
                    .enabled => spi.enabled,
                    .pending => spi.pending,
                    .active => spi.active,
                    .group => spi.group == 1,
                };
            };

            if (val) result |= @as(u32, 1) << @intCast(i);
        }

        return result;
    }

    fn writeBitmap(self: *Gic, offset: u16, base: u16, value: u32, field: BitmapField) void {
        const reg_idx = (offset - base) / 4;
        const start_intid = reg_idx * 32;

        for (0..32) |i| {
            const intid = start_intid + @as(u32, @intCast(i));
            if (intid < 32 or intid >= MAX_INTID) continue;

            const spi = &self.spis[intid - 32];
            const bit = (value >> @intCast(i)) & 1 == 1;

            switch (field) {
                .group => spi.group = if (bit) 1 else 0,
                else => {},
            }
        }
    }

    fn writeBitmapSet(self: *Gic, offset: u16, base: u16, value: u32, field: BitmapField) void {
        const reg_idx = (offset - base) / 4;
        const start_intid = reg_idx * 32;

        for (0..32) |i| {
            const intid = start_intid + @as(u32, @intCast(i));
            if (intid < 32 or intid >= MAX_INTID) continue;
            if ((value >> @intCast(i)) & 1 == 0) continue;

            const spi = &self.spis[intid - 32];
            switch (field) {
                .enabled => spi.enabled = true,
                .pending => spi.pending = true,
                .active => spi.active = true,
                else => {},
            }
        }

        // A pending interrupt may have just become deliverable
        // (e.g. device set pending before the guest enabled the line).
        if (field == .enabled or field == .pending) {
            var cpu: u8 = 0;
            while (cpu < self.num_cpus) : (cpu += 1) self.checkPendingIrq(cpu);
        }
    }

    fn writeBitmapClear(self: *Gic, offset: u16, base: u16, value: u32, field: BitmapField) void {
        const reg_idx = (offset - base) / 4;
        const start_intid = reg_idx * 32;

        for (0..32) |i| {
            const intid = start_intid + @as(u32, @intCast(i));
            if (intid < 32 or intid >= MAX_INTID) continue;
            if ((value >> @intCast(i)) & 1 == 0) continue;

            const spi = &self.spis[intid - 32];
            switch (field) {
                .enabled => spi.enabled = false,
                .pending => spi.pending = false,
                .active => spi.active = false,
                else => {},
            }
        }
    }

    fn readPriority(self: *const Gic, offset: u16) u32 {
        const start_intid = offset;
        var result: u32 = 0;

        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const intid = start_intid + i;
            const priority: u8 = if (intid < 32)
                0xA0 // Default for SGI/PPI
            else if (intid < MAX_INTID)
                self.spis[intid - 32].priority
            else
                0xFF;

            result |= @as(u32, priority) << (@as(u5, @intCast(i)) * 8);
        }

        return result;
    }

    fn writePriority(self: *Gic, offset: u16, value: u32) void {
        const start_intid = offset;

        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const intid = start_intid + i;
            if (intid < 32 or intid >= MAX_INTID) continue;

            const priority: u8 = @truncate(value >> (@as(u5, @intCast(i)) * 8));
            self.spis[intid - 32].priority = priority;
        }
    }

    fn readConfig(self: *const Gic, offset: u16) u32 {
        const start_intid = (offset / 4) * 16;
        var result: u32 = 0;

        var i: u5 = 0;
        while (i < 16) : (i += 1) {
            const intid = start_intid + i;
            const config: u2 = if (intid < 32)
                0
            else if (intid < MAX_INTID)
                self.spis[intid - 32].config
            else
                0;

            result |= @as(u32, config) << (@as(u5, @intCast(i)) * 2);
        }

        return result;
    }

    fn writeConfig(self: *Gic, offset: u16, value: u32) void {
        const start_intid = (offset / 4) * 16;

        var i: u5 = 0;
        while (i < 16) : (i += 1) {
            const intid = start_intid + i;
            if (intid < 32 or intid >= MAX_INTID) continue;

            const config: u2 = @truncate(value >> (@as(u5, @intCast(i)) * 2));
            self.spis[intid - 32].config = config;
        }
    }

    // =========================================================================
    // MMIO: Redistributor (GICR)
    // =========================================================================

    pub fn redistRead(self: *Gic, offset: u64, size: u8) u64 {
        _ = size;

        // Determine which CPU's redistributor
        const cpu_id: u8 = @intCast(offset / GICR_FRAME_SIZE);
        if (cpu_id >= self.num_cpus) return 0;

        const frame_offset: u32 = @intCast(offset % GICR_FRAME_SIZE);
        const is_sgi_frame = frame_offset >= GICR.SGI_OFFSET;
        const reg_offset: u16 = @truncate(if (is_sgi_frame) frame_offset - GICR.SGI_OFFSET else frame_offset);

        const redist = &self.redists[cpu_id];

        if (is_sgi_frame) {
            // SGI_base frame
            return switch (reg_offset) {
                GICR.IGROUPR0 => self.redistReadBitmap(redist, .group),
                GICR.ISENABLER0, GICR.ICENABLER0 => self.redistReadBitmap(redist, .enabled),
                GICR.ISPENDR0, GICR.ICPENDR0 => self.redistReadBitmap(redist, .pending),
                GICR.ISACTIVER0, GICR.ICACTIVER0 => self.redistReadBitmap(redist, .active),
                GICR.IPRIORITYR...GICR.IPRIORITYR + 0x1F => self.redistReadPriority(redist, reg_offset - GICR.IPRIORITYR),
                GICR.ICFGR0 => self.redistReadConfig(redist, 0),
                GICR.ICFGR1 => self.redistReadConfig(redist, 16),
                else => 0,
            };
        } else {
            // RD_base frame
            return switch (reg_offset) {
                GICR.CTLR => 0,
                GICR.IIDR => 0x0100_043B,
                GICR.TYPER => self.redistReadTyper(cpu_id),
                GICR.TYPER + 4 => self.redistReadTyper(cpu_id) >> 32,
                GICR.WAKER => redist.waker,
                GICR.PIDR2 => 0x3B,
                else => 0,
            };
        }
    }

    pub fn redistWrite(self: *Gic, offset: u64, size: u8, value: u64) void {
        _ = size;

        const cpu_id: u8 = @intCast(offset / GICR_FRAME_SIZE);
        if (cpu_id >= self.num_cpus) return;

        const frame_offset: u32 = @intCast(offset % GICR_FRAME_SIZE);
        const is_sgi_frame = frame_offset >= GICR.SGI_OFFSET;
        const reg_offset: u16 = @truncate(if (is_sgi_frame) frame_offset - GICR.SGI_OFFSET else frame_offset);
        const val: u32 = @truncate(value);

        const redist = &self.redists[cpu_id];

        if (is_sgi_frame) {
            switch (reg_offset) {
                GICR.IGROUPR0 => self.redistWriteBitmap(redist, val, .group),
                GICR.ISENABLER0 => self.redistWriteBitmapSet(redist, val, .enabled),
                GICR.ICENABLER0 => self.redistWriteBitmapClear(redist, val, .enabled),
                GICR.ISPENDR0 => self.redistWriteBitmapSet(redist, val, .pending),
                GICR.ICPENDR0 => self.redistWriteBitmapClear(redist, val, .pending),
                GICR.ISACTIVER0 => self.redistWriteBitmapSet(redist, val, .active),
                GICR.ICACTIVER0 => self.redistWriteBitmapClear(redist, val, .active),
                GICR.IPRIORITYR...GICR.IPRIORITYR + 0x1F => self.redistWritePriority(redist, reg_offset - GICR.IPRIORITYR, val),
                GICR.ICFGR0 => self.redistWriteConfig(redist, 0, val),
                GICR.ICFGR1 => self.redistWriteConfig(redist, 16, val),
                else => {},
            }
        } else {
            switch (reg_offset) {
                GICR.WAKER => {
                    // When ProcessorSleep is cleared, clear ChildrenAsleep
                    if ((val & GICR.WAKER_PROCESSOR_SLEEP) == 0) {
                        redist.waker = val & ~GICR.WAKER_CHILDREN_ASLEEP;
                    } else {
                        redist.waker = val | GICR.WAKER_CHILDREN_ASLEEP;
                    }
                    log.debug("CPU{} GICR_WAKER = 0x{x}", .{ cpu_id, redist.waker });
                },
                else => {},
            }
        }
    }

    fn redistReadTyper(self: *const Gic, cpu_id: u8) u64 {
        // Affinity: cpu_id in Aff0
        var typer: u64 = @as(u64, cpu_id) << 32;

        // Processor number
        typer |= @as(u64, cpu_id) << 8;

        // Last redistributor flag
        if (cpu_id == self.num_cpus - 1) {
            typer |= GICR.TYPER_LAST;
        }

        return typer;
    }

    fn redistReadBitmap(self: *const Gic, redist: *const RedistState, field: BitmapField) u32 {
        _ = self;
        var result: u32 = 0;

        for (redist.sgi_ppi, 0..) |irq, i| {
            const val: bool = switch (field) {
                .enabled => irq.enabled,
                .pending => irq.pending,
                .active => irq.active,
                .group => irq.group == 1,
            };
            if (val) result |= @as(u32, 1) << @intCast(i);
        }

        return result;
    }

    fn redistWriteBitmap(self: *Gic, redist: *RedistState, value: u32, field: BitmapField) void {
        _ = self;
        for (&redist.sgi_ppi, 0..) |*irq, i| {
            const bit = (value >> @intCast(i)) & 1 == 1;
            switch (field) {
                .group => irq.group = if (bit) 1 else 0,
                else => {},
            }
        }
    }

    fn redistWriteBitmapSet(self: *Gic, redist: *RedistState, value: u32, field: BitmapField) void {
        _ = self;
        for (&redist.sgi_ppi, 0..) |*irq, i| {
            if ((value >> @intCast(i)) & 1 == 0) continue;
            switch (field) {
                .enabled => irq.enabled = true,
                .pending => irq.pending = true,
                .active => irq.active = true,
                else => {},
            }
        }
    }

    fn redistWriteBitmapClear(self: *Gic, redist: *RedistState, value: u32, field: BitmapField) void {
        _ = self;
        for (&redist.sgi_ppi, 0..) |*irq, i| {
            if ((value >> @intCast(i)) & 1 == 0) continue;
            switch (field) {
                .enabled => irq.enabled = false,
                .pending => irq.pending = false,
                .active => irq.active = false,
                else => {},
            }
        }
    }

    fn redistReadPriority(self: *const Gic, redist: *const RedistState, offset: u16) u32 {
        _ = self;
        var result: u32 = 0;

        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const intid = offset + i;
            if (intid >= 32) break;
            result |= @as(u32, redist.sgi_ppi[intid].priority) << (@as(u5, @intCast(i)) * 8);
        }

        return result;
    }

    fn redistWritePriority(self: *Gic, redist: *RedistState, offset: u16, value: u32) void {
        _ = self;
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const intid = offset + i;
            if (intid >= 32) break;
            redist.sgi_ppi[intid].priority = @truncate(value >> (@as(u5, @intCast(i)) * 8));
        }
    }

    fn redistReadConfig(self: *const Gic, redist: *const RedistState, start: u8) u32 {
        _ = self;
        var result: u32 = 0;

        var i: u5 = 0;
        while (i < 16) : (i += 1) {
            const intid = start + i;
            if (intid >= 32) break;
            result |= @as(u32, redist.sgi_ppi[intid].config) << (i * 2);
        }

        return result;
    }

    fn redistWriteConfig(self: *Gic, redist: *RedistState, start: u8, value: u32) void {
        _ = self;
        var i: u5 = 0;
        while (i < 16) : (i += 1) {
            const intid = start + i;
            if (intid >= 32) break;
            redist.sgi_ppi[intid].config = @truncate(value >> (i * 2));
        }
    }
};

// =============================================================================
// MMIO Callback Wrappers
// =============================================================================

pub fn distMmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
    const gic: *Gic = @ptrCast(@alignCast(context));
    return gic.distRead(offset, size);
}

pub fn distMmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
    const gic: *Gic = @ptrCast(@alignCast(context));
    gic.distWrite(offset, size, value);
}

pub fn redistMmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
    const gic: *Gic = @ptrCast(@alignCast(context));
    return gic.redistRead(offset, size);
}

pub fn redistMmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
    const gic: *Gic = @ptrCast(@alignCast(context));
    gic.redistWrite(offset, size, value);
}

// =============================================================================
// Tests
// =============================================================================

test "Gic init/deinit" {
    const gic = try Gic.init(std.testing.allocator, 2);
    defer gic.deinit();

    try std.testing.expectEqual(@as(u8, 2), gic.num_cpus);
}

test "Gic SPI pending" {
    const gic = try Gic.init(std.testing.allocator, 1);
    defer gic.deinit();

    // Enable SPI 33 (index 1) with a non-default priority
    gic.spis[1].enabled = true;
    gic.spis[1].target_cpu = 0;
    gic.spis[1].priority = 0x80; // Mid-level priority

    // Set pending
    gic.setSpiPending(33, true);
    try std.testing.expect(gic.spis[1].pending);

    // Acknowledge
    const intid = gic.ackInterrupt(0);
    try std.testing.expectEqual(@as(u32, 33), intid);
    try std.testing.expect(gic.spis[1].active);
}
