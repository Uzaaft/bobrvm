//! Virtual CPU wrapper for Apple Hypervisor.framework.
//!
//! Manages vCPU execution, register access, and interrupt handling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const c = @import("c.zig");

/// ARM64 general-purpose registers.
pub const Register = enum(c.hv_reg_t) {
    x0 = c.HV_REG_X0,
    x1 = c.HV_REG_X1,
    x2 = c.HV_REG_X2,
    x3 = c.HV_REG_X3,
    x4 = c.HV_REG_X4,
    x5 = c.HV_REG_X5,
    x6 = c.HV_REG_X6,
    x7 = c.HV_REG_X7,
    x8 = c.HV_REG_X8,
    x9 = c.HV_REG_X9,
    x10 = c.HV_REG_X10,
    x11 = c.HV_REG_X11,
    x12 = c.HV_REG_X12,
    x13 = c.HV_REG_X13,
    x14 = c.HV_REG_X14,
    x15 = c.HV_REG_X15,
    x16 = c.HV_REG_X16,
    x17 = c.HV_REG_X17,
    x18 = c.HV_REG_X18,
    x19 = c.HV_REG_X19,
    x20 = c.HV_REG_X20,
    x21 = c.HV_REG_X21,
    x22 = c.HV_REG_X22,
    x23 = c.HV_REG_X23,
    x24 = c.HV_REG_X24,
    x25 = c.HV_REG_X25,
    x26 = c.HV_REG_X26,
    x27 = c.HV_REG_X27,
    x28 = c.HV_REG_X28,
    fp = c.HV_REG_X29, // Frame pointer
    lr = c.HV_REG_X30, // Link register
    pc = c.HV_REG_PC,
    fpcr = c.HV_REG_FPCR,
    fpsr = c.HV_REG_FPSR,
    cpsr = c.HV_REG_CPSR,
};

/// ARM64 system registers.
pub const SystemRegister = enum(c.hv_sys_reg_t) {
    // Memory management
    sctlr_el1 = c.HV_SYS_REG_SCTLR_EL1,
    ttbr0_el1 = c.HV_SYS_REG_TTBR0_EL1,
    ttbr1_el1 = c.HV_SYS_REG_TTBR1_EL1,
    tcr_el1 = c.HV_SYS_REG_TCR_EL1,
    mair_el1 = c.HV_SYS_REG_MAIR_EL1,

    // Exception handling
    vbar_el1 = c.HV_SYS_REG_VBAR_EL1,
    esr_el1 = c.HV_SYS_REG_ESR_EL1,
    far_el1 = c.HV_SYS_REG_FAR_EL1,
    elr_el1 = c.HV_SYS_REG_ELR_EL1,
    spsr_el1 = c.HV_SYS_REG_SPSR_EL1,

    // Stack pointers
    sp_el0 = c.HV_SYS_REG_SP_EL0,
    sp_el1 = c.HV_SYS_REG_SP_EL1,

    // Thread ID
    tpidr_el0 = c.HV_SYS_REG_TPIDR_EL0,
    tpidr_el1 = c.HV_SYS_REG_TPIDR_EL1,
    tpidrro_el0 = c.HV_SYS_REG_TPIDRRO_EL0,

    // CPU identification
    midr_el1 = c.HV_SYS_REG_MIDR_EL1,
    mpidr_el1 = c.HV_SYS_REG_MPIDR_EL1,

    // Feature identification
    id_aa64pfr0_el1 = c.HV_SYS_REG_ID_AA64PFR0_EL1,
    id_aa64pfr1_el1 = c.HV_SYS_REG_ID_AA64PFR1_EL1,
    id_aa64mmfr0_el1 = c.HV_SYS_REG_ID_AA64MMFR0_EL1,
    id_aa64mmfr1_el1 = c.HV_SYS_REG_ID_AA64MMFR1_EL1,
    id_aa64mmfr2_el1 = c.HV_SYS_REG_ID_AA64MMFR2_EL1,
    id_aa64isar0_el1 = c.HV_SYS_REG_ID_AA64ISAR0_EL1,
    id_aa64isar1_el1 = c.HV_SYS_REG_ID_AA64ISAR1_EL1,

    // Coprocessor access
    cpacr_el1 = c.HV_SYS_REG_CPACR_EL1,

    // Timer
    cntv_ctl_el0 = c.HV_SYS_REG_CNTV_CTL_EL0,
    cntv_cval_el0 = c.HV_SYS_REG_CNTV_CVAL_EL0,
    cntkctl_el1 = c.HV_SYS_REG_CNTKCTL_EL1,

    // Debug
    mdscr_el1 = c.HV_SYS_REG_MDSCR_EL1,

    // Context
    contextidr_el1 = c.HV_SYS_REG_CONTEXTIDR_EL1,

    // Address translation
    par_el1 = c.HV_SYS_REG_PAR_EL1,

    // Auxiliary
    afsr0_el1 = c.HV_SYS_REG_AFSR0_EL1,
    afsr1_el1 = c.HV_SYS_REG_AFSR1_EL1,
    amair_el1 = c.HV_SYS_REG_AMAIR_EL1,
};

