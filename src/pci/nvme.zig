//! NVM Express 1.4 controller on PCIe with a single namespace over a raw
//! disk file. Windows and EDK2 ship NVMe drivers, which makes this the
//! storage path for guests without virtio drivers (Windows Setup, its
//! installed system, and the firmware booting them).
//!
//! Scope: one admin queue pair plus up to `QUEUES_MAX - 1` I/O queue pairs,
//! PRP data transfers (no SGLs), 4 KiB memory pages, 512-byte LBAs and a
//! pin-based interrupt (no MSI-X). Commands complete synchronously inside
//! the doorbell write, like the virtio-blk device.
//!
//! Register layout and command formats follow NVM Express 1.4 (BAR0:
//! controller registers at 0x0, doorbells from 0x1000 with stride 4).

const Nvme = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const GuestMemory = @import("../guest_memory.zig").GuestMemory;
const config_policy = @import("config.zig");

const log = std.log.scoped(.nvme);

alloc: Allocator,
file: ?std.Io.File,
capacity_blocks: u64,
read_only: bool,
memory: ?GuestMemory = null,
irq: ?Irq = null,
irq_level: bool = false,
/// PCI configuration space image (type 0 header).
config: [config_policy.space_size]u8,
bar0_addr: u32 = 0,
cc: u32 = 0,
csts: u32 = 0,
aqa: u32 = 0,
asq: u64 = 0,
acq: u64 = 0,
intms: u32 = 0,
sqs: [QUEUES_MAX]?Sq = @splat(null),
cqs: [QUEUES_MAX]?Cq = @splat(null),
aer_outstanding: u8 = 0,
async_event_config: u32 = 0,
temperature_threshold: u32 = 0x0170,
io_queues_allocated: u16 = QUEUES_MAX - 1,
serial: [20]u8,

pub const BAR0_SIZE: u32 = 16 * 1024;
pub const BAR0_MASK: u32 = 0xFFFF_C000;
pub const QUEUES_MAX: u16 = 8;
pub const QUEUE_ENTRIES_MAX: u32 = 256;
pub const PAGE_SIZE: u64 = 4096;
pub const LBA_SIZE: u64 = 512;
/// Maximum data transfer: 2^MDTS pages.
pub const MDTS: u8 = 4;
const TRANSFER_MAX: u64 = PAGE_SIZE << MDTS;

pub const VENDOR_ID: u16 = 0x1B36; // Red Hat (QEMU's NVMe)
pub const DEVICE_ID: u16 = 0x0010;

pub const Irq = struct {
    callback: *const fn (level: bool, userdata: ?*anyopaque) void,
    userdata: ?*anyopaque,
};

const Reg = struct {
    const CAP: u64 = 0x00;
    const VS: u64 = 0x08;
    const INTMS: u64 = 0x0C;
    const INTMC: u64 = 0x10;
    const CC: u64 = 0x14;
    const CSTS: u64 = 0x1C;
    const NSSR: u64 = 0x20;
    const AQA: u64 = 0x24;
    const ASQ: u64 = 0x28;
    const ACQ: u64 = 0x30;
    const DOORBELLS: u64 = 0x1000;
};

const CC_EN: u32 = 1 << 0;
const CC_SHN_MASK: u32 = 0x3 << 14;
const CSTS_RDY: u32 = 1 << 0;
const CSTS_CFS: u32 = 1 << 1;
const CSTS_SHST_COMPLETE: u32 = 0x2 << 2;

const Sq = struct {
    base: u64,
    entries: u32,
    head: u32 = 0,
    tail: u32 = 0,
    cqid: u16,
};

const Cq = struct {
    base: u64,
    entries: u32,
    head: u32 = 0,
    tail: u32 = 0,
    phase: u1 = 1,
    interrupts_enabled: bool,
};

/// Status field of a completion (SC | SCT << 8), before the phase shift.
const Status = enum(u15) {
    success = 0x0000,
    invalid_opcode = 0x0001,
    invalid_field = 0x0002,
    data_transfer_error = 0x0004,
    invalid_namespace = 0x000B,
    lba_out_of_range = 0x0080,
    // Command specific (SCT 1)
    invalid_queue_id = 0x0101,
    invalid_queue_size = 0x0102,
    aer_limit_exceeded = 0x0105,
    invalid_interrupt_vector = 0x0108,
    // Media errors (SCT 2)
    write_fault = 0x0280,
    unrecovered_read_error = 0x0281,
    /// Pseudo-status: no completion is posted (asynchronous event requests).
    pending = 0x7FFF,
};

const Completion = struct {
    result: u32 = 0,
    status: Status = .success,
};

const Command = struct {
    opcode: u8,
    cid: u16,
    nsid: u32,
    prp1: u64,
    prp2: u64,
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,

    fn parse(bytes: *const [64]u8) Command {
        const dw = struct {
            fn at(b: *const [64]u8, i: usize) u32 {
                return std.mem.readInt(u32, b[i * 4 ..][0..4], .little);
            }
        };
        return .{
            .opcode = @truncate(dw.at(bytes, 0)),
            .cid = @truncate(dw.at(bytes, 0) >> 16),
            .nsid = dw.at(bytes, 1),
            .prp1 = std.mem.readInt(u64, bytes[24..32], .little),
            .prp2 = std.mem.readInt(u64, bytes[32..40], .little),
            .cdw10 = dw.at(bytes, 10),
            .cdw11 = dw.at(bytes, 11),
            .cdw12 = dw.at(bytes, 12),
            .cdw13 = dw.at(bytes, 13),
            .cdw14 = dw.at(bytes, 14),
            .cdw15 = dw.at(bytes, 15),
        };
    }
};

const AdminOpcode = struct {
    const DELETE_IO_SQ: u8 = 0x00;
    const CREATE_IO_SQ: u8 = 0x01;
    const GET_LOG_PAGE: u8 = 0x02;
    const DELETE_IO_CQ: u8 = 0x04;
    const CREATE_IO_CQ: u8 = 0x05;
    const IDENTIFY: u8 = 0x06;
    const ABORT: u8 = 0x08;
    const SET_FEATURES: u8 = 0x09;
    const GET_FEATURES: u8 = 0x0A;
    const ASYNC_EVENT_REQUEST: u8 = 0x0C;
    const KEEP_ALIVE: u8 = 0x18;
};

const NvmOpcode = struct {
    const FLUSH: u8 = 0x00;
    const WRITE: u8 = 0x01;
    const READ: u8 = 0x02;
    const WRITE_ZEROES: u8 = 0x08;
    const DATASET_MANAGEMENT: u8 = 0x09;
};

