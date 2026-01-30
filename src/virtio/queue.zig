//! Virtqueue implementation.
//!
//! Implements split virtqueue layout per virtio 1.2 spec section 2.7.
//! The virtqueue is a lock-free ring buffer for guest↔host communication.
//!
//! Memory layout (split virtqueue):
//!   Descriptor Table: 16 bytes × queue_size
//!   Available Ring: 6 + 2 × queue_size bytes
//!   Used Ring: 6 + 8 × queue_size bytes

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

/// Virtqueue descriptor flags.
pub const DescFlags = packed struct(u16) {
    /// Buffer continues via next field.
    next: bool = false,
    /// Buffer is write-only (device writes, driver reads).
    write: bool = false,
    /// Buffer contains indirect descriptor table.
    indirect: bool = false,
    _padding: u13 = 0,
};

/// Virtqueue descriptor (16 bytes).
pub const Desc = extern struct {
    /// Guest physical address of buffer.
    addr: u64,
    /// Length of buffer in bytes.
    len: u32,
    /// Descriptor flags.
    flags: DescFlags,
    /// Next descriptor index (if NEXT flag set).
    next: u16,
};

/// Available ring header.
pub const AvailRingHeader = extern struct {
    flags: u16,
    idx: u16,
};

/// Used ring element.
pub const UsedElem = extern struct {
    /// Descriptor chain head index.
    id: u32,
    /// Total bytes written to descriptor chain.
    len: u32,
};

/// Used ring header.
pub const UsedRingHeader = extern struct {
    flags: u16,
    idx: u16,
};

/// Available ring flags.
pub const AvailFlags = packed struct(u16) {
    no_interrupt: bool = false,
    _padding: u15 = 0,
};

/// Used ring flags.
pub const UsedFlags = packed struct(u16) {
    no_notify: bool = false,
    _padding: u15 = 0,
};

/// Descriptor chain iterator.
pub const DescChain = struct {
    queue: *VirtQueue,
    current: ?u16,
    count: u16,
    max_count: u16,

    /// Get current descriptor.
    pub fn current_desc(self: *DescChain) ?*const Desc {
        const idx = self.current orelse return null;
        if (idx >= self.queue.size) return null;
        return &self.queue.desc[idx];
    }

    /// Advance to next descriptor in chain.
    pub fn next(self: *DescChain) bool {
        const desc = self.current_desc() orelse return false;

        if (desc.flags.next and self.count < self.max_count) {
            self.current = desc.next;
            self.count += 1;
            return true;
        }

        self.current = null;
        return false;
    }

    /// Check if current buffer is device-writable.
    pub fn isWritable(self: *DescChain) bool {
        const desc = self.current_desc() orelse return false;
        return desc.flags.write;
    }
};

