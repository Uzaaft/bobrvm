const KittyDisplay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const global = @import("../global.zig");
const machine_module = @import("../machine/main.zig");
const simd = @import("../simd/main.zig");
const virtio_gpu = @import("../virtio/gpu.zig");

const log = std.log.scoped(.kitty_display);

alloc: Allocator,
machine: *machine_module.Machine,
thread: ?std.Thread = null,
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
wakeup: std.Io.Semaphore = .{},
pixels_rgba: std.ArrayList(u8) = .empty,
compressed: std.Io.Writer.Allocating,
protocol: std.Io.Writer.Allocating,
terminal_columns: u16 = 80,
terminal_rows: u16 = 24,
terminal_active: bool = false,
animation: Animation = .unplaced,

const stdout_fd = std.posix.STDOUT_FILENO;
const stderr_fd = std.posix.STDERR_FILENO;
const image_id: u32 = 0x4252_564d;
const placement_id: u32 = 1;
const payload_bytes_max: usize = 3072;
const thread_stack_size_bytes: usize = 1024 * 1024;
const frame_interval_ns: i96 = std.time.ns_per_s / 60;

const terminal_enter =
    "\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l" ++
    "\x1b[?1003h\x1b[?1006h\x1b[?1016h";
// The leading ST also terminates a transmission interrupted by a signal.
const terminal_leave =
    "\x1b\\\x1b[?1016l\x1b[?1006l\x1b[?1003l" ++
    "\x1b[?25h\x1b[?1049l";

pub const StartError = Allocator.Error || std.Thread.SpawnError || error{
    NotATerminal,
    WriteFailed,
};

const RenderError = Allocator.Error || std.Io.Writer.Error || error{
    InvalidFrame,
    WriteFailed,
};

const Frame = struct {
    width: u32,
    height: u32,

    fn eql(self: Frame, other: Frame) bool {
        return self.width == other.width and self.height == other.height;
    }
};

const FrameTarget = enum {
    root,
    create_second,
    edit_root,
    edit_second,

    fn frameNumber(self: FrameTarget) ?u8 {
        return switch (self) {
            .root => null,
            .create_second, .edit_second => 2,
            .edit_root => 1,
        };
    }
};

const Animation = union(enum) {
    unplaced,
    one_frame: Frame,
    // The hidden frame is replaced before selection, so Ghostty never renders
    // a frame while bobrvm is changing its backing pixels. See:
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/#animation
    alternating: struct {
        frame: Frame,
        hidden: FrameNumber,
    },

    const FrameNumber = enum {
        root,
        second,
    };

    fn target(self: Animation, frame: Frame) FrameTarget {
        return switch (self) {
            .unplaced => .root,
            .one_frame => |current| if (current.eql(frame)) .create_second else .root,
            .alternating => |state| if (!state.frame.eql(frame))
                .root
            else switch (state.hidden) {
                .root => .edit_root,
                .second => .edit_second,
            },
        };
    }

    fn commit(self: *Animation, frame: Frame, destination: FrameTarget) void {
        std.debug.assert(self.target(frame) == destination);
        self.* = switch (destination) {
            .root => .{ .one_frame = frame },
            .create_second => .{ .alternating = .{ .frame = frame, .hidden = .root } },
            .edit_root => .{ .alternating = .{ .frame = frame, .hidden = .second } },
            .edit_second => .{ .alternating = .{ .frame = frame, .hidden = .root } },
        };
    }

    fn isPlaced(self: Animation) bool {
        return switch (self) {
            .unplaced => false,
            .one_frame, .alternating => true,
        };
    }
};

const TerminalSize = struct {
    columns: u16 = 80,
    rows: u16 = 24,
};

pub fn init(alloc: Allocator, hw: *machine_module.Machine) KittyDisplay {
    return .{
        .alloc = alloc,
        .machine = hw,
        .compressed = .init(alloc),
        .protocol = .init(alloc),
    };
}

pub fn start(self: *KittyDisplay) StartError!void {
    if (std.c.isatty(stdout_fd) == 0) return error.NotATerminal;

    const size = terminalSize(stdout_fd);
    self.terminal_columns = size.columns;
    self.terminal_rows = size.rows;
    try writeAll(stdout_fd, terminal_enter);
    self.terminal_active = true;
    errdefer {
        writeAll(stdout_fd, terminal_leave) catch {};
        self.terminal_active = false;
    }

    self.running.store(true, .release);
    errdefer self.running.store(false, .release);
    self.thread = try std.Thread.spawn(
        .{ .stack_size = thread_stack_size_bytes },
        threadMain,
        .{self},
    );
}

