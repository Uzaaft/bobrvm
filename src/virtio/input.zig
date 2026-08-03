//! Virtio Input Device.
//!
//! Implements virtio-input per virtio 1.2 spec section 5.8.
//! Provides keyboard and mouse input to guest using evdev format.
//!
//! Queues:
//!   0: eventq (host → guest, input events)
//!   1: statusq (guest → host, LED status feedback)
//!
//! Events use Linux evdev format (input_event struct).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");

/// Input device subtype.
pub const Subtype = enum(u8) {
    keyboard = 1,
    mouse = 2,
    tablet = 3,
};

/// Input config select values.
pub const ConfigSelect = enum(u8) {
    unset = 0x00,
    id_name = 0x01,
    id_serial = 0x02,
    id_devids = 0x03,
    prop_bits = 0x10,
    ev_bits = 0x11,
    abs_info = 0x12,
};

/// Evdev event types.
pub const EventType = enum(u16) {
    syn = 0x00,
    key = 0x01,
    rel = 0x02,
    abs = 0x03,
    msc = 0x04,
    led = 0x11,
    rep = 0x14,
    _,
};

/// Evdev relative axis codes.
pub const RelCode = enum(u16) {
    x = 0x00,
    y = 0x01,
    wheel = 0x08,
    hwheel = 0x06,
    _,
};

/// Evdev absolute axis codes.
pub const AbsCode = enum(u16) {
    x = 0x00,
    y = 0x01,
    pressure = 0x18,
    _,
};

/// Evdev key codes (subset).
pub const KeyCode = enum(u16) {
    reserved = 0,
    esc = 1,
    @"1" = 2,
    @"2" = 3,
    @"3" = 4,
    @"4" = 5,
    @"5" = 6,
    @"6" = 7,
    @"7" = 8,
    @"8" = 9,
    @"9" = 10,
    @"0" = 11,
    minus = 12,
    equal = 13,
    backspace = 14,
    tab = 15,
    q = 16,
    w = 17,
    e = 18,
    r = 19,
    t = 20,
    y = 21,
    u = 22,
    i = 23,
    o = 24,
    p = 25,
    leftbrace = 26,
    rightbrace = 27,
    enter = 28,
    leftctrl = 29,
    a = 30,
    s = 31,
    d = 32,
    f = 33,
    g = 34,
    h = 35,
    j = 36,
    k = 37,
    l = 38,
    semicolon = 39,
    apostrophe = 40,
    grave = 41,
    leftshift = 42,
    backslash = 43,
    z = 44,
    x = 45,
    c = 46,
    v = 47,
    b = 48,
    n = 49,
    m = 50,
    comma = 51,
    dot = 52,
    slash = 53,
    rightshift = 54,
    leftalt = 56,
    space = 57,
    capslock = 58,
    f1 = 59,
    f2 = 60,
    f3 = 61,
    f4 = 62,
    f5 = 63,
    f6 = 64,
    f7 = 65,
    f8 = 66,
    f9 = 67,
    f10 = 68,
    f11 = 87,
    f12 = 88,
    rightctrl = 97,
    rightalt = 100,
    home = 102,
    up = 103,
    pageup = 104,
    left = 105,
    right = 106,
    end = 107,
    down = 108,
    pagedown = 109,
    insert = 110,
    delete = 111,
    leftmeta = 125,
    rightmeta = 126,

    // Mouse buttons
    btn_left = 0x110,
    btn_right = 0x111,
    btn_middle = 0x112,
    btn_side = 0x113,
    btn_extra = 0x114,
    _,
};

/// Input event (evdev format, 8 bytes for virtio).
pub const InputEvent = extern struct {
    type: u16,
    code: u16,
    value: i32,
};

/// Device IDs (for config).
pub const DeviceIds = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

/// Absolute axis info.
pub const AbsInfo = extern struct {
    min: i32,
    max: i32,
    fuzz: i32,
    flat: i32,
    res: i32,
};

