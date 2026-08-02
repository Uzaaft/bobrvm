//! Virtio Console Device.
//!
//! Implements virtio-console per virtio 1.2 spec section 5.3.
//! Provides serial console I/O between guest and host.
//!
//! Queues:
//!   0: receiveq (host → guest, input to guest)
//!   1: transmitq (guest → host, output from guest)
//!   2: control receiveq (optional, multiport)
//!   3: control transmitq (optional, multiport)

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");

const log = std.log.scoped(.virtio_console);

/// Console feature bits.
pub const Features = struct {
    pub const SIZE: u64 = 1 << 0; // Console size in config
    pub const MULTIPORT: u64 = 1 << 1; // Multiple ports
    pub const EMERG_WRITE: u64 = 1 << 2; // Emergency write
};

/// Console config space.
pub const Config = extern struct {
    cols: u16 = 80,
    rows: u16 = 25,
    max_nr_ports: u32 = 1,
    emerg_wr: u32 = 0,
};

/// Console queue indices.
pub const QueueIdx = enum(u32) {
    receive = 0,
    transmit = 1,
    control_receive = 2,
    control_transmit = 3,
};

/// Multiport control events (virtio 1.2 section 5.3.6.2).
pub const ControlEvent = enum(u16) {
    device_ready = 0,
    device_add = 1,
    device_remove = 2,
    port_ready = 3,
    console_port = 4,
    resize = 5,
    port_open = 6,
    port_name = 7,
    _,
};

/// Control message header (payload follows for e.g. port_name).
pub const ControlMsg = extern struct {
    id: u32,
    event: u16,
    value: u16,
};

/// One queued host→guest control message.
const PendingCtrl = struct {
    msg: ControlMsg,
    payload: [48]u8 = undefined,
    payload_len: u8 = 0,
};

/// A multiport serial port (ports 1..N; port 0 is the console itself).
const Port = struct {
    /// Static name announced via PORT_NAME (e.g. "org.qemu.guest_agent.0");
    /// shows up in the guest at /sys/class/virtio-ports/vportXpY/name.
    name: []const u8,
    /// Guest→host data sink; unset means data is dropped.
    output_callback: ?*const fn ([]const u8, ?*anyopaque) void = null,
    output_userdata: ?*anyopaque = null,
    /// Host→guest bytes awaiting rx buffers. Guarded by the console's
    /// input_mutex (same append-on-host-thread/drain-on-vCPU pattern).
    input_buffer: std.ArrayListUnmanaged(u8) = .empty,
    /// Guest-side open state (PORT_OPEN from the guest).
    guest_open: bool = false,
};

