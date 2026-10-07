//! Minimal PMUv3 emulation: a running cycle counter and the control
//! registers around it, no event counters.
//!
//! Hypervisor.framework traps every PMU system register instead of
//! virtualizing the host PMU. The Windows boot library enables the cycle
//! counter and requires it to advance (it calibrates a time source from
//! it); a counter stuck at zero ends in a dead loop before anything is
//! drawn. QEMU's HVF accelerator emulates the same set for that reason.
//!
//! Register encoding matches `icc.zig`: (op0<<14)|(op1<<11)|(crn<<7)|(crm<<3)|op2.

const Pmu = @This();

const std = @import("std");

/// PMCR_EL0 as written by the guest (E, P, C, D, X, DP, LC bits kept).
pmcr: u64 = 0,
/// PMCNTENSET/CLR_EL0: bit 31 is the cycle counter.
cnten: u32 = 0,
/// PMOVSSET/CLR_EL0 overflow flags.
ovsr: u32 = 0,
pmselr: u32 = 0,
pmuserenr: u32 = 0,
pminten: u32 = 0,
pmccfiltr: u32 = 0,
/// Host counter value at the last PMCCNTR write or resume.
ccnt_base: u64 = 0,
/// PMCCNTR value at `ccnt_base`; keeps writes exact despite the 125/3 ratio.
ccnt_origin: u64 = 0,
/// Frozen PMCCNTR value while the counter is disabled.
ccnt_frozen: u64 = 0,

const PMCR_E: u64 = 1 << 0;
const PMCR_P: u64 = 1 << 1;
const PMCR_C: u64 = 1 << 2;
const PMCR_D: u64 = 1 << 3;
const PMCR_LC: u64 = 1 << 6;
const PMCR_WRITABLE: u64 = PMCR_E | PMCR_D | (1 << 4) | (1 << 5) | PMCR_LC;
/// IMP = 'A' (0x41), IDCODE = 0, N = 0 event counters.
const PMCR_RO: u64 = 0x41 << 24;
const CYCLE_COUNTER_BIT: u32 = 1 << 31;

/// Nanoseconds per host counter tick: Apple's 24 MHz timebase is 125/3 ns.
/// The emulated CPU clock is 1 GHz, so cycles == nanoseconds.
const TICK_NS_NUMERATOR: u64 = 125;
const TICK_NS_DENOMINATOR: u64 = 3;

