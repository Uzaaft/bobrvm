//! Virtio Memory Balloon Device (virtio-balloon).
//!
//! Implements virtio-balloon per virtio 1.2 section 5.5: the guest hands
//! the host pages it isn't using (inflate) and reclaims them later
//! (deflate). On macOS the host "frees" an inflated guest page with
//! madvise(ptr, len, MADV_FREE), so the physical page is released back to
//! the OS while the mapping stays valid and the page faults back in on the
//! guest's next access.
//!
//! Two queues, no stats: inflateq = 0, deflateq = 1. Each buffer is an
//! array of little-endian u32 PFNs; guest_phys = pfn << PFN_SHIFT.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");

const log = std.log.scoped(.virtio_balloon);

// Darwin libc (zig 0.16's std.c doesn't expose madvise cleanly for macOS).
// MADV_FREE = 5 on Darwin: mark the pages reclaimable without unmapping.
const MADV_FREE: c_int = 5;
extern "c" fn madvise(addr: *anyopaque, len: usize, advice: c_int) c_int;

/// Balloon page shift: pages are always 4 KiB regardless of host page size.
pub const PFN_SHIFT: u6 = 12;
pub const BALLOON_PAGE_SIZE: usize = 1 << PFN_SHIFT;

pub const Balloon = struct {
    alloc: Allocator,
    transport: mmio.Transport,
    transport_queues: [2]mmio.QueueConfig,
    /// Per-queue avail cursor: [inflateq, deflateq].
    last_avail: [2]u16,
    config: Config,

    /// Guest memory accessor.
    guest_memory: ?ring.GetMemFn,

    /// Device configuration space (virtio 1.2 section 5.5.4). Both fields
    /// little-endian; on arm64 macOS native layout already matches.
    pub const Config = extern struct {
        /// Target balloon size in 4 KiB pages (pages the host wants).
        num_pages: u32 = 0,
        /// Pages currently in the balloon.
        actual: u32 = 0,
    };

    pub const Error = Allocator.Error;

    pub fn init(alloc: Allocator) Error!*Balloon {
        // VIRTIO_F_VERSION_1 (bit 32) only; no MUST_TELL_HOST / DEFLATE_ON_OOM
        // / STATS_VQ, so exactly two queues.
        const virtio_version_1: u64 = 1 << 32;
        const balloon = try alloc.create(Balloon);
        errdefer alloc.destroy(balloon);
        balloon.* = .{
            .alloc = alloc,
            .transport = undefined,
            .transport_queues = undefined,
            .last_avail = .{ 0, 0 },
            .config = .{},
            .guest_memory = null,
        };

        balloon.transport.initEmbedded(5, virtio_version_1, &balloon.transport_queues);
        balloon.transport.setNotifyCallback(mmio.bindNotify(Balloon, balloon, handleNotify));

        assert(balloon.transport.device_id == 5);
        return balloon;
    }

    pub fn deinit(self: *Balloon) void {
        self.alloc.destroy(self);
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(self: *Balloon, accessor: ring.GetMemFn) void {
        self.guest_memory = accessor;
    }

    pub fn setIrqCallback(self: *Balloon, irq: mmio.Irq) void {
        self.transport.setIrqCallback(irq);
    }

    /// Set the target balloon size (in 4 KiB pages) and notify the guest via
    /// a config-change interrupt. The guest driver reacts by inflating or
    /// deflating until config.actual reaches config.num_pages.
    pub fn setTarget(self: *Balloon, pages: u32) void {
        self.config.num_pages = pages;
        self.transport.signalConfigChange();
    }

    /// Handle MMIO read.
    pub fn read(self: *Balloon, offset: u12) u32 {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    /// Handle MMIO write.
    pub fn write(self: *Balloon, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            // Config space is host-managed here (we maintain `actual`
            // ourselves as buffers are processed), so guest config writes
            // are ignored.
            return;
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Balloon, offset: u12) u32 {
        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        return 0;
    }

    fn handleNotify(self: *Balloon, queue_idx: u32) void {
        switch (queue_idx) {
            0 => self.processQueue(0, true), // inflateq
            1 => self.processQueue(1, false), // deflateq
            else => {},
        }
    }

    /// Process one balloon queue. `inflate` selects whether posted PFNs are
    /// handed to the host (madvise MADV_FREE, actual++) or reclaimed by the
    /// guest (actual--). Purely notify-driven, on the vCPU thread.
    fn processQueue(self: *Balloon, queue_idx: u8, inflate: bool) void {
        const qc = self.transport.queues[queue_idx];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        while (self.last_avail[queue_idx] != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.last_avail[queue_idx], get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);
            for (chain.slice()) |desc| {
                // PFN arrays are device-readable buffers.
                if (desc.isWrite()) continue;
                const buf = get_mem(desc.addr, desc.len) orelse continue;
                self.processPfns(buf, inflate, get_mem);
            }
            // Balloon used entries carry no written length.
            ring.pushUsed(qc, head, 0, get_mem);
            self.last_avail[queue_idx] +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Walk a buffer of little-endian u32 PFNs, applying inflate/deflate.
    fn processPfns(self: *Balloon, buf: []const u8, inflate: bool, get_mem: ring.GetMemFn) void {
        const count = buf.len / 4;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const pfn = std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
            if (inflate) {
                const guest_phys = @as(u64, pfn) << PFN_SHIFT;
                if (get_mem(guest_phys, BALLOON_PAGE_SIZE)) |page| {
                    // Release the physical page back to the OS. Best-effort:
                    // a failure (e.g. an unaligned host mapping in a test)
                    // must not disturb the accounting path.
                    _ = madvise(@ptrCast(page.ptr), BALLOON_PAGE_SIZE, MADV_FREE);
                }
                self.config.actual +%= 1;
            } else {
                // Deflate: the guest reclaims the page; it faults back in
                // naturally on next access, nothing to un-advise.
                if (self.config.actual > 0) self.config.actual -= 1;
            }
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

test "Balloon init and identity" {
    const balloon = try Balloon.init(testing.allocator);
    defer balloon.deinit();

    try testing.expectEqual(mmio.MAGIC, balloon.read(@intFromEnum(mmio.Reg.magic)));
    try testing.expectEqual(@as(u32, 5), balloon.read(@intFromEnum(mmio.Reg.device_id)));

    // VIRTIO_F_VERSION_1 (bit 32) advertised, nothing else.
    balloon.write(@intFromEnum(mmio.Reg.device_features_sel), 1);
    try testing.expectEqual(@as(u32, 1), balloon.read(@intFromEnum(mmio.Reg.device_features)));
    balloon.write(@intFromEnum(mmio.Reg.device_features_sel), 0);
    try testing.expectEqual(@as(u32, 0), balloon.read(@intFromEnum(mmio.Reg.device_features)));
}

test "Balloon config round-trip and setTarget raises config-change" {
    const balloon = try Balloon.init(testing.allocator);
    defer balloon.deinit();

    const cfg = @intFromEnum(mmio.Reg.config);
    // num_pages at offset 0, actual at offset 4.
    balloon.config.num_pages = 0x1234;
    balloon.config.actual = 0x5678;
    try testing.expectEqual(@as(u32, 0x1234), balloon.read(cfg + 0));
    try testing.expectEqual(@as(u32, 0x5678), balloon.read(cfg + 4));

    const gen_before = balloon.transport.config_generation;
    balloon.setTarget(0x40);
    try testing.expectEqual(@as(u32, 0x40), balloon.read(cfg + 0));
    try testing.expect(balloon.transport.interrupt_status.config_change);
    try testing.expectEqual(gen_before +% 1, balloon.transport.config_generation);
}

// Aligned fake guest RAM for the inflate/deflate tests: madvise needs a
// page-aligned address, so back guest memory with a page-aligned mmap. The
// virtqueue structures live in the first page; the balloon page(s) follow.
const FakeRam = struct {
    var region: []align(std.heap.page_size_min) u8 = &.{};

    fn get(addr: u64, len: usize) ?[]u8 {
        if (addr + len > region.len) return null;
        return region[@intCast(addr)..][0..len];
    }
};

test "Balloon inflate advances actual, used ring, and keeps pages readable" {
    const balloon = try Balloon.init(testing.allocator);
    defer balloon.deinit();

    // 4 pages of aligned guest RAM.
    FakeRam.region = try std.posix.mmap(
        null,
        4 * BALLOON_PAGE_SIZE,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(FakeRam.region);
    @memset(FakeRam.region, 0); // zero the virtqueue structures
    // Pattern the pages we'll inflate (guest pages 2 and 3).
    @memset(FakeRam.region[0x2000..0x4000], 0xAB);
    balloon.setGuestMemory(FakeRam.get);

    // Virtqueue layout in page 0: desc table @0x100, avail @0x200,
    // used @0x300, PFN buffer @0x400.
    // PFN buffer holds two PFNs pointing at guest pages 2 and 3.
    const pfn_buf = FakeRam.region[0x400..][0..8];
    std.mem.writeInt(u32, pfn_buf[0..4], 2, .little); // guest_phys 0x2000
    std.mem.writeInt(u32, pfn_buf[4..8], 3, .little); // guest_phys 0x3000

    // One device-readable descriptor covering the PFN buffer.
    const desc = FakeRam.region[0x100..][0..16];
    std.mem.writeInt(u64, desc[0..8], 0x400, .little); // addr
    std.mem.writeInt(u32, desc[8..12], 8, .little); // len (2 PFNs)
    std.mem.writeInt(u16, desc[12..14], 0, .little); // flags: readable
    // Avail ring: idx=1, ring[0]=0.
    std.mem.writeInt(u16, FakeRam.region[0x200..][2..4], 1, .little);
    std.mem.writeInt(u16, FakeRam.region[0x200..][4..6], 0, .little);

    balloon.transport.queues[0] = .{
        .num = 4,
        .ready = true,
        .desc_addr = 0x100,
        .driver_addr = 0x200,
        .device_addr = 0x300,
    };

    balloon.write(@intFromEnum(mmio.Reg.queue_notify), 0);

    // Accounting advanced by two pages.
    try testing.expectEqual(@as(u32, 2), balloon.config.actual);
    // Used ring advanced.
    const used_idx = std.mem.readInt(u16, FakeRam.region[0x300..][2..4], .little);
    try testing.expectEqual(@as(u16, 1), used_idx);
    try testing.expect(balloon.transport.interrupt_status.used_buffer);

    // MADV_FREE does not unmap: the pages remain readable. (The kernel may
    // have zeroed them, so we only assert the read is valid, not its value.)
    const page2 = FakeRam.region[0x2000..][0..BALLOON_PAGE_SIZE];
    var sink: usize = 0;
    for (page2) |b| sink +%= b;
    try testing.expect(sink == sink);
}

test "Balloon deflate decrements actual" {
    const balloon = try Balloon.init(testing.allocator);
    defer balloon.deinit();

    FakeRam.region = try std.posix.mmap(
        null,
        4 * BALLOON_PAGE_SIZE,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(FakeRam.region);
    @memset(FakeRam.region, 0);
    balloon.setGuestMemory(FakeRam.get);

    // Start with three pages already in the balloon.
    balloon.config.actual = 3;

    // Two PFNs on the deflate queue.
    const pfn_buf = FakeRam.region[0x400..][0..8];
    std.mem.writeInt(u32, pfn_buf[0..4], 2, .little);
    std.mem.writeInt(u32, pfn_buf[4..8], 3, .little);

    const desc = FakeRam.region[0x100..][0..16];
    std.mem.writeInt(u64, desc[0..8], 0x400, .little);
    std.mem.writeInt(u32, desc[8..12], 8, .little);
    std.mem.writeInt(u16, desc[12..14], 0, .little);
    std.mem.writeInt(u16, FakeRam.region[0x200..][2..4], 1, .little);
    std.mem.writeInt(u16, FakeRam.region[0x200..][4..6], 0, .little);

    balloon.transport.queues[1] = .{
        .num = 4,
        .ready = true,
        .desc_addr = 0x100,
        .driver_addr = 0x200,
        .device_addr = 0x300,
    };

    balloon.write(@intFromEnum(mmio.Reg.queue_notify), 1);

    // Two pages reclaimed: 3 - 2 = 1.
    try testing.expectEqual(@as(u32, 1), balloon.config.actual);
    const used_idx = std.mem.readInt(u16, FakeRam.region[0x300..][2..4], .little);
    try testing.expectEqual(@as(u16, 1), used_idx);
}