/// Virtqueue.
pub const VirtQueue = struct {
    alloc: Allocator,

    /// Queue size (power of 2, max 32768).
    size: u16,

    /// Descriptor table (host-allocated for testing, guest-mapped in real use).
    desc: []Desc,

    /// Available ring index (written by guest).
    avail_idx: u16,

    /// Used ring index (written by host).
    used_idx: u16,

    /// Last seen available index.
    last_avail_idx: u16,

    /// Used elements buffer.
    used_ring: []UsedElem,

    /// Signaling state.
    needs_notification: bool,

    pub const InitError = Allocator.Error;

    /// Initialize a host-managed virtqueue (for testing).
    pub fn init(alloc: Allocator, size: u16) InitError!VirtQueue {
        // Pre-conditions
        assert(size > 0);
        assert(size <= 32768);
        assert(std.math.isPowerOfTwo(size));

        const desc = try alloc.alloc(Desc, size);
        errdefer alloc.free(desc);

        const used_ring = try alloc.alloc(UsedElem, size);
        errdefer alloc.free(used_ring);

        // Initialize descriptors
        for (desc, 0..) |*d, i| {
            d.* = .{
                .addr = 0,
                .len = 0,
                .flags = .{},
                .next = if (i + 1 < size) @intCast(i + 1) else 0,
            };
        }

        @memset(used_ring, UsedElem{ .id = 0, .len = 0 });

        // Post-conditions
        assert(desc.len == size);
        assert(used_ring.len == size);

        return .{
            .alloc = alloc,
            .size = size,
            .desc = desc,
            .avail_idx = 0,
            .used_idx = 0,
            .last_avail_idx = 0,
            .used_ring = used_ring,
            .needs_notification = true,
        };
    }

    pub fn deinit(self: *VirtQueue) void {
        self.alloc.free(self.used_ring);
        self.alloc.free(self.desc);
    }

    /// Check if queue has pending buffers.
    pub fn hasPending(self: *const VirtQueue) bool {
        return self.last_avail_idx != self.avail_idx;
    }

    /// Get number of pending buffers.
    pub fn pendingCount(self: *const VirtQueue) u16 {
        return self.avail_idx -% self.last_avail_idx;
    }

    /// Pop a descriptor chain from the available ring.
    /// Returns the head descriptor index.
    pub fn pop(self: *VirtQueue) ?u16 {
        if (!self.hasPending()) return null;

        const idx = self.last_avail_idx % self.size;
        self.last_avail_idx +%= 1;
        return idx;
    }

    /// Get a descriptor chain iterator starting at head.
    pub fn getChain(self: *VirtQueue, head: u16) DescChain {
        return .{
            .queue = self,
            .current = head,
            .count = 0,
            .max_count = self.size, // Prevent infinite loops
        };
    }

    /// Push a used descriptor chain.
    pub fn pushUsed(self: *VirtQueue, head: u16, len: u32) void {
        const idx = self.used_idx % self.size;
        self.used_ring[idx] = .{ .id = head, .len = len };

        // Compiler barrier before updating index
        @setRuntimeSafety(false);

        self.used_idx +%= 1;
    }

    /// Check if we should notify the guest.
    pub fn shouldNotify(self: *VirtQueue) bool {
        return self.needs_notification;
    }

    /// Disable notifications from guest.
    pub fn disableNotification(self: *VirtQueue) void {
        self.needs_notification = false;
    }

    /// Enable notifications from guest.
    pub fn enableNotification(self: *VirtQueue) void {
        self.needs_notification = true;
    }

    /// Calculate descriptor table size.
    pub fn descTableSize(queue_size: u16) usize {
        return @as(usize, queue_size) * @sizeOf(Desc);
    }

    /// Calculate available ring size.
    pub fn availRingSize(queue_size: u16) usize {
        return @sizeOf(AvailRingHeader) + @as(usize, queue_size) * @sizeOf(u16) + @sizeOf(u16);
    }

    /// Calculate used ring size.
    pub fn usedRingSize(queue_size: u16) usize {
        return @sizeOf(UsedRingHeader) + @as(usize, queue_size) * @sizeOf(UsedElem) + @sizeOf(u16);
    }

    /// Calculate total virtqueue memory size.
    pub fn totalSize(queue_size: u16) usize {
        return descTableSize(queue_size) + availRingSize(queue_size) + usedRingSize(queue_size);
    }
};

test "VirtQueue init" {
    var queue = try VirtQueue.init(std.testing.allocator, 16);
    defer queue.deinit();

    try std.testing.expectEqual(@as(u16, 16), queue.size);
    try std.testing.expect(!queue.hasPending());
    try std.testing.expect(queue.shouldNotify());
}

test "VirtQueue size must be power of 2" {
    var queue = try VirtQueue.init(std.testing.allocator, 32);
    defer queue.deinit();

    try std.testing.expectEqual(@as(u16, 32), queue.size);
}

test "VirtQueue push used" {
    var queue = try VirtQueue.init(std.testing.allocator, 16);
    defer queue.deinit();

    queue.pushUsed(5, 100);
    try std.testing.expectEqual(@as(u16, 1), queue.used_idx);
    try std.testing.expectEqual(@as(u32, 5), queue.used_ring[0].id);
    try std.testing.expectEqual(@as(u32, 100), queue.used_ring[0].len);
}

test "VirtQueue size calculations" {
    // 16 descriptors
    try std.testing.expectEqual(@as(usize, 256), VirtQueue.descTableSize(16)); // 16 * 16
    try std.testing.expectEqual(@as(usize, 38), VirtQueue.availRingSize(16)); // 4 + 32 + 2
    // Used ring: header (4) + 16 * UsedElem (8 each) + avail_event (2) = 4 + 128 + 2 = 134
    try std.testing.expectEqual(@as(usize, 134), VirtQueue.usedRingSize(16));
}

test "DescChain iteration" {
    var queue = try VirtQueue.init(std.testing.allocator, 16);
    defer queue.deinit();

    // Set up a chain: 0 -> 1 -> 2
    queue.desc[0] = .{ .addr = 0x1000, .len = 100, .flags = .{ .next = true }, .next = 1 };
    queue.desc[1] = .{ .addr = 0x2000, .len = 200, .flags = .{ .next = true }, .next = 2 };
    queue.desc[2] = .{ .addr = 0x3000, .len = 300, .flags = .{}, .next = 0 };

    var chain = queue.getChain(0);

    // First descriptor
    const d0 = chain.current_desc().?;
    try std.testing.expectEqual(@as(u64, 0x1000), d0.addr);
    try std.testing.expect(chain.next());

    // Second descriptor
    const d1 = chain.current_desc().?;
    try std.testing.expectEqual(@as(u64, 0x2000), d1.addr);
    try std.testing.expect(chain.next());

    // Third descriptor
    const d2 = chain.current_desc().?;
    try std.testing.expectEqual(@as(u64, 0x3000), d2.addr);
    try std.testing.expect(!chain.next()); // No more
}
