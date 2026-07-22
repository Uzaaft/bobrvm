const std = @import("std");

// 1920x1080 XRGB, backing fragmented into 4KB page entries (the real
// guest layout): row-by-row rescans the entry list per row, fast path
// scans it once.
const W = 1920;
const H = 1080;
const BPP = 4;
const stride: u64 = W * BPP;
const total: usize = W * H * BPP;
const PAGE = 4096;

const Entry = struct { addr: u64, length: u32 };

var guest: []u8 = undefined;
var host: []u8 = undefined;
var entries: []Entry = undefined;
var sink: u64 = 0;

fn copyFromBacking(offset: u64, dst: []u8) void {
    var remaining = dst;
    var skip = offset;
    for (entries) |e| {
        if (remaining.len == 0) break;
        if (skip >= e.length) { skip -= e.length; continue; }
        const avail = e.length - @as(u32, @intCast(skip));
        const n: usize = @min(remaining.len, avail);
        @memcpy(remaining[0..n], guest[@intCast(e.addr + skip)..][0..n]);
        remaining = remaining[n..];
        skip = 0;
    }
}

fn rowByRow() void {
    var row: u64 = 0;
    while (row < H) : (row += 1) {
        const off = row * stride;
        copyFromBacking(off, host[@intCast(off)..][0..stride]);
    }
}

fn fastPath() void {
    copyFromBacking(0, host[0..total]);
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    guest = try a.alloc(u8, total);
    host = try a.alloc(u8, total);
    const n_pages = (total + PAGE - 1) / PAGE;
    entries = try a.alloc(Entry, n_pages);
    for (entries, 0..) |*e, i| e.* = .{ .addr = @intCast(i * PAGE), .length = PAGE };
    for (guest, 0..) |*b, i| b.* = @truncate(i);

    var timer = try std.time.Timer.start();
    const iters = 300;

    timer.reset();
    for (0..iters) |_| { rowByRow(); sink +%= host[total - 1]; }
    const t_row = timer.read();

    timer.reset();
    for (0..iters) |_| { fastPath(); sink +%= host[total - 1]; }
    const t_fast = timer.read();

    std.debug.print("1920x1080 XRGB, {} 4KB entries, {} iters (sink={}):\n", .{ n_pages, iters, sink });
    std.debug.print("  row-by-row: {d:.3} ms/frame\n", .{@as(f64, @floatFromInt(t_row)) / iters / 1e6});
    std.debug.print("  fast-path:  {d:.3} ms/frame\n", .{@as(f64, @floatFromInt(t_fast)) / iters / 1e6});
    std.debug.print("  speedup:    {d:.2}x\n", .{@as(f64, @floatFromInt(t_row)) / @as(f64, @floatFromInt(t_fast))});
}
