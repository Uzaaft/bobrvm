//! xHCI 1.0, one interrupter, three USB 2 root ports, 32-byte contexts.
//! All entry points run under the machine lock. Guest pointers are validated
//! through GuestMemory; rings, slots, segments and traversal budgets are bounded.
//! Register/TRB layout: Intel xHCI specification, chapters 5 and 6.
const Xhci = @This();
const std = @import("std");
const global = @import("../global.zig");
const GuestMemory = @import("../guest_memory.zig").GuestMemory;
const policy = @import("config.zig");
pub const Device = @import("../usb/device.zig");

alloc: std.mem.Allocator,
memory: GuestMemory,
config: [policy.space_size]u8 = @splat(0),
bar0_addr: u32 = 0,
irq: ?Irq = null,
irq_level: bool = false,
devices: [ports_max]Device = .{
    .{ .kind = .keyboard }, .{ .kind = .tablet }, .{ .kind = .optical },
},
command: u32 = 0,
status: u32 = 1,
crcr: u64 = 0,
dcbaap: u64 = 0,
slots_enabled: u32 = 0,
portsc: [ports_max]u32 = @splat(0),
iman: u32 = 0,
imod: u32 = 0,
erstsz: u32 = 0,
erstba: u64 = 0,
erdp: u64 = 0,
event_segment: usize = 0,
event_index: u32 = 0,
event_cycle: u1 = 1,
event_outstanding: u32 = 0,
slots: [slots_max + 1]Slot = @splat(.{}),

pub const bar_size: u32 = 0x4000;
const slots_max = 8;
const ports_max = 3;
const traversal_max = 256;
const segments_max = 4;
const log = std.log.scoped(.xhci);
pub const Irq = struct { callback: *const fn (bool, ?*anyopaque) void, userdata: ?*anyopaque };
const Error = GuestMemory.Error || error{InvalidRing};
const Endpoint = struct {
    dequeue: u64 = 0,
    cycle: u1 = 1,
    state: u3 = 0,
    pending: bool = false,
    setup: Device.Setup = .{ .request_type = 0, .request = 0, .value = 0, .index = 0, .length = 0 },
    response: [256]u8 = @splat(0),
    response_length: usize = 0,
    response_offset: usize = 0,
    td_actual: u32 = 0,
};
const Slot = struct {
    enabled: bool = false,
    port: u8 = 0,
    context: u64 = 0,
    endpoints: [32]Endpoint = @splat(.{}),
};
const Trb = struct {
    parameter: u64,
    status: u32,
    control: u32,

    fn read(memory: GuestMemory, address: u64) Error!Trb {
        const data = memory.get(address, 16) orelse return error.OutOfBounds;
        return .{
            .parameter = std.mem.readInt(u64, data[0..8], .little),
            .status = std.mem.readInt(u32, data[8..12], .little),
            .control = std.mem.readInt(u32, data[12..16], .little),
        };
    }
    fn kind(self: Trb) u6 {
        return @truncate(self.control >> 10);
    }
    fn cycle(self: Trb) u1 {
        return @truncate(self.control);
    }
};

pub fn init(
    alloc: std.mem.Allocator,
    memory: GuestMemory,
    iso: ?[]const u8,
) (std.mem.Allocator.Error || Device.Optical.InitError)!*Xhci {
    const self = try alloc.create(Xhci);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .memory = memory };
    if (iso) |path| self.devices[2].optical = try Device.Optical.init(path);
    self.config[0..4].* = .{ 0x36, 0x1b, 0x0d, 0x00 }; // QEMU generic xHCI identity
    self.config[8..12].* = .{ 1, 0x30, 3, 0x0c };
    self.config[0x3d] = 1; // INTA, shared through the PCI host bridge
    self.reset();
    return self;
}

pub fn deinit(self: *Xhci) void {
    self.devices[2].optical.deinit();
    self.alloc.destroy(self);
}

pub fn reset(self: *Xhci) void {
    self.command = 0;
    self.status = 1;
    self.crcr = 0;
    self.dcbaap = 0;
    self.slots_enabled = 0;
    self.iman = 0;
    self.imod = 0;
    self.erstsz = 0;
    self.erstba = 0;
    self.erdp = 0;
    self.event_segment = 0;
    self.event_index = 0;
    self.event_cycle = 1;
    self.event_outstanding = 0;
    self.slots = @splat(.{});
    for (&self.devices, 0..) |*device, index| {
        device.reset();
        const connected = index != 2 or device.optical.file != null;
        const speed: u32 = if (index == 2) 3 else 1;
        self.portsc[index] = (speed << 10) | (1 << 9) |
            (if (connected) @as(u32, 1 | (1 << 17)) else 0);
    }
    self.updateIrq();
}