pub fn encode(op0: u32, op1: u32, crn: u32, crm: u32, op2: u32) u32 {
    return (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2;
}

pub const Reg = struct {
    pub const PMCR_EL0 = encode(3, 3, 9, 12, 0);
    pub const PMCNTENSET_EL0 = encode(3, 3, 9, 12, 1);
    pub const PMCNTENCLR_EL0 = encode(3, 3, 9, 12, 2);
    pub const PMOVSCLR_EL0 = encode(3, 3, 9, 12, 3);
    pub const PMSWINC_EL0 = encode(3, 3, 9, 12, 4);
    pub const PMSELR_EL0 = encode(3, 3, 9, 12, 5);
    pub const PMCEID0_EL0 = encode(3, 3, 9, 12, 6);
    pub const PMCEID1_EL0 = encode(3, 3, 9, 12, 7);
    pub const PMCCNTR_EL0 = encode(3, 3, 9, 13, 0);
    pub const PMXEVTYPER_EL0 = encode(3, 3, 9, 13, 1);
    pub const PMXEVCNTR_EL0 = encode(3, 3, 9, 13, 2);
    pub const PMUSERENR_EL0 = encode(3, 3, 9, 14, 0);
    pub const PMOVSSET_EL0 = encode(3, 3, 9, 14, 3);
    pub const PMINTENSET_EL1 = encode(3, 0, 9, 14, 1);
    pub const PMINTENCLR_EL1 = encode(3, 0, 9, 14, 2);
    pub const PMCCFILTR_EL0 = encode(3, 3, 14, 15, 7);
    /// PMEVCNTR<n>_EL0 / PMEVTYPER<n>_EL0 live in S3_3_C14_C8..C15.
    const EVENT_FIRST = encode(3, 3, 14, 8, 0);
    const EVENT_LAST = encode(3, 3, 14, 15, 6);
};

pub fn isPmuReg(reg: u32) bool {
    return switch (reg) {
        Reg.PMCR_EL0,
        Reg.PMCNTENSET_EL0,
        Reg.PMCNTENCLR_EL0,
        Reg.PMOVSCLR_EL0,
        Reg.PMSWINC_EL0,
        Reg.PMSELR_EL0,
        Reg.PMCEID0_EL0,
        Reg.PMCEID1_EL0,
        Reg.PMCCNTR_EL0,
        Reg.PMXEVTYPER_EL0,
        Reg.PMXEVCNTR_EL0,
        Reg.PMUSERENR_EL0,
        Reg.PMOVSSET_EL0,
        Reg.PMINTENSET_EL1,
        Reg.PMINTENCLR_EL1,
        Reg.PMCCFILTR_EL0,
        => true,
        else => reg >= Reg.EVENT_FIRST and reg <= Reg.EVENT_LAST,
    };
}

fn cyclesSince(self: *const Pmu, now_ticks: u64) u64 {
    const elapsed = now_ticks -% self.ccnt_base;
    var cycles: u64 = @truncate(@as(u128, elapsed) * TICK_NS_NUMERATOR / TICK_NS_DENOMINATOR);
    if (self.pmcr & PMCR_D != 0) cycles /= 64;
    return self.ccnt_origin +% cycles;
}

fn cycleCounterRunning(self: *const Pmu) bool {
    return self.pmcr & PMCR_E != 0 and self.cnten & CYCLE_COUNTER_BIT != 0;
}

fn readCycleCounter(self: *const Pmu, now_ticks: u64) u64 {
    const value = if (self.cycleCounterRunning()) self.cyclesSince(now_ticks) else self.ccnt_frozen;
    return if (self.pmcr & PMCR_LC != 0) value else value & 0xFFFF_FFFF;
}

/// Set PMCCNTR to `value`, keeping it frozen or running as configured.
fn writeCycleCounter(self: *Pmu, now_ticks: u64, value: u64) void {
    self.ccnt_frozen = value;
    self.ccnt_origin = value;
    self.ccnt_base = now_ticks;
}

/// Freeze or resume so the counter neither jumps nor loses time on toggles.
fn updateRunState(self: *Pmu, now_ticks: u64, was_running: bool) void {
    const running = self.cycleCounterRunning();
    if (was_running and !running) {
        self.ccnt_frozen = self.cyclesSince(now_ticks);
    } else if (!was_running and running) {
        self.writeCycleCounter(now_ticks, self.ccnt_frozen);
    }
}

/// `now_ticks` is the host timebase (mach_absolute_time) adjusted to the
/// guest's counter; only differences matter.
pub fn read(self: *Pmu, reg: u32, now_ticks: u64) u64 {
    return switch (reg) {
        Reg.PMCR_EL0 => PMCR_RO | (self.pmcr & PMCR_WRITABLE),
        Reg.PMCNTENSET_EL0, Reg.PMCNTENCLR_EL0 => self.cnten,
        Reg.PMOVSCLR_EL0, Reg.PMOVSSET_EL0 => self.ovsr,
        Reg.PMSELR_EL0 => self.pmselr,
        Reg.PMCCNTR_EL0 => self.readCycleCounter(now_ticks),
        Reg.PMUSERENR_EL0 => self.pmuserenr,
        Reg.PMINTENSET_EL1, Reg.PMINTENCLR_EL1 => self.pminten,
        Reg.PMCCFILTR_EL0 => self.pmccfiltr,
        // No events implemented: PMCEIDn, PMXEV*, PMEV* read as zero.
        else => 0,
    };
}

pub fn write(self: *Pmu, reg: u32, value: u64, now_ticks: u64) void {
    const was_running = self.cycleCounterRunning();
    switch (reg) {
        Reg.PMCR_EL0 => {
            self.pmcr = value & PMCR_WRITABLE;
            if (value & PMCR_C != 0) self.writeCycleCounter(now_ticks, 0);
            self.updateRunState(now_ticks, was_running);
        },
        Reg.PMCNTENSET_EL0 => {
            self.cnten |= @truncate(value);
            self.updateRunState(now_ticks, was_running);
        },
        Reg.PMCNTENCLR_EL0 => {
            self.cnten &= ~@as(u32, @truncate(value));
            self.updateRunState(now_ticks, was_running);
        },
        Reg.PMOVSCLR_EL0 => self.ovsr &= ~@as(u32, @truncate(value)),
        Reg.PMOVSSET_EL0 => self.ovsr |= @truncate(value),
        Reg.PMSELR_EL0 => self.pmselr = @truncate(value & 0x1F),
        Reg.PMCCNTR_EL0 => {
            self.writeCycleCounter(now_ticks, value);
        },
        Reg.PMUSERENR_EL0 => self.pmuserenr = @truncate(value & 0xF),
        Reg.PMINTENSET_EL1 => self.pminten |= @truncate(value),
        Reg.PMINTENCLR_EL1 => self.pminten &= ~@as(u32, @truncate(value)),
        Reg.PMCCFILTR_EL0 => self.pmccfiltr = @truncate(value),
        else => {},
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "register encodings match the architected names" {
    try testing.expectEqual(@as(u32, 0xDCE0), Reg.PMCR_EL0);
    try testing.expectEqual(@as(u32, 0xDCE1), Reg.PMCNTENSET_EL0);
    try testing.expectEqual(@as(u32, 0xDCE8), Reg.PMCCNTR_EL0);
    try testing.expectEqual(@as(u32, 0xDCF0), Reg.PMUSERENR_EL0);
    try testing.expectEqual(@as(u32, 0xDF7F), Reg.PMCCFILTR_EL0);
    try testing.expectEqual(@as(u32, 0xC4F2), Reg.PMINTENCLR_EL1);
    try testing.expect(isPmuReg(0xDF7F));
    try testing.expect(!isPmuReg(0xC600)); // ICC_PMR_EL1 region stays with the GIC
}

test "cycle counter advances only while enabled and counts 1 GHz cycles" {
    var pmu = Pmu{};
    try testing.expectEqual(@as(u64, 0), pmu.read(Reg.PMCCNTR_EL0, 1000));

    // Windows sequence: PMCR = E|P|C|LC-less, enable the cycle counter.
    pmu.write(Reg.PMCR_EL0, PMCR_E | PMCR_P | PMCR_C, 1000);
    pmu.write(Reg.PMCNTENSET_EL0, CYCLE_COUNTER_BIT, 1000);
    try testing.expectEqual(@as(u64, 0), pmu.read(Reg.PMCCNTR_EL0, 1000));
    // 24 ticks == 1 µs == 1000 cycles.
    try testing.expectEqual(@as(u64, 1000), pmu.read(Reg.PMCCNTR_EL0, 1024));

    // Disabling freezes the value; re-enabling resumes without a jump.
    pmu.write(Reg.PMCNTENCLR_EL0, CYCLE_COUNTER_BIT, 1024);
    try testing.expectEqual(@as(u64, 1000), pmu.read(Reg.PMCCNTR_EL0, 5000));
    pmu.write(Reg.PMCNTENSET_EL0, CYCLE_COUNTER_BIT, 5000);
    try testing.expectEqual(@as(u64, 2000), pmu.read(Reg.PMCCNTR_EL0, 5024));
}

test "PMCR read-only fields, 32-bit wrap without LC, and divider" {
    var pmu = Pmu{};
    pmu.write(Reg.PMCR_EL0, PMCR_E, 0);
    try testing.expectEqual(PMCR_RO | PMCR_E, pmu.read(Reg.PMCR_EL0, 0));
    pmu.write(Reg.PMCNTENSET_EL0, CYCLE_COUNTER_BIT, 0);
    pmu.write(Reg.PMCCNTR_EL0, 0xFFFF_FFFF_FFFF_0000, 0);
    try testing.expectEqual(@as(u64, 0xFFFF_0000), pmu.read(Reg.PMCCNTR_EL0, 0));
    pmu.write(Reg.PMCR_EL0, PMCR_E | PMCR_LC, 0);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_0000), pmu.read(Reg.PMCCNTR_EL0, 0));

    pmu.write(Reg.PMCR_EL0, PMCR_E | PMCR_C | PMCR_D | PMCR_LC, 0);
    try testing.expectEqual(@as(u64, 1000 / 64), pmu.read(Reg.PMCCNTR_EL0, 24));
}

test "overflow, interrupt enable and filter registers round-trip" {
    var pmu = Pmu{};
    pmu.write(Reg.PMOVSSET_EL0, 0x8000_0001, 0);
    pmu.write(Reg.PMOVSCLR_EL0, 0x1, 0);
    try testing.expectEqual(@as(u64, 0x8000_0000), pmu.read(Reg.PMOVSCLR_EL0, 0));
    pmu.write(Reg.PMINTENSET_EL1, 0x8000_0000, 0);
    pmu.write(Reg.PMINTENCLR_EL1, 0xFFFF_FFFF, 0);
    try testing.expectEqual(@as(u64, 0), pmu.read(Reg.PMINTENSET_EL1, 0));
    pmu.write(Reg.PMCCFILTR_EL0, 0x0800_0000, 0);
    try testing.expectEqual(@as(u64, 0x0800_0000), pmu.read(Reg.PMCCFILTR_EL0, 0));
    try testing.expectEqual(@as(u64, 0), pmu.read(Reg.PMCEID0_EL0, 0));
}
