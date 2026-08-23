//! ARM register types used to analyze snapshot code on non-Apple hosts.

pub const Register = enum(u8) {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    x8,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x15,
    x16,
    x17,
    x18,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
    x25,
    x26,
    x27,
    x28,
    fp,
    lr,
    pc,
    fpcr,
    fpsr,
    cpsr,
};

pub const SystemRegister = enum(u8) {
    sctlr_el1,
    ttbr0_el1,
    ttbr1_el1,
    tcr_el1,
    mair_el1,
    vbar_el1,
    esr_el1,
    far_el1,
    elr_el1,
    spsr_el1,
    sp_el0,
    sp_el1,
    tpidr_el0,
    tpidr_el1,
    tpidrro_el0,
    cpacr_el1,
    cntv_ctl_el0,
    cntv_cval_el0,
    cntkctl_el1,
    mdscr_el1,
    contextidr_el1,
    par_el1,
    afsr0_el1,
    afsr1_el1,
    amair_el1,
    apiakeylo_el1,
    apiakeyhi_el1,
    apibkeylo_el1,
    apibkeyhi_el1,
    apdakeylo_el1,
    apdakeyhi_el1,
    apdbkeylo_el1,
    apdbkeyhi_el1,
    apgakeylo_el1,
    apgakeyhi_el1,
};

pub const SimdFpRegister = enum(u8) {
    q0 = 0,
    _,
};

pub const Vcpu = struct {
    pub fn getReg(_: *Vcpu, _: Register) error{UnsupportedHost}!u64 {
        return error.UnsupportedHost;
    }

    pub fn setReg(_: *Vcpu, _: Register, _: u64) error{UnsupportedHost}!void {
        return error.UnsupportedHost;
    }

    pub fn getSysReg(_: *Vcpu, _: SystemRegister) error{UnsupportedHost}!u64 {
        return error.UnsupportedHost;
    }

    pub fn setSysReg(_: *Vcpu, _: SystemRegister, _: u64) error{UnsupportedHost}!void {
        return error.UnsupportedHost;
    }

    pub fn getSimdFpReg(_: *Vcpu, _: SimdFpRegister) error{UnsupportedHost}![16]u8 {
        return error.UnsupportedHost;
    }

    pub fn setSimdFpReg(
        _: *Vcpu,
        _: SimdFpRegister,
        _: [16]u8,
    ) error{UnsupportedHost}!void {
        return error.UnsupportedHost;
    }
};
