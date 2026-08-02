//! Machine state serialization (suspend/snapshot substrate).
//!
//! A snapshot is a sequence of named sections:
//!   magic "BBRSNAP1" + version u32 + sections:
//!   { name_len u8, name bytes, size u64, data }
//! Guest RAM is NOT a section here — the suspend-to-disk layer streams
//! it separately (it dwarfs everything else).
//!
//! What is captured: vCPU registers (GP + sysregs + SIMD; capture must
//! run on the vCPU's owning thread — HVF rejects cross-thread register
//! access, so the machine hops the request over to the parked thread),
//! the fully-emulated GIC, every virtio transport (status/features/
//! queues), and per-device cursors/state. Deliberately NOT captured:
//! mininat flows (host sockets can't survive a suspend; the guest's TCP
//! retransmits/reconnects, same story as any laptop sleep) and virgl 3D
//! contexts (reset on restore, QEMU's policy too).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const hypervisor = @import("../hypervisor/main.zig");
const virtio = @import("../virtio/main.zig");
const gic_mod = @import("../gic/main.zig");
const mmio = @import("../virtio/mmio.zig");

const log = std.log.scoped(.snapshot);

pub const MAGIC = "BBRSNAP1";
pub const VERSION: u32 = 1;
const block_section_scratch_bytes = 128;
const gic_section_scratch_bytes = 2 * 1024;

// =============================================================================
// vCPU state
// =============================================================================

/// Everything needed to freeze/thaw one vCPU. Extern struct: serialized
/// by memcpy, so field order is ABI (bump VERSION on change).
pub const VcpuState = extern struct {
    /// x0..x28, fp(x29), lr(x30).
    gp: [31]u64 = @splat(0),
    pc: u64 = 0,
    cpsr: u64 = 0,
    fpcr: u64 = 0,
    fpsr: u64 = 0,
    sys: [35]u64 = @splat(0),
    simd: [32][16]u8 = @splat(@splat(0)),
};

/// Writable system registers, in VcpuState.sys order.
pub const sys_regs = [_]hypervisor.SystemRegister{
    .sctlr_el1,      .ttbr0_el1,     .ttbr1_el1,     .tcr_el1,       .mair_el1,
    .vbar_el1,       .esr_el1,       .far_el1,       .elr_el1,       .spsr_el1,
    .sp_el0,         .sp_el1,        .tpidr_el0,     .tpidr_el1,     .tpidrro_el0,
    .cpacr_el1,      .cntv_ctl_el0,  .cntv_cval_el0, .cntkctl_el1,   .mdscr_el1,
    .contextidr_el1, .par_el1,       .afsr0_el1,     .afsr1_el1,     .amair_el1,
    // PAC keys: without these every signed return address in the guest
    // fails authentication after restore (panic in arch_cpu_idle).
    .apiakeylo_el1,  .apiakeyhi_el1, .apibkeylo_el1, .apibkeyhi_el1, .apdakeylo_el1,
    .apdakeyhi_el1,  .apdbkeylo_el1, .apdbkeyhi_el1, .apgakeylo_el1, .apgakeyhi_el1,
};

const gp_regs = [_]hypervisor.Register{
    .x0,  .x1,  .x2,  .x3,  .x4,  .x5,  .x6,  .x7,
    .x8,  .x9,  .x10, .x11, .x12, .x13, .x14, .x15,
    .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23,
    .x24, .x25, .x26, .x27, .x28, .fp,  .lr,
};

/// Capture registers. MUST run on the vCPU's owning thread.
pub fn captureVcpu(vcpu: *hypervisor.Vcpu, out: *VcpuState) !void {
    for (gp_regs, 0..) |reg, i| out.gp[i] = try vcpu.getReg(reg);
    out.pc = try vcpu.getReg(.pc);
    out.cpsr = try vcpu.getReg(.cpsr);
    out.fpcr = try vcpu.getReg(.fpcr);
    out.fpsr = try vcpu.getReg(.fpsr);
    for (sys_regs, 0..) |reg, i| out.sys[i] = try vcpu.getSysReg(reg);
    inline for (0..32) |q| {
        out.simd[q] = try vcpu.getSimdFpReg(@enumFromInt(q));
    }
}

