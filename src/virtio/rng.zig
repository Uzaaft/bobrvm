//! Virtio Entropy Device (virtio-rng).
//!
//! Implements virtio-rng per virtio 1.2 section 5.4: the guest posts
//! device-writable buffers on a single request queue and the device
//! fills them completely with random bytes. Backing entropy comes from
//! the host kernel CSPRNG (getentropy), so the guest's entropy pool is
//! seeded instantly at boot instead of waiting on interrupt timing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const GuestMemory = @import("../guest_memory.zig").GuestMemory;
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");

// Darwin libc (zig 0.16's std.c doesn't expose it for macOS). Caps each
// call at 256 bytes, hence the fill loop below.
extern "c" fn getentropy(buf: [*]u8, len: usize) c_int;

/// Fill a buffer from the host kernel CSPRNG.
fn fillEntropy(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const chunk = @min(buf.len - off, 256);
        if (getentropy(buf.ptr + off, chunk) != 0) {
            // getentropy only fails on bad args; never hand the guest
            // uninitialized bytes regardless.
            @memset(buf[off..], 0);
            return;
        }
        off += chunk;
    }
}

const log = std.log.scoped(.virtio_rng);

pub const Rng = struct {
    alloc: Allocator,
    transport: mmio.Transport,
    transport_queues: [1]mmio.QueueConfig,
    last_avail: u16,

    /// Guest memory accessor.
    guest_memory: ?GuestMemory,

    pub const Error = Allocator.Error;

    pub fn init(alloc: Allocator) Error!*Rng {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        const rng = try alloc.create(Rng);
        errdefer alloc.destroy(rng);
        rng.* = .{
            .alloc = alloc,
            .transport = undefined,
            .transport_queues = undefined,
            .last_avail = 0,
            .guest_memory = null,
        };

        rng.transport.initEmbedded(4, virtio_version_1, &rng.transport_queues);
        rng.transport.setNotifyCallback(mmio.bindNotify(Rng, rng, handleNotify));

        assert(rng.transport.device_id == 4);
        return rng;
    }

    pub fn deinit(self: *Rng) void {
        self.alloc.destroy(self);
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(self: *Rng, accessor: anytype) void {
        self.guest_memory = switch (@typeInfo(@TypeOf(accessor))) {
            .@"fn", .pointer => GuestMemory.bindGlobal(accessor),
            .@"struct" => accessor,
            else => @compileError("unsupported guest-memory accessor"),
        };
    }

    pub fn setIrqCallback(self: *Rng, irq: mmio.Irq) void {
        self.transport.setIrqCallback(irq);
    }

    /// Handle MMIO read.
    pub fn read(self: *Rng, offset: u12) u32 {
        // No config space.
        if (offset >= @intFromEnum(mmio.Reg.config)) return 0;
        return self.transport.read(offset);
    }

    /// Handle MMIO write.
    pub fn write(self: *Rng, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) return;
        self.transport.write(offset, value);
    }

    fn handleNotify(self: *Rng, queue_idx: u32) void {
        if (queue_idx == 0) self.processQueue();
    }

    /// Fill every posted buffer with random bytes. Purely notify-driven:
    /// the guest hwrng core kicks when it wants entropy.
    fn processQueue(self: *Rng) void {
        const qc = self.transport.queues[0];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        while (self.last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.last_avail, get_mem) orelse break;
            const chain = ring.Chain.collect(qc, head, get_mem);
            var written: u32 = 0;
            for (chain.slice()) |desc| {
                if (!desc.isWrite()) continue;
                const buf = get_mem.get(desc.addr, desc.len) orelse continue;
                fillEntropy(buf);
                written += @intCast(buf.len);
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

test "Rng init and identity" {
    const rng = try Rng.init(testing.allocator);
    defer rng.deinit();

    try testing.expectEqual(mmio.MAGIC, rng.read(@intFromEnum(mmio.Reg.magic)));
    try testing.expectEqual(@as(u32, 4), rng.read(@intFromEnum(mmio.Reg.device_id)));
}

test "Rng fills posted buffers with entropy" {
    const rng = try Rng.init(testing.allocator);
    defer rng.deinit();

    // Synthetic guest memory: descriptor table at 0x100, avail at 0x200,
    // used at 0x300, data buffer at 0x400.
    const Ctx = struct {
        var mem: [4096]u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr + len > mem.len) return null;
            return mem[@intCast(addr)..][0..len];
        }
    };
    @memset(&Ctx.mem, 0);
    rng.setGuestMemory(Ctx.get);

    // One writable 64-byte descriptor at index 0.
    const desc = Ctx.mem[0x100..][0..16];
    std.mem.writeInt(u64, desc[0..8], 0x400, .little); // addr
    std.mem.writeInt(u32, desc[8..12], 64, .little); // len
    std.mem.writeInt(u16, desc[12..14], ring.Desc.F_WRITE, .little);
    // Avail ring: idx=1, ring[0]=0.
    std.mem.writeInt(u16, Ctx.mem[0x200..][2..4], 1, .little);
    std.mem.writeInt(u16, Ctx.mem[0x200..][4..6], 0, .little);

    // Configure and mark the queue ready.
    rng.transport.queues[0] = .{
        .num = 4,
        .ready = true,
        .desc_addr = 0x100,
        .driver_addr = 0x200,
        .device_addr = 0x300,
    };
    rng.write(@intFromEnum(mmio.Reg.status), 0x0C);

    rng.write(@intFromEnum(mmio.Reg.queue_notify), 0);

    // Used ring advanced and reports the full buffer length.
    const used_idx = std.mem.readInt(u16, Ctx.mem[0x300..][2..4], .little);
    try testing.expectEqual(@as(u16, 1), used_idx);
    const used_len = std.mem.readInt(u32, Ctx.mem[0x300..][8..12], .little);
    try testing.expectEqual(@as(u32, 64), used_len);
    // Buffer no longer all-zero (2^-512 false-failure odds).
    var nonzero = false;
    for (Ctx.mem[0x400..][0..64]) |b| {
        if (b != 0) nonzero = true;
    }
    try testing.expect(nonzero);
    try testing.expect(rng.transport.interrupt_status.used_buffer);
}