const Feature = struct {
    const ARBITRATION: u8 = 0x01;
    const POWER_MANAGEMENT: u8 = 0x02;
    const TEMPERATURE_THRESHOLD: u8 = 0x04;
    const ERROR_RECOVERY: u8 = 0x05;
    const VOLATILE_WRITE_CACHE: u8 = 0x06;
    const NUMBER_OF_QUEUES: u8 = 0x07;
    const INTERRUPT_COALESCING: u8 = 0x08;
    const INTERRUPT_VECTOR_CONFIG: u8 = 0x09;
    const WRITE_ATOMICITY: u8 = 0x0A;
    const ASYNC_EVENT_CONFIG: u8 = 0x0B;
    const AUTONOMOUS_POWER_STATE: u8 = 0x0C;
    const KEEP_ALIVE_TIMER: u8 = 0x0F;
    const HOST_CONTROLLED_THERMAL: u8 = 0x10;
    const SOFTWARE_PROGRESS_MARKER: u8 = 0x80;
};

/// Open `path` as the namespace backing store.
pub fn init(alloc: Allocator, path: []const u8, read_only: bool, serial: []const u8) !*Nvme {
    const options: std.Io.Dir.OpenFileOptions = if (read_only)
        .{ .mode = .read_only }
    else
        .{ .mode = .read_write };
    const file = try std.Io.Dir.cwd().openFile(global.io(), path, options);
    errdefer file.close(global.io());
    const stat = try file.stat(global.io());
    return initWithFile(alloc, file, stat.size, read_only, serial);
}

/// Wrap an already-open file; `capacity_bytes` is rounded down to LBAs.
pub fn initWithFile(
    alloc: Allocator,
    file: std.Io.File,
    capacity_bytes: u64,
    read_only: bool,
    serial: []const u8,
) Allocator.Error!*Nvme {
    const self = try alloc.create(Nvme);
    self.* = .{
        .alloc = alloc,
        .file = file,
        .capacity_blocks = capacity_bytes / LBA_SIZE,
        .read_only = read_only,
        .config = @splat(0),
        .serial = @splat(' '),
    };
    @memcpy(self.serial[0..@min(serial.len, self.serial.len)], serial[0..@min(serial.len, self.serial.len)]);
    self.initConfigSpace();
    return self;
}

pub fn deinit(self: *Nvme) void {
    if (self.file) |file| file.close(global.io());
    self.alloc.destroy(self);
}

pub fn setGuestMemory(self: *Nvme, memory: GuestMemory) void {
    self.memory = memory;
}

pub fn setIrqCallback(self: *Nvme, irq: Irq) void {
    self.irq = irq;
}

fn initConfigSpace(self: *Nvme) void {
    const c = &self.config;
    std.mem.writeInt(u16, c[0x00..0x02], VENDOR_ID, .little);
    std.mem.writeInt(u16, c[0x02..0x04], DEVICE_ID, .little);
    std.mem.writeInt(u16, c[0x04..0x06], 0x0000, .little); // command
    std.mem.writeInt(u16, c[0x06..0x08], 0x0010, .little); // status: capabilities list
    c[0x08] = 0x02; // revision
    c[0x09] = 0x02; // prog-if: NVM Express
    c[0x0A] = 0x08; // subclass: non-volatile memory controller
    c[0x0B] = 0x01; // class: mass storage
    c[0x0E] = 0x00; // header type 0
    std.mem.writeInt(u32, c[0x10..0x14], 0, .little); // BAR0, assigned by firmware
    std.mem.writeInt(u16, c[0x2C..0x2E], VENDOR_ID, .little);
    std.mem.writeInt(u16, c[0x2E..0x30], DEVICE_ID, .little);
    c[0x34] = 0x40; // capabilities pointer
    c[0x3D] = 1; // INTA#
    // PCI Express capability (v2, endpoint) so the OS treats the function as
    // a native PCIe device; no link/slot registers are implemented.
    c[0x40] = 0x10; // cap id: PCI Express
    c[0x41] = 0x00; // next
    std.mem.writeInt(u16, c[0x42..0x44], 0x0002, .little); // version 2, endpoint
    std.mem.writeInt(u32, c[0x44..0x48], 0x0000_8000, .little); // device caps: RBER
}

// =============================================================================
// PCI configuration space
// =============================================================================

pub fn readConfig(self: *const Nvme, offset: u12, size: u8) u64 {
    assert(size == 1 or size == 2 or size == 4);
    if (@as(usize, offset) + size > self.config.len) return 0xFFFF_FFFF;
    var value: u64 = 0;
    for (0..size) |i| value |= @as(u64, self.config[offset + i]) << @intCast(i * 8);
    return value;
}

pub fn writeConfig(self: *Nvme, offset: u12, size: u8, value: u64) void {
    assert(size == 1 or size == 2 or size == 4);
    switch (config_policy.writeType0Masked(&self.config, offset, size, value, BAR0_MASK)) {
        .none, .bar0_probe => {},
        .bar0_assigned => |address| {
            self.bar0_addr = address;
            log.debug("BAR0 assigned to 0x{x}", .{address});
        },
    }
}

/// Offset within BAR0 for a guest physical address, if it hits this device.
pub fn barOffset(self: *const Nvme, addr: u64) ?u32 {
    if (self.bar0_addr == 0) return null;
    if (addr < self.bar0_addr or addr >= @as(u64, self.bar0_addr) + BAR0_SIZE) return null;
    return @intCast(addr - self.bar0_addr);
}

// =============================================================================
// Controller registers
// =============================================================================

fn capRegister(self: *const Nvme) u64 {
    _ = self;
    const mqes: u64 = QUEUE_ENTRIES_MAX - 1;
    const cqr: u64 = 1 << 16;
    const timeout: u64 = 15 << 24; // 7.5 s in 500 ms units
    const css_nvm: u64 = 1 << 37;
    return mqes | cqr | timeout | css_nvm; // MPSMIN = MPSMAX = 0 → 4 KiB
}

/// Value of the 8-byte-aligned register block containing `offset`.
fn registerBlock(self: *const Nvme, aligned: u64) u64 {
    return switch (aligned) {
        Reg.CAP => self.capRegister(),
        Reg.VS => @as(u64, 0x0001_0400) | (@as(u64, self.intms) << 32),
        Reg.INTMC => @as(u64, self.intms) | (@as(u64, self.cc) << 32),
        0x18 => @as(u64, self.csts) << 32, // 0x18 reserved, 0x1C CSTS
        Reg.NSSR => @as(u64, self.aqa) << 32,
        Reg.ASQ => self.asq,
        Reg.ACQ => self.acq,
        else => 0,
    };
}

pub fn readBar(self: *const Nvme, offset: u64, size: u8) u64 {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    if (offset >= Reg.DOORBELLS) return 0;
    const aligned = offset & ~@as(u64, 7);
    const block = self.registerBlock(aligned);
    const shift: u6 = @intCast((offset - aligned) * 8);
    const value = block >> shift;
    return if (size == 8) value else value & ((@as(u64, 1) << @intCast(size * 8)) - 1);
}