/// Input config space.
pub const Config = extern struct {
    select: u8 = 0,
    subsel: u8 = 0,
    size: u8 = 0,
    _reserved: [5]u8 = .{0} ** 5,
    data: [128]u8 = .{0} ** 128,
};

/// Input device.
pub const Input = struct {
    alloc: Allocator,
    transport: mmio.Transport,
    transport_queues: [2]mmio.QueueConfig,
    config: Config,
    subtype: Subtype,

    /// Pending events to deliver. Guarded by events_mutex: the host
    /// UI thread appends, the vCPU thread drains via pollEvents.
    pending_events: [PENDING_EVENTS_MAX]InputEvent,
    pending_head: usize,
    pending_count: usize,
    events_mutex: std.Io.Mutex,

    /// Shadow avail-ring cursors.
    event_last_avail: u16,
    status_last_avail: u16,

    /// Device name.
    name: []const u8,

    /// Guest memory accessor.
    guest_memory: ?*const fn (addr: u64, len: usize) ?[]u8,

    /// Interrupt callback.
    interrupt_callback: ?*const fn (userdata: ?*anyopaque) void,
    interrupt_userdata: ?*anyopaque,

    // Tablet absolute position state
    abs_x: i32 = 0,
    abs_y: i32 = 0,
    abs_max_x: i32 = 32767,
    abs_max_y: i32 = 32767,

    pub const Error = Allocator.Error;
    pub const QUEUE_SIZE: u16 = 64;

    pub fn init(alloc: Allocator, subtype: Subtype) Error!*Input {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        const input = try alloc.create(Input);
        errdefer alloc.destroy(input);
        input.* = .{
            .alloc = alloc,
            .transport = undefined,
            .transport_queues = undefined,
            .config = .{},
            .subtype = subtype,
            .pending_events = undefined,
            .pending_head = 0,
            .pending_count = 0,
            .events_mutex = .init,
            .event_last_avail = 0,
            .status_last_avail = 0,
            .name = switch (subtype) {
                .keyboard => "bobrvm-keyboard",
                .mouse => "bobrvm-mouse",
                .tablet => "bobrvm-tablet",
            },
            .guest_memory = null,
            .interrupt_callback = null,
            .interrupt_userdata = null,
        };

        input.transport.initEmbedded(18, virtio_version_1, &input.transport_queues);
        input.transport.setNotifyCallback(handleNotify, input);

        assert(input.transport.device_id == 18);

        return input;
    }

    pub fn deinit(self: *Input) void {
        self.alloc.destroy(self);
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(
        self: *Input,
        accessor: *const fn (u64, usize) ?[]u8,
    ) void {
        self.guest_memory = accessor;
    }

    /// Set interrupt callback.
    pub fn setInterruptCallback(
        self: *Input,
        callback: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.interrupt_callback = callback;
        self.interrupt_userdata = userdata;
    }

    // =========================================================================
    // Event Injection (from Swift/host)
    // =========================================================================

    /// Inject a key event.
    pub fn injectKey(self: *Input, keycode: u16, pressed: bool) !void {
        try self.queueEvent(.{
            .type = @intFromEnum(EventType.key),
            .code = keycode,
            .value = if (pressed) 1 else 0,
        });
        try self.queueSyn();
    }

    /// Inject a relative mouse movement.
    pub fn injectRelative(self: *Input, dx: i32, dy: i32) !void {
        if (dx != 0) {
            try self.queueEvent(.{
                .type = @intFromEnum(EventType.rel),
                .code = @intFromEnum(RelCode.x),
                .value = dx,
            });
        }
        if (dy != 0) {
            try self.queueEvent(.{
                .type = @intFromEnum(EventType.rel),
                .code = @intFromEnum(RelCode.y),
                .value = dy,
            });
        }
        if (dx != 0 or dy != 0) {
            try self.queueSyn();
        }
    }

    /// Inject absolute tablet position.
    pub fn injectAbsolute(self: *Input, x: i32, y: i32) !void {
        if (x != self.abs_x) {
            self.abs_x = x;
            try self.queueEvent(.{
                .type = @intFromEnum(EventType.abs),
                .code = @intFromEnum(AbsCode.x),
                .value = x,
            });
        }
        if (y != self.abs_y) {
            self.abs_y = y;
            try self.queueEvent(.{
                .type = @intFromEnum(EventType.abs),
                .code = @intFromEnum(AbsCode.y),
                .value = y,
            });
        }
        try self.queueSyn();
    }

    /// Inject mouse button event.
    pub fn injectButton(self: *Input, button: u16, pressed: bool) !void {
        try self.queueEvent(.{
            .type = @intFromEnum(EventType.key),
            .code = button,
            .value = if (pressed) 1 else 0,
        });
        try self.queueSyn();
    }

    /// Inject scroll wheel event.
    pub fn injectScroll(self: *Input, dx: i32, dy: i32) !void {
        if (dy != 0) {
            try self.queueEvent(.{
                .type = @intFromEnum(EventType.rel),
                .code = @intFromEnum(RelCode.wheel),
                .value = dy,
            });
        }
        if (dx != 0) {
            try self.queueEvent(.{
                .type = @intFromEnum(EventType.rel),
                .code = @intFromEnum(RelCode.hwheel),
                .value = dx,
            });
        }
        if (dx != 0 or dy != 0) {
            try self.queueSyn();
        }
    }

    pub const PENDING_EVENTS_MAX: usize = 1024;

    fn queueEvent(self: *Input, event: InputEvent) !void {
        self.events_mutex.lockUncancelable(global.io());
        defer self.events_mutex.unlock(global.io());
        // Bound the queue so a wedged guest can't grow it forever.
        if (self.pending_count >= self.pending_events.len) return;
        const tail = (self.pending_head + self.pending_count) % self.pending_events.len;
        self.pending_events[tail] = event;
        self.pending_count += 1;
    }

    fn queueSyn(self: *Input) !void {
        try self.queueEvent(.{
            .type = @intFromEnum(EventType.syn),
            .code = 0,
            .value = 0,
        });
    }

    // =========================================================================
    // MMIO Interface
    // =========================================================================

    pub fn read(self: *Input, offset: u12) u32 {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    pub fn write(self: *Input, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            self.writeConfig(offset - @intFromEnum(mmio.Reg.config), value);
            return;
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Input, offset: u12) u32 {
        // Update config data based on select
        self.updateConfigData();

        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        return 0;
    }

    fn writeConfig(self: *Input, offset: u12, value: u32) void {
        if (offset == 0) {
            self.config.select = @truncate(value);
        } else if (offset == 1) {
            self.config.subsel = @truncate(value);
        }
    }

    fn updateConfigData(self: *Input) void {
        @memset(&self.config.data, 0);

        switch (@as(ConfigSelect, @enumFromInt(self.config.select))) {
            .id_name => {
                const len = @min(self.name.len, self.config.data.len);
                @memcpy(self.config.data[0..len], self.name[0..len]);
                self.config.size = @intCast(len);
            },
            .id_devids => {
                const ids = DeviceIds{
                    .bustype = 0x06, // BUS_VIRTUAL
                    .vendor = 0x1234,
                    .product = @intFromEnum(self.subtype),
                    .version = 1,
                };
                const bytes = std.mem.asBytes(&ids);
                @memcpy(self.config.data[0..bytes.len], bytes);
                self.config.size = @intCast(bytes.len);
            },
            .ev_bits => {
                // Report supported event types
                self.config.size = self.getEvBits();
            },
            .abs_info => {
                if (self.subtype == .tablet) {
                    const info = AbsInfo{
                        .min = 0,
                        .max = self.abs_max_x,
                        .fuzz = 0,
                        .flat = 0,
                        .res = 0,
                    };
                    const bytes = std.mem.asBytes(&info);
                    @memcpy(self.config.data[0..bytes.len], bytes);
                    self.config.size = @intCast(bytes.len);
                }
            },
            else => {
                self.config.size = 0;
            },
        }
    }

    /// Fill config.data with the code bitmap for the queried event type
    /// (select=EV_BITS, subsel=<EV_*>); returns the bitmap size in bytes.
    /// A size of 0 means the event type is unsupported.
    fn getEvBits(self: *Input) u8 {
        const subsel: EventType = @enumFromInt(self.config.subsel);
        switch (self.subtype) {
            .keyboard => switch (subsel) {
                .key => {
                    // Keys 1..127 (standard keyboard range incl. modifiers)
                    var code: u16 = 1;
                    while (code < 128) : (code += 1) {
                        self.config.data[code / 8] |= @as(u8, 1) << @intCast(code % 8);
                    }
                    return 16;
                },
                .rep => return 1, // autorepeat handled by the guest
                else => return 0,
            },
            .mouse => switch (subsel) {
                .key => {
                    // BTN_LEFT (0x110), BTN_RIGHT (0x111), BTN_MIDDLE (0x112)
                    inline for ([_]u16{ 0x110, 0x111, 0x112 }) |code| {
                        self.config.data[code / 8] |= @as(u8, 1) << @intCast(code % 8);
                    }
                    return 0x113 / 8 + 1;
                },
                .rel => {
                    // REL_X, REL_Y, REL_HWHEEL, REL_WHEEL
                    inline for ([_]u16{ 0x00, 0x01, 0x06, 0x08 }) |code| {
                        self.config.data[code / 8] |= @as(u8, 1) << @intCast(code % 8);
                    }
                    return 2;
                },
                else => return 0,
            },
            .tablet => switch (subsel) {
                .key => {
                    inline for ([_]u16{ 0x110, 0x111, 0x112 }) |code| {
                        self.config.data[code / 8] |= @as(u8, 1) << @intCast(code % 8);
                    }
                    return 0x113 / 8 + 1;
                },
                .abs => {
                    // ABS_X, ABS_Y
                    self.config.data[0] = 0x3;
                    return 1;
                },
                .rel => {
                    // REL_HWHEEL, REL_WHEEL
                    inline for ([_]u16{ 0x06, 0x08 }) |code| {
                        self.config.data[code / 8] |= @as(u8, 1) << @intCast(code % 8);
                    }
                    return 2;
                },
                else => return 0,
            },
        }
    }

    // =========================================================================
    // Event Delivery
    // =========================================================================

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Input = @ptrCast(@alignCast(userdata));
        switch (queue_idx) {
            0 => self.deliverEvents(),
            1 => self.processStatusQueue(),
            else => {},
        }
    }

    /// Poll for deliverable events. Called from the vCPU loop so all
    /// guest-memory access stays on one thread.
    pub fn pollEvents(self: *Input) void {
        self.deliverEvents();
        self.processStatusQueue();
    }

    fn deliverEvents(self: *Input) void {
        const qc = self.transport.queues[0];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        self.events_mutex.lockUncancelable(global.io());
        defer self.events_mutex.unlock(global.io());
        if (self.pending_count == 0) return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var last_avail = self.event_last_avail;
        var delivered: usize = 0;

        while (last_avail != avail_idx and delivered < self.pending_count) {
            const head = ring.availEntry(qc, last_avail, get_mem) orelse break;
            const desc = ring.readDesc(qc, head, get_mem) orelse break;
            if (!desc.isWrite() or desc.len < @sizeOf(InputEvent)) {
                // Unusable buffer: consume it with zero length.
                ring.pushUsed(qc, head, 0, get_mem);
                last_avail +%= 1;
                continue;
            }

            const mem = get_mem(desc.addr, @sizeOf(InputEvent)) orelse break;
            const event_index = (self.pending_head + delivered) % self.pending_events.len;
            const event = self.pending_events[event_index];
            @memcpy(mem[0..@sizeOf(InputEvent)], std.mem.asBytes(&event));
            ring.pushUsed(qc, head, @sizeOf(InputEvent), get_mem);

            delivered += 1;
            last_avail +%= 1;
        }

        self.event_last_avail = last_avail;
        if (delivered > 0) {
            self.pending_head = (self.pending_head + delivered) % self.pending_events.len;
            self.pending_count -= delivered;
            if (self.pending_count == 0) self.pending_head = 0;
            self.transport.signalUsedBuffer();
        }
    }

    fn processStatusQueue(self: *Input) void {
        const qc = self.transport.queues[1];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        // LED/status updates: consume and ignore.
        while (self.status_last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.status_last_avail, get_mem) orelse break;
            ring.pushUsed(qc, head, 0, get_mem);
            self.status_last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Input init keyboard" {
    const input = try Input.init(std.testing.allocator, .keyboard);
    defer input.deinit();

    const magic = input.read(@intFromEnum(mmio.Reg.magic));
    try std.testing.expectEqual(mmio.MAGIC, magic);

    const device_id = input.read(@intFromEnum(mmio.Reg.device_id));
    try std.testing.expectEqual(@as(u32, 18), device_id);
}

test "Input init mouse" {
    const input = try Input.init(std.testing.allocator, .mouse);
    defer input.deinit();

    try std.testing.expectEqual(Subtype.mouse, input.subtype);
}

test "Input tablet advertises absolute axes, buttons, and wheels" {
    const input = try Input.init(std.testing.allocator, .tablet);
    defer input.deinit();

    input.config.subsel = @intFromEnum(EventType.abs);
    try std.testing.expectEqual(@as(u8, 1), input.getEvBits());
    try std.testing.expectEqual(@as(u8, 0x03), input.config.data[0]);

    input.config.subsel = @intFromEnum(EventType.key);
    _ = input.getEvBits();
    inline for ([_]u16{ 0x110, 0x111, 0x112 }) |code| {
        try std.testing.expect(input.config.data[code / 8] &
            (@as(u8, 1) << @intCast(code % 8)) != 0);
    }

    input.config.subsel = @intFromEnum(EventType.rel);
    _ = input.getEvBits();
    inline for ([_]u16{ 0x06, 0x08 }) |code| {
        try std.testing.expect(input.config.data[code / 8] &
            (@as(u8, 1) << @intCast(code % 8)) != 0);
    }
}

test "InputEvent size" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(InputEvent));
}

