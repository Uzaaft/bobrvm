//! Raw Apple Hypervisor.framework bindings.
//!
//! Prefer the wrappers in `vm.zig` and `vcpu.zig`.

const std = @import("std");

// =============================================================================
// Type Aliases
// =============================================================================

pub const hv_return_t = u32;
pub const hv_vcpu_t = u64;
pub const hv_gpaddr_t = u64;
pub const hv_ipa_t = u64;
pub const hv_vm_options_t = u64;
pub const hv_reg_t = u32;
pub const hv_sys_reg_t = u16;
pub const hv_simd_fp_reg_t = u32;
pub const hv_memory_flags_t = u64;
pub const hv_vcpu_config_t = ?*anyopaque;

// =============================================================================
// Return Codes
// =============================================================================

pub const HV_SUCCESS: hv_return_t = 0;
pub const HV_ERROR: hv_return_t = 0xFAE94001;
pub const HV_BUSY: hv_return_t = 0xFAE94002;
pub const HV_BAD_ARGUMENT: hv_return_t = 0xFAE94003;
pub const HV_NO_RESOURCES: hv_return_t = 0xFAE94005;
pub const HV_NO_DEVICE: hv_return_t = 0xFAE94006;
pub const HV_DENIED: hv_return_t = 0xFAE94007;
pub const HV_UNSUPPORTED: hv_return_t = 0xFAE9400F;

// =============================================================================
// Memory Flags
// =============================================================================

pub const HV_MEMORY_READ: hv_memory_flags_t = 1 << 0;
pub const HV_MEMORY_WRITE: hv_memory_flags_t = 1 << 1;
pub const HV_MEMORY_EXEC: hv_memory_flags_t = 1 << 2;

// =============================================================================
// ARM64 General Purpose Registers
// =============================================================================

pub const HV_REG_X0: hv_reg_t = 0;
pub const HV_REG_X1: hv_reg_t = 1;
pub const HV_REG_X2: hv_reg_t = 2;
pub const HV_REG_X3: hv_reg_t = 3;
pub const HV_REG_X4: hv_reg_t = 4;
pub const HV_REG_X5: hv_reg_t = 5;
pub const HV_REG_X6: hv_reg_t = 6;
pub const HV_REG_X7: hv_reg_t = 7;
pub const HV_REG_X8: hv_reg_t = 8;
pub const HV_REG_X9: hv_reg_t = 9;
pub const HV_REG_X10: hv_reg_t = 10;
pub const HV_REG_X11: hv_reg_t = 11;
pub const HV_REG_X12: hv_reg_t = 12;
pub const HV_REG_X13: hv_reg_t = 13;
pub const HV_REG_X14: hv_reg_t = 14;
pub const HV_REG_X15: hv_reg_t = 15;
pub const HV_REG_X16: hv_reg_t = 16;
pub const HV_REG_X17: hv_reg_t = 17;
pub const HV_REG_X18: hv_reg_t = 18;
pub const HV_REG_X19: hv_reg_t = 19;
pub const HV_REG_X20: hv_reg_t = 20;
pub const HV_REG_X21: hv_reg_t = 21;
pub const HV_REG_X22: hv_reg_t = 22;
pub const HV_REG_X23: hv_reg_t = 23;
pub const HV_REG_X24: hv_reg_t = 24;
pub const HV_REG_X25: hv_reg_t = 25;
pub const HV_REG_X26: hv_reg_t = 26;
pub const HV_REG_X27: hv_reg_t = 27;
pub const HV_REG_X28: hv_reg_t = 28;
pub const HV_REG_X29: hv_reg_t = 29; // FP
pub const HV_REG_X30: hv_reg_t = 30; // LR
pub const HV_REG_PC: hv_reg_t = 31;
pub const HV_REG_FPCR: hv_reg_t = 32;
pub const HV_REG_FPSR: hv_reg_t = 33;
pub const HV_REG_CPSR: hv_reg_t = 34;

// =============================================================================
// ARM64 System Registers
// =============================================================================