pub fn writeBar(self: *Nvme, offset: u64, size: u8, value: u64) void {
    assert(size == 1 or size == 2 or size == 4 or size == 8);
    if (offset >= Reg.DOORBELLS) {
        self.writeDoorbell(offset - Reg.DOORBELLS, @truncate(value));
        return;
    }
    if (size == 8) {
        self.writeRegister32(offset, @truncate(value));
        self.writeRegister32(offset + 4, @truncate(value >> 32));
        return;
    }
    self.writeRegister32(offset & ~@as(u64, 3), @truncate(value));
}

fn writeRegister32(self: *Nvme, offset: u64, value: u32) void {
    switch (offset) {
        Reg.INTMS => {
            self.intms |= value;
            self.updateIrq();
        },
        Reg.INTMC => {
            self.intms &= ~value;
            self.updateIrq();
        },
        Reg.CC => self.writeCc(value),
        Reg.AQA => self.aqa = value,
        Reg.ASQ => self.asq = (self.asq & 0xFFFF_FFFF_0000_0000) | value,
        Reg.ASQ + 4 => self.asq = (self.asq & 0xFFFF_FFFF) | (@as(u64, value) << 32),
        Reg.ACQ => self.acq = (self.acq & 0xFFFF_FFFF_0000_0000) | value,
        Reg.ACQ + 4 => self.acq = (self.acq & 0xFFFF_FFFF) | (@as(u64, value) << 32),
        else => {},
    }
}

fn writeCc(self: *Nvme, value: u32) void {
    const was_enabled = self.cc & CC_EN != 0;
    const enable = value & CC_EN != 0;
    self.cc = value;
    if (!was_enabled and enable) {
        self.enableController();
    } else if (was_enabled and !enable) {
        self.resetController();
    }
    if (enable and value & CC_SHN_MASK != 0) {
        if (self.file) |file| file.sync(global.io()) catch {};
        self.csts |= CSTS_SHST_COMPLETE;
    }
}

fn enableController(self: *Nvme) void {
    const sq_entries = (self.aqa & 0xFFF) + 1;
    const cq_entries = ((self.aqa >> 16) & 0xFFF) + 1;
    if (sq_entries < 2 or cq_entries < 2 or self.asq == 0 or self.acq == 0 or
        sq_entries > QUEUE_ENTRIES_MAX or cq_entries > QUEUE_ENTRIES_MAX)
    {
        log.warn("controller enable with invalid admin queues (aqa=0x{x})", .{self.aqa});
        self.csts |= CSTS_CFS;
        return;
    }
    self.sqs[0] = .{ .base = self.asq, .entries = sq_entries, .cqid = 0 };
    self.cqs[0] = .{ .base = self.acq, .entries = cq_entries, .interrupts_enabled = true };
    self.csts = CSTS_RDY;
    log.info("controller enabled: admin sq={} cq={} entries", .{ sq_entries, cq_entries });
}

fn resetController(self: *Nvme) void {
    self.sqs = @splat(null);
    self.cqs = @splat(null);
    self.csts = 0;
    self.intms = 0;
    self.aer_outstanding = 0;
    self.updateIrq();
}

fn writeDoorbell(self: *Nvme, offset: u64, value: u32) void {
    if (self.csts & CSTS_RDY == 0) return;
    const index = offset / 4;
    const qid: usize = @intCast(index / 2);
    if (qid >= QUEUES_MAX) return;
    if (index % 2 == 0) {
        const sq = &(self.sqs[qid] orelse return);
        if (value >= sq.entries) return;
        sq.tail = value;
        self.processSubmissionQueue(@intCast(qid));
    } else {
        const cq = &(self.cqs[qid] orelse return);
        if (value >= cq.entries) return;
        cq.head = value;
        self.updateIrq();
    }
}

/// Pin-based interrupt: asserted while any interrupt-enabled completion
/// queue holds entries the host has not consumed and the vector is unmasked.
fn updateIrq(self: *Nvme) void {
    var level = false;
    if (self.intms & 1 == 0) {
        for (self.cqs) |maybe| {
            const cq = maybe orelse continue;
            if (cq.interrupts_enabled and cq.head != cq.tail) level = true;
        }
    }
    if (level == self.irq_level) return;
    self.irq_level = level;
    if (self.irq) |irq| irq.callback(level, irq.userdata);
}

// =============================================================================
// Command processing
// =============================================================================

fn processSubmissionQueue(self: *Nvme, qid: u16) void {
    const memory = self.memory orelse return;
    var guard: u32 = 0;
    while (guard < QUEUE_ENTRIES_MAX) : (guard += 1) {
        const sq = &(self.sqs[qid] orelse return);
        if (sq.head == sq.tail) break;
        var raw: [64]u8 = undefined;
        memory.read(sq.base + @as(u64, sq.head) * 64, &raw) catch {
            log.warn("sq {} entry {} outside guest memory", .{ qid, sq.head });
            self.csts |= CSTS_CFS;
            return;
        };
        sq.head = (sq.head + 1) % sq.entries;
        const command = Command.parse(&raw);
        const completion = if (qid == 0) self.executeAdmin(command) else self.executeNvm(command);
        if (traceNvme() and (qid == 0 or completion.status != .success or
            (command.opcode != NvmOpcode.READ and command.opcode != NvmOpcode.WRITE)))
        {
            log.debug("{s} sq{} op=0x{x} nsid={} cdw10=0x{x} cdw11=0x{x} cdw12=0x{x} -> {s} result=0x{x}", .{
                self.serial,                 qid,               command.opcode, command.nsid, command.cdw10, command.cdw11, command.cdw12,
                @tagName(completion.status), completion.result,
            });
        }
        if (completion.status == .pending) continue;
        const sq_head: u16 = @intCast((self.sqs[qid] orelse return).head);
        self.postCompletion(self.sqs[qid].?.cqid, qid, sq_head, command.cid, completion);
    }
}

fn postCompletion(self: *Nvme, cqid: u16, sqid: u16, sq_head: u16, cid: u16, completion: Completion) void {
    const memory = self.memory orelse return;
    const cq = &(self.cqs[cqid] orelse return);
    const next_tail = (cq.tail + 1) % cq.entries;
    if (next_tail == cq.head) {
        log.warn("completion queue {} full; dropping completion", .{cqid});
        return;
    }
    var entry: [16]u8 = undefined;
    std.mem.writeInt(u32, entry[0..4], completion.result, .little);
    std.mem.writeInt(u32, entry[4..8], 0, .little);
    std.mem.writeInt(u16, entry[8..10], sq_head, .little);
    std.mem.writeInt(u16, entry[10..12], sqid, .little);
    std.mem.writeInt(u16, entry[12..14], cid, .little);
    const status_phase: u16 = @as(u16, cq.phase) | (@as(u16, @intFromEnum(completion.status)) << 1);
    std.mem.writeInt(u16, entry[14..16], status_phase, .little);
    memory.write(cq.base + @as(u64, cq.tail) * 16, &entry) catch {
        log.warn("completion queue {} outside guest memory", .{cqid});
        self.csts |= CSTS_CFS;
        return;
    };
    cq.tail = next_tail;
    if (cq.tail == 0) cq.phase ^= 1;
    self.updateIrq();
}

