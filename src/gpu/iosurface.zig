//! Minimal IOSurface bindings for zero-copy scanout.
//!
//! An IOSurface is a device-independent, CPU+GPU-shareable pixel buffer. We
//! create one on the vCPU thread (no Metal device required) to back a 2D
//! scanout resource's pixels, then the render thread wraps an `MTLTexture`
//! around the *same* memory (`Device.newTextureFromIOSurface`). That way the
//! guest's `transfer_to_host_2d` writes land directly in GPU-visible memory
//! and the per-frame CPU->GPU upload (`MTLTexture.replaceRegion`) disappears.
//!
//! Being device-independent is the whole point: the display `MTLDevice` comes
//! from the Swift app on another thread (and is absent in CLI mode), so the
//! shared buffer cannot be an `MTLBuffer` created at resource-creation time —
//! it has to be something any device can later wrap. That is exactly IOSurface.

const std = @import("std");

/// Opaque `IOSurfaceRef`.
pub const Ref = *anyopaque;

extern "c" fn IOSurfaceCreate(properties: ?*anyopaque) callconv(.c) ?Ref;
extern "c" fn IOSurfaceGetBaseAddress(buffer: Ref) callconv(.c) ?[*]u8;
extern "c" fn IOSurfaceGetBytesPerRow(buffer: Ref) callconv(.c) usize;
extern "c" fn IOSurfaceGetAllocSize(buffer: Ref) callconv(.c) usize;

extern "c" fn CFRelease(cf: *anyopaque) callconv(.c) void;
extern "c" fn CFDictionaryCreate(
    allocator: ?*anyopaque,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    num_values: isize,
    key_callbacks: ?*const anyopaque,
    value_callbacks: ?*const anyopaque,
) callconv(.c) ?*anyopaque;
extern "c" fn CFNumberCreate(
    allocator: ?*anyopaque,
    the_type: c_int,
    value_ptr: *const anyopaque,
) callconv(.c) ?*anyopaque;

// CoreFoundation callback tables — we only need their addresses.
extern "c" const kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" const kCFTypeDictionaryValueCallBacks: anyopaque;

// IOSurface property keys (CFStringRef globals).
extern "c" const kIOSurfaceWidth: ?*const anyopaque;
extern "c" const kIOSurfaceHeight: ?*const anyopaque;
extern "c" const kIOSurfaceBytesPerElement: ?*const anyopaque;
extern "c" const kIOSurfaceBytesPerRow: ?*const anyopaque;
extern "c" const kIOSurfacePixelFormat: ?*const anyopaque;

const kCFNumberSInt32Type: c_int = 3;
/// 'BGRA' four-char code — matches Metal `bgra8Unorm` / `kCVPixelFormatType_32BGRA`.
const pixel_format_bgra: i32 = 0x42475241;

pub const BYTES_PER_PIXEL: u32 = 4;

