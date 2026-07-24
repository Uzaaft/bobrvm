//! Virtio 9P Transport Device.
//!
//! Exposes one shared host directory via 9P2000.L (virtio device id 9,
//! per virtio 1.2 section 5.9). One request queue: each descriptor chain
//! carries a readable T-message followed by writable space for the
//! R-message; both sides may scatter across descriptors, so requests are
//! gathered into (and responses scattered from) msize-sized bounce
//! buffers. Protocol logic lives in src/fs/p9.zig.
//!
//! Guest mount: mount -t 9p -o trans=virtio,version=9p2000.L <tag> /mnt

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");
const p9 = @import("../fs/p9.zig");

const log = std.log.scoped(.virtio_p9);

/// VIRTIO_9P_MOUNT_TAG: the config space carries the mount tag.
const FEATURE_MOUNT_TAG: u64 = 1 << 0;

pub const P9 = struct {
    alloc: Allocator,
    transport: *mmio.Transport,
    server: p9.P9Server,
    /// Mount tag the guest uses to identify the export.
    tag: []u8,
    last_avail: u16 = 0,

    /// Bounce buffers (guest messages may scatter across descriptors).
    req_buf: []u8,
    resp_buf: []u8,

    /// Guest memory accessor.
    guest_memory: ?ring.GetMemFn = null,

    pub fn init(alloc: Allocator, tag: []const u8, root_path: []const u8) !*P9 {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        const transport = try mmio.Transport.init(alloc, 9, virtio_version_1 | FEATURE_MOUNT_TAG, 1);
        errdefer transport.deinit();

        var server = try p9.P9Server.init(alloc, root_path);
        errdefer server.deinit();

        const owned_tag = try alloc.dupe(u8, tag);
        errdefer alloc.free(owned_tag);
        const req_buf = try alloc.alloc(u8, p9.MSIZE_MAX);
        errdefer alloc.free(req_buf);
        const resp_buf = try alloc.alloc(u8, p9.MSIZE_MAX);
        errdefer alloc.free(resp_buf);

        const dev = try alloc.create(P9);
        dev.* = .{
            .alloc = alloc,
            .transport = transport,
            .server = server,
            .tag = owned_tag,
            .req_buf = req_buf,
            .resp_buf = resp_buf,
        };
        transport.setNotifyCallback(handleNotify, dev);

        assert(dev.transport.device_id == 9);
        return dev;
    }

    pub fn deinit(self: *P9) void {
        self.server.deinit();
        self.alloc.free(self.tag);
        self.alloc.free(self.req_buf);
        self.alloc.free(self.resp_buf);
        self.transport.deinit();
        self.alloc.destroy(self);
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(self: *P9, accessor: ring.GetMemFn) void {
        self.guest_memory = accessor;
    }

    /// Handle MMIO read.
    pub fn read(self: *P9, offset: u12) u32 {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    /// Handle MMIO write.
    pub fn write(self: *P9, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) return;
        self.transport.write(offset, value);
    }

    /// Config space: tag_len (u16) followed by the tag bytes.
    fn readConfig(self: *P9, offset: u12) u32 {
        var out: [4]u8 = .{ 0, 0, 0, 0 };
        for (&out, 0..) |*byte, i| {
            const pos = offset + i;
            if (pos < 2) {
                const len: u16 = @intCast(self.tag.len);
                byte.* = if (pos == 0) @truncate(len) else @truncate(len >> 8);
            } else if (pos - 2 < self.tag.len) {
                byte.* = self.tag[pos - 2];
            }
        }
        return std.mem.readInt(u32, &out, .little);
    }

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *P9 = @ptrCast(@alignCast(userdata));
        if (queue_idx == 0) self.processQueue();
    }

    fn processQueue(self: *P9) void {
        const qc = self.transport.queues[0];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        while (self.last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.last_avail, get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);

            // Gather the readable T-message.
            var req_len: usize = 0;
            for (chain.slice()) |desc| {
                if (desc.isWrite()) continue;
                const data = get_mem(desc.addr, desc.len) orelse continue;
                const n = @min(data.len, self.req_buf.len - req_len);
                @memcpy(self.req_buf[req_len..][0..n], data[0..n]);
                req_len += n;
            }

            var written: u32 = 0;
            if (req_len >= 7) {
                const resp_len = self.server.handle(self.req_buf[0..req_len], self.resp_buf);
                // Scatter the R-message into the writable descriptors.
                var off: usize = 0;
                for (chain.slice()) |desc| {
                    if (!desc.isWrite()) continue;
                    if (off >= resp_len) break;
                    const data = get_mem(desc.addr, desc.len) orelse continue;
                    const n = @min(data.len, resp_len - off);
                    @memcpy(data[0..n], self.resp_buf[off..][0..n]);
                    off += n;
                }
                written = @intCast(off);
            }

            ring.pushUsed(qc, head, written, get_mem);
            self.last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Get MMIO region size.
    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "P9 device: identity, mount tag config, and a version exchange" {
    const io = @import("../global.zig").io();
    const root = ".zig-cache/p9-dev-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const dev = try P9.init(testing.allocator, "host", root);
    defer dev.deinit();

    try testing.expectEqual(@as(u32, 9), dev.read(@intFromEnum(mmio.Reg.device_id)));
    try testing.expect(dev.transport.device_features & FEATURE_MOUNT_TAG != 0);
    // Config: tag_len=4 then "host".
    const w0 = dev.read(@intFromEnum(mmio.Reg.config));
    try testing.expectEqual(@as(u32, 4), w0 & 0xFFFF); // tag_len
    try testing.expectEqual(@as(u8, 'h'), @as(u8, @truncate(w0 >> 16)));
    try testing.expectEqual(@as(u8, 'o'), @as(u8, @truncate(w0 >> 24)));
    const w1 = dev.read(@intFromEnum(mmio.Reg.config) + 4);
    try testing.expectEqual(@as(u8, 's'), @as(u8, @truncate(w1)));
    try testing.expectEqual(@as(u8, 't'), @as(u8, @truncate(w1 >> 8)));

    // Drive a TVERSION through the queue with synthetic guest memory.
    const Ctx = struct {
        var mem: [8192]u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr + len > mem.len) return null;
            return mem[@intCast(addr)..][0..len];
        }
    };
    @memset(&Ctx.mem, 0);
    dev.setGuestMemory(Ctx.get);

    // T-message at 0x800: TVERSION msize=8192 "9P2000.L"
    const tv = Ctx.mem[0x800..];
    std.mem.writeInt(u32, tv[0..4], 7 + 4 + 2 + 8, .little);
    tv[4] = p9.Tversion;
    std.mem.writeInt(u16, tv[5..7], 0xFFFF, .little);
    std.mem.writeInt(u32, tv[7..11], 8192, .little);
    std.mem.writeInt(u16, tv[11..13], 8, .little);
    @memcpy(tv[13..21], "9P2000.L");

    // Descriptors: 0 = readable T at 0x800 (21 bytes), 1 = writable R at 0xA00.
    const d0 = Ctx.mem[0x100..][0..16];
    std.mem.writeInt(u64, d0[0..8], 0x800, .little);
    std.mem.writeInt(u32, d0[8..12], 21, .little);
    std.mem.writeInt(u16, d0[12..14], ring.Desc.F_NEXT, .little);
    std.mem.writeInt(u16, d0[14..16], 1, .little);
    const d1 = Ctx.mem[0x110..][0..16];
    std.mem.writeInt(u64, d1[0..8], 0xA00, .little);
    std.mem.writeInt(u32, d1[8..12], 256, .little);
    std.mem.writeInt(u16, d1[12..14], ring.Desc.F_WRITE, .little);

    // Avail ring at 0x200: idx=1, ring[0]=0. Used at 0x300.
    std.mem.writeInt(u16, Ctx.mem[0x200..][2..4], 1, .little);
    std.mem.writeInt(u16, Ctx.mem[0x200..][4..6], 0, .little);
    dev.transport.queues[0] = .{
        .num = 8,
        .ready = true,
        .desc_addr = 0x100,
        .driver_addr = 0x200,
        .device_addr = 0x300,
    };

    dev.write(@intFromEnum(mmio.Reg.queue_notify), 0);

    // RVERSION landed in the writable buffer.
    const resp = Ctx.mem[0xA00..];
    try testing.expectEqual(p9.Tversion + 1, resp[4]);
    try testing.expectEqualStrings("9P2000.L", resp[13..21]);
    try testing.expect(dev.transport.interrupt_status.used_buffer);
}