var trace_nvme = std.atomic.Value(u8).init(0);

/// BOBRVM_TRACE_NVME=1: log admin commands and non-read/write or failed
/// NVM commands.
fn traceNvme() bool {
    const state = trace_nvme.load(.acquire);
    if (state != 0) return state == 1;
    const on = std.c.getenv("BOBRVM_TRACE_NVME") != null;
    trace_nvme.store(if (on) 1 else 2, .release);
    return on;
}

fn executeAdmin(self: *Nvme, cmd: Command) Completion {
    return switch (cmd.opcode) {
        AdminOpcode.IDENTIFY => self.identify(cmd),
        AdminOpcode.CREATE_IO_CQ => self.createIoCq(cmd),
        AdminOpcode.CREATE_IO_SQ => self.createIoSq(cmd),
        AdminOpcode.DELETE_IO_CQ => self.deleteQueue(cmd, false),
        AdminOpcode.DELETE_IO_SQ => self.deleteQueue(cmd, true),
        AdminOpcode.SET_FEATURES => self.setFeatures(cmd),
        AdminOpcode.GET_FEATURES => self.getFeatures(cmd),
        AdminOpcode.GET_LOG_PAGE => self.getLogPage(cmd),
        AdminOpcode.ABORT => .{ .result = 1 }, // nothing to abort
        AdminOpcode.KEEP_ALIVE => .{},
        AdminOpcode.ASYNC_EVENT_REQUEST => blk: {
            if (self.aer_outstanding >= 4) break :blk .{ .status = .aer_limit_exceeded };
            self.aer_outstanding += 1;
            break :blk .{ .status = .pending };
        },
        else => .{ .status = .invalid_opcode },
    };
}

fn identify(self: *Nvme, cmd: Command) Completion {
    const cns: u8 = @truncate(cmd.cdw10);
    var page: [PAGE_SIZE]u8 = @splat(0);
    switch (cns) {
        0x00 => {
            if (cmd.nsid != 1) return .{ .status = .invalid_namespace };
            self.identifyNamespace(&page);
        },
        0x01 => self.identifyController(&page),
        0x02 => std.mem.writeInt(u32, page[0..4], 1, .little), // active namespace list
        0x03 => {
            if (cmd.nsid != 1) return .{ .status = .invalid_namespace };
            // Namespace identification descriptors: EUI-64 then CSI (NVM).
            page[0] = 0x01;
            page[1] = 8;
            self.eui64(page[4..12]);
            page[12] = 0x04;
            page[13] = 1;
            page[16] = 0;
        },
        else => return .{ .status = .invalid_field },
    }
    return self.transferToGuest(cmd, &page);
}

fn eui64(self: *const Nvme, out: *[8]u8) void {
    // Locally administered, derived from the serial so it is stable.
    const hash = std.hash.Wyhash.hash(0x4e564d45, &self.serial);
    std.mem.writeInt(u64, out, (hash & 0xFFFF_FFFF_FFFF_FF00) | 0x02, .big);
}

fn identifyController(self: *const Nvme, page: *[PAGE_SIZE]u8) void {
    std.mem.writeInt(u16, page[0..2], VENDOR_ID, .little);
    std.mem.writeInt(u16, page[2..4], VENDOR_ID, .little);
    @memcpy(page[4..24], &self.serial);
    const model = "bobrvm NVMe Disk                        ";
    @memcpy(page[24..64], model[0..40]);
    @memcpy(page[64..72], "1.0     ");
    page[72] = 0; // RAB
    page[73] = 0x52; // IEEE OUI (arbitrary)
    page[74] = 0x54;
    page[75] = 0x00;
    page[77] = MDTS;
    std.mem.writeInt(u32, page[80..84], 0x0001_0400, .little); // VER 1.4
    std.mem.writeInt(u16, page[256..258], 0, .little); // OACS
    page[258] = 3; // ACL
    page[259] = 3; // AERL
    page[260] = 0x03; // FRMW: slot 1 read-only, 1 slot
    page[261] = 0x00; // LPA
    page[262] = 0; // ELPE: one error log entry
    page[263] = 0; // NPSS: one power state
    std.mem.writeInt(u16, page[266..268], 0x0157, .little); // WCTEMP 343 K
    std.mem.writeInt(u16, page[268..270], 0x0161, .little); // CCTEMP 353 K
    page[512] = 0x66; // SQES 64 bytes
    page[513] = 0x44; // CQES 16 bytes
    std.mem.writeInt(u32, page[516..520], 1, .little); // NN
    std.mem.writeInt(u16, page[520..522], 0x000C, .little); // ONCS: write zeroes, DSM
    page[525] = 1; // VWC present
    const nqn = "nqn.2014-08.org.nvmexpress:uuid:bobrvm-";
    @memcpy(page[768 .. 768 + nqn.len], nqn);
    @memcpy(page[768 + nqn.len .. 768 + nqn.len + 20], &self.serial);
    // Power state descriptor 0: 25 W max power (0.01 W units).
    std.mem.writeInt(u16, page[2048..2050], 0x09C4, .little);
    std.mem.writeInt(u32, page[2052..2056], 0x10, .little); // entry latency
    std.mem.writeInt(u32, page[2056..2060], 0x10, .little); // exit latency
}

fn identifyNamespace(self: *const Nvme, page: *[PAGE_SIZE]u8) void {
    std.mem.writeInt(u64, page[0..8], self.capacity_blocks, .little); // NSZE
    std.mem.writeInt(u64, page[8..16], self.capacity_blocks, .little); // NCAP
    std.mem.writeInt(u64, page[16..24], self.capacity_blocks, .little); // NUSE
    page[24] = 0; // NSFEAT
    page[25] = 0; // NLBAF: one format
    page[26] = 0; // FLBAS: format 0
    page[27] = 0; // MC
    page[28] = 0; // DPC
    page[29] = 0; // DPS
    page[30] = 0; // NMIC
    self.eui64(page[120..128]);
    // LBA format 0: 512-byte data, no metadata, best performance.
    std.mem.writeInt(u16, page[128..130], 0, .little);
    page[130] = 9;
    page[131] = 0;
}