pub const IOSurface = struct {
    ref: Ref,
    base: [*]u8,
    /// Row stride in bytes; guaranteed to equal `width * 4` (see `createBGRA`).
    bytes_per_row: usize,

    /// Create a BGRA8 surface for a tightly-packed `width`x`height` image.
    ///
    /// Returns null if IOSurface is unavailable or padded the row stride past
    /// `width*4`. Callers then fall back to a plain heap buffer, because the
    /// guest transfers tightly-packed rows and the rest of the pipeline assumes
    /// `stride == width*4`; a padded surface would misalign every row.
    pub fn createBGRA(width: u32, height: u32) ?IOSurface {
        // Metal refuses to wrap a texture over an IOSurface whose bytesPerRow
        // isn't 16-byte aligned ("IOSurface texture: bytesPerRow (N) must be
        // aligned to 16 bytes" — a hard assertion that ABORTS the process, so
        // this must be caught here rather than at texture creation). IOSurface
        // itself happily hands out a tight odd stride, so check before asking:
        // a tight BGRA stride is width*4, which is 16-aligned iff width % 4 == 0.
        // Callers fall back to a heap buffer (upload path) when this returns
        // null. Real-world trigger: a compositor sizing a surface 431px wide.
        if (width % 4 != 0) return null;

        const w: i32 = @intCast(width);
        const h: i32 = @intCast(height);
        const bpe: i32 = @intCast(BYTES_PER_PIXEL);
        const want_bpr: i32 = @intCast(width * BYTES_PER_PIXEL);
        const fmt: i32 = pixel_format_bgra;

        const n_w = CFNumberCreate(null, kCFNumberSInt32Type, &w) orelse return null;
        defer CFRelease(n_w);
        const n_h = CFNumberCreate(null, kCFNumberSInt32Type, &h) orelse return null;
        defer CFRelease(n_h);
        const n_bpe = CFNumberCreate(null, kCFNumberSInt32Type, &bpe) orelse return null;
        defer CFRelease(n_bpe);
        const n_bpr = CFNumberCreate(null, kCFNumberSInt32Type, &want_bpr) orelse return null;
        defer CFRelease(n_bpr);
        const n_fmt = CFNumberCreate(null, kCFNumberSInt32Type, &fmt) orelse return null;
        defer CFRelease(n_fmt);

        const keys = [_]?*const anyopaque{
            kIOSurfaceWidth,           kIOSurfaceHeight,
            kIOSurfaceBytesPerElement, kIOSurfaceBytesPerRow,
            kIOSurfacePixelFormat,
        };
        const values = [_]?*const anyopaque{ n_w, n_h, n_bpe, n_bpr, n_fmt };

        const dict = CFDictionaryCreate(
            null,
            &keys,
            &values,
            keys.len,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ) orelse return null;
        defer CFRelease(dict);

        const ref = IOSurfaceCreate(dict) orelse return null;
        const actual_bpr = IOSurfaceGetBytesPerRow(ref);
        // Reject a padded stride so the guest's width*4 layout maps 1:1.
        if (actual_bpr != @as(usize, width) * BYTES_PER_PIXEL) {
            CFRelease(ref);
            return null;
        }
        const base = IOSurfaceGetBaseAddress(ref) orelse {
            CFRelease(ref);
            return null;
        };
        return .{ .ref = ref, .base = base, .bytes_per_row = actual_bpr };
    }

    /// The pixel bytes as a slice. `size` must be `<= IOSurfaceGetAllocSize`;
    /// callers pass `width*height*4`, which the tight stride guarantees fits.
    pub fn pixels(self: IOSurface, size: usize) []u8 {
        return self.base[0..size];
    }

    pub fn release(self: IOSurface) void {
        CFRelease(self.ref);
    }
};

/// Base address of a surface identified only by its ref (e.g. one obtained
/// from another module). Returns null if the ref has no mapping.
pub fn baseAddressOf(ref: Ref) ?[*]u8 {
    return IOSurfaceGetBaseAddress(ref);
}

test "iosurface: widths with a non-16-byte-aligned stride are refused" {
    // 431*4 == 1724, tight but not a multiple of 16: Metal ABORTS on such an
    // IOSurface-backed texture, so creation must fail here and let the caller
    // fall back to the upload path. (Regression: a compositor allocating a
    // 431px-wide target crashed the VM.)
    try std.testing.expect(IOSurface.createBGRA(431, 100) == null);
    try std.testing.expect(IOSurface.createBGRA(1, 1) == null);
    // Multiples of 4 stay on the zero-copy path.
    if (IOSurface.createBGRA(432, 100)) |surf| {
        defer surf.release();
        try std.testing.expectEqual(@as(usize, 432 * 4), surf.bytes_per_row);
        try std.testing.expectEqual(@as(usize, 0), surf.bytes_per_row % 16);
    }
}

test "iosurface: tight-stride BGRA surface is CPU-writable" {
    const surf = IOSurface.createBGRA(64, 32) orelse return error.SkipZigTest;
    defer surf.release();
    try std.testing.expectEqual(@as(usize, 64 * 4), surf.bytes_per_row);

    const px = surf.pixels(64 * 32 * 4);
    @memset(px, 0);
    px[0] = 0xAA;
    px[px.len - 1] = 0xBB;
    try std.testing.expectEqual(@as(u8, 0xAA), surf.base[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), surf.base[64 * 32 * 4 - 1]);
}
