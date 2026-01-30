//! Renderer module.
//!
//! Dedicated thread for Metal rendering at 60fps (vsync).
//! Receives translated GPU commands from the gpu module
//! and encodes Metal command buffers.
//!
//! Architecture:
//! 1. Swift calls bobrvm_surface_draw on CVDisplayLink callback
//! 2. This triggers requestFrame() on the renderer thread
//! 3. Renderer thread wakes up and encodes Metal commands
//! 4. Frame is presented via MTLCommandBuffer.presentDrawable
//!
//! Communication with main thread via lock-free mailbox.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

pub const Thread = @import("Thread.zig");
pub const RenderThread = Thread.RenderThread;
pub const Mailbox = Thread.Mailbox;
pub const Message = Thread.Message;
pub const Size = Thread.Size;
pub const ContentScale = Thread.ContentScale;
pub const CommandBatch = Thread.CommandBatch;
pub const Wakeup = Thread.Wakeup;

/// Renderer state.
/// Thin wrapper around RenderThread for compatibility.
pub const Renderer = struct {
    render_thread: RenderThread,

    pub const InitError = Allocator.Error || std.Thread.SpawnError;

    pub fn init(
        alloc: Allocator,
        mtl_device: *anyopaque,
        mtl_layer: *anyopaque,
        mtl_queue: *anyopaque,
    ) Renderer {
        return .{
            .render_thread = RenderThread.init(alloc, mtl_device, mtl_layer, mtl_queue),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.stop();
    }

    pub fn start(self: *Renderer) !void {
        try self.render_thread.start();
    }

    pub fn stop(self: *Renderer) void {
        self.render_thread.stop();
    }

    /// Send a message to the render thread.
    pub fn send(self: *Renderer, msg: Message) void {
        self.render_thread.send(msg);
    }

    /// Request immediate frame draw (called from CVDisplayLink).
    pub fn requestFrame(self: *Renderer) void {
        self.render_thread.requestFrame();
    }

    /// Resize the surface.
    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        self.send(.{ .resize = .{ .width = width, .height = height } });
    }

    /// Set content scale (HiDPI).
    pub fn setContentScale(self: *Renderer, x: f64, y: f64) void {
        self.send(.{ .content_scale = .{ .x = x, .y = y } });
    }

    /// Set focus state.
    pub fn setFocus(self: *Renderer, focused: bool) void {
        self.send(.{ .focus = focused });
    }

    /// Set visibility state.
    pub fn setVisible(self: *Renderer, visible: bool) void {
        self.send(.{ .visible = visible });
    }

    /// Submit GPU commands for encoding.
    pub fn submitCommands(self: *Renderer, batch: *CommandBatch) void {
        self.send(.{ .commands_ready = batch });
    }

    /// Set presentation callback.
    pub fn setPresentCallback(
        self: *Renderer,
        callback: ?*const fn (?*anyopaque) callconv(.c) void,
        userdata: ?*anyopaque,
    ) void {
        self.render_thread.setPresentCallback(callback, userdata);
    }

    /// Get current surface size.
    pub fn getSize(self: *const Renderer) Size {
        return self.render_thread.size;
    }

    /// Check if renderer is running.
    pub fn isRunning(self: *const Renderer) bool {
        return self.render_thread.running.load(.acquire);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Renderer init and lifecycle" {
    var dummy: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);

    var renderer = Renderer.init(std.testing.allocator, ptr, ptr, ptr);
    defer renderer.deinit();

    try std.testing.expect(!renderer.isRunning());
}

test "Renderer message sending" {
    var dummy: u32 = 0;
    const ptr: *anyopaque = @ptrCast(&dummy);

    var renderer = Renderer.init(std.testing.allocator, ptr, ptr, ptr);
    defer renderer.deinit();

    // These should not crash even without thread running
    renderer.resize(800, 600);
    renderer.setFocus(true);
    renderer.setVisible(true);
}

test {
    _ = Thread;
}
