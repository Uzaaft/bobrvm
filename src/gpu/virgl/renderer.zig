//! Virgl → Metal execution backend.
//!
//! The decoder/context layer parses the guest Gallium command stream and
//! tracks state; this module is where those commands actually hit the GPU.
//! It owns the MTLDevice/queue and the Metal-side backing for each guest
//! render-target resource, and executes the terminal operations (clear,
//! and later draw) by encoding real Metal command buffers.
//!
//! Milestone 1 (this file): resource-backed render targets + `clear`,
//! validated end-to-end against a real Metal device by reading the pixels
//! back. No guest required — the translator is driven directly by tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const metal = @import("../metal.zig");
const proto = @import("protocol.zig");

pub const ResourceHandle = u32;

/// A guest render-target resource backed by an MTLTexture.
pub const Target = struct {
    tex: metal.Texture,
    width: u32,
    height: u32,
    format: metal.MTLPixelFormat,
};

pub const Error = error{
    NoMetalDevice,
    NoCommandQueue,
    TextureCreateFailed,
    CommandBufferFailed,
    EncoderFailed,
    UnknownTarget,
} || Allocator.Error;

/// Map a virgl/Gallium pixel format to the closest Metal pixel format.
/// Covers the formats a render target realistically uses; unknown formats
/// fall back to BGRA8 so we still produce a usable attachment.
pub fn mapFormat(fmt: proto.Format) metal.MTLPixelFormat {
    return switch (fmt) {
        .b8g8r8a8_unorm, .b8g8r8x8_unorm => .bgra8Unorm,
        .r8g8b8a8_unorm => .rgba8Unorm,
        .r32g32b32a32_float => .rgba16Float, // narrowing; adequate for scanout
        .r8_unorm => .r8Unorm,
        else => .bgra8Unorm,
    };
}

/// Bytes per pixel for a Metal pixel format we produce here.
fn bytesPerPixel(fmt: metal.MTLPixelFormat) u32 {
    return switch (fmt) {
        .bgra8Unorm, .bgra8Unorm_sRGB, .rgba8Unorm, .rgba8Unorm_sRGB => 4,
        .rgba16Float => 8,
        .r8Unorm => 1,
        .rg8Unorm => 2,
        else => 4,
    };
}