pub const HV_SYS_REG_DBGBVR0_EL1: hv_sys_reg_t = 0x8004;
pub const HV_SYS_REG_DBGBCR0_EL1: hv_sys_reg_t = 0x8005;
pub const HV_SYS_REG_DBGWVR0_EL1: hv_sys_reg_t = 0x8006;
pub const HV_SYS_REG_DBGWCR0_EL1: hv_sys_reg_t = 0x8007;
pub const HV_SYS_REG_MDSCR_EL1: hv_sys_reg_t = 0x8012;
pub const HV_SYS_REG_MIDR_EL1: hv_sys_reg_t = 0xC000;
pub const HV_SYS_REG_MPIDR_EL1: hv_sys_reg_t = 0xC005;
pub const HV_SYS_REG_ID_AA64PFR0_EL1: hv_sys_reg_t = 0xC020;
pub const HV_SYS_REG_ID_AA64PFR1_EL1: hv_sys_reg_t = 0xC021;
pub const HV_SYS_REG_ID_AA64DFR0_EL1: hv_sys_reg_t = 0xC028;
pub const HV_SYS_REG_ID_AA64DFR1_EL1: hv_sys_reg_t = 0xC029;
pub const HV_SYS_REG_ID_AA64ISAR0_EL1: hv_sys_reg_t = 0xC030;
pub const HV_SYS_REG_ID_AA64ISAR1_EL1: hv_sys_reg_t = 0xC031;
pub const HV_SYS_REG_ID_AA64MMFR0_EL1: hv_sys_reg_t = 0xC038;
pub const HV_SYS_REG_ID_AA64MMFR1_EL1: hv_sys_reg_t = 0xC039;
pub const HV_SYS_REG_ID_AA64MMFR2_EL1: hv_sys_reg_t = 0xC03A;
pub const HV_SYS_REG_SCTLR_EL1: hv_sys_reg_t = 0xC080;
pub const HV_SYS_REG_CPACR_EL1: hv_sys_reg_t = 0xC082;
pub const HV_SYS_REG_TTBR0_EL1: hv_sys_reg_t = 0xC100;
pub const HV_SYS_REG_TTBR1_EL1: hv_sys_reg_t = 0xC101;
pub const HV_SYS_REG_TCR_EL1: hv_sys_reg_t = 0xC102;
pub const HV_SYS_REG_APIAKEYLO_EL1: hv_sys_reg_t = 0xC108;
pub const HV_SYS_REG_APIAKEYHI_EL1: hv_sys_reg_t = 0xC109;
pub const HV_SYS_REG_APIBKEYLO_EL1: hv_sys_reg_t = 0xC10A;
pub const HV_SYS_REG_APIBKEYHI_EL1: hv_sys_reg_t = 0xC10B;
pub const HV_SYS_REG_APDAKEYLO_EL1: hv_sys_reg_t = 0xC110;
pub const HV_SYS_REG_APDAKEYHI_EL1: hv_sys_reg_t = 0xC111;
pub const HV_SYS_REG_APDBKEYLO_EL1: hv_sys_reg_t = 0xC112;
pub const HV_SYS_REG_APDBKEYHI_EL1: hv_sys_reg_t = 0xC113;
pub const HV_SYS_REG_APGAKEYLO_EL1: hv_sys_reg_t = 0xC118;
pub const HV_SYS_REG_APGAKEYHI_EL1: hv_sys_reg_t = 0xC119;
pub const HV_SYS_REG_SPSR_EL1: hv_sys_reg_t = 0xC200;
pub const HV_SYS_REG_ELR_EL1: hv_sys_reg_t = 0xC201;
pub const HV_SYS_REG_SP_EL0: hv_sys_reg_t = 0xC208;
pub const HV_SYS_REG_SP_EL1: hv_sys_reg_t = 0xE208;
pub const HV_SYS_REG_AFSR0_EL1: hv_sys_reg_t = 0xC288;
pub const HV_SYS_REG_AFSR1_EL1: hv_sys_reg_t = 0xC289;
pub const HV_SYS_REG_ESR_EL1: hv_sys_reg_t = 0xC290;
pub const HV_SYS_REG_FAR_EL1: hv_sys_reg_t = 0xC300;
pub const HV_SYS_REG_PAR_EL1: hv_sys_reg_t = 0xC3A0;
pub const HV_SYS_REG_MAIR_EL1: hv_sys_reg_t = 0xC510;
pub const HV_SYS_REG_AMAIR_EL1: hv_sys_reg_t = 0xC518;
pub const HV_SYS_REG_VBAR_EL1: hv_sys_reg_t = 0xC600;
pub const HV_SYS_REG_CONTEXTIDR_EL1: hv_sys_reg_t = 0xC681;
pub const HV_SYS_REG_TPIDR_EL1: hv_sys_reg_t = 0xC684;
pub const HV_SYS_REG_CNTKCTL_EL1: hv_sys_reg_t = 0xC708;
pub const HV_SYS_REG_CSSELR_EL1: hv_sys_reg_t = 0xD000;
pub const HV_SYS_REG_TPIDR_EL0: hv_sys_reg_t = 0xDE82;
pub const HV_SYS_REG_TPIDRRO_EL0: hv_sys_reg_t = 0xDE83;
pub const HV_SYS_REG_CNTV_CTL_EL0: hv_sys_reg_t = 0xDF19;
pub const HV_SYS_REG_CNTV_CVAL_EL0: hv_sys_reg_t = 0xDF1A;