pub fn deinit(self: *KittyDisplay) void {
    self.running.store(false, .release);
    self.wakeup.post(global.io());
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }

    if (self.terminal_active) {
        if (self.animation.isPlaced()) {
            var delete_buffer: [96]u8 = undefined;
            const delete = std.fmt.bufPrint(
                &delete_buffer,
                "\x1b_Ga=d,d=I,i={d},q=2\x1b\\",
                .{image_id},
            ) catch "";
            writeAll(stdout_fd, delete) catch {};
        }
        writeAll(stdout_fd, terminal_leave) catch {};
        self.terminal_active = false;
    }

    self.pixels_rgba.deinit(self.alloc);
    self.compressed.deinit();
    self.protocol.deinit();
}

/// Best-effort async-signal-safe cleanup for SIGINT/SIGTERM. The process exits
/// immediately afterwards, so ending a partial APC and leaving the alternate
/// screen is sufficient; normal teardown also deletes the image.
pub fn restoreTerminalSignalSafe() void {
    _ = std.c.write(stdout_fd, terminal_leave.ptr, terminal_leave.len);
}

/// Frame callbacks run on a vCPU thread. Coalescing here keeps all copying,
/// compression, and terminal I/O on the dedicated display thread.
pub fn frameReady(userdata: ?*anyopaque) void {
    const self: *KittyDisplay = @ptrCast(@alignCast(userdata orelse return));
    if (!self.running.load(.acquire)) return;
    if (!self.pending.swap(true, .acq_rel)) self.wakeup.post(global.io());
}

fn threadMain(self: *KittyDisplay) void {
    self.run() catch |err| {
        log.err("terminal display stopped: {}", .{err});
        self.running.store(false, .release);
        if (self.terminal_active) {
            writeAll(stdout_fd, terminal_leave) catch {};
            self.terminal_active = false;
        }
        var buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "bobrvm: Kitty display stopped: {s}\n",
            .{@errorName(err)},
        ) catch return;
        writeAll(stderr_fd, message) catch {};
    };
}

fn run(self: *KittyDisplay) RenderError!void {
    var deadline_ns: i96 = 0;
    while (true) {
        self.wakeup.waitUncancelable(global.io());
        if (!self.running.load(.acquire)) return;
        const now_ns = std.Io.Clock.awake.now(global.io()).nanoseconds;
        if (deadline_ns > now_ns) {
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = deadline_ns - now_ns },
                .clock = .awake,
            }, global.io()) catch {};
            if (!self.running.load(.acquire)) return;
        }

        // Keep pending set while waiting so callbacks coalesce into the frame
        // captured at this deadline. A callback during encoding posts the next
        // wakeup instead of being lost behind the in-flight frame.
        _ = self.pending.swap(false, .acquire);
        const started_ns = std.Io.Clock.awake.now(global.io()).nanoseconds;
        try self.drawFrame();
        const finished_ns = std.Io.Clock.awake.now(global.io()).nanoseconds;
        deadline_ns = nextFrameDeadline(deadline_ns, started_ns, finished_ns);
    }
}

fn drawFrame(self: *KittyDisplay) RenderError!void {
    const gpu = self.machine.gpu orelse return;
    const frame: ?Frame = frame: {
        const scanout = gpu.lockScanout() orelse return;
        defer gpu.unlockScanout();
        break :frame self.capture(scanout) catch |err| switch (err) {
            error.InvalidFrame => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
    };
    const captured = frame orelse return;

    self.compressed.clearRetainingCapacity();
    try self.compressed.ensureUnusedCapacity(4096);
    var flate_buffer: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &self.compressed.writer,
        &flate_buffer,
        .zlib,
        .fastest,
    );
    try compressor.writer.writeAll(self.pixels_rgba.items);
    try compressor.finish();

    const target = self.animation.target(captured);
    self.protocol.clearRetainingCapacity();
    try encodeTransmission(
        &self.protocol.writer,
        self.compressed.written(),
        captured,
        self.terminal_columns,
        self.terminal_rows,
        target,
    );
    try writeAll(stdout_fd, self.protocol.written());
    self.animation.commit(captured, target);
}

