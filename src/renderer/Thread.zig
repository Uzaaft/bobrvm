//! Metal render loop and its main-thread mailbox.

const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const metal = @import("../gpu/metal.zig");
const global = @import("../global.zig");
const thread_compat = @import("../compat/thread.zig");

const log = std.log.scoped(.renderer);

/// Power of two so wrapping compiles to a mask.
const MAILBOX_CAPACITY = 64;
/// Render work is iterative and keeps its large state in RenderThread.
const stack_size_bytes: usize = 1024 * 1024;

pub const Message = union(enum) {
    resize: Size,
    content_scale: ContentScale,
    focus: bool,
    visible: bool,
    commands_ready: *CommandBatch,
    draw_now: void,
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

pub const ContentScale = struct {
    x: f64 = 1.0,
    y: f64 = 1.0,
};

/// Pending GPU work. This remains a placeholder until commands reference `gpu.Context` state.
pub const CommandBatch = struct {
    draw_count: u32 = 0,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    framebuffer: u32 = 0,
};

/// Mutex-protected SPSC circular buffer between the main and render threads.
pub const Mailbox = struct {
    const Bounds = std.math.Log2Int(u32);

    data: [MAILBOX_CAPACITY]Message = undefined,
    write: u32 = 0,
    read: u32 = 0,
    len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
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

        while (self.len.load(.acquire) >= MAILBOX_CAPACITY) {
            self.cond.waitUncancelable(io, &self.mutex);
        }

        self.data[self.write % MAILBOX_CAPACITY] = msg;
        self.write +%= 1;
        _ = self.len.fetchAdd(1, .release);

        self.cond.signal(io);
    }

    /// Try to push without blocking.
    /// Returns false if mailbox is full.
    pub fn tryPush(self: *Mailbox, msg: Message) bool {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len.load(.acquire) >= MAILBOX_CAPACITY) {
            return false;
        }

        self.data[self.write % MAILBOX_CAPACITY] = msg;
        self.write +%= 1;
        _ = self.len.fetchAdd(1, .release);

        self.cond.signal(io);
        return true;
    }

    /// Pop a message from the mailbox.
    /// Returns null if empty.
    pub fn pop(self: *Mailbox) ?Message {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len.load(.acquire) == 0) {
            return null;
        }

        const msg = self.data[self.read % MAILBOX_CAPACITY];
        self.read +%= 1;
        _ = self.len.fetchSub(1, .release);

        self.cond.signal(io);
        return msg;
    }

    /// Wait for a message with timeout.
    /// Returns null on timeout.
    pub fn waitPop(self: *Mailbox, timeout_ns: u64) ?Message {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len.load(.acquire) == 0) {
            thread_compat.waitTimeout(&self.cond, io, &self.mutex, .{
                .duration = .{ .raw = .{ .nanoseconds = @intCast(timeout_ns) }, .clock = .awake },
            }) catch {};
            if (self.len.load(.acquire) == 0) {
                return null;
            }
        }

        const msg = self.data[self.read % MAILBOX_CAPACITY];
        self.read +%= 1;
        _ = self.len.fetchSub(1, .release);

        return msg;
    }

    pub fn hasMessages(self: *Mailbox) bool {
        return self.len.load(.acquire) > 0;
    }

    pub fn wakeup(self: *Mailbox) void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cond.signal(io);
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

    /// Wait with timeout (returns true if notified).
    pub fn timedWait(self: *Wakeup, timeout_ns: u64) bool {
        var s = self.state.load(.acquire);
        while (true) {
            if (s == NOTIFIED) {
                if (self.state.cmpxchgWeak(NOTIFIED, IDLE, .acquire, .acquire)) |v| {
                    s = v;
                    continue;
                }
                return true;
            }

            if (self.state.cmpxchgWeak(s, WAITING, .acquire, .acquire)) |v| {
                s = v;
                continue;
            }

            global.io().futexWaitTimeout(u32, &self.state.raw, WAITING, .{
                .duration = .{ .raw = .{ .nanoseconds = @intCast(timeout_ns) }, .clock = .awake },
            }) catch {};
            s = self.state.load(.acquire);
            return s == NOTIFIED;
        }
    }
};