pub fn readConfig(self: *const Xhci, offset: u12, size: u8) u64 {
    if (@as(usize, offset) + size > self.config.len) return 0xffffffff;
    var value: u64 = 0;
    for (0..size) |i| value |= @as(u64, self.config[offset + i]) << @intCast(i * 8);
    return value;
}

pub fn writeConfig(self: *Xhci, offset: u12, size: u8, value: u64) void {
    switch (policy.writeType0Masked(&self.config, offset, size, value, 0xffffc000)) {
        .bar0_assigned => |address| self.bar0_addr = address,
        else => {},
    }
}

pub fn barOffset(self: *const Xhci, address: u64) ?u32 {
    if (self.bar0_addr == 0 or address < self.bar0_addr or
        address - self.bar0_addr >= bar_size) return null;
    return @intCast(address - self.bar0_addr);
}

pub fn readBar(self: *Xhci, offset: u32, size: u8) u64 {
    if (size == 8) return @as(u64, self.read32(offset)) | (@as(u64, self.read32(offset + 4)) << 32);
    const value = self.read32(offset & ~@as(u32, 3)) >> @as(u5, @intCast((offset & 3) * 8));
    return if (size == 4) value else value & ((@as(u32, 1) << @intCast(size * 8)) - 1);
}

fn read32(self: *Xhci, offset: u32) u32 {
    if (offset >= 0x440 and offset < 0x440 + ports_max * 16) {
        return if (offset & 15 == 0) self.portsc[(offset - 0x440) / 16] else 0;
    }
    return switch (offset) {
        0 => 0x01000040, // HCIVERSION 1.0, CAPLENGTH 0x40
        4 => slots_max | (1 << 8) | (ports_max << 24),
        8 => 0x20, // ERST max: 2^2 segments, no scratchpads
        0x10 => 1 | (0x40 << 16), // 64-bit addressing, 32-byte contexts, xECP
        0x14 => 0x1000, // doorbells
        0x18 => 0x2000, // runtime
        0x40 => self.command,
        0x44 => self.status,
        0x48 => 1, // 4 KiB pages
        0x58 => @truncate(self.crcr),
        0x5c => @truncate(self.crcr >> 32),
        0x70 => @truncate(self.dcbaap),
        0x74 => @truncate(self.dcbaap >> 32),
        0x78 => self.slots_enabled,
        0x100 => 0x02000002, // USB 2.0 Supported Protocol capability
        0x104 => 0x20425355, // "USB "
        0x108 => 1 | (ports_max << 8),
        0x2000 => microframeIndex(),
        0x2020 => self.iman,
        0x2024 => self.imod,
        0x2028 => self.erstsz,
        0x2030 => @truncate(self.erstba),
        0x2034 => @truncate(self.erstba >> 32),
        0x2038 => @truncate(self.erdp),
        0x203c => @truncate(self.erdp >> 32),
        else => 0,
    };
}

pub fn writeBar(self: *Xhci, offset: u32, size: u8, value: u64) void {
    if (size != 4 and size != 8) return;
    self.write32(offset, @truncate(value));
    if (size == 8) self.write32(offset + 4, @truncate(value >> 32));
}