fn capture(
    self: *KittyDisplay,
    scanout: virtio_gpu.Gpu.ScanoutView,
) (Allocator.Error || error{InvalidFrame})!Frame {
    const pixel_count = std.math.mul(
        usize,
        scanout.width,
        scanout.height,
    ) catch return error.InvalidFrame;
    const rgba_length = std.math.mul(usize, pixel_count, 4) catch
        return error.InvalidFrame;
    try self.pixels_rgba.resize(self.alloc, rgba_length);
    try copyScanoutRgba(self.pixels_rgba.items, scanout);
    if (scanout.cursor) |cursor| {
        try compositeCursorRgba(
            self.pixels_rgba.items,
            scanout.width,
            scanout.height,
            cursor,
        );
    }
    return .{ .width = scanout.width, .height = scanout.height };
}

fn copyScanoutRgba(
    output: []u8,
    scanout: virtio_gpu.Gpu.ScanoutView,
) error{InvalidFrame}!void {
    const layout = try scanoutLayout(output.len, scanout);

    var destination_offset: usize = 0;
    var row: usize = 0;
    while (row < scanout.height) : (row += 1) {
        const source_offset = (@as(usize, scanout.src_y) + row) *
            layout.source_stride + layout.source_x_bytes;
        const source = scanout.data[source_offset..][0..layout.row_bytes];
        const destination = output[destination_offset..][0..layout.row_bytes];
        copyBgraRowRgba(destination, source);
        destination_offset += layout.row_bytes;
    }
}

const ScanoutLayout = struct {
    source_stride: usize,
    source_x_bytes: usize,
    row_bytes: usize,
};

fn scanoutLayout(
    output_length: usize,
    scanout: virtio_gpu.Gpu.ScanoutView,
) error{InvalidFrame}!ScanoutLayout {
    if (scanout.width == 0 or scanout.height == 0) return error.InvalidFrame;
    if (scanout.width > virtio_gpu.Gpu.MAX_RESOURCE_DIM or
        scanout.height > virtio_gpu.Gpu.MAX_RESOURCE_DIM or
        scanout.full_width > virtio_gpu.Gpu.MAX_RESOURCE_DIM or
        scanout.full_height > virtio_gpu.Gpu.MAX_RESOURCE_DIM)
    {
        return error.InvalidFrame;
    }
    if (scanout.full_width < scanout.width or scanout.full_height < scanout.height) {
        return error.InvalidFrame;
    }
    if (scanout.src_x > scanout.full_width - scanout.width or
        scanout.src_y > scanout.full_height - scanout.height)
    {
        return error.InvalidFrame;
    }

    const pixel_count = std.math.mul(
        usize,
        scanout.width,
        scanout.height,
    ) catch return error.InvalidFrame;
    const expected_output_length = std.math.mul(usize, pixel_count, 4) catch
        return error.InvalidFrame;
    if (output_length != expected_output_length) return error.InvalidFrame;

    const source_stride = std.math.mul(usize, scanout.full_width, 4) catch
        return error.InvalidFrame;
    const source_x_bytes = std.math.mul(usize, scanout.src_x, 4) catch
        return error.InvalidFrame;
    const row_bytes = std.math.mul(usize, scanout.width, 4) catch
        return error.InvalidFrame;
    const last_row = std.math.add(
        usize,
        scanout.src_y,
        scanout.height - 1,
    ) catch return error.InvalidFrame;
    const last_start = std.math.mul(usize, last_row, source_stride) catch
        return error.InvalidFrame;
    const last_pixel_start = std.math.add(
        usize,
        last_start,
        source_x_bytes,
    ) catch return error.InvalidFrame;
    const source_end = std.math.add(
        usize,
        last_pixel_start,
        row_bytes,
    ) catch return error.InvalidFrame;
    if (source_end > scanout.data.len) return error.InvalidFrame;

    return .{
        .source_stride = source_stride,
        .source_x_bytes = source_x_bytes,
        .row_bytes = row_bytes,
    };
}