/// Renderer thread state.
pub const RenderThread = struct {
    alloc: Allocator,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Communication
    mailbox: Mailbox = Mailbox.init(),
    wakeup: Wakeup = .{},

    // Metal context (opaque pointers from Swift)
    mtl_device: *anyopaque,
    mtl_layer: *anyopaque,
    mtl_queue: *anyopaque,

    // Metal frame renderer
    frame_renderer: metal.FrameRenderer,

    // Surface state
    size: Size = .{ .width = 0, .height = 0 },
    content_scale: ContentScale = .{},
    focused: bool = false,
    visible: bool = true,

    // Pending commands
    pending_batch: ?*CommandBatch = null,
    frame_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Clear color (can be set from GPU state)
    clear_color: metal.MTLClearColor = .{ .red = 0.0, .green = 0.0, .blue = 0.1, .alpha = 1.0 },
    clear_presented: bool = false,

    // maxInt guarantees the first frame draws.
    last_generation: u64 = std.math.maxInt(u64),
    last_cursor_generation: u64 = std.math.maxInt(u64),

    present_callback: ?*const fn (?*anyopaque) callconv(.c) void = null,
    present_userdata: ?*anyopaque = null,

    // Scanout source (guest framebuffer). lock returns a view valid
    // until unlock is called; null when no scanout exists yet.
    scanout_lock: ?*const fn (?*anyopaque) ?Scanout = null,
    scanout_unlock: ?*const fn (?*anyopaque) void = null,
    scanout_userdata: ?*anyopaque = null,

    pub const InitError = Allocator.Error || std.Thread.SpawnError;

    pub fn init(
        alloc: Allocator,
        mtl_device: *anyopaque,
        mtl_layer: *anyopaque,
        mtl_queue: *anyopaque,
    ) RenderThread {
        return .{
            .alloc = alloc,
            .mtl_device = mtl_device,
            .mtl_layer = mtl_layer,
            .mtl_queue = mtl_queue,
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

    pub fn setPresentCallback(
        self: *RenderThread,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        userdata: ?*anyopaque,
    ) void {
        self.present_callback = callback;
        self.present_userdata = userdata;
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

    /// Try to send without blocking.
    pub fn trySend(self: *RenderThread, msg: Message) bool {
        if (self.mailbox.tryPush(msg)) {
            self.wakeup.notify();
            return true;
        }
        return false;
    }

    /// Request immediate frame draw (called from CVDisplayLink).
    pub fn requestFrame(self: *RenderThread) void {
        self.frame_requested.store(true, .release);
        self.wakeup.notify();
    }

    fn threadMain(self: *RenderThread) void {
        log.debug("renderer thread started", .{});

        if (comptime builtin.os.tag == .macos) {
            // Thread naming would go here via pthread
        }

        self.runLoop() catch |err| {
            log.err("renderer thread error: {}", .{err});
        };

        log.debug("renderer thread exiting", .{});
    }

    fn runLoop(self: *RenderThread) !void {
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
                .content_scale => |scale| {
                    self.content_scale = scale;
                    self.frame_requested.store(true, .release);
                },
                .focus => |focused| {
                    self.focused = focused;
                    self.setQosClass();
                },
                .visible => |visible| {
                    self.visible = visible;
                    if (visible) {
                        self.clear_presented = false;
                        self.frame_requested.store(true, .release);
                    }
                    self.setQosClass();
                },
                .commands_ready => |batch| {
                    self.pending_batch = batch;
                    self.frame_requested.store(true, .release);
                },
                .draw_now => {
                    self.clear_presented = false;
                    self.drawFrame();
                },
                .shutdown => {
                    self.running.store(false, .release);
                    return;
                },
            }
        }
    }

    fn drawFrame(self: *RenderThread) void {
        if (!self.visible) return;
        if (self.size.width == 0 or self.size.height == 0) return;

        if (self.scanout_lock) |lock_fn| {
            if (lock_fn(self.scanout_userdata)) |scan| {
                const cursor_gen = if (scan.cursor) |c| c.generation else 0;
                // Cursor movement must redraw even when the framebuffer is unchanged.
                if (scan.generation == self.last_generation and cursor_gen == self.last_cursor_generation) {
                    if (self.scanout_unlock) |unlock_fn| unlock_fn(self.scanout_userdata);
                    self.pending_batch = null;
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
                self.pending_batch = null;
                if (ok) {
                    self.clear_presented = false;
                    self.last_generation = scan.generation;
                    self.last_cursor_generation = cursor_gen;
                    if (self.present_callback) |cb| cb(self.present_userdata);
                }
                return;
            }
        }

        // No scanout yet: clear (color from pending batch if available).
        if (self.pending_batch == null and self.clear_presented) return;
        var clear_color = self.clear_color;
        if (self.pending_batch) |batch| {
            clear_color = .{
                .red = batch.clear_color[0],
                .green = batch.clear_color[1],
                .blue = batch.clear_color[2],
                .alpha = batch.clear_color[3],
            };
        }

        const success = self.frame_renderer.renderFrame(clear_color);
        self.pending_batch = null;
        if (success) {
            self.clear_presented = true;
            if (self.present_callback) |cb| {
                cb(self.present_userdata);
            }
        }
    }

    fn setQosClass(self: *const RenderThread) void {
        if (comptime builtin.os.tag != .macos) return;

        _ = self;

        // TODO: Call pthread_set_qos_class_self_np
    }
};

test "Mailbox push and pop" {
    var mailbox = Mailbox.init();

    mailbox.push(.{ .resize = .{ .width = 800, .height = 600 } });
    mailbox.push(.{ .focus = true });
    mailbox.push(.draw_now);

    const msg1 = mailbox.pop();
    try std.testing.expect(msg1 != null);
    try std.testing.expectEqual(@as(u32, 800), msg1.?.resize.width);

    const msg2 = mailbox.pop();
    try std.testing.expect(msg2 != null);
    try std.testing.expect(msg2.?.focus);

    const msg3 = mailbox.pop();
    try std.testing.expect(msg3 != null);
    try std.testing.expect(msg3.? == .draw_now);

    const msg4 = mailbox.pop();
    try std.testing.expect(msg4 == null);
}

test "Mailbox hasMessages" {
    var mailbox = Mailbox.init();

    try std.testing.expect(!mailbox.hasMessages());

    mailbox.push(.shutdown);
    try std.testing.expect(mailbox.hasMessages());

    _ = mailbox.pop();
    try std.testing.expect(!mailbox.hasMessages());
}

test "Wakeup notify and wait" {
    var wakeup = Wakeup{};

    wakeup.notify();
    const got = wakeup.timedWait(1_000_000);
    try std.testing.expect(got);
}

test "RenderThread init" {
    var dummy: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);

    var rt = RenderThread.init(std.testing.allocator, ptr, ptr, ptr);

    try std.testing.expect(!rt.running.load(.acquire));
}

test "RenderThread state messages request a frame" {
    var dummy: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);
    var rt = RenderThread.init(std.testing.allocator, ptr, ptr, ptr);

    rt.mailbox.push(.{ .resize = .{ .width = 800, .height = 600 } });
    rt.drainMailbox();

    try std.testing.expectEqual(Size{ .width = 800, .height = 600 }, rt.size);
    try std.testing.expect(rt.frame_requested.load(.acquire));
}