fn write32(self: *Xhci, offset: u32, value: u32) void {
    if (offset >= 0x1000 and offset <= 0x1000 + slots_max * 4) {
        if (self.command & 1 == 0) return;
        const slot: u8 = @intCast((offset - 0x1000) / 4);
        if (slot == 0) self.runCommands() catch self.fault() else {
            const ep: u8 = @truncate(value);
            if (ep > 0 and ep < 32 and value >> 16 == 0 and self.slots[slot].enabled) {
                self.slots[slot].endpoints[ep].pending = true;
                self.runEndpoint(slot, ep) catch self.fault();
            }
        }
        return;
    }
    if (offset >= 0x440 and offset < 0x440 + ports_max * 16) {
        if (offset & 15 == 0) self.writePort(@intCast((offset - 0x440) / 16), value);
        return;
    }
    switch (offset) {
        0x40 => {
            if (value & 2 != 0) {
                self.reset();
                return;
            }
            self.command = value & 0x0d;
            if (value & 1 != 0) self.status &= ~@as(u32, 1) else self.status |= 1;
            self.updateIrq();
        },
        0x44 => {
            self.status &= ~(value & 0x41c);
            self.updateIrq();
        },
        0x58 => self.crcr = (self.crcr & 0xffffffff00000000) | (value & 0xffffffc1),
        0x5c => self.crcr = (self.crcr & 0xffffffff) | (@as(u64, value) << 32),
        0x70 => self.dcbaap = (self.dcbaap & 0xffffffff00000000) | (value & 0xffffffc0),
        0x74 => self.dcbaap = (self.dcbaap & 0xffffffff) | (@as(u64, value) << 32),
        0x78 => self.slots_enabled = @min(value & 0xff, slots_max),
        0x2020 => {
            self.iman = (self.iman & ~(value & 1)) & 1 | (value & 2);
            self.updateIrq();
        },
        0x2024 => self.imod = value,
        0x2028 => self.erstsz = value & 0xffff,
        0x2030 => {
            self.erstba = (self.erstba & 0xffffffff00000000) | (value & 0xffffffc0);
            self.event_segment = 0;
            self.event_index = 0;
            self.event_cycle = 1;
            self.event_outstanding = 0;
        },
        0x2034 => self.erstba = (self.erstba & 0xffffffff) | (@as(u64, value) << 32),
        0x2038 => self.erdp = (self.erdp & 0xffffffff00000000) | (value & 0xfffffff0),
        0x203c => self.erdp = (self.erdp & 0xffffffff) | (@as(u64, value) << 32),
        else => {},
    }
}

fn writePort(self: *Xhci, port: usize, value: u32) void {
    self.portsc[port] &= ~(value & 0x00fe0000); // change bits W1C
    self.portsc[port] = (self.portsc[port] & ~@as(u32, 1 << 9)) | (value & (1 << 9));
    if (value & (1 << 16) != 0) {
        self.portsc[port] = (self.portsc[port] & ~@as(u32, 0x1e0)) | (value & 0x1e0);
    }
    if (value & ((1 << 4) | (1 << 31)) != 0 and self.portsc[port] & 1 != 0) {
        self.devices[port].reset();
        self.portsc[port] &= ~@as(u32, 0x1e0);
        self.portsc[port] |= 2 | (1 << 21);
        self.status |= 1 << 4;
        self.event(.{
            .parameter = (port + 1) << 24,
            .status = 1 << 24,
            .control = 34 << 10,
        }) catch self.fault();
    }
}

fn updateIrq(self: *Xhci) void {
    const level = self.command & 4 != 0 and self.iman & 3 == 3;
    if (level == self.irq_level) return;
    self.irq_level = level;
    if (self.irq) |irq| irq.callback(level, irq.userdata);
}

fn fault(self: *Xhci) void {
    log.warn("invalid or exhausted guest xHCI ring", .{});
    self.status |= 1 | 4;
    self.command &= ~@as(u32, 1);
}

const Segment = struct { base: u64, count: u32 };
fn segment(self: *const Xhci, index: usize) Error!Segment {
    if (self.erstsz == 0 or self.erstsz > segments_max or index >= self.erstsz)
        return error.InvalidRing;
    const address = std.math.add(u64, self.erstba, index * 16) catch return error.InvalidRing;
    const entry = try Trb.read(self.memory, address);
    const count = entry.status & 0xffff;
    if (entry.parameter & 63 != 0 or count < 16 or count > 4096) return error.InvalidRing;
    _ = self.memory.get(entry.parameter, @as(usize, count) * 16) orelse return error.OutOfBounds;
    return .{ .base = entry.parameter, .count = count };
}