/// SIMD/FP registers (Q0-Q31, 128-bit each).
pub const SimdFpRegister = enum(c.hv_simd_fp_reg_t) {
    q0 = c.HV_SIMD_FP_REG_Q0,
    q1 = c.HV_SIMD_FP_REG_Q1,
    q2 = c.HV_SIMD_FP_REG_Q2,
    q3 = c.HV_SIMD_FP_REG_Q3,
    q4 = c.HV_SIMD_FP_REG_Q4,
    q5 = c.HV_SIMD_FP_REG_Q5,
    q6 = c.HV_SIMD_FP_REG_Q6,
    q7 = c.HV_SIMD_FP_REG_Q7,
    q8 = c.HV_SIMD_FP_REG_Q8,
    q9 = c.HV_SIMD_FP_REG_Q9,
    q10 = c.HV_SIMD_FP_REG_Q10,
    q11 = c.HV_SIMD_FP_REG_Q11,
    q12 = c.HV_SIMD_FP_REG_Q12,
    q13 = c.HV_SIMD_FP_REG_Q13,
    q14 = c.HV_SIMD_FP_REG_Q14,
    q15 = c.HV_SIMD_FP_REG_Q15,
    q16 = c.HV_SIMD_FP_REG_Q16,
    q17 = c.HV_SIMD_FP_REG_Q17,
    q18 = c.HV_SIMD_FP_REG_Q18,
    q19 = c.HV_SIMD_FP_REG_Q19,
    q20 = c.HV_SIMD_FP_REG_Q20,
    q21 = c.HV_SIMD_FP_REG_Q21,
    q22 = c.HV_SIMD_FP_REG_Q22,
    q23 = c.HV_SIMD_FP_REG_Q23,
    q24 = c.HV_SIMD_FP_REG_Q24,
    q25 = c.HV_SIMD_FP_REG_Q25,
    q26 = c.HV_SIMD_FP_REG_Q26,
    q27 = c.HV_SIMD_FP_REG_Q27,
    q28 = c.HV_SIMD_FP_REG_Q28,
    q29 = c.HV_SIMD_FP_REG_Q29,
    q30 = c.HV_SIMD_FP_REG_Q30,
    q31 = c.HV_SIMD_FP_REG_Q31,
};

/// vCPU exit reason.
pub const ExitReason = enum(u32) {
    /// vCPU was interrupted.
    canceled = c.HV_EXIT_REASON_CANCELED,
    /// Guest triggered an exception (trap).
    exception = c.HV_EXIT_REASON_EXCEPTION,
    /// Virtual timer activated.
    vtimer_activated = c.HV_EXIT_REASON_VTIMER_ACTIVATED,
    /// Unknown exit reason.
    unknown = c.HV_EXIT_REASON_UNKNOWN,
};

/// Exception class (EC field of ESR_EL2).
pub const ExceptionClass = enum(u6) {
    unknown = 0x00,
    wf_trapped = 0x01, // WFI/WFE
    mcr_mrc_cp15 = 0x03,
    mcrr_mrrc_cp15 = 0x04,
    mcr_mrc_cp14 = 0x05,
    ldc_stc_cp14 = 0x06,
    fp_simd_access = 0x07,
    pauth_trapped = 0x09,
    ld_st_pc_align = 0x0A,
    mrrc_cp14 = 0x0C,
    branch_target = 0x0D,
    illegal_state = 0x0E,
    svc_aarch32 = 0x11,
    hvc_aarch32 = 0x12,
    smc_aarch32 = 0x13,
    svc_aarch64 = 0x15,
    hvc_aarch64 = 0x16,
    smc_aarch64 = 0x17,
    msr_mrs_system = 0x18,
    sve_access = 0x19,
    pac_failure = 0x1C,
    inst_abort_lower = 0x20,
    inst_abort_same = 0x21,
    pc_alignment = 0x22,
    data_abort_lower = 0x24,
    data_abort_same = 0x25,
    sp_alignment = 0x26,
    fp_exception_32 = 0x28,
    fp_exception_64 = 0x2C,
    serror = 0x2F,
    breakpoint_lower = 0x30,
    breakpoint_same = 0x31,
    software_step_lower = 0x32,
    software_step_same = 0x33,
    watchpoint_lower = 0x34,
    watchpoint_same = 0x35,
    bkpt_aarch32 = 0x38,
    brk_aarch64 = 0x3C,
    _,
};

