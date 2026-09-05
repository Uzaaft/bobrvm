//! Metal render loop and its main-thread mailbox.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const metal = @import("../gpu/metal.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.renderer);

/// Power of two so wrapping compiles to a mask.
const MAILBOX_CAPACITY = 64;
/// Render work is iterative and keeps its large state in RenderThread.
const stack_size_bytes: usize = 1024 * 1024;

pub const Message = union(enum) {
    resize: Size,
    shutdown: void,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

/// A guest framebuffer view (BGRA, 4 bytes per pixel).
pub const Scanout = struct {
    data: []const u8,
    /// Visible (scanned-out) dimensions — the scanout rect.
    width: u32,
    height: u32,
    /// Origin of the visible rect within the resource, whose rows are
    /// full_width*4 bytes (fbdev re-modeset scans a sub-rect of its fb).
    src_x: u32 = 0,
    src_y: u32 = 0,
    /// Full resource dimensions; 0 = same as width/height.
    full_width: u32 = 0,
    full_height: u32 = 0,
    /// Content generation; unchanged since last present means skip.
    generation: u64 = 0,
    /// IOSurfaceRef backing `data` for the zero-copy present path, if any.
    surface: ?*anyopaque = null,
    cursor: ?Cursor = null,
};

/// Hardware cursor sprite (BGRA), positioned via the virtio-gpu cursor queue.
pub const Cursor = struct {
    data: []const u8,
    width: u32,
    height: u32,
    hot_x: u32,
    hot_y: u32,
    x: i32,
    y: i32,
    generation: u64 = 0,
};

/// Mutex-protected SPSC circular buffer between the main and render threads.
pub const Mailbox = struct {
    data: [MAILBOX_CAPACITY]Message = undefined,
    write: u32 = 0,
    read: u32 = 0,
    len: u32 = 0,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    pub fn init() Mailbox {
        return .{};
    }

    /// Push a message to the mailbox.
    /// Blocks if mailbox is full (backpressure).
    pub fn push(self: *Mailbox, msg: Message) void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.len >= MAILBOX_CAPACITY) {
            self.cond.waitUncancelable(io, &self.mutex);
        }

        self.data[self.write % MAILBOX_CAPACITY] = msg;
        self.write +%= 1;
        self.len += 1;
    }

    /// Pop a message from the mailbox.
    /// Returns null if empty.
    pub fn pop(self: *Mailbox) ?Message {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len == 0) {
            return null;
        }

        const msg = self.data[self.read % MAILBOX_CAPACITY];
        self.read +%= 1;
        self.len -= 1;

        self.cond.signal(io);
        return msg;
    }
};

/// Wakeup mechanism for renderer thread.
/// Uses futex on Linux, Mach semaphore on macOS.
pub const Wakeup = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const IDLE: u32 = 0;
    const NOTIFIED: u32 = 1;
    const WAITING: u32 = 2;

    /// Notify the waiting thread.
    pub fn notify(self: *Wakeup) void {
        const prev = self.state.swap(NOTIFIED, .release);
        if (prev == WAITING) {
            global.io().futexWake(u32, &self.state.raw, 1);
        }
    }

    /// Wait for notification.
    pub fn wait(self: *Wakeup) void {
        var s = self.state.load(.acquire);
        while (true) {
            if (s == NOTIFIED) {
                if (self.state.cmpxchgWeak(NOTIFIED, IDLE, .acquire, .acquire)) |v| {
                    s = v;
                    continue;
                }
                return;
            }

            if (self.state.cmpxchgWeak(s, WAITING, .acquire, .acquire)) |v| {
                s = v;
                continue;
            }

            global.io().futexWaitUncancelable(u32, &self.state.raw, WAITING);
            s = self.state.load(.acquire);
        }
    }
};