fn event(self: *Xhci, trb: Trb) Error!void {
    // Before the event ring is configured, port change bits remain latched.
    if (self.erstsz == 0) return;
    const seg = try self.segment(self.event_segment);
    if (self.event_index >= seg.count) return error.InvalidRing;
    const address = seg.base + self.event_index * 16;
    // Leave one event entry unused to distinguish full from empty. ERDP is
    // the last consumed entry; never overwrite it on wrapping the producer.
    var next_index = self.event_index + 1;
    var next_segment = self.event_segment;
    var next_cycle = self.event_cycle;
    if (next_index == seg.count) {
        next_index = 0;
        next_segment += 1;
        if (next_segment == self.erstsz) {
            next_segment = 0;
            next_cycle ^= 1;
        }
    }
    const next = (try self.segment(next_segment)).base + next_index * 16;
    if (self.event_outstanding > 0 and next == self.erdp) return error.InvalidRing;
    const data = self.memory.get(address, 16) orelse return error.OutOfBounds;
    std.mem.writeInt(u64, data[0..8], trb.parameter, .little);
    std.mem.writeInt(u32, data[8..12], trb.status, .little);
    std.mem.writeInt(u32, data[12..16], (trb.control & ~@as(u32, 1)) | self.event_cycle, .little);
    self.event_segment = next_segment;
    self.event_index = next_index;
    self.event_cycle = next_cycle;
    self.event_outstanding +|= 1;
    self.iman |= 1;
    self.status |= 8;
    self.updateIrq();
}

fn runCommands(self: *Xhci) Error!void {
    var address = self.crcr & ~@as(u64, 15);
    var cycle: u1 = @truncate(self.crcr);
    for (0..traversal_max) |_| {
        const trb = try Trb.read(self.memory, address);
        if (trb.cycle() != cycle) return;
        if (trb.kind() == 6) {
            address = trb.parameter & ~@as(u64, 15);
            if (trb.control & 2 != 0) cycle ^= 1;
        } else {
            var slot: u8 = @truncate(trb.control >> 24);
            const code = try self.commandTrb(trb, &slot);
            if (trace()) log.debug("command {} slot {} -> {}", .{ trb.kind(), slot, code });
            try self.event(.{
                .parameter = address,
                .status = @as(u32, code) << 24,
                .control = (33 << 10) | (@as(u32, slot) << 24),
            });
            address = std.math.add(u64, address, 16) catch return error.InvalidRing;
        }
        self.crcr = address | cycle;
    }
    return error.InvalidRing;
}

fn commandTrb(self: *Xhci, trb: Trb, slot_id: *u8) Error!u8 {
    const kind = trb.kind();
    if (kind == 23) return 1; // No-op command
    if (kind == 9) {
        for (1..self.slots_enabled + 1) |i| {
            if (self.slots[i].enabled) continue;
            self.slots[i] = .{ .enabled = true };
            slot_id.* = @intCast(i);
            return 1;
        }
        return 9; // No Slots Available
    }
    if (slot_id.* == 0 or slot_id.* > slots_max or !self.slots[slot_id.*].enabled) return 11;
    const slot = &self.slots[slot_id.*];
    if (kind == 10) {
        slot.* = .{};
        return 1;
    }
    if (kind == 11) return self.addressDevice(slot_id.*, trb);
    if (kind == 12 or kind == 13) return self.configureDevice(slot_id.*, trb);
    if (kind == 17) {
        slot.endpoints[2..].* = @splat(.{});
        if (slot.port > 0) self.devices[slot.port - 1].reset();
        return 1;
    }
    const ep_id: u5 = @truncate(trb.control >> 16);
    if (ep_id == 0 or slot.context == 0) return 19;
    const ep = &slot.endpoints[ep_id];
    switch (kind) {
        14, 15 => {
            ep.pending = false;
            ep.state = 3;
        },
        16 => {
            ep.dequeue = trb.parameter & ~@as(u64, 15);
            ep.cycle = @truncate(trb.parameter);
            ep.pending = false;
            ep.state = 3;
        },
        else => return 5,
    }
    try self.writeEndpoint(slot_id.*, ep_id);
    return 1;
}