/// Interrupt type.
pub const InterruptType = enum(u32) {
    irq = c.HV_INTERRUPT_TYPE_IRQ,
    fiq = c.HV_INTERRUPT_TYPE_FIQ,
};

/// vCPU exit information.
pub const ExitInfo = struct {
    reason: ExitReason,
    syndrome: u64,
    virtual_address: u64,
    physical_address: u64,

    /// Extract exception class from syndrome.
    pub fn exceptionClass(self: ExitInfo) ExceptionClass {
        const ec: u6 = @truncate(self.syndrome >> 26);
        return @enumFromInt(ec);
    }

    /// Extract instruction length from syndrome (0 = 16-bit, 1 = 32-bit).
    pub fn instructionLength(self: ExitInfo) u1 {
        return @truncate(self.syndrome >> 25);
    }

    /// Extract instruction-specific syndrome (ISS).
    pub fn iss(self: ExitInfo) u25 {
        return @truncate(self.syndrome);
    }

    /// Check if this is a data abort.
    pub fn isDataAbort(self: ExitInfo) bool {
        const ec = self.exceptionClass();
        return ec == .data_abort_lower or ec == .data_abort_same;
    }

    /// Check if this is an instruction abort.
    pub fn isInstructionAbort(self: ExitInfo) bool {
        const ec = self.exceptionClass();
        return ec == .inst_abort_lower or ec == .inst_abort_same;
    }

    /// Check if data abort was a write.
    pub fn isWrite(self: ExitInfo) bool {
        return self.iss() & (1 << 6) != 0;
    }

    /// Get data transfer size for data aborts (0=byte, 1=halfword, 2=word, 3=doubleword).
    pub fn accessSize(self: ExitInfo) u2 {
        return @truncate(self.iss() >> 22);
    }
};