fn createIoCq(self: *Nvme, cmd: Command) Completion {
    const qid: u16 = @truncate(cmd.cdw10);
    const entries: u32 = (cmd.cdw10 >> 16) + 1;
    const contiguous = cmd.cdw11 & 1 != 0;
    const interrupts_enabled = cmd.cdw11 & 2 != 0;
    const vector: u16 = @truncate(cmd.cdw11 >> 16);
    if (qid == 0 or qid >= QUEUES_MAX or self.cqs[qid] != null) return .{ .status = .invalid_queue_id };
    if (entries < 2 or entries > QUEUE_ENTRIES_MAX) return .{ .status = .invalid_queue_size };
    if (!contiguous or cmd.prp1 == 0) return .{ .status = .invalid_field };
    if (vector != 0) return .{ .status = .invalid_interrupt_vector };
    self.cqs[qid] = .{ .base = cmd.prp1, .entries = entries, .interrupts_enabled = interrupts_enabled };
    return .{};
}

fn createIoSq(self: *Nvme, cmd: Command) Completion {
    const qid: u16 = @truncate(cmd.cdw10);
    const entries: u32 = (cmd.cdw10 >> 16) + 1;
    const contiguous = cmd.cdw11 & 1 != 0;
    const cqid: u16 = @truncate(cmd.cdw11 >> 16);
    if (qid == 0 or qid >= QUEUES_MAX or self.sqs[qid] != null) return .{ .status = .invalid_queue_id };
    if (entries < 2 or entries > QUEUE_ENTRIES_MAX) return .{ .status = .invalid_queue_size };
    if (cqid == 0 or cqid >= QUEUES_MAX or self.cqs[cqid] == null) return .{ .status = .invalid_queue_id };
    if (!contiguous or cmd.prp1 == 0) return .{ .status = .invalid_field };
    self.sqs[qid] = .{ .base = cmd.prp1, .entries = entries, .cqid = cqid };
    return .{};
}

fn deleteQueue(self: *Nvme, cmd: Command, submission: bool) Completion {
    const qid: u16 = @truncate(cmd.cdw10);
    if (qid == 0 or qid >= QUEUES_MAX) return .{ .status = .invalid_queue_id };
    if (submission) {
        if (self.sqs[qid] == null) return .{ .status = .invalid_queue_id };
        self.sqs[qid] = null;
    } else {
        if (self.cqs[qid] == null) return .{ .status = .invalid_queue_id };
        for (self.sqs) |maybe| {
            if (maybe) |sq| if (sq.cqid == qid) return .{ .status = .invalid_queue_id };
        }
        self.cqs[qid] = null;
        self.updateIrq();
    }
    return .{};
}

fn setFeatures(self: *Nvme, cmd: Command) Completion {
    const fid: u8 = @truncate(cmd.cdw10);
    switch (fid) {
        Feature.NUMBER_OF_QUEUES => {
            const requested_sq = (cmd.cdw11 & 0xFFFF) + 1;
            const requested_cq = (cmd.cdw11 >> 16) + 1;
            const granted: u32 = @min(@min(requested_sq, requested_cq), QUEUES_MAX - 1);
            self.io_queues_allocated = @intCast(granted);
            return .{ .result = (granted - 1) | ((granted - 1) << 16) };
        },
        Feature.TEMPERATURE_THRESHOLD => {
            self.temperature_threshold = cmd.cdw11 & 0xFFFF;
            return .{};
        },
        Feature.ASYNC_EVENT_CONFIG => {
            self.async_event_config = cmd.cdw11;
            return .{};
        },
        Feature.ARBITRATION,
        Feature.POWER_MANAGEMENT,
        Feature.ERROR_RECOVERY,
        Feature.VOLATILE_WRITE_CACHE,
        Feature.INTERRUPT_COALESCING,
        Feature.INTERRUPT_VECTOR_CONFIG,
        Feature.WRITE_ATOMICITY,
        Feature.AUTONOMOUS_POWER_STATE,
        Feature.KEEP_ALIVE_TIMER,
        Feature.HOST_CONTROLLED_THERMAL,
        Feature.SOFTWARE_PROGRESS_MARKER,
        => return .{},
        else => return .{ .status = .invalid_field },
    }
}

fn getFeatures(self: *Nvme, cmd: Command) Completion {
    const fid: u8 = @truncate(cmd.cdw10);
    return switch (fid) {
        Feature.NUMBER_OF_QUEUES => .{
            .result = (@as(u32, self.io_queues_allocated) - 1) |
                ((@as(u32, self.io_queues_allocated) - 1) << 16),
        },
        Feature.TEMPERATURE_THRESHOLD => .{ .result = self.temperature_threshold },
        Feature.ASYNC_EVENT_CONFIG => .{ .result = self.async_event_config },
        Feature.VOLATILE_WRITE_CACHE => .{ .result = 1 },
        Feature.INTERRUPT_VECTOR_CONFIG => .{ .result = cmd.cdw11 & 0xFFFF },
        Feature.ARBITRATION,
        Feature.POWER_MANAGEMENT,
        Feature.ERROR_RECOVERY,
        Feature.INTERRUPT_COALESCING,
        Feature.WRITE_ATOMICITY,
        Feature.AUTONOMOUS_POWER_STATE,
        Feature.KEEP_ALIVE_TIMER,
        Feature.HOST_CONTROLLED_THERMAL,
        Feature.SOFTWARE_PROGRESS_MARKER,
        => .{ .result = 0 },
        else => .{ .status = .invalid_field },
    };
}

fn getLogPage(self: *Nvme, cmd: Command) Completion {
    const lid: u8 = @truncate(cmd.cdw10);
    const numd: u32 = ((cmd.cdw10 >> 16) & 0xFFF) | ((cmd.cdw11 & 0xFFFF) << 12);
    const requested: u64 = (@as(u64, numd) + 1) * 4;
    var page: [PAGE_SIZE]u8 = @splat(0);
    switch (lid) {
        0x01 => {}, // error information: no entries
        0x02 => {
            // SMART / health: composite temperature 300 K, spare 100 %.
            std.mem.writeInt(u16, page[1..3], 300, .little);
            page[3] = 100;
            page[4] = 100;
            page[5] = 10;
        },
        0x03 => {
            // Firmware slot information: slot 1 active, revision string.
            page[0] = 1;
            @memcpy(page[8..16], "1.0     ");
        },
        0x04, 0x05, 0x06 => {}, // changed namespaces, command effects, self-test
        else => return .{ .status = .invalid_field },
    }
    return transferPageToGuestLimited(self, cmd, &page, @min(requested, PAGE_SIZE));
}

fn transferPageToGuestLimited(self: *Nvme, cmd: Command, page: *const [PAGE_SIZE]u8, len: u64) Completion {
    var offset: u64 = 0;
    var iter = PrpIterator.init(cmd.prp1, cmd.prp2, len);
    const memory = self.memory orelse return .{ .status = .data_transfer_error };
    while (iter.next(memory)) |segment| {
        memory.write(segment.addr, page[@intCast(offset)..@intCast(offset + segment.len)]) catch
            return .{ .status = .data_transfer_error };
        offset += segment.len;
    }
    if (offset != len) return .{ .status = .data_transfer_error };
    return .{};
}