fn addressDevice(self: *Xhci, slot_id: u8, trb: Trb) Error!u8 {
    const input = self.memory.get(trb.parameter & ~@as(u64, 15), 96) orelse return 17;
    const port = input[32 + 6];
    if (port == 0 or port > ports_max or self.portsc[port - 1] & 1 == 0) return 17;
    const entry_address = std.math.add(u64, self.dcbaap, @as(u64, slot_id) * 8) catch return 17;
    const entry = self.memory.get(entry_address, 8) orelse return 17;
    const output_address = std.mem.readInt(u64, entry[0..8], .little) & ~@as(u64, 63);
    const output = self.memory.get(output_address, 1024) orelse return 17;
    @memset(output, 0);
    @memcpy(output[0..64], input[32..96]);
    const slot = &self.slots[slot_id];
    slot.context = output_address;
    slot.port = port;
    const state: u32 = if (trb.control & (1 << 9) != 0) 1 else 2;
    std.mem.writeInt(u32, output[12..16], (state << 27) | slot_id, .little);
    self.loadEndpoint(&slot.endpoints[1], input[64..96]);
    try self.writeEndpoint(slot_id, 1);
    return 1;
}

fn loadEndpoint(_: *Xhci, ep: *Endpoint, input: []const u8) void {
    const dequeue = std.mem.readInt(u64, input[8..16], .little);
    ep.* = .{ .dequeue = dequeue & ~@as(u64, 15), .cycle = @truncate(dequeue), .state = 1 };
}

fn configureDevice(self: *Xhci, slot_id: u8, trb: Trb) Error!u8 {
    const slot = &self.slots[slot_id];
    if (slot.context == 0) return 19;
    const input = self.memory.get(trb.parameter & ~@as(u64, 15), 1056) orelse return 17;
    const output = self.memory.get(slot.context, 1024) orelse return 17;
    const drop = std.mem.readInt(u32, input[0..4], .little);
    const add = std.mem.readInt(u32, input[4..8], .little);
    if (add & 1 != 0) {
        @memcpy(output[0..12], input[32..44]);
        output[3] = (output[3] & 7) | (input[35] & 0xf8);
    }
    for (1..32) |id| {
        const mask = @as(u32, 1) << @intCast(id);
        if (drop & mask != 0 or (trb.control & (1 << 9) != 0 and id > 1)) {
            slot.endpoints[id] = .{};
            @memset(output[id * 32 ..][0..32], 0);
        }
        if (add & mask == 0) continue;
        const context = input[(id + 1) * 32 ..][0..32];
        @memcpy(output[id * 32 ..][0..32], context);
        if (trb.kind() == 12 or slot.endpoints[id].state == 0)
            self.loadEndpoint(&slot.endpoints[id], context);
        try self.writeEndpoint(slot_id, @intCast(id));
    }
    if (trb.kind() == 12) {
        const state: u32 = if (trb.control & (1 << 9) != 0) 2 else 3;
        std.mem.writeInt(u32, output[12..16], (state << 27) | slot_id, .little);
    }
    return 1;
}

fn writeEndpoint(self: *Xhci, slot_id: u8, ep_id: u8) Error!void {
    const slot = &self.slots[slot_id];
    const ep = &slot.endpoints[ep_id];
    const context = self.memory.get(slot.context + @as(u64, ep_id) * 32, 32) orelse
        return error.OutOfBounds;
    context[0] = (context[0] & 0xf8) | ep.state;
    std.mem.writeInt(u64, context[8..16], ep.dequeue | ep.cycle, .little);
}

pub fn poll(self: *Xhci) void {
    if (self.command & 1 == 0) return;
    for (1..slots_max + 1) |slot| {
        if (!self.slots[slot].enabled) continue;
        for (1..32) |ep| {
            if (self.slots[slot].endpoints[ep].pending)
                self.runEndpoint(@intCast(slot), @intCast(ep)) catch self.fault();
        }
    }
}