fn copyBgraRowRgba(output: []u8, source: []const u8) void {
    std.debug.assert(source.len % 4 == 0);
    std.debug.assert(output.len == source.len);

    var source_offset: usize = 0;
    if (simd.lanes(u32)) |lanes| {
        const Pixels = @Vector(lanes, u32);
        const vector_bytes = lanes * @sizeOf(u32);
        const blue_mask: Pixels = @splat(0x0000_00ff);
        const green_mask: Pixels = @splat(0x0000_ff00);
        // Scanout byte four is padding; Kitty's 32-bit format needs an opaque
        // alpha channel or XRGB guest surfaces disappear.
        const alpha: Pixels = @splat(0xff00_0000);
        const Shift = @Vector(lanes, u5);
        const shift: Shift = @splat(16);

        while (source_offset + vector_bytes <= source.len) {
            const bgra: Pixels = @bitCast(source[source_offset..][0..vector_bytes].*);
            const rgba = ((bgra & blue_mask) << shift) |
                (bgra & green_mask) | ((bgra >> shift) & blue_mask) | alpha;
            output[source_offset..][0..vector_bytes].* = @bitCast(rgba);
            source_offset += vector_bytes;
        }
    }

    while (source_offset < source.len) {
        output[source_offset..][0..4].* = .{
            source[source_offset + 2],
            source[source_offset + 1],
            source[source_offset],
            0xff,
        };
        source_offset += 4;
    }
}

fn compositeCursorRgba(
    output: []u8,
    width: u32,
    height: u32,
    cursor: virtio_gpu.Gpu.CursorView,
) error{InvalidFrame}!void {
    if (width > virtio_gpu.Gpu.MAX_RESOURCE_DIM or
        height > virtio_gpu.Gpu.MAX_RESOURCE_DIM or
        cursor.width > virtio_gpu.Gpu.MAX_RESOURCE_DIM or
        cursor.height > virtio_gpu.Gpu.MAX_RESOURCE_DIM)
    {
        return error.InvalidFrame;
    }
    const output_pixels = std.math.mul(usize, width, height) catch
        return error.InvalidFrame;
    const output_length = std.math.mul(usize, output_pixels, 4) catch
        return error.InvalidFrame;
    if (output.len != output_length) return error.InvalidFrame;

    const cursor_pixels = std.math.mul(
        usize,
        cursor.width,
        cursor.height,
    ) catch return error.InvalidFrame;
    const cursor_length = std.math.mul(usize, cursor_pixels, 4) catch
        return error.InvalidFrame;
    if (cursor.data.len < cursor_length) return error.InvalidFrame;

    const left = @as(i64, cursor.x) - cursor.hot_x;
    const top = @as(i64, cursor.y) - cursor.hot_y;
    var source_y: u32 = 0;
    while (source_y < cursor.height) : (source_y += 1) {
        const destination_y = top + source_y;
        if (destination_y < 0 or destination_y >= height) continue;
        var source_x: u32 = 0;
        while (source_x < cursor.width) : (source_x += 1) {
            const destination_x = left + source_x;
            if (destination_x < 0 or destination_x >= width) continue;

            const source_offset = (@as(usize, source_y) * cursor.width + source_x) * 4;
            const destination_offset = (@as(usize, @intCast(destination_y)) * width +
                @as(usize, @intCast(destination_x))) * 4;
            const alpha = cursor.data[source_offset + 3];
            blend(&output[destination_offset], cursor.data[source_offset + 2], alpha);
            blend(&output[destination_offset + 1], cursor.data[source_offset + 1], alpha);
            blend(&output[destination_offset + 2], cursor.data[source_offset], alpha);
        }
    }
}

fn blend(destination: *u8, source: u8, alpha: u8) void {
    const inverse = 255 - @as(u16, alpha);
    const mixed = @as(u16, source) * alpha + @as(u16, destination.*) * inverse + 127;
    destination.* = @intCast(mixed / 255);
}

fn nextFrameDeadline(deadline_ns: i96, started_ns: i96, finished_ns: i96) i96 {
    var next_ns = if (deadline_ns == 0)
        started_ns + frame_interval_ns
    else
        deadline_ns + frame_interval_ns;
    if (next_ns > finished_ns) return next_ns;

    const intervals_missed = @divTrunc(finished_ns - next_ns, frame_interval_ns) + 1;
    next_ns += intervals_missed * frame_interval_ns;
    return next_ns;
}