fn transferToGuest(self: *Nvme, cmd: Command, page: *const [PAGE_SIZE]u8) Completion {
    return self.transferPageToGuestLimited(cmd, page, PAGE_SIZE);
}

// =============================================================================
// NVM command set
// =============================================================================

fn executeNvm(self: *Nvme, cmd: Command) Completion {
    if (cmd.nsid != 1) return .{ .status = .invalid_namespace };
    return switch (cmd.opcode) {
        NvmOpcode.FLUSH => blk: {
            if (self.file) |file| file.sync(global.io()) catch break :blk .{ .status = .write_fault };
            break :blk .{};
        },
        NvmOpcode.READ => self.readWrite(cmd, false),
        NvmOpcode.WRITE => self.readWrite(cmd, true),
        NvmOpcode.WRITE_ZEROES => self.writeZeroes(cmd),
        NvmOpcode.DATASET_MANAGEMENT => .{}, // deallocate hints are advisory
        else => .{ .status = .invalid_opcode },
    };
}

fn lbaRange(self: *const Nvme, cmd: Command) ?struct { offset: u64, bytes: u64 } {
    const slba = (@as(u64, cmd.cdw11) << 32) | cmd.cdw10;
    const count: u64 = (cmd.cdw12 & 0xFFFF) + 1;
    if (slba >= self.capacity_blocks or count > self.capacity_blocks - slba) return null;
    return .{ .offset = slba * LBA_SIZE, .bytes = count * LBA_SIZE };
}

fn readWrite(self: *Nvme, cmd: Command, is_write: bool) Completion {
    const file = self.file orelse return .{ .status = .unrecovered_read_error };
    const memory = self.memory orelse return .{ .status = .data_transfer_error };
    const range = self.lbaRange(cmd) orelse return .{ .status = .lba_out_of_range };
    if (range.bytes > TRANSFER_MAX) return .{ .status = .invalid_field };
    if (is_write and self.read_only) return .{ .status = .write_fault };

    var file_offset = range.offset;
    var iter = PrpIterator.init(cmd.prp1, cmd.prp2, range.bytes);
    while (iter.next(memory)) |segment| {
        const buffer = memory.get(segment.addr, @intCast(segment.len)) orelse
            return .{ .status = .data_transfer_error };
        if (is_write) {
            file.writePositionalAll(global.io(), buffer, file_offset) catch return .{ .status = .write_fault };
        } else {
            _ = file.readPositionalAll(global.io(), buffer, file_offset) catch
                return .{ .status = .unrecovered_read_error };
        }
        file_offset += segment.len;
    }
    if (file_offset != range.offset + range.bytes) return .{ .status = .data_transfer_error };
    return .{};
}

fn writeZeroes(self: *Nvme, cmd: Command) Completion {
    const file = self.file orelse return .{ .status = .write_fault };
    const range = self.lbaRange(cmd) orelse return .{ .status = .lba_out_of_range };
    if (self.read_only) return .{ .status = .write_fault };
    const zeros = [_]u8{0} ** 4096;
    var done: u64 = 0;
    while (done < range.bytes) {
        const chunk = @min(zeros.len, range.bytes - done);
        file.writePositionalAll(global.io(), zeros[0..@intCast(chunk)], range.offset + done) catch
            return .{ .status = .write_fault };
        done += chunk;
    }
    return .{};
}