/// Restore registers. MUST run on the vCPU's owning thread.
pub fn restoreVcpu(vcpu: *hypervisor.Vcpu, state: *const VcpuState) !void {
    for (gp_regs, 0..) |reg, i| try vcpu.setReg(reg, state.gp[i]);
    try vcpu.setReg(.pc, state.pc);
    try vcpu.setReg(.cpsr, state.cpsr);
    try vcpu.setReg(.fpcr, state.fpcr);
    try vcpu.setReg(.fpsr, state.fpsr);
    for (sys_regs, 0..) |reg, i| try vcpu.setSysReg(reg, state.sys[i]);
    inline for (0..32) |q| {
        try vcpu.setSimdFpReg(@enumFromInt(q), state.simd[q]);
    }
}

// =============================================================================
// Container
// =============================================================================

pub const Builder = struct {
    alloc: Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(alloc: Allocator) !Builder {
        var b = Builder{ .alloc = alloc };
        try b.buf.appendSlice(alloc, MAGIC);
        try b.appendInt(u32, VERSION);
        return b;
    }

    pub fn deinit(self: *Builder) void {
        self.buf.deinit(self.alloc);
    }

    pub fn appendInt(self: *Builder, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try self.buf.appendSlice(self.alloc, &tmp);
    }

    pub fn section(self: *Builder, name: []const u8, data: []const u8) !void {
        try self.buf.append(self.alloc, @intCast(name.len));
        try self.buf.appendSlice(self.alloc, name);
        try self.appendInt(u64, data.len);
        try self.buf.appendSlice(self.alloc, data);
    }

    /// Take ownership of the finished snapshot bytes.
    pub fn finish(self: *Builder) ![]u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }
};

pub const Reader = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) !Reader {
        if (bytes.len < MAGIC.len + 4) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..MAGIC.len], MAGIC)) return error.BadMagic;
        const version = std.mem.readInt(u32, bytes[MAGIC.len..][0..4], .little);
        if (version != VERSION) return error.BadVersion;
        return .{ .bytes = bytes };
    }

    /// Find a section by name.
    pub fn section(self: Reader, name: []const u8) ?[]const u8 {
        var off: usize = MAGIC.len + 4;
        while (off + 1 <= self.bytes.len) {
            const name_len = self.bytes[off];
            off += 1;
            if (off + name_len + 8 > self.bytes.len) return null;
            const sec_name = self.bytes[off..][0..name_len];
            off += name_len;
            const size = std.mem.readInt(u64, self.bytes[off..][0..8], .little);
            off += 8;
            if (off + size > self.bytes.len) return null;
            if (std.mem.eql(u8, sec_name, name)) return self.bytes[off..][0..size];
            off += @intCast(size);
        }
        return null;
    }
};

// =============================================================================
// Field-wise value serialization helpers
// =============================================================================

const Cursor = struct {
    buf: []const u8,
    off: usize = 0,

    fn int(self: *Cursor, comptime T: type) !T {
        if (self.off + @sizeOf(T) > self.buf.len) return error.Truncated;
        defer self.off += @sizeOf(T);
        return std.mem.readInt(T, self.buf[self.off..][0..@sizeOf(T)], .little);
    }
    fn bytes(self: *Cursor, len: usize) ![]const u8 {
        if (self.off + len > self.buf.len) return error.Truncated;
        defer self.off += len;
        return self.buf[self.off..][0..len];
    }
    fn blob(self: *Cursor) ![]const u8 {
        const len = try self.int(u64);
        return self.bytes(@intCast(len));
    }
};

const Out = struct {
    alloc: Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn int(self: *Out, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try self.buf.appendSlice(self.alloc, &tmp);
    }
    fn bytes(self: *Out, data: []const u8) !void {
        try self.buf.appendSlice(self.alloc, data);
    }
    fn blob(self: *Out, data: []const u8) !void {
        try self.int(u64, data.len);
        try self.bytes(data);
    }
};

fn inputBufferBlob(out: *Out, buffer: anytype) !void {
    assert(buffer.count <= virtio.Console.INPUT_BUFFER_MAX);
    assert(buffer.firstSlice().len + buffer.secondSlice().len == buffer.count);
    try out.int(u64, buffer.count);
    try out.bytes(buffer.firstSlice());
    try out.bytes(buffer.secondSlice());
}

// =============================================================================
// GIC
// =============================================================================

