//! ICC (Interrupt Controller CPU Interface) System Register Emulation.
//!
//! The GICv3 CPU interface is accessed via ICC_* system registers.
//! These are trapped and emulated to interact with the GIC.
//!
//! Key registers:
//! - ICC_IAR1_EL1: Interrupt Acknowledge (read to get pending INTID)
//! - ICC_EOIR1_EL1: End Of Interrupt (write to signal completion)
//! - ICC_PMR_EL1: Priority Mask Register
//! - ICC_CTLR_EL1: Control Register
//! - ICC_SRE_EL1: System Register Enable
//! - ICC_IGRPEN1_EL1: Group 1 Enable

const std = @import("std");
const Gic = @import("main.zig").Gic;

const log = std.log.scoped(.icc);

/// ICC system register encodings.
/// Format: Op0=3, Op1, CRn, CRm, Op2
pub const Reg = struct {
    // Register encoding: (Op0 << 14) | (Op1 << 11) | (CRn << 7) | (CRm << 3) | Op2
    // For ICC registers: Op0=3, CRn=12

    /// ICC_PMR_EL1: Priority Mask Register
    /// MRS/MSR encoding: S3_0_C4_C6_0
    pub const PMR: u32 = encode(3, 0, 4, 6, 0);

    /// ICC_IAR0_EL1: Interrupt Acknowledge Register (Group 0)
    pub const IAR0: u32 = encode(3, 0, 12, 8, 0);

    /// ICC_IAR1_EL1: Interrupt Acknowledge Register (Group 1)
    pub const IAR1: u32 = encode(3, 0, 12, 12, 0);

    /// ICC_EOIR0_EL1: End of Interrupt Register (Group 0)
    pub const EOIR0: u32 = encode(3, 0, 12, 8, 1);

    /// ICC_EOIR1_EL1: End of Interrupt Register (Group 1)
    pub const EOIR1: u32 = encode(3, 0, 12, 12, 1);

    /// ICC_HPPIR0_EL1: Highest Priority Pending Interrupt (Group 0)
    pub const HPPIR0: u32 = encode(3, 0, 12, 8, 2);

    /// ICC_HPPIR1_EL1: Highest Priority Pending Interrupt (Group 1)
    pub const HPPIR1: u32 = encode(3, 0, 12, 12, 2);

    /// ICC_BPR0_EL1: Binary Point Register (Group 0)
    pub const BPR0: u32 = encode(3, 0, 12, 8, 3);

    /// ICC_BPR1_EL1: Binary Point Register (Group 1)
    pub const BPR1: u32 = encode(3, 0, 12, 12, 3);

    /// ICC_CTLR_EL1: Control Register
    pub const CTLR: u32 = encode(3, 0, 12, 12, 4);

    /// ICC_SRE_EL1: System Register Enable
    pub const SRE: u32 = encode(3, 0, 12, 12, 5);

    /// ICC_IGRPEN0_EL1: Group 0 Enable
    pub const IGRPEN0: u32 = encode(3, 0, 12, 12, 6);

    /// ICC_IGRPEN1_EL1: Group 1 Enable
    pub const IGRPEN1: u32 = encode(3, 0, 12, 12, 7);

    /// ICC_SGI1R_EL1: Software Generated Interrupt (Group 1)
    pub const SGI1R: u32 = encode(3, 0, 12, 11, 5);

    /// ICC_SGI0R_EL1: Software Generated Interrupt (Group 0)
    pub const SGI0R: u32 = encode(3, 0, 12, 11, 7);

    /// ICC_DIR_EL1: Deactivate Interrupt
    pub const DIR: u32 = encode(3, 0, 12, 11, 1);

    /// ICC_RPR_EL1: Running Priority
    pub const RPR: u32 = encode(3, 0, 12, 11, 3);

    fn encode(op0: u32, op1: u32, crn: u32, crm: u32, op2: u32) u32 {
        return (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2;
    }
};

/// Per-CPU ICC state.
pub const IccState = struct {
    /// Priority Mask (0xFF = all interrupts enabled).
    pmr: u8 = 0xFF,

    /// Binary Point Register (preemption grouping).
    bpr0: u8 = 0,
    bpr1: u8 = 0,

    /// Group enables.
    igrpen0: bool = false,
    igrpen1: bool = false,

    /// Control register.
    ctlr: u32 = 0,

    /// Running priority (lowest active interrupt priority).
    running_priority: u8 = 0xFF,
};

/// ICC register handler.
pub const IccHandler = struct {
    gic: *Gic,
    states: []IccState,

    pub fn init(allocator: std.mem.Allocator, gic: *Gic, num_cpus: u8) !*IccHandler {
        const handler = try allocator.create(IccHandler);
        errdefer allocator.destroy(handler);

        handler.* = .{
            .gic = gic,
            .states = try allocator.alloc(IccState, num_cpus),
        };

        for (handler.states) |*state| {
            state.* = .{};
        }

        return handler;
    }

    pub fn deinit(self: *IccHandler, allocator: std.mem.Allocator) void {
        allocator.free(self.states);
        allocator.destroy(self);
    }

    /// Decode ISS from MSR/MRS trap and extract register encoding.
    /// ISS format: [24:22]=Op0, [21:19]=Op2, [18:16]=Op1, [15:12]=CRn, [11:8]=Rt, [4:1]=CRm, [0]=direction
    pub fn decodeIss(iss: u32) struct { reg: u32, rt: u5, is_read: bool } {
        const op0: u32 = (iss >> 20) & 0x3;
        const op2: u32 = (iss >> 17) & 0x7;
        const op1: u32 = (iss >> 14) & 0x7;
        const crn: u32 = (iss >> 10) & 0xF;
        const rt: u5 = @truncate((iss >> 5) & 0x1F);
        const crm: u32 = (iss >> 1) & 0xF;
        const is_read = (iss & 1) == 1;

        // Reconstruct register encoding
        const reg = (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2;

        return .{ .reg = reg, .rt = rt, .is_read = is_read };
    }

    /// Handle ICC register read.
    pub fn read(self: *IccHandler, cpu_id: u8, reg: u32) u64 {
        if (cpu_id >= self.states.len) return 0;
        const state = &self.states[cpu_id];

        return switch (reg) {
            Reg.PMR => state.pmr,
            Reg.IAR0, Reg.IAR1 => self.gic.ackInterrupt(cpu_id),
            Reg.HPPIR0, Reg.HPPIR1 => 1023, // TODO: implement without ack
            Reg.BPR0 => state.bpr0,
            Reg.BPR1 => state.bpr1,
            Reg.CTLR => state.ctlr,
            Reg.SRE => 0x7, // SRE=1, DIB=1, DFB=1 (system registers enabled, no bypass)
            Reg.IGRPEN0 => @intFromBool(state.igrpen0),
            Reg.IGRPEN1 => @intFromBool(state.igrpen1),
            Reg.RPR => state.running_priority,
            else => blk: {
                log.debug("CPU{}: ICC read unknown reg 0x{x}", .{ cpu_id, reg });
                break :blk 0;
            },
        };
    }

    /// Handle ICC register write.
    pub fn write(self: *IccHandler, cpu_id: u8, reg: u32, value: u64) void {
        if (cpu_id >= self.states.len) return;
        const state = &self.states[cpu_id];

        switch (reg) {
            Reg.PMR => state.pmr = @truncate(value),
            Reg.EOIR0, Reg.EOIR1 => {
                const intid: u32 = @truncate(value & 0xFFFFFF);
                self.gic.endInterrupt(cpu_id, intid);
            },
            Reg.BPR0 => state.bpr0 = @truncate(value),
            Reg.BPR1 => state.bpr1 = @truncate(value),
            Reg.CTLR => state.ctlr = @truncate(value),
            Reg.IGRPEN0 => {
                state.igrpen0 = (value & 1) != 0;
                log.debug("CPU{}: IGRPEN0 = {}", .{ cpu_id, state.igrpen0 });
            },
            Reg.IGRPEN1 => {
                state.igrpen1 = (value & 1) != 0;
                log.debug("CPU{}: IGRPEN1 = {}", .{ cpu_id, state.igrpen1 });
            },
            Reg.SGI0R, Reg.SGI1R => {
                // Software Generated Interrupt
                self.handleSgi(cpu_id, value);
            },
            Reg.DIR => {
                // Deactivate Interrupt (for split EOI mode)
                const intid: u32 = @truncate(value & 0xFFFFFF);
                self.gic.endInterrupt(cpu_id, intid);
            },
            Reg.SRE => {
                // SRE is read-only (system registers always enabled)
            },
            else => {
                log.debug("CPU{}: ICC write unknown reg 0x{x} = 0x{x}", .{ cpu_id, reg, value });
            },
        }
    }

    fn handleSgi(self: *IccHandler, source_cpu: u8, value: u64) void {
        _ = self;
        const intid: u32 = @truncate((value >> 24) & 0xF);
        const target_list: u16 = @truncate(value);
        const irm = (value >> 40) & 1; // Interrupt Routing Mode

        log.debug("CPU{}: SGI {} target_list=0x{x} irm={}", .{ source_cpu, intid, target_list, irm });

        // TODO: Send SGI to target CPUs
    }
};