/// Virtual CPU instance.
pub const Vcpu = struct {
    alloc: Allocator,
    handle: c.hv_vcpu_t,
    exit: *c.hv_vcpu_exit_t,
    created: bool,

    pub const Error = c.Error || Allocator.Error;

    /// Create a new vCPU.
    pub fn create(alloc: Allocator) Error!*Vcpu {
        var handle: c.hv_vcpu_t = undefined;
        var exit: *c.hv_vcpu_exit_t = undefined;

        const ret = c.hv_vcpu_create(&handle, &exit, null);
        try c.check(ret);

        const vcpu = try alloc.create(Vcpu);
        vcpu.* = .{
            .alloc = alloc,
            .handle = handle,
            .exit = exit,
            .created = true,
        };

        // Post-condition: vCPU is created
        assert(vcpu.created);

        return vcpu;
    }

    /// Destroy the vCPU.
    pub fn destroy(self: *Vcpu) void {
        if (self.created) {
            _ = c.hv_vcpu_destroy(self.handle);
            self.created = false;
        }
        self.alloc.destroy(self);
    }

    /// Run the vCPU until it exits.
    pub fn run(self: *Vcpu) Error!ExitInfo {
        // Pre-condition: vCPU is valid
        assert(self.created);

        const ret = c.hv_vcpu_run(self.handle);
        try c.check(ret);

        return .{
            .reason = @enumFromInt(self.exit.reason),
            .syndrome = self.exit.exception.syndrome,
            .virtual_address = self.exit.exception.virtual_address,
            .physical_address = self.exit.exception.physical_address,
        };
    }

    // -------------------------------------------------------------------------
    // General Purpose Registers
    // -------------------------------------------------------------------------

    /// Get a general-purpose register value.
    pub fn getReg(self: *Vcpu, reg: Register) Error!u64 {
        assert(self.created);
        var value: u64 = undefined;
        const ret = c.hv_vcpu_get_reg(self.handle, @intFromEnum(reg), &value);
        try c.check(ret);
        return value;
    }

    /// Set a general-purpose register value.
    pub fn setReg(self: *Vcpu, reg: Register, value: u64) Error!void {
        assert(self.created);
        const ret = c.hv_vcpu_set_reg(self.handle, @intFromEnum(reg), value);
        try c.check(ret);
    }

    // -------------------------------------------------------------------------
    // System Registers
    // -------------------------------------------------------------------------

    /// Get a system register value.
    pub fn getSysReg(self: *Vcpu, reg: SystemRegister) Error!u64 {
        assert(self.created);
        var value: u64 = undefined;
        const ret = c.hv_vcpu_get_sys_reg(self.handle, @intFromEnum(reg), &value);
        try c.check(ret);
        return value;
    }

    /// Set a system register value.
    pub fn setSysReg(self: *Vcpu, reg: SystemRegister, value: u64) Error!void {
        assert(self.created);
        const ret = c.hv_vcpu_set_sys_reg(self.handle, @intFromEnum(reg), value);
        try c.check(ret);
    }

    // -------------------------------------------------------------------------
    // SIMD/FP Registers
    // -------------------------------------------------------------------------

    /// Get a SIMD/FP register value (128-bit).
    pub fn getSimdFpReg(self: *Vcpu, reg: SimdFpRegister) Error![16]u8 {
        assert(self.created);
        var value: c.hv_simd_fp_uchar16_t = undefined;
        const ret = c.hv_vcpu_get_simd_fp_reg(self.handle, @intFromEnum(reg), &value);
        try c.check(ret);
        return value.bytes;
    }

    /// Set a SIMD/FP register value (128-bit).
    pub fn setSimdFpReg(self: *Vcpu, reg: SimdFpRegister, value: [16]u8) Error!void {
        assert(self.created);
        const ret = c.hv_vcpu_set_simd_fp_reg(self.handle, @intFromEnum(reg), .{ .bytes = value });
        try c.check(ret);
    }

    // -------------------------------------------------------------------------
    // Interrupts
    // -------------------------------------------------------------------------

    /// Check if an interrupt is pending.
    pub fn getPendingInterrupt(self: *Vcpu, int_type: InterruptType) Error!bool {
        assert(self.created);
        var pending: bool = undefined;
        const ret = c.hv_vcpu_get_pending_interrupt(self.handle, @intFromEnum(int_type), &pending);
        try c.check(ret);
        return pending;
    }

    /// Set a pending interrupt.
    pub fn setPendingInterrupt(self: *Vcpu, int_type: InterruptType, pending: bool) Error!void {
        assert(self.created);
        const ret = c.hv_vcpu_set_pending_interrupt(self.handle, @intFromEnum(int_type), pending);
        try c.check(ret);
    }

    // -------------------------------------------------------------------------
    // Virtual Timer
    // -------------------------------------------------------------------------

    /// Get virtual timer mask state.
    pub fn getVTimerMask(self: *Vcpu) Error!bool {
        assert(self.created);
        var masked: bool = undefined;
        const ret = c.hv_vcpu_get_vtimer_mask(self.handle, &masked);
        try c.check(ret);
        return masked;
    }

    /// Set virtual timer mask.
    pub fn setVTimerMask(self: *Vcpu, masked: bool) Error!void {
        assert(self.created);
        const ret = c.hv_vcpu_set_vtimer_mask(self.handle, masked);
        try c.check(ret);
    }

    // -------------------------------------------------------------------------
    // Convenience Methods
    // -------------------------------------------------------------------------

    /// Get program counter.
    pub fn getPC(self: *Vcpu) Error!u64 {
        return self.getReg(.pc);
    }

    /// Set program counter.
    pub fn setPC(self: *Vcpu, pc: u64) Error!void {
        return self.setReg(.pc, pc);
    }

    /// Get stack pointer (SP_EL0).
    pub fn getSP(self: *Vcpu) Error!u64 {
        return self.getSysReg(.sp_el0);
    }

    /// Set stack pointer (SP_EL0).
    pub fn setSP(self: *Vcpu, sp: u64) Error!void {
        return self.setSysReg(.sp_el0, sp);
    }

    /// Advance PC past current instruction.
    pub fn advancePC(self: *Vcpu, exit_info: ExitInfo) Error!void {
        const pc = try self.getPC();
        const len: u64 = if (exit_info.instructionLength() == 1) 4 else 2;
        try self.setPC(pc + len);
    }

    /// Force the vCPU to exit from hv_vcpu_run().
    /// Can be called from another thread.
    pub fn forceExit(self: *Vcpu) Error!void {
        assert(self.created);
        const handles = [1]c.hv_vcpu_t{self.handle};
        const ret = c.hv_vcpus_exit(&handles, 1);
        try c.check(ret);
    }

    /// Get the raw vCPU handle (for hv_vcpus_exit batching).
    pub fn getHandle(self: *const Vcpu) c.hv_vcpu_t {
        return self.handle;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ExitInfo syndrome parsing" {
    // EC=0x24 (data_abort_lower), IL=1 (32-bit), ISS=0x50
    const info = ExitInfo{
        .reason = .exception,
        .syndrome = 0x92000050, // 0x24 << 26 | 1 << 25 | 0x50
        .virtual_address = 0x1000,
        .physical_address = 0x2000,
    };

    try std.testing.expectEqual(ExceptionClass.data_abort_lower, info.exceptionClass());
    try std.testing.expectEqual(@as(u1, 1), info.instructionLength());
    try std.testing.expect(info.isDataAbort());
    try std.testing.expect(!info.isInstructionAbort());
}

test "Register enum values" {
    try std.testing.expectEqual(@as(c.hv_reg_t, 0), @intFromEnum(Register.x0));
    try std.testing.expectEqual(@as(c.hv_reg_t, 30), @intFromEnum(Register.lr));
    try std.testing.expectEqual(@as(c.hv_reg_t, 31), @intFromEnum(Register.pc));
}