fn encodeTransmission(
    writer: *std.Io.Writer,
    payload: []const u8,
    frame: Frame,
    columns: u16,
    rows: u16,
    target: FrameTarget,
) std.Io.Writer.Error!void {
    var offset: usize = 0;
    while (offset < payload.len) {
        const length = @min(payload_bytes_max, payload.len - offset);
        const chunk = payload[offset..][0..length];
        const more = offset + length < payload.len;
        if (offset == 0) {
            try writeTransmissionHeader(writer, frame, columns, rows, target, more);
        } else {
            switch (target) {
                .root => try writer.print("\x1b_Gm={d};", .{@intFromBool(more)}),
                .create_second, .edit_root, .edit_second => try writer.print(
                    "\x1b_Ga=f,m={d};",
                    .{@intFromBool(more)},
                ),
            }
        }

        var encoded: [4096]u8 = undefined;
        const base64 = std.base64.standard.Encoder.encode(&encoded, chunk);
        try writer.writeAll(base64);
        try writer.writeAll("\x1b\\");
        offset += length;
    }

    if (target.frameNumber()) |number| {
        try writer.print("\x1b_Ga=a,i={d},c={d},q=2\x1b\\", .{ image_id, number });
    }
}

fn writeTransmissionHeader(
    writer: *std.Io.Writer,
    frame: Frame,
    columns: u16,
    rows: u16,
    target: FrameTarget,
    more: bool,
) std.Io.Writer.Error!void {
    switch (target) {
        .root => try writer.print(
            "\x1b_Ga=T,f=32,s={d},v={d},i={d},p={d},c={d},r={d}," ++
                "C=1,q=2,o=z,m={d};",
            .{
                frame.width,
                frame.height,
                image_id,
                placement_id,
                columns,
                rows,
                @intFromBool(more),
            },
        ),
        .create_second => try writer.print(
            "\x1b_Ga=f,f=32,s={d},v={d},i={d},X=1,q=2,o=z,m={d};",
            .{ frame.width, frame.height, image_id, @intFromBool(more) },
        ),
        .edit_root, .edit_second => try writer.print(
            "\x1b_Ga=f,f=32,s={d},v={d},i={d},r={d},X=1,q=2,o=z,m={d};",
            .{
                frame.width,
                frame.height,
                image_id,
                target.frameNumber().?,
                @intFromBool(more),
            },
        ),
    }
}

fn terminalSize(fd: std.posix.fd_t) TerminalSize {
    const request: c_int = switch (builtin.os.tag) {
        .linux => 0x5413,
        .macos => 0x4008_7468,
        else => return .{},
    };
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(fd, request, &size) != 0 or size.col == 0 or size.row == 0) return .{};
    return .{ .columns = size.col, .rows = size.row };
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (written < 0) {
            if (std.c.errno(written) == .INTR) continue;
            return error.WriteFailed;
        }
        if (written == 0) return error.WriteFailed;
        offset += @intCast(written);
    }
}

test "scanout conversion crops BGRA rows and composites the cursor" {
    const source = [_]u8{
        0, 0, 0, 0, 10, 20, 30, 0, 40,  50,  60,  0,
        0, 0, 0, 0, 70, 80, 90, 0, 100, 110, 120, 0,
    };
    const cursor = [_]u8{ 200, 100, 50, 255 };
    const scanout: virtio_gpu.Gpu.ScanoutView = .{
        .data = &source,
        .width = 2,
        .height = 2,
        .src_x = 1,
        .src_y = 0,
        .full_width = 3,
        .full_height = 2,
        .generation = 1,
        .cursor = .{
            .data = &cursor,
            .width = 1,
            .height = 1,
            .hot_x = 0,
            .hot_y = 0,
            .x = 1,
            .y = 0,
            .generation = 1,
        },
    };
    var output: [16]u8 = undefined;
    try copyScanoutRgba(&output, scanout);
    try compositeCursorRgba(&output, 2, 2, scanout.cursor.?);
    try std.testing.expectEqualSlices(u8, &.{
        30, 20, 10, 255, 50,  100, 200, 255,
        90, 80, 70, 255, 120, 110, 100, 255,
    }, &output);
}