fn runEndpoint(self: *Xhci, slot_id: u8, ep_id: u8) Error!void {
    const slot = &self.slots[slot_id];
    if (slot.port == 0 or slot.port > ports_max) return;
    const ep = &slot.endpoints[ep_id];
    if (ep.state == 0 or ep.state == 2) {
        ep.pending = false;
        return;
    }
    ep.state = 1;
    const device = &self.devices[slot.port - 1];
    for (0..traversal_max) |_| {
        const address = ep.dequeue;
        const trb = try Trb.read(self.memory, address);
        if (trb.cycle() != ep.cycle) {
            ep.pending = false;
            return;
        }
        if (trb.kind() == 6) {
            ep.dequeue = trb.parameter & ~@as(u64, 15);
            if (trb.control & 2 != 0) ep.cycle ^= 1;
            continue;
        }
        const result = self.transfer(device, ep, ep_id, trb) catch |err| {
            ep.state = 2;
            ep.pending = false;
            try self.writeEndpoint(slot_id, ep_id);
            const code: u8 = if (err == error.Stall) 6 else 4;
            try self.transferEvent(slot_id, ep_id, address, trb.status & 0x1ffff, code, false);
            return;
        };
        const actual = result orelse return; // NAK, preserve TRB for next poll
        ep.dequeue = std.math.add(u64, address, 16) catch return error.InvalidRing;
        const requested = trb.status & 0x1ffff;
        const short = (trb.kind() == 1 or trb.kind() == 3) and actual < requested;
        // Event Data completion lengths count payload bytes, excluding the
        // eight-byte Setup packet and zero-length Status stage (xHCI 4.11.5).
        if (trb.kind() == 1 or trb.kind() == 3) ep.td_actual +|= actual;
        const event_data = trb.kind() == 7;
        if (trb.control & 32 != 0 or (short and trb.control & 4 != 0)) {
            try self.transferEvent(
                slot_id,
                ep_id,
                if (event_data) trb.parameter else address,
                if (event_data) ep.td_actual else requested -| actual,
                if (short) 13 else 1,
                event_data,
            );
        }
        if (trb.control & 16 == 0 and trb.kind() != 2 and trb.kind() != 3) ep.td_actual = 0;
        try self.writeEndpoint(slot_id, ep_id);
    }
    return error.InvalidRing;
}

fn transfer(
    self: *Xhci,
    device: *Device,
    ep: *Endpoint,
    ep_id: u8,
    trb: Trb,
) (Error || Device.Error)!?u32 {
    const length = trb.status & 0x1ffff;
    switch (trb.kind()) {
        2 => { // Setup Stage: exactly eight bytes, immediate data
            if (ep_id != 1 or length != 8 or trb.control & 64 == 0) return error.Stall;
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, trb.parameter, .little);
            ep.setup = Device.Setup.parse(&bytes);
            ep.response_offset = 0;
            ep.td_actual = 0;
            ep.response_length = try device.control(ep.setup, &ep.response);
            return 8;
        },
        4 => return 0, // Status Stage
        7, 8 => return 0, // Event Data, No-op transfer
        1, 3 => {
            const input = if (ep_id == 1) ep.setup.request_type & 0x80 != 0 else ep_id & 1 != 0;
            var immediate: [8]u8 = undefined;
            const data = if (trb.control & 64 != 0) blk: {
                if (length > 8 or input) return error.Stall;
                std.mem.writeInt(u64, &immediate, trb.parameter, .little);
                break :blk immediate[0..length];
            } else self.memory.get(trb.parameter, length) orelse return error.OutOfBounds;
            if (ep_id == 1) {
                if (!input) return length;
                const count = @min(length, ep.response_length - ep.response_offset);
                @memcpy(data[0..count], ep.response[ep.response_offset..][0..count]);
                ep.response_offset += count;
                return @intCast(count);
            }
            const count = try device.transfer(ep_id / 2, input, data);
            return if (count) |n| @intCast(n) else null;
        },
        else => return error.Stall,
    }
}

fn transferEvent(
    self: *Xhci,
    slot: u8,
    ep: u8,
    pointer: u64,
    length: u32,
    code: u8,
    data: bool,
) Error!void {
    if (trace()) log.debug("transfer slot {} ep {} code {} len {} ptr 0x{x}", .{
        slot, ep, code, length, pointer,
    });
    try self.event(.{
        .parameter = pointer,
        .status = (length & 0xffffff) | (@as(u32, code) << 24),
        .control = (32 << 10) | (@as(u32, ep) << 16) |
            (@as(u32, slot) << 24) | (if (data) @as(u32, 4) else 0),
    });
}

fn microframeIndex() u32 {
    const now_ns = std.Io.Clock.awake.now(global.io()).nanoseconds;
    return @intCast(@mod(@divTrunc(now_ns, 125000), 16384));
}

fn trace() bool {
    return std.c.getenv("BOBRVM_TRACE_USB") != null;
}

test {
    _ = Device;
}

