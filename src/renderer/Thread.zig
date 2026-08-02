//! Renderer thread implementation.
//!
//! Handles the render loop and Metal command encoding.
//! Communicates with main thread via mailbox.
//!
//! Pattern follows Ghostty's renderer/Thread.zig:
//! - Fixed-capacity mailbox for message passing
//! - Wakeup mechanism for low-latency notifications
//! - VSync coordination via CVDisplayLink (from Swift)
//! - QoS class adjustment based on visibility/focus

const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const metal = @import("../gpu/metal.zig");
const global = @import("../global.zig");
const thread_compat = @import("../compat/thread.zig");

const log = std.log.scoped(.renderer);

/// Mailbox capacity (power of 2 for efficient modulo).
const MAILBOX_CAPACITY = 64;

/// Mailbox message types.
pub const Message = union(enum) {
    /// Surface resize.
    resize: Size,

    /// Content scale change (HiDPI).
    content_scale: ContentScale,

    /// Focus state change.
    focus: bool,

    /// Visibility change.
    visible: bool,

    /// GPU command buffer ready for encoding.
    /// Contains a pointer to the command batch from the GPU module.
    commands_ready: *CommandBatch,

    /// Force immediate frame draw (called from CVDisplayLink).
    draw_now: void,

    /// Shutdown the renderer thread.
    shutdown: void,
};

/// Surface size.
pub const Size = struct {
    width: u32,
    height: u32,
};

/// Content scale for HiDPI.
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

/// Batch of GPU commands to encode.
/// This is a placeholder; actual implementation will reference gpu.Context state.
pub const CommandBatch = struct {
    /// Number of draw calls.
    draw_count: u32 = 0,
    /// Clear color (RGBA).
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    /// Resource handle of framebuffer to present.
    framebuffer: u32 = 0,
};

/// Fixed-capacity mailbox for thread communication.
///
/// Uses a circular buffer with mutex protection.
/// SPSC-optimized: single producer (main thread), single consumer (render thread).
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

        // Wait for space
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

    /// Check if mailbox has pending messages.
    pub fn hasMessages(self: *Mailbox) bool {
        return self.len.load(.acquire) > 0;
    }

    /// Wake up a waiting consumer.
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

    // Frame timing
    target_fps: u32 = 60,
    frame_time_ns: u64,

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

    // Last scanout generation presented; skip re-upload when unchanged.
    // maxInt = "nothing presented yet" so the first frame always draws.
    last_generation: u64 = std.math.maxInt(u64),
    // Same idea for the cursor: redraw on cursor-only movement even when
    // the framebuffer itself (last_generation) hasn't changed.
    last_cursor_generation: u64 = std.math.maxInt(u64),

    // Callback to Swift for frame presentation
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
        const target_fps: u32 = 60;
        return .{
            .alloc = alloc,
            .mtl_device = mtl_device,
            .mtl_layer = mtl_layer,
            .mtl_queue = mtl_queue,
            .frame_renderer = metal.FrameRenderer.init(mtl_device, mtl_layer, mtl_queue),
            .target_fps = target_fps,
            .frame_time_ns = std.time.ns_per_s / target_fps,
        };
    }

    /// Set presentation callback (called from Swift).
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

    /// Start the render thread.
    pub fn start(self: *RenderThread) !void {
        // Pre-condition: not already running
        assert(!self.running.load(.acquire));

        log.info("starting renderer thread (target {}fps)", .{self.target_fps});

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Stop the render thread.
    pub fn stop(self: *RenderThread) void {
        if (!self.running.load(.acquire)) return;

        log.info("stopping renderer thread", .{});

        // Signal shutdown
        self.running.store(false, .release);
        self.mailbox.push(.shutdown);
        self.wakeup.notify();

        // Wait for thread
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        log.debug("renderer thread stopped", .{});
    }

    /// Send a message to the render thread.
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

    // =========================================================================
    // Thread Entry
    // =========================================================================

    fn threadMain(self: *RenderThread) void {
        log.debug("renderer thread started", .{});

        // Set thread name for debugging
        if (comptime builtin.os.tag == .macos) {
            // Thread naming would go here via pthread
        }

        // Thread main loop
        self.runLoop() catch |err| {
            log.err("renderer thread error: {}", .{err});
        };

        log.debug("renderer thread exiting", .{});
    }

    fn runLoop(self: *RenderThread) !void {
        while (self.running.load(.acquire)) {
            // Wait for wakeup or timeout
            const frame_ns = self.frame_time_ns;
            _ = self.wakeup.timedWait(frame_ns);

            // Drain mailbox
            self.drainMailbox();

            // Check if we should draw
            if (self.frame_requested.swap(false, .acquire) or self.visible) {
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
                },
                .content_scale => |scale| {
                    self.content_scale = scale;
                },
                .focus => |focused| {
                    self.focused = focused;
                    self.setQosClass();
                },
                .visible => |visible| {
                    self.visible = visible;
                    if (visible) self.clear_presented = false;
                    self.setQosClass();
                },
                .commands_ready => |batch| {
                    self.pending_batch = batch;
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
        // Skip if invisible or no size
        if (!self.visible) return;
        if (self.size.width == 0 or self.size.height == 0) return;

        // Present the guest scanout when one exists.
        if (self.scanout_lock) |lock_fn| {
            if (lock_fn(self.scanout_userdata)) |scan| {
                const cursor_gen = if (scan.cursor) |c| c.generation else 0;
                // Skip the upload+blit+present entirely when neither the
                // framebuffer nor the cursor has changed since our last
                // frame (idle-screen case) — cursor-only motion still needs
                // a redraw even though the framebuffer generation is static.
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

        // Render frame using Metal
        const success = self.frame_renderer.renderFrame(clear_color);

        // Clear pending batch after encoding
        self.pending_batch = null;

        // Notify Swift that frame was presented
        if (success) {
            self.clear_presented = true;
            if (self.present_callback) |cb| {
                cb(self.present_userdata);
            }
        }
    }

    fn setQosClass(self: *const RenderThread) void {
        if (comptime builtin.os.tag != .macos) return;

        // QoS class adjustment based on visibility/focus
        // - Hidden: utility (background)
        // - Visible, unfocused: user_initiated
        // - Visible, focused: user_interactive
        _ = self;

        // TODO: Call pthread_set_qos_class_self_np
    }
};

// =============================================================================
// Tests
// =============================================================================

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

    // Notify before wait
    wakeup.notify();

    // Timed wait should return immediately
    const got = wakeup.timedWait(1_000_000);
    try std.testing.expect(got);
}

test "RenderThread init" {
    var dummy: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);

    var rt = RenderThread.init(std.testing.allocator, ptr, ptr, ptr);

    try std.testing.expectEqual(@as(u32, 60), rt.target_fps);
    try std.testing.expect(!rt.running.load(.acquire));
}
