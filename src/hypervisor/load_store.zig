//! AArch64 instruction decoding and register writeback for MMIO exits.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Vcpu = @import("vcpu.zig").Vcpu;
const Register = @import("vcpu.zig").Register;
const SystemRegister = @import("vcpu.zig").SystemRegister;

/// Decoded load/store instruction info
pub const LoadStoreInfo = struct {
    is_write: bool,
    size: u8,
    rt: u5,
    // For post-indexed addressing: base register and increment
    writeback_rn: ?u5 = null,
    writeback_imm: i64 = 0,
};

/// Result of instruction decode
pub const DecodeResult = union(enum) {
    load_store: LoadStoreInfo,
    cache_op, // DC CIVAC, etc. - skip
    unknown,
};

pub fn applyLoadStoreWriteback(vcpu: *Vcpu, rn: u5, delta: i64) !void {
    assert(delta >= -256);
    assert(delta <= 255);

    if (rn == 31) {
        const pstate = try vcpu.getReg(.cpsr);
        const sp_register: SystemRegister = if (pstate & 1 == 0)
            .sp_el0
        else
            .sp_el1;
        const base = try vcpu.getSysReg(sp_register);
        const updated = if (delta >= 0)
            base +% @as(u64, @intCast(delta))
        else
            base -% @as(u64, @intCast(-delta));
        try vcpu.setSysReg(sp_register, updated);
        return;
    }

    const register: Register = @enumFromInt(rn);
    const base = try vcpu.getReg(register);
    const updated = if (delta >= 0)
        base +% @as(u64, @intCast(delta))
    else
        base -% @as(u64, @intCast(-delta));
    try vcpu.setReg(register, updated);
}

/// Decode AArch64 load/store instruction to determine access type
pub fn decodeLoadStore(instr: u32) DecodeResult {
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

    return .unknown;
}

test "load-store decoder rejects unrelated instructions" {
    try std.testing.expectEqual(DecodeResult.unknown, decodeLoadStore(0x14000000));
}

test "load-store decoder identifies system instructions" {
    try std.testing.expectEqual(DecodeResult.cache_op, decodeLoadStore(0xD50B7E20));
}