pub const Renderer = struct {
    alloc: Allocator,
    device: metal.Device,
    queue: metal.CommandQueue,
    /// Whether we own the device (created it) vs. borrowing it from Swift.
    owns_device: bool,
    targets: std.AutoHashMap(ResourceHandle, Target),

    /// Create a renderer with the system default Metal device. Works
    /// headlessly (no window), which is exactly what tests and the
    /// WSL-like path need.
    pub fn init(alloc: Allocator) Error!Renderer {
        const device = metal.Device.createSystemDefault() orelse return Error.NoMetalDevice;
        const queue = device.newCommandQueue() orelse return Error.NoCommandQueue;
        return .{
            .alloc = alloc,
            .device = device,
            .queue = queue,
            .owns_device = true,
            .targets = std.AutoHashMap(ResourceHandle, Target).init(alloc),
        };
    }

    /// Create a renderer borrowing an existing device/queue (e.g. the one
    /// backing the CAMetalLayer handed over by Swift), so on-screen and
    /// off-screen rendering share resources with zero copies.
    pub fn initWithDevice(alloc: Allocator, device: metal.Device, queue: metal.CommandQueue) Renderer {
        return .{
            .alloc = alloc,
            .device = device,
            .queue = queue,
            .owns_device = false,
            .targets = std.AutoHashMap(ResourceHandle, Target).init(alloc),
        };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.targets.valueIterator();
        while (it.next()) |t| t.tex.release();
        self.targets.deinit();
    }

    /// Back a guest render-target resource with an MTLTexture. Idempotent
    /// per handle: re-creating replaces (and releases) the old texture.
    pub fn createRenderTarget(
        self: *Renderer,
        handle: ResourceHandle,
        format: proto.Format,
        width: u32,
        height: u32,
    ) Error!void {
        if (width == 0 or height == 0) return Error.TextureCreateFailed;
        const mtl_fmt = mapFormat(format);
        const tex = self.device.newTexture2D(
            mtl_fmt,
            width,
            height,
            metal.MTLTextureUsage.render_target | metal.MTLTextureUsage.shader_read,
            .shared,
        ) orelse return Error.TextureCreateFailed;

        if (self.targets.fetchRemove(handle)) |old| old.value.tex.release();
        try self.targets.put(handle, .{
            .tex = tex,
            .width = width,
            .height = height,
            .format = mtl_fmt,
        });
    }

    pub fn getTarget(self: *Renderer, handle: ResourceHandle) ?Target {
        return self.targets.get(handle);
    }

    /// Execute a clear against a render-target resource: encode a render
    /// pass whose color attachment is the target's texture with
    /// loadAction=clear, then end + commit. With no draws, this is exactly
    /// a hardware clear to `color`.
    pub fn clearTarget(self: *Renderer, handle: ResourceHandle, color: [4]f32) Error!void {
        const target = self.targets.get(handle) orelse return Error.UnknownTarget;

        const pass = metal.RenderPassDescriptor.create() orelse return Error.EncoderFailed;
        const attachments = pass.colorAttachments() orelse return Error.EncoderFailed;
        const att = attachments.objectAtIndex(0) orelse return Error.EncoderFailed;
        att.setTexture(target.tex.ptr);
        att.setLoadAction(.clear);
        att.setStoreAction(.store);
        att.setClearColor(.{
            .red = color[0],
            .green = color[1],
            .blue = color[2],
            .alpha = color[3],
        });

        const cmd = self.queue.commandBuffer() orelse return Error.CommandBufferFailed;
        const enc = cmd.renderCommandEncoderWithDescriptor(pass) orelse return Error.EncoderFailed;
        enc.endEncoding();
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    /// Read a render target's pixels back into a host buffer (tight rows).
    /// `out` must be at least width*height*bytesPerPixel.
    pub fn readback(self: *Renderer, handle: ResourceHandle, out: []u8) Error!void {
        const target = self.targets.get(handle) orelse return Error.UnknownTarget;
        const bpp = bytesPerPixel(target.format);
        const bpr: usize = @as(usize, target.width) * bpp;
        std.debug.assert(out.len >= bpr * target.height);
        target.tex.getBytes(
            out.ptr,
            bpr,
            .{ .size = .{ .width = target.width, .height = target.height } },
            0,
        );
    }
};

// =============================================================================
// Tests
// =============================================================================

test "clear render target produces exact pixels" {
    const alloc = std.testing.allocator;
    var r = Renderer.init(alloc) catch |err| {
        // On a machine without a usable Metal device (unlikely on macOS),
        // skip rather than fail the whole suite.
        if (err == Error.NoMetalDevice) return error.SkipZigTest;
        return err;
    };
    defer r.deinit();

    const w: u32 = 16;
    const h: u32 = 8;
    try r.createRenderTarget(1, .b8g8r8a8_unorm, w, h);

    // Clear to a known color. Metal bgra8Unorm stores as B,G,R,A in memory.
    // color = (r=0.25, g=0.5, b=0.75, a=1.0)
    try r.clearTarget(1, .{ 0.25, 0.5, 0.75, 1.0 });

    var buf: [16 * 8 * 4]u8 = undefined;
    try r.readback(1, &buf);

    const expect_b: u8 = @intFromFloat(@round(0.75 * 255.0));
    const expect_g: u8 = @intFromFloat(@round(0.5 * 255.0));
    const expect_r: u8 = @intFromFloat(@round(0.25 * 255.0));
    const expect_a: u8 = 255;

    // Check a few sample pixels (allow ±1 for rounding/format conversion).
    const samples = [_]usize{ 0, (w * h / 2), (w * h - 1) };
    for (samples) |px| {
        const o = px * 4;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_b)), @as(f32, @floatFromInt(buf[o + 0])), 1.5);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_g)), @as(f32, @floatFromInt(buf[o + 1])), 1.5);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expect_r)), @as(f32, @floatFromInt(buf[o + 2])), 1.5);
        try std.testing.expectEqual(expect_a, buf[o + 3]);
    }
}