/// Console device.
pub const Console = struct {
    alloc: Allocator,
    transport: mmio.Transport,
    config: Config,

    /// Shadow cursors for the guest-owned receive and transmit queues.
    receive_last_avail: u16,
    transmit_last_avail: u16,

    /// Output buffer (guest → host).
    output_buffer: std.ArrayListUnmanaged(u8),

    /// Input buffer (host → guest). Guarded by input_mutex: the host
    /// input thread appends, the vCPU thread drains.
    input_buffer: std.ArrayListUnmanaged(u8),
    input_mutex: std.Io.Mutex,

    /// Callback for output data.
    output_callback: ?*const fn (data: []const u8, userdata: ?*anyopaque) void,
    output_userdata: ?*anyopaque,

    /// Guest memory accessor.
    guest_memory: ?*const fn (addr: u64, len: usize) ?[]u8,

    /// Multiport: named ports 1..N (empty = plain single-port console).
    ports: []Port,
    /// Host→guest control messages awaiting control-rx buffers.
    ctrl_pending: std.ArrayListUnmanaged(PendingCtrl) = .empty,
    /// last_avail cursors for the multiport queues (control + per-port),
    /// indexed by queue index. Port 0 uses the dedicated cursors above.
    mp_last_avail: [mmio.Transport.MAX_QUEUES]u16 = @splat(0),

    pub const Error = Allocator.Error;
    pub const QUEUE_SIZE: u16 = 128;
    pub const INPUT_BUFFER_MAX: usize = 64 * 1024;

    const AllocationLayout = struct {
        ports_offset: usize,
        queues_offset: usize,
        queue_count: usize,
        size: usize,
    };

    fn allocationLayout(port_count: usize) AllocationLayout {
        assert(port_count <= (mmio.Transport.MAX_QUEUES - 4) / 2);
        assert(@alignOf(Console) >= @max(@alignOf(Port), @alignOf(mmio.QueueConfig)));

        const ports_offset = std.mem.alignForward(
            usize,
            @sizeOf(Console),
            @alignOf(Port),
        );
        const ports_end = ports_offset + @sizeOf(Port) * port_count;
        const queues_offset = std.mem.alignForward(usize, ports_end, @alignOf(mmio.QueueConfig));
        const queue_count = if (port_count > 0) 4 + 2 * port_count else 2;
        return .{
            .ports_offset = ports_offset,
            .queues_offset = queues_offset,
            .queue_count = queue_count,
            .size = queues_offset + @sizeOf(mmio.QueueConfig) * queue_count,
        };
    }

    /// Queue indices for multiport port p (p >= 1).
    fn portRxQueue(port: u32) u32 {
        return 2 * (port + 1);
    }
    fn portTxQueue(port: u32) u32 {
        return 2 * (port + 1) + 1;
    }

    /// `port_names`: names for extra ports 1..N (port 0 stays the hvc0
    /// console). Empty keeps the device in plain single-port mode with
    /// the exact pre-multiport behavior.
    pub fn init(alloc: Allocator, port_names: []const []const u8) Error!*Console {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        var features = Features.SIZE | Features.EMERG_WRITE | virtio_version_1;
        const multiport = port_names.len > 0;
        if (multiport) features |= Features.MULTIPORT;
        const layout = allocationLayout(port_names.len);

        const allocation = try alloc.alignedAlloc(
            u8,
            .of(Console),
            layout.size,
        );
        errdefer alloc.free(allocation);

        const console: *Console = @ptrCast(allocation.ptr);
        const ports_ptr: [*]Port = @ptrCast(@alignCast(allocation.ptr + layout.ports_offset));
        const ports = ports_ptr[0..port_names.len];
        const queues_ptr: [*]mmio.QueueConfig = @ptrCast(@alignCast(
            allocation.ptr + layout.queues_offset,
        ));
        const queues = queues_ptr[0..layout.queue_count];
        console.* = .{
            .alloc = alloc,
            .transport = undefined,
            .config = .{ .max_nr_ports = @intCast(1 + port_names.len) },
            .receive_last_avail = 0,
            .transmit_last_avail = 0,
            .output_buffer = .empty,
            .input_buffer = .empty,
            .input_mutex = .init,
            .output_callback = null,
            .output_userdata = null,
            .guest_memory = null,
            .ports = ports,
        };
        for (console.ports, port_names) |*port, name| {
            port.* = .{ .name = name };
        }

        // Set up notification callback
        console.transport.initEmbedded(3, features, queues);
        console.transport.setNotifyCallback(handleNotify, console);

        // Post-condition
        assert(console.transport.device_id == 3); // console device ID

        return console;
    }

    pub fn deinit(self: *Console) void {
        for (self.ports) |*port| port.input_buffer.deinit(self.alloc);
        self.ctrl_pending.deinit(self.alloc);
        self.output_buffer.deinit(self.alloc);
        self.input_buffer.deinit(self.alloc);

        const alloc = self.alloc;
        const allocation_len = allocationLayout(self.ports.len).size;
        const allocation_ptr: [*]align(@alignOf(Console)) u8 = @ptrCast(self);
        alloc.free(allocation_ptr[0..allocation_len]);
    }

    /// Attach a guest→host data sink for multiport port `id` (1-based).
    pub fn setPortOutput(
        self: *Console,
        id: u32,
        callback: *const fn ([]const u8, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        assert(id >= 1 and id <= self.ports.len);
        self.ports[id - 1].output_callback = callback;
        self.ports[id - 1].output_userdata = userdata;
    }

    /// Queue host→guest data for multiport port `id` (1-based). Same
    /// threading contract as queueInput.
    pub fn queuePortInput(self: *Console, id: u32, data: []const u8) Error!void {
        assert(id >= 1 and id <= self.ports.len);
        self.input_mutex.lockUncancelable(global.io());
        defer self.input_mutex.unlock(global.io());
        const port = &self.ports[id - 1];
        if (port.input_buffer.items.len + data.len > INPUT_BUFFER_MAX) return;
        try port.input_buffer.appendSlice(self.alloc, data);
    }

    /// Whether the guest has opened multiport port `id` (1-based).
    pub fn portGuestOpen(self: *Console, id: u32) bool {
        assert(id >= 1 and id <= self.ports.len);
        return self.ports[id - 1].guest_open;
    }

    /// Set output callback (called when guest writes to console).
    pub fn setOutputCallback(
        self: *Console,
        callback: *const fn ([]const u8, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.output_callback = callback;
        self.output_userdata = userdata;
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(
        self: *Console,
        accessor: *const fn (u64, usize) ?[]u8,
    ) void {
        self.guest_memory = accessor;
    }

    /// Queue input data to send to guest. Called from the host input
    /// thread; delivery happens on the vCPU thread via pollReceive.
    pub fn queueInput(self: *Console, data: []const u8) Error!void {
        self.input_mutex.lockUncancelable(global.io());
        defer self.input_mutex.unlock(global.io());
        // Bound the buffer so a wedged guest can't grow it forever.
        if (self.input_buffer.items.len + data.len > INPUT_BUFFER_MAX) return;
        try self.input_buffer.appendSlice(self.alloc, data);
    }

    /// Handle MMIO read.
    pub fn read(self: *Console, offset: u12) u32 {
        // Config space starts at 0x100
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    /// Handle MMIO write.
    pub fn write(self: *Console, offset: u12, value: u32) void {
        // Config space starts at 0x100
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            self.writeConfig(offset - @intFromEnum(mmio.Reg.config), value);
            return;
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Console, offset: u12) u32 {
        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        return 0;
    }

    fn writeConfig(self: *Console, offset: u12, value: u32) void {
        // Emergency write (single character output)
        if (offset == @offsetOf(Config, "emerg_wr")) {
            const char: u8 = @truncate(value);
            if (self.output_callback) |cb| {
                cb(&[_]u8{char}, self.output_userdata);
            }
        }
    }

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Console = @ptrCast(@alignCast(userdata));
        switch (queue_idx) {
            0 => {
                self.processReceiveQueue();
                // Also check TX queue on any notification (some drivers don't notify TX)
                self.processTransmitQueue();
            },
            1 => self.processTransmitQueue(),
            2 => self.processControlRx(),
            3 => {
                self.processControlTx();
                // The guest may have posted control-rx buffers before the
                // handshake message; flush anything we just queued.
                self.processControlRx();
            },
            else => {
                const port_base = 4;
                if (queue_idx < port_base) return;
                const p: u32 = (queue_idx - port_base) / 2 + 1;
                if (p > self.ports.len) return;
                if ((queue_idx - port_base) % 2 == 0) {
                    self.processPortRx(p);
                } else {
                    self.processPortTx(p);
                }
            },
        }
    }

    /// Queue a host→guest control message (delivered via control-rx).
    fn queueCtrl(self: *Console, id: u32, event: ControlEvent, value: u16, payload: []const u8) void {
        var pending = PendingCtrl{
            .msg = .{ .id = id, .event = @intFromEnum(event), .value = value },
        };
        const n = @min(payload.len, pending.payload.len);
        @memcpy(pending.payload[0..n], payload[0..n]);
        pending.payload_len = @intCast(n);
        self.ctrl_pending.append(self.alloc, pending) catch {};
    }

    /// Guest→host control messages (queue 3): the multiport handshake.
    fn processControlTx(self: *Console) void {
        const qidx = @intFromEnum(QueueIdx.control_transmit);
        const qc = self.transport.queues[qidx];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;
        while (self.mp_last_avail[qidx] != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.mp_last_avail[qidx], get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);
            if (chain.request(get_mem)) |req| {
                if (req.len >= @sizeOf(ControlMsg)) {
                    const msg = std.mem.bytesToValue(ControlMsg, req[0..@sizeOf(ControlMsg)]);
                    self.handleControlMsg(msg);
                }
            }
            ring.pushUsed(qc, head, 0, get_mem);
            self.mp_last_avail[qidx] +%= 1;
        }
        if (processed > 0) self.transport.signalUsedBuffer();
    }

    fn handleControlMsg(self: *Console, msg: ControlMsg) void {
        switch (@as(ControlEvent, @enumFromInt(msg.event))) {
            .device_ready => {
                if (msg.value != 1) return;
                // Announce every port (0 = the console, 1..N = named).
                var p: u32 = 0;
                while (p <= self.ports.len) : (p += 1) {
                    self.queueCtrl(p, .device_add, 0, &.{});
                }
            },
            .port_ready => {
                if (msg.value != 1) return;
                if (msg.id == 0) {
                    // Port 0 is the console (hvc0).
                    self.queueCtrl(0, .console_port, 1, &.{});
                    self.queueCtrl(0, .port_open, 1, &.{});
                } else if (msg.id <= self.ports.len) {
                    const port = &self.ports[msg.id - 1];
                    self.queueCtrl(msg.id, .port_name, 1, port.name);
                    // Host side is considered always-open: guest agents may
                    // write immediately; data is dropped until a host
                    // handler attaches via setPortOutput.
                    self.queueCtrl(msg.id, .port_open, 1, &.{});
                }
            },
            .port_open => {
                if (msg.id >= 1 and msg.id <= self.ports.len) {
                    self.ports[msg.id - 1].guest_open = msg.value == 1;
                }
            },
            else => {},
        }
    }

    /// Host→guest control messages (queue 2): one message per buffer.
    fn processControlRx(self: *Console) void {
        const qidx = @intFromEnum(QueueIdx.control_receive);
        const qc = self.transport.queues[qidx];
        if (!qc.ready or qc.num == 0) return;
        if (self.ctrl_pending.items.len == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var sent: usize = 0;
        while (self.mp_last_avail[qidx] != avail_idx and sent < self.ctrl_pending.items.len) {
            const head = ring.availEntry(qc, self.mp_last_avail[qidx], get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);
            const resp = chain.response(get_mem) orelse {
                ring.pushUsed(qc, head, 0, get_mem);
                self.mp_last_avail[qidx] +%= 1;
                continue;
            };
            const pending = self.ctrl_pending.items[sent];
            const total = @sizeOf(ControlMsg) + @as(usize, pending.payload_len);
            if (resp.len < total) break;
            @memcpy(resp[0..@sizeOf(ControlMsg)], std.mem.asBytes(&pending.msg));
            @memcpy(resp[@sizeOf(ControlMsg)..][0..pending.payload_len], pending.payload[0..pending.payload_len]);
            ring.pushUsed(qc, head, @intCast(total), get_mem);
            self.mp_last_avail[qidx] +%= 1;
            sent += 1;
        }
        if (sent > 0) {
            self.ctrl_pending.replaceRangeAssumeCapacity(0, sent, &.{});
            self.transport.signalUsedBuffer();
        }
    }

    /// Guest→host data on multiport port p (1-based).
    fn processPortTx(self: *Console, p: u32) void {
        const qidx = portTxQueue(p);
        if (qidx >= self.transport.queues.len) return;
        const qc = self.transport.queues[qidx];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;
        const port = &self.ports[p - 1];

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;
        while (self.mp_last_avail[qidx] != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.mp_last_avail[qidx], get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);
            for (chain.slice()) |desc| {
                if (desc.isWrite()) continue;
                const data = get_mem(desc.addr, desc.len) orelse continue;
                if (port.output_callback) |cb| cb(data, port.output_userdata);
            }
            ring.pushUsed(qc, head, 0, get_mem);
            self.mp_last_avail[qidx] +%= 1;
        }
        if (processed > 0) self.transport.signalUsedBuffer();
    }

    /// Host→guest data on multiport port p (1-based).
    fn processPortRx(self: *Console, p: u32) void {
        const qidx = portRxQueue(p);
        if (qidx >= self.transport.queues.len) return;
        const qc = self.transport.queues[qidx];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;
        const port = &self.ports[p - 1];
        // Flow control: the guest driver discards rx data on ports it
        // hasn't opened. Hold data in the host buffer until PORT_OPEN so
        // nothing sent early is silently lost.
        if (!port.guest_open) return;

        self.input_mutex.lockUncancelable(global.io());
        defer self.input_mutex.unlock(global.io());
        if (port.input_buffer.items.len == 0) return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var consumed: usize = 0;
        var delivered: u32 = 0;
        while (self.mp_last_avail[qidx] != avail_idx and consumed < port.input_buffer.items.len) {
            const head = ring.availEntry(qc, self.mp_last_avail[qidx], get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);
            var written: u32 = 0;
            for (chain.slice()) |desc| {
                if (!desc.isWrite()) continue;
                const buf = get_mem(desc.addr, desc.len) orelse continue;
                const remaining = port.input_buffer.items[consumed..];
                if (remaining.len == 0) break;
                const n: usize = @min(buf.len, remaining.len);
                @memcpy(buf[0..n], remaining[0..n]);
                consumed += n;
                written += @intCast(n);
            }
            ring.pushUsed(qc, head, written, get_mem);
            self.mp_last_avail[qidx] +%= 1;
            delivered += written;
        }
        if (consumed > 0) port.input_buffer.replaceRangeAssumeCapacity(0, consumed, &.{});
        if (delivered > 0) self.transport.signalUsedBuffer();
    }

    fn processReceiveQueue(self: *Console) void {
        const qc = self.transport.queues[@intFromEnum(QueueIdx.receive)];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        self.input_mutex.lockUncancelable(global.io());
        defer self.input_mutex.unlock(global.io());
        if (self.input_buffer.items.len == 0) return;

        const avail_ring = get_mem(qc.driver_addr, 6) orelse return;
        const avail_idx = std.mem.readInt(u16, avail_ring[2..4], .little);

        var last_avail_idx = self.receive_last_avail;
        var consumed: usize = 0;
        var delivered: u32 = 0;

        while (last_avail_idx != avail_idx and consumed < self.input_buffer.items.len) {
            const ring_idx = last_avail_idx % qc.num;
            const ring_entry = get_mem(qc.driver_addr + 4 + @as(u64, ring_idx) * 2, 2) orelse break;
            const desc_idx = std.mem.readInt(u16, ring_entry[0..2], .little);

            // Fill this (device-writable) descriptor chain with input.
            var written: u32 = 0;
            var idx = desc_idx;
            var iterations: u16 = 0;
            while (iterations < qc.num and consumed < self.input_buffer.items.len) : (iterations += 1) {
                const desc_mem = get_mem(qc.desc_addr + @as(u64, idx) * 16, 16) orelse break;
                const buf_addr = std.mem.readInt(u64, desc_mem[0..8], .little);
                const buf_len = std.mem.readInt(u32, desc_mem[8..12], .little);
                const flags = std.mem.readInt(u16, desc_mem[12..14], .little);
                const next = std.mem.readInt(u16, desc_mem[14..16], .little);

                // Only fill device-writable descriptors (VIRTQ_DESC_F_WRITE).
                if ((flags & 2) != 0) {
                    if (get_mem(buf_addr, buf_len)) |buf| {
                        const remaining = self.input_buffer.items[consumed..];
                        const n: usize = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        consumed += n;
                        written += @intCast(n);
                    }
                }

                if ((flags & 1) == 0) break; // No VIRTQ_DESC_F_NEXT
                idx = next;
            }

            // Report the buffer used, even if written == 0, to keep the
            // ring consistent with the driver's expectations.
            const used_ring = get_mem(qc.device_addr, 6) orelse break;
            var used_idx = std.mem.readInt(u16, used_ring[2..4], .little);
            const used_ring_idx = used_idx % qc.num;
            const used_entry = get_mem(qc.device_addr + 4 + @as(u64, used_ring_idx) * 8, 8) orelse break;
            std.mem.writeInt(u32, used_entry[0..4], desc_idx, .little);
            std.mem.writeInt(u32, used_entry[4..8], written, .little);
            used_idx +%= 1;
            std.mem.writeInt(u16, @ptrCast(used_ring[2..4]), used_idx, .little);

            delivered += written;
            last_avail_idx +%= 1;
        }

        self.receive_last_avail = last_avail_idx;

        if (consumed > 0) {
            self.input_buffer.replaceRangeAssumeCapacity(0, consumed, &.{});
        }
        if (delivered > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Poll the transmit queues. Can be called from vCPU loop.
    pub fn pollTransmit(self: *Console) void {
        self.processTransmitQueue();
        if (self.ports.len > 0) {
            self.processControlTx();
            for (1..self.ports.len + 1) |p| self.processPortTx(@intCast(p));
        }
    }

    /// Poll the receive queues for pending host input/control messages.
    /// Called from the vCPU loop so all guest-memory access stays on one
    /// thread.
    pub fn pollReceive(self: *Console) void {
        self.processReceiveQueue();
        if (self.ports.len > 0) {
            self.processControlRx();
            for (1..self.ports.len + 1) |p| self.processPortRx(@intCast(p));
        }
    }

    /// Debug: dump queue state for diagnostics.
    pub fn debugState(self: *Console) void {
        const get_mem = self.guest_memory orelse return;
        for ([_]QueueIdx{ .receive, .transmit }) |qi| {
            const qc = self.transport.queues[@intFromEnum(qi)];
            var avail_idx: u16 = 0;
            var used_idx: u16 = 0;
            if (qc.ready) {
                if (get_mem(qc.driver_addr, 6)) |a| avail_idx = std.mem.readInt(u16, a[2..4], .little);
                if (get_mem(qc.device_addr, 6)) |u| used_idx = std.mem.readInt(u16, u[2..4], .little);
            }
            log.debug("q{}: ready={} num={} avail_idx={} used_idx={} last_avail={} desc=0x{x}", .{
                @intFromEnum(qi),                                                           qc.ready,     qc.num, avail_idx, used_idx,
                if (qi == .transmit) self.transmit_last_avail else self.receive_last_avail, qc.desc_addr,
            });
        }
    }

    /// Debug: check if TX queue has pending data.
    pub fn hasPendingTx(self: *Console) bool {
        const qc = self.transport.queues[@intFromEnum(QueueIdx.transmit)];
        if (!qc.ready or qc.num == 0) return false;
        const get_mem = self.guest_memory orelse return false;
        const avail_ring = get_mem(qc.driver_addr, 6) orelse return false;
        const avail_idx = std.mem.readInt(u16, avail_ring[2..4], .little);
        return avail_idx != self.transmit_last_avail;
    }

    fn processTransmitQueue(self: *Console) void {
        // Get queue config from transport
        const qc = self.transport.queues[@intFromEnum(QueueIdx.transmit)];
        if (!qc.ready or qc.num == 0) {
            return;
        }

        const get_mem = self.guest_memory orelse return;

        // Read available ring from guest memory
        const avail_ring = get_mem(qc.driver_addr, 6) orelse {
            log.warn("TX: can't read avail ring at 0x{x}", .{qc.driver_addr});
            return;
        };
        const avail_idx = std.mem.readInt(u16, avail_ring[2..4], .little);

        // Process all available descriptors
        var last_avail_idx = self.transmit_last_avail;
        var processed: u32 = 0;
        while (last_avail_idx != avail_idx) : (processed += 1) {
            const ring_idx = last_avail_idx % qc.num;
            const ring_entry = get_mem(qc.driver_addr + 4 + @as(u64, ring_idx) * 2, 2) orelse break;
            const desc_idx = std.mem.readInt(u16, ring_entry[0..2], .little);

            // Process this descriptor chain
            const total_len = self.processDescriptorChainGuest(qc, desc_idx, get_mem);

            // Add to used ring
            const used_ring = get_mem(qc.device_addr, 6) orelse break;
            var used_idx = std.mem.readInt(u16, used_ring[2..4], .little);
            const used_ring_idx = used_idx % qc.num;
            const used_entry = get_mem(qc.device_addr + 4 + @as(u64, used_ring_idx) * 8, 8) orelse break;
            std.mem.writeInt(u32, used_entry[0..4], desc_idx, .little);
            std.mem.writeInt(u32, used_entry[4..8], total_len, .little);
            used_idx +%= 1;
            std.mem.writeInt(u16, @ptrCast(used_ring[2..4]), used_idx, .little);

            last_avail_idx +%= 1;
        }

        self.transmit_last_avail = last_avail_idx;
        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    fn processDescriptorChainGuest(
        self: *Console,
        qc: mmio.QueueConfig,
        head: u16,
        get_mem: *const fn (addr: u64, len: usize) ?[]u8,
    ) u32 {
        var idx = head;
        var total_len: u32 = 0;
        var iterations: u16 = 0;

        // Walk the descriptor chain
        while (iterations < qc.num) : (iterations += 1) {
            // Read descriptor from guest memory (16 bytes each)
            const desc_mem = get_mem(qc.desc_addr + @as(u64, idx) * 16, 16) orelse break;
            const buf_addr = std.mem.readInt(u64, desc_mem[0..8], .little);
            const buf_len = std.mem.readInt(u32, desc_mem[8..12], .little);
            const flags = std.mem.readInt(u16, desc_mem[12..14], .little);
            const next = std.mem.readInt(u16, desc_mem[14..16], .little);

            // Read data buffer from guest memory
            if (get_mem(buf_addr, buf_len)) |data| {
                if (self.output_callback) |cb| {
                    cb(data, self.output_userdata);
                }
                total_len += buf_len;
            }

            // Check for next descriptor (NEXT flag is bit 0)
            if ((flags & 1) == 0) break;
            idx = next;
        }

        return total_len;
    }

    /// Get MMIO base address requirement.
    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

/// Device ID for console.
const DeviceId = enum(u32) {
    console = 3,
};

// Ensure mmio module has the DeviceId
const mmioDeviceId = struct {
    pub const console: u32 = 3;
};

// =============================================================================
// Tests
// =============================================================================

test "Console init" {
    const console = try Console.init(std.testing.allocator, &.{});
    defer console.deinit();

    // Check magic value
    const magic = console.read(@intFromEnum(mmio.Reg.magic));
    try std.testing.expectEqual(mmio.MAGIC, magic);

    // Check device ID
    const device_id = console.read(@intFromEnum(mmio.Reg.device_id));
    try std.testing.expectEqual(@as(u32, 3), device_id);

    // No ports: plain 2-queue console without MULTIPORT.
    try std.testing.expectEqual(@as(usize, 2), console.transport.queues.len);
    try std.testing.expect(console.transport.device_features & Features.MULTIPORT == 0);
}

test "Console config read" {
    const console = try Console.init(std.testing.allocator, &.{});
    defer console.deinit();

    // Read cols (offset 0x100)
    const cols = console.read(@intFromEnum(mmio.Reg.config));
    // cols=80, rows=25 → 0x00190050 in little-endian as u32
    try std.testing.expectEqual(@as(u32, 80 | (25 << 16)), cols);
}

test "Console queue input" {
    const console = try Console.init(std.testing.allocator, &.{});
    defer console.deinit();

    try console.queueInput("Hello, guest!");
    try std.testing.expectEqual(@as(usize, 13), console.input_buffer.items.len);
}

// -----------------------------------------------------------------------------
// Multiport tests: synthetic guest memory + rings
// -----------------------------------------------------------------------------

const TestMem = struct {
    var mem: [64 * 1024]u8 = undefined;
    fn get(addr: u64, len: usize) ?[]u8 {
        if (addr + len > mem.len) return null;
        return mem[@intCast(addr)..][0..len];
    }
};

/// Lay out one queue at `base`: descriptors at +0, avail at +0x400,
/// used at +0x800.
fn setupTestQueue(console: *Console, qidx: u32, base: u64) void {
    console.transport.queues[qidx] = .{
        .num = 8,
        .ready = true,
        .desc_addr = base,
        .driver_addr = base + 0x400,
        .device_addr = base + 0x800,
    };
}

fn writeTestDesc(base: u64, idx: u16, addr: u64, len: u32, flags: u16) void {
    const d = TestMem.get(base + @as(u64, idx) * 16, 16).?;
    std.mem.writeInt(u64, d[0..8], addr, .little);
    std.mem.writeInt(u32, d[8..12], len, .little);
    std.mem.writeInt(u16, d[12..14], flags, .little);
    std.mem.writeInt(u16, d[14..16], 0, .little);
}

fn pushTestAvail(base: u64, desc_idx: u16) void {
    const avail = TestMem.get(base + 0x400, 64).?;
    const idx = std.mem.readInt(u16, avail[2..4], .little);
    std.mem.writeInt(u16, avail[4 + @as(usize, idx % 8) * 2 ..][0..2], desc_idx, .little);
    std.mem.writeInt(u16, avail[2..4], idx +% 1, .little);
}

fn testUsedIdx(base: u64) u16 {
    const used = TestMem.get(base + 0x800, 6).?;
    return std.mem.readInt(u16, used[2..4], .little);
}

var test_port_out: std.ArrayListUnmanaged(u8) = .empty;
fn testPortSink(data: []const u8, _: ?*anyopaque) void {
    test_port_out.appendSlice(std.testing.allocator, data) catch {};
}

test "Console multiport: handshake announces and names ports" {
    const console = try Console.init(std.testing.allocator, &.{"org.qemu.guest_agent.0"});
    defer console.deinit();
    @memset(&TestMem.mem, 0);
    console.setGuestMemory(TestMem.get);

    // Multiport advertised, 6 queues (rx/tx, ctrl rx/tx, port1 rx/tx).
    try std.testing.expect(console.transport.device_features & Features.MULTIPORT != 0);
    try std.testing.expectEqual(@as(usize, 6), console.transport.queues.len);
    try std.testing.expectEqual(@as(u32, 2), console.config.max_nr_ports);

    const CTRL_RX: u64 = 0x1000;
    const CTRL_TX: u64 = 0x3000;
    setupTestQueue(console, 2, CTRL_RX);
    setupTestQueue(console, 3, CTRL_TX);

    // Guest posts 8 writable 64-byte control-rx buffers at 0x8000.
    for (0..8) |i| {
        writeTestDesc(CTRL_RX, @intCast(i), 0x8000 + @as(u64, i) * 64, 64, ring.Desc.F_WRITE);
        pushTestAvail(CTRL_RX, @intCast(i));
    }

    // Guest sends DEVICE_READY(value=1) on control-tx.
    const ready = ControlMsg{ .id = 0, .event = @intFromEnum(ControlEvent.device_ready), .value = 1 };
    @memcpy(TestMem.get(0x7000, 8).?, std.mem.asBytes(&ready));
    writeTestDesc(CTRL_TX, 0, 0x7000, 8, 0);
    pushTestAvail(CTRL_TX, 0);
    console.pollTransmit();
    console.pollReceive();

    // DEVICE_ADD for ports 0 and 1 must have landed in control-rx.
    try std.testing.expectEqual(@as(u16, 2), testUsedIdx(CTRL_RX));
    const add0 = std.mem.bytesToValue(ControlMsg, TestMem.get(0x8000, 8).?[0..8]);
    const add1 = std.mem.bytesToValue(ControlMsg, TestMem.get(0x8040, 8).?[0..8]);
    try std.testing.expectEqual(@intFromEnum(ControlEvent.device_add), add0.event);
    try std.testing.expectEqual(@as(u32, 0), add0.id);
    try std.testing.expectEqual(@as(u32, 1), add1.id);

    // Guest reports PORT_READY for port 1: expect PORT_NAME (with the
    // name as payload) then PORT_OPEN.
    const port_ready = ControlMsg{ .id = 1, .event = @intFromEnum(ControlEvent.port_ready), .value = 1 };
    @memcpy(TestMem.get(0x7100, 8).?, std.mem.asBytes(&port_ready));
    writeTestDesc(CTRL_TX, 1, 0x7100, 8, 0);
    pushTestAvail(CTRL_TX, 1);
    console.pollTransmit();
    console.pollReceive();

    try std.testing.expectEqual(@as(u16, 4), testUsedIdx(CTRL_RX));
    const name_msg = std.mem.bytesToValue(ControlMsg, TestMem.get(0x8080, 8).?[0..8]);
    try std.testing.expectEqual(@intFromEnum(ControlEvent.port_name), name_msg.event);
    const name = TestMem.get(0x8080 + 8, 22).?;
    try std.testing.expectEqualStrings("org.qemu.guest_agent.0", name);
    const open_msg = std.mem.bytesToValue(ControlMsg, TestMem.get(0x80C0, 8).?[0..8]);
    try std.testing.expectEqual(@intFromEnum(ControlEvent.port_open), open_msg.event);
    try std.testing.expectEqual(@as(u16, 1), open_msg.value);

    // Guest opens the port; both data directions flow.
    const opened = ControlMsg{ .id = 1, .event = @intFromEnum(ControlEvent.port_open), .value = 1 };
    @memcpy(TestMem.get(0x7200, 8).?, std.mem.asBytes(&opened));
    writeTestDesc(CTRL_TX, 2, 0x7200, 8, 0);
    pushTestAvail(CTRL_TX, 2);
    console.pollTransmit();
    try std.testing.expect(console.portGuestOpen(1));

    // Host→guest: queuePortInput lands in the port-1 rx queue (idx 4).
    const P1_RX: u64 = 0x9000;
    setupTestQueue(console, 4, P1_RX);
    writeTestDesc(P1_RX, 0, 0xA000, 64, ring.Desc.F_WRITE);
    pushTestAvail(P1_RX, 0);
    try console.queuePortInput(1, "ping");
    console.pollReceive();
    try std.testing.expectEqualStrings("ping", TestMem.get(0xA000, 4).?);

    // Guest→host: port-1 tx (idx 5) reaches the port sink.
    defer test_port_out.deinit(std.testing.allocator);
    console.setPortOutput(1, testPortSink, null);
    const P1_TX: u64 = 0xB000;
    setupTestQueue(console, 5, P1_TX);
    @memcpy(TestMem.get(0xC000, 4).?, "pong");
    writeTestDesc(P1_TX, 0, 0xC000, 4, 0);
    pushTestAvail(P1_TX, 0);
    console.pollTransmit();
    try std.testing.expectEqualStrings("pong", test_port_out.items);
}