// =============================================================================
// SIMD/FP Registers
// =============================================================================

pub const HV_SIMD_FP_REG_Q0: hv_simd_fp_reg_t = 0;
pub const HV_SIMD_FP_REG_Q1: hv_simd_fp_reg_t = 1;
pub const HV_SIMD_FP_REG_Q2: hv_simd_fp_reg_t = 2;
pub const HV_SIMD_FP_REG_Q3: hv_simd_fp_reg_t = 3;
pub const HV_SIMD_FP_REG_Q4: hv_simd_fp_reg_t = 4;
pub const HV_SIMD_FP_REG_Q5: hv_simd_fp_reg_t = 5;
pub const HV_SIMD_FP_REG_Q6: hv_simd_fp_reg_t = 6;
pub const HV_SIMD_FP_REG_Q7: hv_simd_fp_reg_t = 7;
pub const HV_SIMD_FP_REG_Q8: hv_simd_fp_reg_t = 8;
pub const HV_SIMD_FP_REG_Q9: hv_simd_fp_reg_t = 9;
pub const HV_SIMD_FP_REG_Q10: hv_simd_fp_reg_t = 10;
pub const HV_SIMD_FP_REG_Q11: hv_simd_fp_reg_t = 11;
pub const HV_SIMD_FP_REG_Q12: hv_simd_fp_reg_t = 12;
pub const HV_SIMD_FP_REG_Q13: hv_simd_fp_reg_t = 13;
pub const HV_SIMD_FP_REG_Q14: hv_simd_fp_reg_t = 14;
pub const HV_SIMD_FP_REG_Q15: hv_simd_fp_reg_t = 15;
pub const HV_SIMD_FP_REG_Q16: hv_simd_fp_reg_t = 16;
pub const HV_SIMD_FP_REG_Q17: hv_simd_fp_reg_t = 17;
pub const HV_SIMD_FP_REG_Q18: hv_simd_fp_reg_t = 18;
pub const HV_SIMD_FP_REG_Q19: hv_simd_fp_reg_t = 19;
pub const HV_SIMD_FP_REG_Q20: hv_simd_fp_reg_t = 20;
pub const HV_SIMD_FP_REG_Q21: hv_simd_fp_reg_t = 21;
pub const HV_SIMD_FP_REG_Q22: hv_simd_fp_reg_t = 22;
pub const HV_SIMD_FP_REG_Q23: hv_simd_fp_reg_t = 23;
pub const HV_SIMD_FP_REG_Q24: hv_simd_fp_reg_t = 24;
pub const HV_SIMD_FP_REG_Q25: hv_simd_fp_reg_t = 25;
pub const HV_SIMD_FP_REG_Q26: hv_simd_fp_reg_t = 26;
pub const HV_SIMD_FP_REG_Q27: hv_simd_fp_reg_t = 27;
pub const HV_SIMD_FP_REG_Q28: hv_simd_fp_reg_t = 28;
pub const HV_SIMD_FP_REG_Q29: hv_simd_fp_reg_t = 29;
pub const HV_SIMD_FP_REG_Q30: hv_simd_fp_reg_t = 30;
pub const HV_SIMD_FP_REG_Q31: hv_simd_fp_reg_t = 31;

// =============================================================================
// Exit Reason
// =============================================================================

pub const HV_EXIT_REASON_CANCELED: u32 = 0;
pub const HV_EXIT_REASON_EXCEPTION: u32 = 1;
pub const HV_EXIT_REASON_VTIMER_ACTIVATED: u32 = 2;
pub const HV_EXIT_REASON_UNKNOWN: u32 = 3;

// =============================================================================
// Structures
// =============================================================================

/// SIMD/FP register value (128-bit).
pub const hv_simd_fp_uchar16_t = extern struct {
    bytes: [16]u8,
};