fn putIrqState(out: *Out, s: anytype) !void {
    const flags: u8 = @as(u8, @intFromBool(s.enabled)) |
        (@as(u8, @intFromBool(s.pending)) << 1) |
        (@as(u8, @intFromBool(s.active)) << 2) |
        (@as(u8, s.config) << 3) |
        (@as(u8, s.group) << 5);
    try out.int(u8, flags);
    try out.int(u8, s.priority);
    try out.int(u8, s.target_cpu);
}

fn getIrqState(cur: *Cursor, s: anytype) !void {
    const flags = try cur.int(u8);
    s.enabled = flags & 1 != 0;
    s.pending = flags & 2 != 0;
    s.active = flags & 4 != 0;
    s.config = @truncate(flags >> 3);
    s.group = @truncate(flags >> 5);
    s.priority = try cur.int(u8);
    s.target_cpu = try cur.int(u8);
}

pub fn serializeGic(alloc: Allocator, gic: *const gic_mod.Gic) ![]u8 {
    assert(gic.spis.len == gic_mod.MAX_SPI);
    assert(gic.redists.len == gic.num_cpus);
    const irq_state_bytes = 3;
    const redist_state_bytes = @sizeOf(u32) + 32 * irq_state_bytes;
    const serialized_bytes = 2 * @sizeOf(u32) + gic.spis.len * irq_state_bytes +
        @sizeOf(u8) + gic.redists.len * redist_state_bytes;
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try out.int(u32, gic.ctlr);
    try out.int(u32, @intCast(gic.spis.len));
    for (gic.spis) |spi| try putIrqState(&out, spi);
    try out.int(u8, gic.num_cpus);
    for (gic.redists) |redist| {
        try out.int(u32, redist.waker);
        for (redist.sgi_ppi) |irq| try putIrqState(&out, irq);
    }
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn appendGicSection(
    builder: *Builder,
    fallback_alloc: Allocator,
    gic: *const gic_mod.Gic,
) !void {
    assert(gic.num_cpus > 0);
    assert(gic.num_cpus <= gic_mod.MAX_VCPUS);
    var stack_allocator = std.heap.stackFallback(gic_section_scratch_bytes, fallback_alloc);
    const scratch_alloc = stack_allocator.get();
    const data = try serializeGic(scratch_alloc, gic);
    defer scratch_alloc.free(data);
    try builder.section("gic", data);
}

pub fn deserializeGic(gic: *gic_mod.Gic, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    gic.ctlr = try cur.int(u32);
    const nspis = try cur.int(u32);
    if (nspis != gic.spis.len) return error.Mismatch;
    for (gic.spis) |*spi| try getIrqState(&cur, spi);
    const ncpus = try cur.int(u8);
    if (ncpus != gic.num_cpus) return error.Mismatch;
    for (gic.redists) |*redist| {
        redist.waker = try cur.int(u32);
        for (&redist.sgi_ppi) |*irq| try getIrqState(&cur, irq);
    }
}

// =============================================================================
// Virtio transport
// =============================================================================

pub fn serializeTransport(out: *Out, t: *const mmio.Transport) !void {
    try out.int(u64, t.driver_features);
    try out.int(u32, t.device_features_sel);
    try out.int(u32, t.driver_features_sel);
    try out.int(u8, @bitCast(t.status));
    try out.int(u32, t.queue_sel);
    try out.int(u32, @bitCast(t.interrupt_status));
    try out.int(u32, t.config_generation);
    try out.int(u8, @intCast(t.queues.len));
    for (t.queues) |q| {
        try out.int(u16, q.num);
        try out.int(u8, @intFromBool(q.ready));
        try out.int(u64, q.desc_addr);
        try out.int(u64, q.driver_addr);
        try out.int(u64, q.device_addr);
    }
}

pub fn deserializeTransport(cur: *Cursor, t: *mmio.Transport) !void {
    t.driver_features = try cur.int(u64);
    t.device_features_sel = try cur.int(u32);
    t.driver_features_sel = try cur.int(u32);
    t.status = @bitCast(try cur.int(u8));
    t.queue_sel = try cur.int(u32);
    t.interrupt_status = @bitCast(try cur.int(u32));
    t.config_generation = try cur.int(u32);
    const nq = try cur.int(u8);
    if (nq != t.queues.len) return error.Mismatch;
    for (t.queues) |*q| {
        q.num = try cur.int(u16);
        q.ready = (try cur.int(u8)) != 0;
        q.desc_addr = try cur.int(u64);
        q.driver_addr = try cur.int(u64);
        q.device_addr = try cur.int(u64);
    }
}

fn transportSerializedBytes(t: *const mmio.Transport) usize {
    assert(t.queues.len <= std.math.maxInt(u8));
    assert(t.queues.len <= mmio.Transport.MAX_QUEUES);
    const queue_state_bytes = @sizeOf(u16) + @sizeOf(u8) + 3 * @sizeOf(u64);
    return @sizeOf(u64) + 5 * @sizeOf(u32) + 2 * @sizeOf(u8) +
        t.queues.len * queue_state_bytes;
}

// =============================================================================
// Devices
// =============================================================================

pub fn serializeConsole(alloc: Allocator, con: *const virtio.Console) ![]u8 {
    assert(con.ports.len <= std.math.maxInt(u8));
    assert(con.input_buffer.count <= virtio.Console.INPUT_BUFFER_MAX);
    var serialized_bytes = transportSerializedBytes(&con.transport) + 2 * @sizeOf(u16) +
        @sizeOf(u64) + con.input_buffer.count + con.mp_last_avail.len * @sizeOf(u16) +
        @sizeOf(u8);
    for (con.ports) |port| {
        serialized_bytes += @sizeOf(u8) + @sizeOf(u64) + port.input_buffer.count;
    }
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try serializeTransport(&out, &con.transport);
    try out.int(u16, con.receive_last_avail);
    try out.int(u16, con.transmit_last_avail);
    try inputBufferBlob(&out, &con.input_buffer);
    for (con.mp_last_avail) |cursor| try out.int(u16, cursor);
    try out.int(u8, @intCast(con.ports.len));
    for (con.ports) |port| {
        try out.int(u8, @intFromBool(port.guest_open));
        try inputBufferBlob(&out, &port.input_buffer);
    }
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn deserializeConsole(_: Allocator, con: *virtio.Console, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    try deserializeTransport(&cur, &con.transport);
    con.receive_last_avail = try cur.int(u16);
    con.transmit_last_avail = try cur.int(u16);
    const input = try cur.blob();
    if (!con.input_buffer.replace(input)) return error.Mismatch;
    for (&con.mp_last_avail) |*cursor| cursor.* = try cur.int(u16);
    const nports = try cur.int(u8);
    if (nports != con.ports.len) return error.Mismatch;
    for (con.ports) |*port| {
        port.guest_open = (try cur.int(u8)) != 0;
        const pbuf = try cur.blob();
        if (!port.input_buffer.replace(pbuf)) return error.Mismatch;
    }
}

pub fn serializeBlock(alloc: Allocator, blk: *const virtio.Block) ![]u8 {
    const serialized_bytes = transportSerializedBytes(&blk.transport) + @sizeOf(u16);
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try serializeTransport(&out, &blk.transport);
    try out.int(u16, blk.request_last_avail);
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn appendBlockSection(
    builder: *Builder,
    fallback_alloc: Allocator,
    name: []const u8,
    blk: *const virtio.Block,
) !void {
    assert(name.len > 0);
    assert(name.len <= std.math.maxInt(u8));
    var stack_allocator = std.heap.stackFallback(block_section_scratch_bytes, fallback_alloc);
    const scratch_alloc = stack_allocator.get();
    const data = try serializeBlock(scratch_alloc, blk);
    defer scratch_alloc.free(data);
    try builder.section(name, data);
}

pub fn deserializeBlock(blk: *virtio.Block, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    try deserializeTransport(&cur, &blk.transport);
    blk.request_last_avail = try cur.int(u16);
}

pub fn serializeRng(alloc: Allocator, rng: *const virtio.Rng) ![]u8 {
    const serialized_bytes = transportSerializedBytes(&rng.transport) + @sizeOf(u16);
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try serializeTransport(&out, &rng.transport);
    try out.int(u16, rng.last_avail);
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn deserializeRng(rng: *virtio.Rng, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    try deserializeTransport(&cur, &rng.transport);
    rng.last_avail = try cur.int(u16);
}

pub fn serializeNet(alloc: Allocator, net: *const virtio.Net) ![]u8 {
    const serialized_bytes = transportSerializedBytes(&net.transport) + 2 * @sizeOf(u16);
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try serializeTransport(&out, &net.transport);
    try out.int(u16, net.rx_last_avail);
    try out.int(u16, net.tx_last_avail);
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn deserializeNet(net: *virtio.Net, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    try deserializeTransport(&cur, &net.transport);
    net.rx_last_avail = try cur.int(u16);
    net.tx_last_avail = try cur.int(u16);
}

pub fn serializeInput(alloc: Allocator, input: *const virtio.Input) ![]u8 {
    const serialized_bytes = transportSerializedBytes(&input.transport) + 2 * @sizeOf(u16);
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try serializeTransport(&out, &input.transport);
    try out.int(u16, input.event_last_avail);
    try out.int(u16, input.status_last_avail);
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn deserializeInput(input: *virtio.Input, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    try deserializeTransport(&cur, &input.transport);
    input.event_last_avail = try cur.int(u16);
    input.status_last_avail = try cur.int(u16);
}

pub fn serializeP9(alloc: Allocator, dev: *const virtio.P9) ![]u8 {
    assert(dev.server.fids.count() <= std.math.maxInt(u32));
    const fid_state_bytes = @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u32);
    var serialized_bytes = transportSerializedBytes(dev.transport) + @sizeOf(u16) +
        2 * @sizeOf(u32);
    var size_iter = dev.server.fids.valueIterator();
    while (size_iter.next()) |fid| serialized_bytes += fid_state_bytes + fid.rel.len;
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try serializeTransport(&out, dev.transport);
    try out.int(u16, dev.last_avail);
    try out.int(u32, dev.server.msize);
    try out.int(u32, dev.server.fids.count());
    var iter = dev.server.fids.iterator();
    while (iter.next()) |entry| {
        try out.int(u32, entry.key_ptr.*);
        try out.blob(entry.value_ptr.rel);
        try out.int(u32, entry.value_ptr.open_linux_flags orelse 0xFFFF_FFFF);
    }
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn deserializeP9(alloc: Allocator, dev: *virtio.P9, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    try deserializeTransport(&cur, dev.transport);
    dev.last_avail = try cur.int(u16);
    dev.server.msize = try cur.int(u32);
    const nfids = try cur.int(u32);
    var i: u32 = 0;
    while (i < nfids) : (i += 1) {
        const fid = try cur.int(u32);
        const rel = try cur.blob();
        const flags = try cur.int(u32);
        try dev.server.restoreFid(
            alloc,
            fid,
            rel,
            if (flags == 0xFFFF_FFFF) null else flags,
        );
    }
}

// =============================================================================
// GPU (2D scanout state only)
// =============================================================================
//
// Serializes the transport, display size, and the 2D framebuffer resources
// (id/format/dims + host pixels) so a GUI VM restores with its screen
// intact instead of a black frame until the guest's next redraw. virgl 3D
// contexts/resources are NOT captured (reset on restore, per QEMU policy).

pub fn serializeGpu(alloc: Allocator, g: *const virtio.Gpu) ![]u8 {
    assert(g.resources.count() <= std.math.maxInt(u32));
    const resource_state_bytes = 4 * @sizeOf(u32) + @sizeOf(u64);
    var serialized_bytes = transportSerializedBytes(g.transport) + 2 * @sizeOf(u16) +
        5 * @sizeOf(u32);
    var size_it = g.resources.valueIterator();
    while (size_it.next()) |resource| {
        serialized_bytes += resource_state_bytes + resource.host_data.len;
    }
    var out = Out{ .alloc = alloc };
    errdefer out.buf.deinit(alloc);
    try out.buf.ensureTotalCapacityPrecise(alloc, serialized_bytes);
    try serializeTransport(&out, g.transport);
    try out.int(u16, g.ctrl_last_avail);
    try out.int(u16, g.cursor_last_avail);
    try out.int(u32, g.config.events_read);
    try out.int(u32, g.display_width);
    try out.int(u32, g.display_height);
    try out.int(u32, g.scanout_resource_id);
    try out.int(u32, g.resources.count());
    var it = g.resources.iterator();
    while (it.next()) |e| {
        const r = e.value_ptr;
        try out.int(u32, r.id);
        try out.int(u32, r.format);
        try out.int(u32, r.width);
        try out.int(u32, r.height);
        try out.blob(r.host_data);
    }
    assert(out.buf.items.len == serialized_bytes);
    assert(out.buf.items.len == out.buf.capacity);
    const result = out.buf.items;
    out.buf = .empty;
    return result;
}

pub fn deserializeGpu(g: *virtio.Gpu, data: []const u8) !void {
    var cur = Cursor{ .buf = data };
    try deserializeTransport(&cur, g.transport);
    g.ctrl_last_avail = try cur.int(u16);
    g.cursor_last_avail = try cur.int(u16);
    g.config.events_read = try cur.int(u32);
    g.display_width = try cur.int(u32);
    g.display_height = try cur.int(u32);
    const scanout_id = try cur.int(u32);
    const nres = try cur.int(u32);
    var i: u32 = 0;
    while (i < nres) : (i += 1) {
        const id = try cur.int(u32);
        const format = try cur.int(u32);
        const width = try cur.int(u32);
        const height = try cur.int(u32);
        const pixels = try cur.blob();
        try g.restore2dResource(id, format, width, height, pixels);
    }
    g.scanout_resource_id = scanout_id;
    g.frame_generation +%= 1; // force the renderer to re-present
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "snapshot: container roundtrip and unknown sections" {
    var b = try Builder.init(testing.allocator);
    defer b.deinit();
    try b.section("alpha", "aaa");
    try b.section("beta", "bb-bb");
    const bytes = try b.finish();
    defer testing.allocator.free(bytes);

    const r = try Reader.init(bytes);
    try testing.expectEqualStrings("aaa", r.section("alpha").?);
    try testing.expectEqualStrings("bb-bb", r.section("beta").?);
    try testing.expect(r.section("gamma") == null);

    try testing.expectError(error.BadMagic, Reader.init("XXXXXXXX\x01\x00\x00\x00"));
}

test "snapshot: gic state roundtrip" {
    const gic = try gic_mod.Gic.init(testing.allocator, 2);
    defer gic.deinit();
    gic.ctlr = 0x33;
    gic.spis[10].enabled = true;
    gic.spis[10].pending = true;
    gic.spis[10].priority = 0x40;
    gic.spis[10].target_cpu = 1;
    gic.redists[1].waker = 7;
    gic.redists[1].sgi_ppi[27].pending = true;

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeGic(counted.allocator(), gic);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const gic2 = try gic_mod.Gic.init(testing.allocator, 2);
    defer gic2.deinit();
    try deserializeGic(gic2, data);
    try testing.expectEqual(@as(u32, 0x33), gic2.ctlr);
    try testing.expect(gic2.spis[10].enabled and gic2.spis[10].pending);
    try testing.expectEqual(@as(u8, 0x40), gic2.spis[10].priority);
    try testing.expectEqual(@as(u8, 1), gic2.spis[10].target_cpu);
    try testing.expectEqual(@as(u32, 7), gic2.redists[1].waker);
    try testing.expect(gic2.redists[1].sgi_ppi[27].pending);
}

test "snapshot: GIC section assembly allocation profile" {
    const gic = try gic_mod.Gic.init(testing.allocator, 2);
    defer gic.deinit();

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = counted.allocator();
    var builder = try Builder.init(alloc);
    defer builder.deinit();
    try appendGicSection(&builder, alloc, gic);
    const bytes = try builder.finish();
    defer alloc.free(bytes);

    const reader = try Reader.init(bytes);
    try testing.expectEqual(@as(usize, 3), counted.allocations);
    try testing.expectEqual(@as(usize, 1810), counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);
    try testing.expectEqual(@as(usize, 593), reader.section("gic").?.len);
}

test "snapshot: console device roundtrip (multiport)" {
    const con = try virtio.Console.init(testing.allocator, &.{"org.qemu.guest_agent.0"});
    defer con.deinit();
    con.transport.status = @bitCast(@as(u8, 0x0F));
    con.transport.driver_features = 0xdead_beef;
    con.transport.queues[0].ready = true;
    con.transport.queues[0].desc_addr = 0x4000_0000;
    con.receive_last_avail = 17;
    con.input_buffer.head = virtio.Console.INPUT_BUFFER_MAX - 4;
    try con.queueInput("pending host input");
    con.ports[0].input_buffer.head = virtio.Console.INPUT_BUFFER_MAX - 3;
    try con.queuePortInput(1, "agent bytes");
    con.ports[0].guest_open = true;

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeConsole(counted.allocator(), con);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const con2 = try virtio.Console.init(testing.allocator, &.{"org.qemu.guest_agent.0"});
    defer con2.deinit();
    try deserializeConsole(testing.allocator, con2, data);
    try testing.expectEqual(@as(u8, 0x0F), @as(u8, @bitCast(con2.transport.status)));
    try testing.expectEqual(@as(u64, 0xdead_beef), con2.transport.driver_features);
    try testing.expect(con2.transport.queues[0].ready);
    try testing.expectEqual(@as(u64, 0x4000_0000), con2.transport.queues[0].desc_addr);
    try testing.expectEqual(@as(u16, 17), con2.receive_last_avail);
    try testing.expectEqualStrings("pending host input", con2.input_buffer.firstSlice());
    try testing.expectEqualStrings("agent bytes", con2.ports[0].input_buffer.firstSlice());
    try testing.expect(con2.ports[0].guest_open);
}

test "snapshot: block device roundtrip" {
    const blk = try virtio.Block.init(testing.allocator);
    defer blk.deinit();
    blk.transport.status = @bitCast(@as(u8, 0x0F));
    blk.transport.driver_features = 0xfeed_face;
    blk.transport.queues[0].ready = true;
    blk.transport.queues[0].device_addr = 0x5000_0000;
    blk.request_last_avail = 23;

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeBlock(counted.allocator(), blk);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const blk2 = try virtio.Block.init(testing.allocator);
    defer blk2.deinit();
    try deserializeBlock(blk2, data);
    try testing.expectEqual(@as(u8, 0x0F), @as(u8, @bitCast(blk2.transport.status)));
    try testing.expectEqual(@as(u64, 0xfeed_face), blk2.transport.driver_features);
    try testing.expect(blk2.transport.queues[0].ready);
    try testing.expectEqual(@as(u64, 0x5000_0000), blk2.transport.queues[0].device_addr);
    try testing.expectEqual(@as(u16, 23), blk2.request_last_avail);
}

test "snapshot: block section assembly allocation profile" {
    const blk = try virtio.Block.init(testing.allocator);
    defer blk.deinit();

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = counted.allocator();
    var builder = try Builder.init(alloc);
    defer builder.deinit();
    try appendBlockSection(&builder, alloc, "blk1", blk);
    const bytes = try builder.finish();
    defer alloc.free(bytes);

    const reader = try Reader.init(bytes);
    try testing.expectEqual(@as(usize, 2), counted.allocations);
    try testing.expectEqual(@as(usize, 224), counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);
    try testing.expectEqual(@as(usize, 59), reader.section("blk1").?.len);
}

test "snapshot: RNG device roundtrip" {
    const rng = try virtio.Rng.init(testing.allocator);
    defer rng.deinit();
    rng.transport.status = @bitCast(@as(u8, 0x0F));
    rng.transport.queues[0].ready = true;
    rng.transport.queues[0].driver_addr = 0x6000_0000;
    rng.last_avail = 29;

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeRng(counted.allocator(), rng);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const rng2 = try virtio.Rng.init(testing.allocator);
    defer rng2.deinit();
    try deserializeRng(rng2, data);
    try testing.expectEqual(@as(u8, 0x0F), @as(u8, @bitCast(rng2.transport.status)));
    try testing.expect(rng2.transport.queues[0].ready);
    try testing.expectEqual(@as(u64, 0x6000_0000), rng2.transport.queues[0].driver_addr);
    try testing.expectEqual(@as(u16, 29), rng2.last_avail);
}

test "snapshot: network device roundtrip" {
    const net = try virtio.Net.init(testing.allocator);
    defer net.deinit();
    net.transport.status = @bitCast(@as(u8, 0x0F));
    net.transport.queues[0].ready = true;
    net.transport.queues[1].ready = true;
    net.transport.queues[1].desc_addr = 0x7000_0000;
    net.rx_last_avail = 31;
    net.tx_last_avail = 37;

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeNet(counted.allocator(), net);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const net2 = try virtio.Net.init(testing.allocator);
    defer net2.deinit();
    try deserializeNet(net2, data);
    try testing.expectEqual(@as(u8, 0x0F), @as(u8, @bitCast(net2.transport.status)));
    try testing.expect(net2.transport.queues[0].ready);
    try testing.expect(net2.transport.queues[1].ready);
    try testing.expectEqual(@as(u64, 0x7000_0000), net2.transport.queues[1].desc_addr);
    try testing.expectEqual(@as(u16, 31), net2.rx_last_avail);
    try testing.expectEqual(@as(u16, 37), net2.tx_last_avail);
}

test "snapshot: input device roundtrip" {
    const input = try virtio.Input.init(testing.allocator, .keyboard);
    defer input.deinit();
    input.transport.status = @bitCast(@as(u8, 0x0F));
    input.transport.queues[0].ready = true;
    input.transport.queues[1].ready = true;
    input.transport.queues[0].device_addr = 0x8000_0000;
    input.event_last_avail = 41;
    input.status_last_avail = 43;

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeInput(counted.allocator(), input);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const input2 = try virtio.Input.init(testing.allocator, .keyboard);
    defer input2.deinit();
    try deserializeInput(input2, data);
    try testing.expectEqual(@as(u8, 0x0F), @as(u8, @bitCast(input2.transport.status)));
    try testing.expect(input2.transport.queues[0].ready);
    try testing.expect(input2.transport.queues[1].ready);
    try testing.expectEqual(@as(u64, 0x8000_0000), input2.transport.queues[0].device_addr);
    try testing.expectEqual(@as(u16, 41), input2.event_last_avail);
    try testing.expectEqual(@as(u16, 43), input2.status_last_avail);
}

test "snapshot: P9 device roundtrip with fids" {
    const dev = try virtio.P9.init(testing.allocator, "hostshare", ".");
    defer dev.deinit();
    dev.transport.status = @bitCast(@as(u8, 0x0F));
    dev.transport.queues[0].ready = true;
    dev.server.msize = 64 * 1024;
    dev.last_avail = 47;
    try dev.server.restoreFid(testing.allocator, 3, "src", null);
    try dev.server.restoreFid(testing.allocator, 9, "src/machine", null);

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeP9(counted.allocator(), dev);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const dev2 = try virtio.P9.init(testing.allocator, "hostshare", ".");
    defer dev2.deinit();
    try deserializeP9(testing.allocator, dev2, data);
    try testing.expectEqual(@as(u8, 0x0F), @as(u8, @bitCast(dev2.transport.status)));
    try testing.expect(dev2.transport.queues[0].ready);
    try testing.expectEqual(@as(u32, 64 * 1024), dev2.server.msize);
    try testing.expectEqual(@as(u16, 47), dev2.last_avail);
    try testing.expectEqual(@as(usize, 2), dev2.server.fids.count());
    try testing.expectEqualStrings("src", dev2.server.fids.get(3).?.rel);
    try testing.expectEqualStrings("src/machine", dev2.server.fids.get(9).?.rel);
}

test "snapshot: gpu 2D framebuffer survives roundtrip" {
    const gpu = try virtio.Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    // A 4x2 scanout resource with a known pixel pattern (4*2*4 = 32 bytes).
    var pattern: [32]u8 = undefined;
    for (&pattern, 0..) |*b, i| b.* = @truncate(i * 3 + 1);
    try gpu.restore2dResource(7, 2, 4, 2, &pattern);
    const res = gpu.resources.getPtr(7).?;
    gpu.scanout_resource_id = 7;
    gpu.setDisplaySize(4, 2);
    gpu.transport.status = @bitCast(@as(u8, 0x0F));

    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const data = try serializeGpu(counted.allocator(), gpu);
    defer counted.allocator().free(data);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(data.len, counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);

    const gpu2 = try virtio.Gpu.init(testing.allocator, false);
    defer gpu2.deinit();
    try deserializeGpu(gpu2, data);

    try testing.expectEqual(@as(u32, 7), gpu2.scanout_resource_id);
    try testing.expectEqual(@as(u32, 4), gpu2.display_width);
    try testing.expectEqual(@as(u32, 2), gpu2.display_height);
    try testing.expectEqual(@as(u8, 0x0F), @as(u8, @bitCast(gpu2.transport.status)));
    const r2 = gpu2.resources.getPtr(7).?;
    try testing.expectEqual(@as(u32, 4), r2.width);
    try testing.expectEqual(@as(u32, 2), r2.height);
    try testing.expectEqualSlices(u8, res.host_data, r2.host_data);
    // Restored scanout serves the same pixels.
    const view = gpu2.scanout().?;
    try testing.expectEqual(@as(u32, 4), view.width);
    try testing.expectEqualSlices(u8, res.host_data, view.data);
}

test "snapshot: VcpuState is a stable extern layout" {
    // 31 GP + pc + cpsr + fpcr + fpsr + 35 sys = 70 u64s + 512 SIMD bytes.
    try testing.expectEqual(@as(usize, 70 * 8 + 512), @sizeOf(VcpuState));
    try testing.expectEqual(sys_regs.len, @as(usize, 35));
}