/// Renderer thread state.
pub const RenderThread = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Communication
    mailbox: Mailbox = Mailbox.init(),
    wakeup: Wakeup = .{},

    // Metal frame renderer
    frame_renderer: metal.FrameRenderer,

    // Surface state
    size: Size = .{ .width = 0, .height = 0 },

    frame_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    clear_presented: bool = false,

    // maxInt guarantees the first frame draws.
    last_generation: u64 = std.math.maxInt(u64),
    last_cursor_generation: u64 = std.math.maxInt(u64),

    // Scanout source (guest framebuffer). lock returns a view valid
    // until unlock is called; null when no scanout exists yet.
    scanout_lock: ?*const fn (?*anyopaque) ?Scanout = null,
    scanout_unlock: ?*const fn (?*anyopaque) void = null,
    scanout_userdata: ?*anyopaque = null,

    pub fn init(
        mtl_device: *anyopaque,
        mtl_layer: *anyopaque,
        mtl_queue: *anyopaque,
    ) RenderThread {
        return .{
            .frame_renderer = metal.FrameRenderer.init(mtl_device, mtl_layer, mtl_queue),
        };
    }

    /// Set the guest scanout source. Must be set before start().
    pub fn setScanoutSource(
        self: *RenderThread,
        lock_fn: *const fn (?*anyopaque) ?Scanout,
        unlock_fn: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.scanout_lock = lock_fn;
        self.scanout_unlock = unlock_fn;
        self.scanout_userdata = userdata;
    }

    pub fn deinit(self: *RenderThread) void {
        self.stop();
    }

    pub fn resize(self: *RenderThread, width: u32, height: u32) void {
        self.send(.{ .resize = .{ .width = width, .height = height } });
    }

    pub fn start(self: *RenderThread) !void {
        assert(!self.running.load(.acquire));

        log.info("starting renderer thread", .{});

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{ .stack_size = stack_size_bytes }, threadMain, .{self});
    }

    pub fn stop(self: *RenderThread) void {
        if (!self.running.load(.acquire)) return;

        log.info("stopping renderer thread", .{});

        self.running.store(false, .release);
        self.mailbox.push(.shutdown);
        self.wakeup.notify();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        log.debug("renderer thread stopped", .{});
    }

    pub fn send(self: *RenderThread, msg: Message) void {
        self.mailbox.push(msg);
        self.wakeup.notify();
    }

    /// Request immediate frame draw (called from CVDisplayLink).
    pub fn requestFrame(self: *RenderThread) void {
        self.frame_requested.store(true, .release);
        self.wakeup.notify();
    }

    fn threadMain(self: *RenderThread) void {
        log.debug("renderer thread started", .{});

        self.runLoop();

        log.debug("renderer thread exiting", .{});
    }

    fn runLoop(self: *RenderThread) void {
        while (self.running.load(.acquire)) {
            // CVDisplayLink requests frames only when the guest presentation
            // generation changes; mailbox producers wake us for state changes.
            self.wakeup.wait();

            self.drainMailbox();
            if (!self.running.load(.acquire)) return;

            if (self.frame_requested.swap(false, .acquire)) {
                self.drawFrame();
            }
        }
    }

    fn drainMailbox(self: *RenderThread) void {
        while (self.mailbox.pop()) |msg| {
            switch (msg) {
                .resize => |size| {
                    self.size = size;
                    self.clear_presented = false;
                    self.frame_requested.store(true, .release);
                },
                .shutdown => {
                    self.running.store(false, .release);
                    return;
                },
            }
        }
    }

    fn drawFrame(self: *RenderThread) void {
        if (self.size.width == 0 or self.size.height == 0) return;

        if (self.scanout_lock) |lock_fn| {
            if (lock_fn(self.scanout_userdata)) |scan| {
                const cursor_gen = if (scan.cursor) |c| c.generation else 0;
                // Cursor movement must redraw even when the framebuffer is unchanged.
                if (scan.generation == self.last_generation and cursor_gen == self.last_cursor_generation) {
                    if (self.scanout_unlock) |unlock_fn| unlock_fn(self.scanout_userdata);
                    return;
                }
                const cursor_info: ?metal.CursorInfo = if (scan.cursor) |c| .{
                    .data = c.data,
                    .width = c.width,
                    .height = c.height,
                    .hot_x = c.hot_x,
                    .hot_y = c.hot_y,
                    .x = c.x,
                    .y = c.y,
                    .generation = c.generation,
                } else null;
                const ok = self.frame_renderer.renderFramebuffer(
                    scan.data,
                    scan.width,
                    scan.height,
                    .{
                        .x = scan.src_x,
                        .y = scan.src_y,
                        .full_width = if (scan.full_width != 0) scan.full_width else scan.width,
                        .full_height = if (scan.full_height != 0) scan.full_height else scan.height,
                    },
                    scan.surface,
                    cursor_info,
                );
                if (self.scanout_unlock) |unlock_fn| unlock_fn(self.scanout_userdata);
                if (ok) {
                    self.clear_presented = false;
                    self.last_generation = scan.generation;
                    self.last_cursor_generation = cursor_gen;
                }
                return;
            }
        }

        // Present a background once while the guest has no scanout.
        if (self.clear_presented) return;
        const success = self.frame_renderer.renderFrame(.{
            .red = 0.0,
            .green = 0.0,
            .blue = 0.1,
            .alpha = 1.0,
        });
        if (success) {
            self.clear_presented = true;
        }
    }
};

