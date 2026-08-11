//! Linux PCM playback for virtio-snd.
//!
//! The vCPU copies guest periods into a fixed-size ring and never waits for
//! the host sound server. A dedicated thread performs potentially blocking
//! ALSA writes through the desktop's default PCM route.

const Audio = @This();

const std = @import("std");
const global = @import("../global.zig");
const snd = @import("../virtio/snd.zig");

const c = @cImport({
    @cInclude("alsa/asoundlib.h");
});

const ring_bytes: usize = 512 * 1024;
const write_bytes_max: usize = 64 * 1024;
const latency_us: c_uint = 100_000;

allocator: std.mem.Allocator,
pcm: *c.snd_pcm_t,
thread: ?std.Thread = null,
mutex: std.Io.Mutex = .init,
condition: std.Io.Condition = .init,
buffer: []u8,
head: usize = 0,
len: usize = 0,
partial: [snd.FRAME_BYTES]u8 = @splat(0),
partial_len: u8 = 0,
stopping: bool = false,
queued_bytes: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
dropped_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

pub const CreateError = std.mem.Allocator.Error || std.Thread.SpawnError || error{
    OpenFailed,
    ConfigureFailed,
};

pub fn create(allocator: std.mem.Allocator) CreateError!*Audio {
    const self = try allocator.create(Audio);
    errdefer allocator.destroy(self);
    const buffer = try allocator.alloc(u8, ring_bytes);
    errdefer allocator.free(buffer);
    var pcm: ?*c.snd_pcm_t = null;
    if (c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_PLAYBACK, 0) < 0) {
        return error.OpenFailed;
    }
    errdefer _ = c.snd_pcm_close(pcm.?);
    if (c.snd_pcm_set_params(
        pcm.?,
        c.SND_PCM_FORMAT_S16_LE,
        c.SND_PCM_ACCESS_RW_INTERLEAVED,
        snd.CHANNELS,
        snd.SAMPLE_RATE_HZ,
        1,
        latency_us,
    ) < 0) return error.ConfigureFailed;
    self.* = .{
        .allocator = allocator,
        .pcm = pcm.?,
        .buffer = buffer,
    };
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    return self;
}

pub fn destroy(self: *Audio) void {
    self.mutex.lockUncancelable(global.io());
    self.stopping = true;
    self.len = 0;
    self.queued_bytes.store(0, .release);
    self.condition.broadcast(global.io());
    self.mutex.unlock(global.io());
    _ = c.snd_pcm_drop(self.pcm);
    if (self.thread) |thread| thread.join();
    _ = c.snd_pcm_close(self.pcm);
    self.allocator.free(self.buffer);
    self.allocator.destroy(self);
}

pub fn playbackSink(self: *Audio) snd.PlaybackSink {
    return .{
        .on_period = onPeriod,
        .latency_bytes = latencyBytes,
        .userdata = self,
    };
}

pub fn droppedBytes(self: *const Audio) u64 {
    return self.dropped_bytes.load(.acquire);
}

fn onPeriod(data: []const u8, userdata: ?*anyopaque) void {
    const self: *Audio = @ptrCast(@alignCast(userdata orelse return));
    self.enqueue(data);
}

fn latencyBytes(userdata: ?*anyopaque) u32 {
    const self: *Audio = @ptrCast(@alignCast(userdata orelse return 0));
    return self.queued_bytes.load(.acquire);
}

fn enqueue(self: *Audio, data_unaligned: []const u8) void {
    const frame_bytes: usize = snd.FRAME_BYTES;
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.stopping) return;
    var data = data_unaligned;
    if (self.partial_len > 0) {
        const needed = frame_bytes - self.partial_len;
        const take = @min(needed, data.len);
        @memcpy(self.partial[self.partial_len..][0..take], data[0..take]);
        self.partial_len += @intCast(take);
        data = data[take..];
        if (self.partial_len < frame_bytes) return;
        self.enqueueAligned(&self.partial);
        self.partial_len = 0;
    }
    const aligned_len = data.len / frame_bytes * frame_bytes;
    self.enqueueAligned(data[0..aligned_len]);
    const remainder = data[aligned_len..];
    @memcpy(self.partial[0..remainder.len], remainder);
    self.partial_len = @intCast(remainder.len);
}

fn enqueueAligned(self: *Audio, data_unbounded: []const u8) void {
    var data = data_unbounded;
    if (data.len == 0) return;
    if (data.len > self.buffer.len) data = data[data.len - self.buffer.len ..];
    const overflow = if (data.len > self.buffer.len - self.len)
        data.len - (self.buffer.len - self.len)
    else
        0;
    if (overflow > 0) {
        self.head = (self.head + overflow) % self.buffer.len;
        self.len -= overflow;
        _ = self.dropped_bytes.fetchAdd(overflow, .monotonic);
    }
    const tail = (self.head + self.len) % self.buffer.len;
    const first = @min(data.len, self.buffer.len - tail);
    @memcpy(self.buffer[tail..][0..first], data[0..first]);
    @memcpy(self.buffer[0 .. data.len - first], data[first..]);
    self.len += data.len;
    self.queued_bytes.store(@intCast(self.len), .release);
    self.condition.signal(global.io());
}

fn threadMain(self: *Audio) void {
    var bytes: [write_bytes_max]u8 align(@alignOf(i16)) = undefined;
    while (self.dequeue(&bytes)) |count| self.write(bytes[0..count]);
}

fn dequeue(self: *Audio, destination: []u8) ?usize {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    while (self.len == 0 and !self.stopping) {
        self.condition.waitUncancelable(global.io(), &self.mutex);
    }
    if (self.stopping) return null;
    const count = @min(destination.len, self.len);
    const first = @min(count, self.buffer.len - self.head);
    @memcpy(destination[0..first], self.buffer[self.head..][0..first]);
    @memcpy(destination[first..count], self.buffer[0 .. count - first]);
    self.head = (self.head + count) % self.buffer.len;
    self.len -= count;
    self.queued_bytes.store(@intCast(self.len), .release);
    return count;
}

fn write(self: *Audio, bytes: []const u8) void {
    const frame_bytes: usize = snd.FRAME_BYTES;
    var frames_written: usize = 0;
    const frames_total = bytes.len / frame_bytes;
    while (frames_written < frames_total and !self.isStopping()) {
        const result = c.snd_pcm_writei(
            self.pcm,
            bytes.ptr + frames_written * frame_bytes,
            frames_total - frames_written,
        );
        if (result < 0) {
            if (c.snd_pcm_recover(self.pcm, @intCast(result), 1) < 0) {
                _ = self.dropped_bytes.fetchAdd(
                    (frames_total - frames_written) * frame_bytes,
                    .monotonic,
                );
                return;
            }
            continue;
        }
        if (result == 0) return;
        frames_written += @intCast(result);
    }
}

fn isStopping(self: *Audio) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    return self.stopping;
}

comptime {
    std.debug.assert(ring_bytes % snd.FRAME_BYTES == 0);
    std.debug.assert(write_bytes_max % snd.FRAME_BYTES == 0);
}