/// vCPU exit information.
pub const hv_vcpu_exit_t = extern struct {
    reason: u32,
    exception: extern struct {
        syndrome: u64,
        virtual_address: u64,
        physical_address: u64,
    },
};

// =============================================================================
// VM Functions
// =============================================================================

pub extern "Hypervisor" fn hv_vm_create(flags: ?*anyopaque) callconv(.c) hv_return_t;
pub extern "Hypervisor" fn hv_vm_destroy() callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vm_map(
    addr: *anyopaque,
    ipa: hv_ipa_t,
    size: usize,
    flags: hv_memory_flags_t,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vm_unmap(
    ipa: hv_ipa_t,
    size: usize,
) callconv(.c) hv_return_t;

// =============================================================================
// vCPU Functions
// =============================================================================

pub extern "Hypervisor" fn hv_vcpu_create(
    vcpu: *hv_vcpu_t,
    exit: **hv_vcpu_exit_t,
    config: hv_vcpu_config_t,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_destroy(
    vcpu: hv_vcpu_t,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_run(
    vcpu: hv_vcpu_t,
) callconv(.c) hv_return_t;

// =============================================================================
// Register Access Functions
// =============================================================================

pub extern "Hypervisor" fn hv_vcpu_get_reg(
    vcpu: hv_vcpu_t,
    reg: hv_reg_t,
    value: *u64,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_set_reg(
    vcpu: hv_vcpu_t,
    reg: hv_reg_t,
    value: u64,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_get_sys_reg(
    vcpu: hv_vcpu_t,
    reg: hv_sys_reg_t,
    value: *u64,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_set_sys_reg(
    vcpu: hv_vcpu_t,
    reg: hv_sys_reg_t,
    value: u64,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_get_simd_fp_reg(
    vcpu: hv_vcpu_t,
    reg: hv_simd_fp_reg_t,
    value: *hv_simd_fp_uchar16_t,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_set_simd_fp_reg(
    vcpu: hv_vcpu_t,
    reg: hv_simd_fp_reg_t,
    value: hv_simd_fp_uchar16_t,
) callconv(.c) hv_return_t;

// =============================================================================
// Pending Interrupt
// =============================================================================

pub const HV_INTERRUPT_TYPE_IRQ: u32 = 0;
pub const HV_INTERRUPT_TYPE_FIQ: u32 = 1;

pub extern "Hypervisor" fn hv_vcpu_get_pending_interrupt(
    vcpu: hv_vcpu_t,
    interrupt_type: u32,
    pending: *bool,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_set_pending_interrupt(
    vcpu: hv_vcpu_t,
    interrupt_type: u32,
    pending: bool,
) callconv(.c) hv_return_t;

// =============================================================================
// vTimer
// =============================================================================

pub extern "Hypervisor" fn hv_vcpu_get_vtimer_mask(
    vcpu: hv_vcpu_t,
    masked: *bool,
) callconv(.c) hv_return_t;

pub extern "Hypervisor" fn hv_vcpu_set_vtimer_mask(
    vcpu: hv_vcpu_t,
    masked: bool,
) callconv(.c) hv_return_t;

// =============================================================================
// vCPU Exit (force exit from another thread)
// =============================================================================

pub extern "Hypervisor" fn hv_vcpus_exit(
    vcpus: [*]const hv_vcpu_t,
    vcpu_count: u32,
) callconv(.c) hv_return_t;

// =============================================================================
// Helper Functions
// =============================================================================

/// Convert hv_return_t to Zig error.
pub fn toError(ret: hv_return_t) ?Error {
    return switch (ret) {
        HV_SUCCESS => null,
        HV_ERROR => Error.HypervisorError,
        HV_BUSY => Error.Busy,
        HV_BAD_ARGUMENT => Error.BadArgument,
        HV_NO_RESOURCES => Error.NoResources,
        HV_NO_DEVICE => Error.NoDevice,
        HV_DENIED => Error.Denied,
        HV_UNSUPPORTED => Error.Unsupported,
        else => Error.HypervisorError,
    };
}

/// Check return value and return error if not success.
pub fn check(ret: hv_return_t) Error!void {
    if (toError(ret)) |err| return err;
}

pub const Error = error{
    HypervisorError,
    Busy,
    BadArgument,
    NoResources,
    NoDevice,
    Denied,
    Unsupported,
};
