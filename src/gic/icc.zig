//! Emulates the trapped GICv3 CPU interface system registers.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const gic_module = @import("main.zig");
const Gic = gic_module.Gic;

const log = std.log.scoped(.icc);

/// ICC system-register encodings in `(Op0, Op1, CRn, CRm, Op2)` form.
pub const Reg = struct {
    pub const PMR: u32 = encode(3, 0, 4, 6, 0);
    pub const IAR0: u32 = encode(3, 0, 12, 8, 0);
    pub const IAR1: u32 = encode(3, 0, 12, 12, 0);
    pub const EOIR0: u32 = encode(3, 0, 12, 8, 1);
    pub const EOIR1: u32 = encode(3, 0, 12, 12, 1);
    pub const HPPIR0: u32 = encode(3, 0, 12, 8, 2);
    pub const HPPIR1: u32 = encode(3, 0, 12, 12, 2);
    pub const BPR0: u32 = encode(3, 0, 12, 8, 3);
    pub const BPR1: u32 = encode(3, 0, 12, 12, 3);
    pub const CTLR: u32 = encode(3, 0, 12, 12, 4);
    pub const SRE: u32 = encode(3, 0, 12, 12, 5);
    pub const IGRPEN0: u32 = encode(3, 0, 12, 12, 6);
    pub const IGRPEN1: u32 = encode(3, 0, 12, 12, 7);
    pub const SGI1R: u32 = encode(3, 0, 12, 11, 5);
    pub const SGI0R: u32 = encode(3, 0, 12, 11, 7);
    pub const DIR: u32 = encode(3, 0, 12, 11, 1);
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

    ctlr: u32 = 0,

    /// Running priority (lowest active interrupt priority).
    running_priority: u8 = 0xFF,
};

/// ICC register handler.
pub const IccHandler = struct {
    gic: *Gic,
    states: []IccState,

    pub fn init(allocator: std.mem.Allocator, gic: *Gic, num_cpus: u8) !*IccHandler {
        assert(num_cpus > 0);
        assert(num_cpus <= gic_module.MAX_VCPUS);

        comptime assert(@alignOf(IccHandler) >= @alignOf(IccState));
        const states_offset = std.mem.alignForward(
            usize,
            @sizeOf(IccHandler),
            @alignOf(IccState),
        );
        const allocation_len = states_offset + @sizeOf(IccState) * num_cpus;
        const allocation = try allocator.alignedAlloc(u8, .of(IccHandler), allocation_len);

        const handler: *IccHandler = @ptrCast(allocation.ptr);
        const states_ptr: [*]IccState = @ptrCast(
            @alignCast(allocation.ptr + states_offset),
        );

        handler.* = .{
            .gic = gic,
            .states = states_ptr[0..num_cpus],
        };

        for (handler.states) |*state| {
            state.* = .{};
        }

        return handler;
    }

    pub fn deinit(self: *IccHandler, allocator: std.mem.Allocator) void {
        assert(self.states.len > 0);
        assert(self.states.len <= gic_module.MAX_VCPUS);

        const states_offset = std.mem.alignForward(
            usize,
            @sizeOf(IccHandler),
            @alignOf(IccState),
        );
        const allocation_len = states_offset + @sizeOf(IccState) * self.states.len;
        const allocation_ptr: [*]align(@alignOf(IccHandler)) u8 = @ptrCast(self);
        allocator.free(allocation_ptr[0..allocation_len]);
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

        const reg = (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2;

        return .{ .reg = reg, .rt = rt, .is_read = is_read };
    }

    /// Handle ICC register read.
    pub fn read(self: *IccHandler, cpu_id: u8, reg: u32) u64 {
        if (cpu_id >= self.states.len) return 0;
        const state = &self.states[cpu_id];

        return switch (reg) {
            Reg.PMR => state.pmr,
            Reg.IAR0 => if (state.igrpen0)
                self.gic.ackInterruptForGroup(cpu_id, 0, state.pmr)
            else
                1023,
            Reg.IAR1 => if (state.igrpen1)
                self.gic.ackInterruptForGroup(cpu_id, 1, state.pmr)
            else
                1023,
            Reg.HPPIR0 => self.gic.peekInterruptForGroup(cpu_id, 0, state.pmr),
            Reg.HPPIR1 => self.gic.peekInterruptForGroup(cpu_id, 1, state.pmr),
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
        const intid: u32 = @truncate((value >> 24) & 0xF);
        const target_list: u16 = @truncate(value);
        const irm = (value >> 40) & 1; // Interrupt Routing Mode

        self.gic.sendSgi(source_cpu, intid, target_list, irm == 1);
    }
};

test "ICC IAR1 honors its group enable and priority mask" {
    const gic = try Gic.init(std.testing.allocator, 1);
    defer gic.deinit();
    const handler = try IccHandler.init(std.testing.allocator, gic, 1);
    defer handler.deinit(std.testing.allocator);

    const sgi_frame = gic_module.GICR.SGI_OFFSET;
    gic.redistWrite(sgi_frame + gic_module.GICR.ISENABLER0, 4, 1 << 5);
    gic.setPpiPending(0, 5, true);

    try std.testing.expectEqual(@as(u64, 1023), handler.read(0, Reg.IAR1));
    handler.write(0, Reg.IGRPEN1, 1);
    handler.write(0, Reg.PMR, 0x80);
    try std.testing.expectEqual(@as(u64, 1023), handler.read(0, Reg.IAR1));

    handler.write(0, Reg.PMR, 0xB0);
    try std.testing.expectEqual(@as(u64, 5), handler.read(0, Reg.IAR1));
}

test "ICC HPPIR1 reports the highest pending interrupt without acknowledging it" {
    const gic = try Gic.init(std.testing.allocator, 1);
    defer gic.deinit();
    const handler = try IccHandler.init(std.testing.allocator, gic, 1);
    defer handler.deinit(std.testing.allocator);

    const sgi_frame = gic_module.GICR.SGI_OFFSET;
    gic.redistWrite(sgi_frame + gic_module.GICR.ISENABLER0, 4, 1 << 5);
    gic.setPpiPending(0, 5, true);
    handler.write(0, Reg.IGRPEN1, 1);
    handler.write(0, Reg.PMR, 0xB0);

    try std.testing.expectEqual(@as(u64, 5), handler.read(0, Reg.HPPIR1));
    try std.testing.expectEqual(@as(u64, 5), handler.read(0, Reg.IAR1));
}