const TestRig = struct {
    bytes: []u8,
    controller: *Xhci,
    irq_level: bool = false,

    fn init(self: *TestRig) !void {
        self.bytes = try std.testing.allocator.alloc(u8, 65536);
        errdefer std.testing.allocator.free(self.bytes);
        @memset(self.bytes, 0);
        self.irq_level = false;
        const memory = GuestMemory.bind(TestRig, self, get);
        self.controller = try Xhci.init(std.testing.allocator, memory, null);
        self.controller.irq = .{ .callback = interrupt, .userdata = self };
        self.put(0x1000, .{ .parameter = 0x1100, .status = 16, .control = 0 });
        self.controller.erstba = 0x1000;
        self.controller.erstsz = 1;
        self.controller.erdp = 0x1100;
    }

    fn deinit(self: *TestRig) void {
        self.controller.deinit();
        std.testing.allocator.free(self.bytes);
    }

    fn get(self: *TestRig, address: u64, size: usize) ?[]u8 {
        if (address > self.bytes.len or size > self.bytes.len - address) return null;
        return self.bytes[@intCast(address)..][0..size];
    }

    fn interrupt(level: bool, context: ?*anyopaque) void {
        const self: *TestRig = @ptrCast(@alignCast(context));
        self.irq_level = level;
    }

    fn put(self: *TestRig, address: usize, trb: Trb) void {
        std.mem.writeInt(u64, self.bytes[address..][0..8], trb.parameter, .little);
        std.mem.writeInt(u32, self.bytes[address + 8 ..][0..4], trb.status, .little);
        std.mem.writeInt(u32, self.bytes[address + 12 ..][0..4], trb.control, .little);
    }
};

test "USB xHCI Event Data counts payload, excluding control Setup and Status" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    const hc = rig.controller;
    hc.slots[1] = .{ .enabled = true, .port = 1, .context = 0x2000 };
    hc.slots[1].endpoints[1] = .{ .state = 1, .dequeue = 0x4000, .pending = true };
    rig.put(0x4000, .{ .parameter = 0x0012000001000680, .status = 8, .control = (2 << 10) | 65 });
    rig.put(0x4010, .{ .parameter = 0x3000, .status = 18, .control = (3 << 10) | 17 });
    rig.put(0x4020, .{ .parameter = 0xface, .status = 0, .control = (7 << 10) | 33 });
    rig.put(0x4030, .{ .parameter = 0, .status = 0, .control = (4 << 10) | 17 });
    rig.put(0x4040, .{ .parameter = 0xbeef, .status = 0, .control = (7 << 10) | 33 });
    try hc.runEndpoint(1, 1);
    const data_event = try Trb.read(hc.memory, 0x1100);
    const status_event = try Trb.read(hc.memory, 0x1110);
    try std.testing.expectEqual(0xface, data_event.parameter);
    try std.testing.expectEqual(18, data_event.status & 0xffffff);
    try std.testing.expectEqual(4, data_event.control & 4);
    try std.testing.expectEqual(0, status_event.status & 0xffffff);
    try std.testing.expectEqualSlices(u8, &.{ 18, 1, 0, 2 }, rig.bytes[0x3000..0x3004]);
}

test "USB xHCI bounds cyclic command rings and rejects unmapped contexts" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    const hc = rig.controller;
    hc.crcr = 0x4001;
    rig.put(0x4000, .{ .parameter = 0x4000, .status = 0, .control = (6 << 10) | 1 });
    try std.testing.expectError(error.InvalidRing, hc.runCommands());
    hc.slots[1].enabled = true;
    var slot: u8 = 1;
    try std.testing.expectEqual(17, try hc.commandTrb(.{
        .parameter = std.math.maxInt(u64),
        .status = 0,
        .control = 11 << 10,
    }, &slot));
}

test "USB xHCI event ring full preserves unconsumed entries and IRQ reset deasserts" {
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    const hc = rig.controller;
    hc.command = 5;
    hc.iman = 2;
    const event_trb: Trb = .{ .parameter = 123, .status = 1 << 24, .control = 33 << 10 };
    for (0..15) |_| try hc.event(event_trb);
    try std.testing.expect(rig.irq_level);
    try std.testing.expectError(error.InvalidRing, hc.event(event_trb));
    try std.testing.expectEqual(123, (try Trb.read(hc.memory, 0x1100)).parameter);
    hc.write32(0x2020, 3);
    try std.testing.expect(!rig.irq_level);
    hc.reset();
    try std.testing.expect(!rig.irq_level);
    try std.testing.expectEqual(0, hc.erstsz);
}