test "Mailbox push and pop" {
    var mailbox = Mailbox.init();

    mailbox.push(.{ .resize = .{ .width = 800, .height = 600 } });
    mailbox.push(.{ .resize = .{ .width = 1024, .height = 768 } });
    mailbox.push(.shutdown);

    const msg1 = mailbox.pop();
    try std.testing.expect(msg1 != null);
    try std.testing.expectEqual(@as(u32, 800), msg1.?.resize.width);

    const msg2 = mailbox.pop();
    try std.testing.expect(msg2 != null);
    try std.testing.expectEqual(@as(u32, 1024), msg2.?.resize.width);

    const msg3 = mailbox.pop();
    try std.testing.expect(msg3 != null);
    try std.testing.expect(msg3.? == .shutdown);

    const msg4 = mailbox.pop();
    try std.testing.expect(msg4 == null);
}

test "Mailbox preserves order across backpressure and ring wraparound" {
    const message_count = MAILBOX_CAPACITY * 4;
    const Producer = struct {
        fn run(mailbox: *Mailbox) void {
            for (0..message_count) |i| {
                mailbox.push(.{ .resize = .{ .width = @intCast(i), .height = 1 } });
            }
        }
    };

    var mailbox = Mailbox.init();
    // Start full so the producer must wait for the consumer to release space.
    for (0..MAILBOX_CAPACITY) |_| mailbox.push(.shutdown);
    const producer = try std.Thread.spawn(.{}, Producer.run, .{&mailbox});
    defer producer.join();

    for (0..MAILBOX_CAPACITY + message_count) |i| {
        const message = while (true) {
            if (mailbox.pop()) |message| break message;
            std.atomic.spinLoopHint();
        };
        if (i < MAILBOX_CAPACITY) {
            try std.testing.expect(message == .shutdown);
        } else {
            try std.testing.expectEqual(@as(u32, @intCast(i - MAILBOX_CAPACITY)), message.resize.width);
        }
    }
    try std.testing.expect(mailbox.pop() == null);
}

test "Wakeup notify and wait" {
    var wakeup = Wakeup{};

    wakeup.notify();
    wakeup.wait();
}

test "RenderThread init" {
    var dummy: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);

    var rt = RenderThread.init(ptr, ptr, ptr);

    try std.testing.expect(!rt.running.load(.acquire));
}

test "RenderThread state messages request a frame" {
    var dummy: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);
    var rt = RenderThread.init(ptr, ptr, ptr);

    rt.mailbox.push(.{ .resize = .{ .width = 800, .height = 600 } });
    rt.drainMailbox();

    try std.testing.expectEqual(Size{ .width = 800, .height = 600 }, rt.size);
    try std.testing.expect(rt.frame_requested.load(.acquire));
}