test "BGRA conversion handles vector chunks and the scalar tail" {
    const pixel_count = (simd.lanes(u32) orelse 4) + 1;
    var source: [pixel_count * 4]u8 = undefined;
    var expected: [pixel_count * 4]u8 = undefined;
    for (0..pixel_count) |pixel| {
        const blue: u8 = @truncate(pixel * 3);
        const green: u8 = @truncate(pixel * 5);
        const red: u8 = @truncate(pixel * 7);
        source[pixel * 4 ..][0..4].* = .{ blue, green, red, 0 };
        expected[pixel * 4 ..][0..4].* = .{ red, green, blue, 0xff };
    }

    var output: [expected.len]u8 = undefined;
    copyBgraRowRgba(&output, &source);
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "scanout conversion rejects invalid buffer geometry" {
    const source_short = [_]u8{ 1, 2, 3 };
    var scanout: virtio_gpu.Gpu.ScanoutView = .{
        .data = &source_short,
        .width = 1,
        .height = 1,
        .src_x = 0,
        .src_y = 0,
        .full_width = 1,
        .full_height = 1,
        .generation = 1,
        .cursor = null,
    };
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidFrame, copyScanoutRgba(&output, scanout));

    const source = [_]u8{ 1, 2, 3, 4 };
    scanout.data = &source;
    try std.testing.expectError(error.InvalidFrame, copyScanoutRgba(output[0..3], scanout));
}

test "root transmission creates one persistent placement" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const payload = [_]u8{0xa5} ** (payload_bytes_max + 1);

    try encodeTransmission(
        &output.writer,
        &payload,
        .{ .width = 640, .height = 480 },
        80,
        24,
        .root,
    );
    const bytes = output.written();
    try std.testing.expect(std.mem.startsWith(
        u8,
        bytes,
        "\x1b_Ga=T,f=32,s=640,v=480",
    ));
    try std.testing.expect(std.mem.indexOf(
        u8,
        bytes,
        "i=1112692301,p=1,c=80,r=24",
    ) != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\x1b_G"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b_Gm=0;") != null);
}

test "animation transmissions create and edit a bounded second frame" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const payload = [_]u8{0xa5} ** (payload_bytes_max + 1);

    try encodeTransmission(
        &output.writer,
        &payload,
        .{ .width = 640, .height = 480 },
        80,
        24,
        .create_second,
    );
    const create = output.written();
    try std.testing.expect(std.mem.startsWith(u8, create, "\x1b_Ga=f,f=32"));
    try std.testing.expect(std.mem.indexOf(u8, create, ",X=1,q=2,o=z") != null);
    try std.testing.expect(std.mem.indexOf(u8, create, "\x1b_Ga=f,m=0;") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        create,
        "\x1b_Ga=a,i=1112692301,c=2,q=2\x1b\\",
    ));

    output.clearRetainingCapacity();
    try encodeTransmission(
        &output.writer,
        payload[0..3],
        .{ .width = 640, .height = 480 },
        80,
        24,
        .edit_root,
    );
    const edit = output.written();
    try std.testing.expect(std.mem.indexOf(u8, edit, ",r=1,X=1,") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        edit,
        "\x1b_Ga=a,i=1112692301,c=1,q=2\x1b\\",
    ));
    try std.testing.expect(std.mem.indexOf(u8, edit, ",p=1,") == null);
}

test "animation state alternates hidden frames and resets after resize" {
    var animation: Animation = .unplaced;
    const frame: Frame = .{ .width = 640, .height = 480 };

    try std.testing.expectEqual(FrameTarget.root, animation.target(frame));
    animation.commit(frame, .root);
    try std.testing.expectEqual(FrameTarget.create_second, animation.target(frame));
    animation.commit(frame, .create_second);
    try std.testing.expectEqual(FrameTarget.edit_root, animation.target(frame));
    animation.commit(frame, .edit_root);
    try std.testing.expectEqual(FrameTarget.edit_second, animation.target(frame));

    const resized: Frame = .{ .width = 800, .height = 600 };
    try std.testing.expectEqual(FrameTarget.root, animation.target(resized));
}

test "frame deadlines include work time without adding it to every interval" {
    const interval = frame_interval_ns;
    try std.testing.expectEqual(interval, nextFrameDeadline(0, 0, interval / 2));
    try std.testing.expectEqual(interval * 2, nextFrameDeadline(interval, interval, interval + 1));
    try std.testing.expectEqual(
        interval * 3,
        nextFrameDeadline(interval, interval, interval * 2),
    );
}