test "Input inject key" {
    const input = try Input.init(std.testing.allocator, .keyboard);
    defer input.deinit();

    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    input.alloc = counted.allocator();
    try input.injectKey(@intFromEnum(KeyCode.a), true);
    input.alloc = std.testing.allocator;

    // Should have key event + syn event
    try std.testing.expectEqual(@as(usize, 0), counted.allocations);
    try std.testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 2), input.pending_count);
}

test "Input inject absolute position without allocation" {
    const input = try Input.init(std.testing.allocator, .tablet);
    defer input.deinit();

    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    input.alloc = counted.allocator();
    try input.injectAbsolute(123, 456);
    input.alloc = std.testing.allocator;

    try std.testing.expectEqual(@as(usize, 0), counted.allocations);
    try std.testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 3), input.pending_count);
    try std.testing.expectEqual(@as(u16, @intFromEnum(EventType.abs)), input.pending_events[0].type);
    try std.testing.expectEqual(@as(u16, @intFromEnum(AbsCode.x)), input.pending_events[0].code);
    try std.testing.expectEqual(@as(i32, 123), input.pending_events[0].value);
    try std.testing.expectEqual(@as(u16, @intFromEnum(AbsCode.y)), input.pending_events[1].code);
    try std.testing.expectEqual(@as(i32, 456), input.pending_events[1].value);
    try std.testing.expectEqual(@as(u16, @intFromEnum(EventType.syn)), input.pending_events[2].type);
}