/// Walks PRP1/PRP2 and PRP lists, yielding guest-contiguous segments.
const PrpIterator = struct {
    prp1: u64,
    prp2: u64,
    remaining: u64,
    started: bool = false,
    /// Current PRP list page and index once past the first two entries.
    list: u64 = 0,
    list_index: u32 = 0,
    failed: bool = false,

    const Segment = struct { addr: u64, len: u64 };
    const ENTRIES_PER_LIST: u32 = @intCast(PAGE_SIZE / 8);

    fn init(prp1: u64, prp2: u64, total: u64) PrpIterator {
        return .{ .prp1 = prp1, .prp2 = prp2, .remaining = total };
    }

    fn next(self: *PrpIterator, memory: GuestMemory) ?Segment {
        if (self.remaining == 0 or self.failed) return null;
        if (!self.started) {
            self.started = true;
            const offset = self.prp1 % PAGE_SIZE;
            const len = @min(PAGE_SIZE - offset, self.remaining);
            self.remaining -= len;
            // PRP2 is a single page pointer when the rest fits in one page.
            if (self.remaining > PAGE_SIZE) self.list = self.prp2 & ~(PAGE_SIZE - 1);
            return .{ .addr = self.prp1, .len = len };
        }
        if (self.list == 0) {
            const len = @min(PAGE_SIZE, self.remaining);
            self.remaining -= len;
            return .{ .addr = self.prp2 & ~(PAGE_SIZE - 1), .len = len };
        }
        // Last entry of a list chains to the next list when more follows.
        if (self.list_index == ENTRIES_PER_LIST - 1 and self.remaining > PAGE_SIZE) {
            self.list = self.readEntry(memory) orelse return null;
            self.list_index = 0;
        }
        const page = self.readEntry(memory) orelse return null;
        self.list_index += 1;
        const len = @min(PAGE_SIZE, self.remaining);
        self.remaining -= len;
        return .{ .addr = page & ~(PAGE_SIZE - 1), .len = len };
    }

    fn readEntry(self: *PrpIterator, memory: GuestMemory) ?u64 {
        var bytes: [8]u8 = undefined;
        memory.read(self.list + @as(u64, self.list_index) * 8, &bytes) catch {
            self.failed = true;
            return null;
        };
        const entry = std.mem.readInt(u64, &bytes, .little);
        if (entry == 0) {
            self.failed = true;
            return null;
        }
        return entry;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TestMemory = struct {
    base: u64,
    bytes: []u8,

    fn get(self: *TestMemory, address: u64, length: usize) ?[]u8 {
        if (address < self.base) return null;
        const offset_u64 = address - self.base;
        if (offset_u64 > self.bytes.len) return null;
        const offset: usize = @intCast(offset_u64);
        if (length > self.bytes.len - offset) return null;
        return self.bytes[offset..][0..length];
    }
};

const TestRig = struct {
    ram: []u8,
    context: TestMemory,
    nvme: *Nvme,
    path: []const u8,
    irq_level: bool = false,

    const BASE: u64 = 0x4000_0000;
    const RAM_BYTES: usize = 1024 * 1024;
    const ASQ: u64 = BASE + 0x10000;
    const ACQ: u64 = BASE + 0x20000;
    const IOSQ: u64 = BASE + 0x30000;
    const IOCQ: u64 = BASE + 0x40000;
    const DATA: u64 = BASE + 0x50000;
    const PRP_LIST: u64 = BASE + 0x60000;

    fn irqCallback(level: bool, userdata: ?*anyopaque) void {
        const self: *TestRig = @ptrCast(@alignCast(userdata));
        self.irq_level = level;
    }

    fn init(self: *TestRig, path: []const u8, disk_blocks: u64) !void {
        self.* = .{ .ram = undefined, .context = undefined, .nvme = undefined, .path = path };
        self.ram = try testing.allocator.alloc(u8, RAM_BYTES);
        @memset(self.ram, 0);
        self.context = .{ .base = BASE, .bytes = self.ram };
        const file = try std.Io.Dir.cwd().createFile(global.io(), path, .{ .read = true });
        try file.setLength(global.io(), disk_blocks * LBA_SIZE);
        self.nvme = try Nvme.initWithFile(testing.allocator, file, disk_blocks * LBA_SIZE, false, "TEST0001");
        self.nvme.setGuestMemory(GuestMemory.bind(TestMemory, &self.context, TestMemory.get));
        self.nvme.setIrqCallback(.{ .callback = irqCallback, .userdata = self });
        // Admin queues: 16 entries each, then enable.
        self.nvme.writeBar(Reg.AQA, 4, (15 << 16) | 15);
        self.nvme.writeBar(Reg.ASQ, 8, ASQ);
        self.nvme.writeBar(Reg.ACQ, 8, ACQ);
        self.nvme.writeBar(Reg.CC, 4, CC_EN | (6 << 16) | (4 << 20));
    }

    fn deinit(self: *TestRig) void {
        self.nvme.deinit();
        testing.allocator.free(self.ram);
        std.Io.Dir.cwd().deleteFile(global.io(), self.path) catch {};
    }

    fn slice(self: *TestRig, addr: u64, len: usize) []u8 {
        return self.ram[@intCast(addr - BASE)..][0..len];
    }

    /// Submit one command on queue `qid` (base/tail tracked here) and
    /// return the completion status (SC | SCT<<8) plus result.
    fn submit(self: *TestRig, qid: u16, sq_base: u64, cq_base: u64, tail: *u32, cq_index: *u32, cq_phase: *u1, cmd: [64]u8) struct { status: u16, result: u32 } {
        @memcpy(self.slice(sq_base + @as(u64, tail.*) * 64, 64), &cmd);
        tail.* = (tail.* + 1) % 16; // every test queue has 16 entries
        self.nvme.writeBar(Reg.DOORBELLS + @as(u64, qid) * 8, 4, tail.*);
        const entry = self.slice(cq_base + @as(u64, cq_index.*) * 16, 16);
        const status_phase = std.mem.readInt(u16, entry[14..16], .little);
        try_expect_phase(status_phase, cq_phase.*);
        cq_index.* += 1;
        return .{ .status = status_phase >> 1, .result = std.mem.readInt(u32, entry[0..4], .little) };
    }

    fn try_expect_phase(status_phase: u16, phase: u1) void {
        if ((status_phase & 1) != phase) {
            std.debug.print("phase mismatch: entry status/phase=0x{x} expected phase {}\n", .{ status_phase, phase });
            unreachable;
        }
    }
};

fn makeCommand(opcode: u8, cid: u16, nsid: u32, prp1: u64, prp2: u64, cdw10: u32, cdw11: u32, cdw12: u32) [64]u8 {
    var raw: [64]u8 = @splat(0);
    std.mem.writeInt(u32, raw[0..4], @as(u32, opcode) | (@as(u32, cid) << 16), .little);
    std.mem.writeInt(u32, raw[4..8], nsid, .little);
    std.mem.writeInt(u64, raw[24..32], prp1, .little);
    std.mem.writeInt(u64, raw[32..40], prp2, .little);
    std.mem.writeInt(u32, raw[40..44], cdw10, .little);
    std.mem.writeInt(u32, raw[44..48], cdw11, .little);
    std.mem.writeInt(u32, raw[48..52], cdw12, .little);
    return raw;
}

test "controller registers: CAP/VS, enable sets RDY, disable clears it" {
    var rig: TestRig = undefined;
    try rig.init(".zig-cache/nvme-regs-test.raw", 64);
    defer rig.deinit();

    try testing.expectEqual(@as(u64, 0x0001_0400), rig.nvme.readBar(Reg.VS, 4));
    const cap = rig.nvme.readBar(Reg.CAP, 8);
    try testing.expectEqual(@as(u64, QUEUE_ENTRIES_MAX - 1), cap & 0xFFFF);
    try testing.expectEqual(@as(u64, 1), (cap >> 37) & 0xFF); // NVM command set
    try testing.expectEqual(cap >> 32, rig.nvme.readBar(Reg.CAP + 4, 4));
    try testing.expectEqual(@as(u64, CSTS_RDY), rig.nvme.readBar(Reg.CSTS, 4) & 1);
    try testing.expectEqual(TestRig.ASQ, rig.nvme.readBar(Reg.ASQ, 8));

    rig.nvme.writeBar(Reg.CC, 4, 0);
    try testing.expectEqual(@as(u64, 0), rig.nvme.readBar(Reg.CSTS, 4) & 1);
    rig.nvme.writeBar(Reg.CC, 4, CC_EN);
    try testing.expectEqual(@as(u64, CSTS_RDY), rig.nvme.readBar(Reg.CSTS, 4) & 1);
}

test "identify controller and namespace through the admin queue" {
    var rig: TestRig = undefined;
    try rig.init(".zig-cache/nvme-identify-test.raw", 4096);
    defer rig.deinit();
    var tail: u32 = 0;
    var cq_index: u32 = 0;
    var phase: u1 = 1;

    var done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &tail, &cq_index, &phase, makeCommand(AdminOpcode.IDENTIFY, 7, 0, TestRig.DATA, 0, 1, 0, 0));
    try testing.expectEqual(@as(u16, 0), done.status);
    const ctrl = rig.slice(TestRig.DATA, PAGE_SIZE);
    try testing.expectEqual(VENDOR_ID, std.mem.readInt(u16, ctrl[0..2], .little));
    try testing.expectEqualStrings("TEST0001", ctrl[4..12]);
    try testing.expectEqual(@as(u8, 0x66), ctrl[512]);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, ctrl[516..520], .little));
    const entry = rig.slice(TestRig.ACQ, 16);
    try testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, entry[12..14], .little)); // cid
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, entry[8..10], .little)); // sq head
    try testing.expect(rig.irq_level);

    // Consuming the completion drops the interrupt line.
    rig.nvme.writeBar(Reg.DOORBELLS + 4, 4, 1);
    try testing.expect(!rig.irq_level);

    done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &tail, &cq_index, &phase, makeCommand(AdminOpcode.IDENTIFY, 8, 1, TestRig.DATA, 0, 0, 0, 0));
    try testing.expectEqual(@as(u16, 0), done.status);
    const ns = rig.slice(TestRig.DATA, PAGE_SIZE);
    try testing.expectEqual(@as(u64, 4096), std.mem.readInt(u64, ns[0..8], .little));
    try testing.expectEqual(@as(u8, 9), ns[130]);

    done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &tail, &cq_index, &phase, makeCommand(AdminOpcode.IDENTIFY, 9, 0, TestRig.DATA, 0, 0x2, 0, 0));
    try testing.expectEqual(@as(u16, 0), done.status);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, rig.slice(TestRig.DATA, 4)[0..4], .little));

    done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &tail, &cq_index, &phase, makeCommand(0x7F, 10, 0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u16, @intFromEnum(Status.invalid_opcode)), done.status);
}

test "io queues carry writes and reads through PRP1/PRP2 and PRP lists" {
    var rig: TestRig = undefined;
    try rig.init(".zig-cache/nvme-io-test.raw", 4096);
    defer rig.deinit();
    var atail: u32 = 0;
    var acq_index: u32 = 0;
    var aphase: u1 = 1;

    // Number of queues, then create CQ 1 (interrupts on) and SQ 1 → CQ 1.
    var done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &atail, &acq_index, &aphase, makeCommand(AdminOpcode.SET_FEATURES, 1, 0, 0, 0, Feature.NUMBER_OF_QUEUES, (3 << 16) | 3, 0));
    try testing.expectEqual(@as(u16, 0), done.status);
    try testing.expectEqual(@as(u32, (3 << 16) | 3), done.result);
    done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &atail, &acq_index, &aphase, makeCommand(AdminOpcode.CREATE_IO_CQ, 2, 0, TestRig.IOCQ, 0, (15 << 16) | 1, 0x3, 0));
    try testing.expectEqual(@as(u16, 0), done.status);
    done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &atail, &acq_index, &aphase, makeCommand(AdminOpcode.CREATE_IO_SQ, 3, 0, TestRig.IOSQ, 0, (15 << 16) | 1, (1 << 16) | 1, 0));
    try testing.expectEqual(@as(u16, 0), done.status);
    rig.nvme.writeBar(Reg.DOORBELLS + 4, 4, acq_index);

    // Write 16 LBAs (8 KiB) from two pages, then read them back elsewhere.
    var tail: u32 = 0;
    var cq_index: u32 = 0;
    var phase: u1 = 1;
    const src = rig.slice(TestRig.DATA, 8192);
    for (src, 0..) |*b, i| b.* = @truncate(i * 7);
    done = rig.submit(1, TestRig.IOSQ, TestRig.IOCQ, &tail, &cq_index, &phase, makeCommand(NvmOpcode.WRITE, 20, 1, TestRig.DATA, TestRig.DATA + 4096, 100, 0, 15));
    try testing.expectEqual(@as(u16, 0), done.status);
    try testing.expect(rig.irq_level);

    const dst_base = TestRig.DATA + 0x8000;
    done = rig.submit(1, TestRig.IOSQ, TestRig.IOCQ, &tail, &cq_index, &phase, makeCommand(NvmOpcode.READ, 21, 1, dst_base, dst_base + 4096, 100, 0, 15));
    try testing.expectEqual(@as(u16, 0), done.status);
    try testing.expectEqualSlices(u8, src, rig.slice(dst_base, 8192));

    // 3 pages via a PRP list (PRP2 points at the list): read LBAs 100..123.
    const list = rig.slice(TestRig.PRP_LIST, 16);
    const p2 = TestRig.DATA + 0x20000;
    std.mem.writeInt(u64, list[0..8], p2 + 4096, .little);
    std.mem.writeInt(u64, list[8..16], p2 + 8192, .little);
    done = rig.submit(1, TestRig.IOSQ, TestRig.IOCQ, &tail, &cq_index, &phase, makeCommand(NvmOpcode.READ, 22, 1, p2, TestRig.PRP_LIST, 100, 0, 23));
    try testing.expectEqual(@as(u16, 0), done.status);
    try testing.expectEqualSlices(u8, src, rig.slice(p2, 8192));
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 4096, rig.slice(p2 + 8192, 4096));

    // Out-of-range and flush.
    done = rig.submit(1, TestRig.IOSQ, TestRig.IOCQ, &tail, &cq_index, &phase, makeCommand(NvmOpcode.READ, 23, 1, p2, 0, 4090, 0, 15));
    try testing.expectEqual(@as(u16, @intFromEnum(Status.lba_out_of_range)), done.status);
    done = rig.submit(1, TestRig.IOSQ, TestRig.IOCQ, &tail, &cq_index, &phase, makeCommand(NvmOpcode.FLUSH, 24, 1, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(u16, 0), done.status);

    // Masking the vector drops the line even with unconsumed completions.
    try testing.expect(rig.irq_level);
    rig.nvme.writeBar(Reg.INTMS, 4, 1);
    try testing.expect(!rig.irq_level);
    rig.nvme.writeBar(Reg.INTMC, 4, 1);
    try testing.expect(rig.irq_level);
    rig.nvme.writeBar(Reg.DOORBELLS + 8 + 4, 4, cq_index);
    try testing.expect(!rig.irq_level);
}

test "completion phase flips when the queue wraps" {
    var rig: TestRig = undefined;
    try rig.init(".zig-cache/nvme-phase-test.raw", 64);
    defer rig.deinit();
    // Admin CQ has 16 entries; issue 17 keep-alives and watch the phase.
    var tail: u32 = 0;
    var cq_index: u32 = 0;
    var phase: u1 = 1;
    var i: u32 = 0;
    while (i < 17) : (i += 1) {
        if (cq_index == 16) {
            cq_index = 0;
            phase = 0;
        }
        // Keep the CQ from filling: acknowledge everything so far.
        rig.nvme.writeBar(Reg.DOORBELLS + 4, 4, cq_index);
        const done = rig.submit(0, TestRig.ASQ, TestRig.ACQ, &tail, &cq_index, &phase, makeCommand(AdminOpcode.KEEP_ALIVE, @intCast(i), 0, 0, 0, 0, 0, 0));
        try testing.expectEqual(@as(u16, 0), done.status);
    }
}

test "config space exposes an NVMe class code and a 16 KiB BAR" {
    var rig: TestRig = undefined;
    try rig.init(".zig-cache/nvme-config-test.raw", 64);
    defer rig.deinit();
    try testing.expectEqual(@as(u64, 0x0108_02), rig.nvme.readConfig(0x09, 4) & 0xFF_FFFF);
    rig.nvme.writeConfig(0x10, 4, 0xFFFF_FFFF);
    try testing.expectEqual(@as(u64, BAR0_MASK), rig.nvme.readConfig(0x10, 4));
    rig.nvme.writeConfig(0x10, 4, 0x1001_2345);
    try testing.expectEqual(@as(u32, 0x1001_0000), rig.nvme.bar0_addr);
    try testing.expectEqual(@as(?u32, 0x14), rig.nvme.barOffset(0x1001_0014));
    try testing.expectEqual(@as(?u32, null), rig.nvme.barOffset(0x1001_4000));
}