test "Input pending event ring wraps without allocation" {
    const input = try Input.init(std.testing.allocator, .keyboard);
    defer input.deinit();

    input.pending_head = input.pending_events.len - 1;
    const first = InputEvent{ .type = 1, .code = 30, .value = 1 };
    const second = InputEvent{ .type = 0, .code = 0, .value = 0 };
    try input.queueEvent(first);
    try input.queueEvent(second);

    try std.testing.expectEqual(@as(usize, 2), input.pending_count);
    const last = input.pending_events[input.pending_events.len - 1];
    try std.testing.expectEqual(first.code, last.code);
    try std.testing.expectEqual(second.type, input.pending_events[0].type);
}

test "KeyCode values" {
    try std.testing.expectEqual(@as(u16, 30), @intFromEnum(KeyCode.a));
    try std.testing.expectEqual(@as(u16, 0x110), @intFromEnum(KeyCode.btn_left));
}

var test_guest_mem: [8192]u8 = undefined;

fn testGetMem(addr: u64, len: usize) ?[]u8 {
    if (addr < 0x1000) return null;
    const off = addr - 0x1000;
    if (off + len > test_guest_mem.len) return null;
    return test_guest_mem[off..][0..len];
}

test "Input delivers events into a guest ring" {
    const input = try Input.init(std.testing.allocator, .keyboard);
    defer input.deinit();

    @memset(&test_guest_mem, 0);
    input.setGuestMemory(testGetMem);

    // Layout in fake guest memory (base 0x1000):
    //   desc table @0x1000, avail @0x1400, used @0x1600, buffers @0x1800
    // One writable 8-byte buffer in desc 0, avail_idx = 1.
    std.mem.writeInt(u64, test_guest_mem[0..8], 0x1800, .little); // desc0.addr
    std.mem.writeInt(u32, test_guest_mem[8..12], 8, .little); // desc0.len
    std.mem.writeInt(u16, test_guest_mem[12..14], 2, .little); // desc0.flags = WRITE
    std.mem.writeInt(u16, test_guest_mem[0x402..0x404], 1, .little); // avail.idx = 1
    std.mem.writeInt(u16, test_guest_mem[0x404..0x406], 0, .little); // avail.ring[0] = 0

    // Configure the transport's queue 0 via MMIO like a driver would.
    input.write(@intFromEnum(mmio.Reg.queue_sel), 0);
    input.write(@intFromEnum(mmio.Reg.queue_num), 64);
    input.write(@intFromEnum(mmio.Reg.queue_desc_low), 0x1000);
    input.write(@intFromEnum(mmio.Reg.queue_driver_low), 0x1400);
    input.write(@intFromEnum(mmio.Reg.queue_device_low), 0x1600);
    input.write(@intFromEnum(mmio.Reg.queue_ready), 1);

    try input.injectKey(30, true); // KEY_A press (+ SYN)
    input.pollEvents();

    // used.idx must have advanced and the buffer must hold the event.
    const used_idx = std.mem.readInt(u16, test_guest_mem[0x602..0x604], .little);
    try std.testing.expectEqual(@as(u16, 1), used_idx);
    const ev_type = std.mem.readInt(u16, test_guest_mem[0x800..0x802], .little);
    const ev_code = std.mem.readInt(u16, test_guest_mem[0x802..0x804], .little);
    const ev_value = std.mem.readInt(u32, test_guest_mem[0x804..0x808], .little);
    try std.testing.expectEqual(@as(u16, 1), ev_type); // EV_KEY
    try std.testing.expectEqual(@as(u16, 30), ev_code); // KEY_A
    try std.testing.expectEqual(@as(u32, 1), ev_value); // pressed
}
