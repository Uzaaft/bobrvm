//! Virtual Machine wrapper for Apple Hypervisor.framework.
//!
//! Manages the VM lifecycle and guest physical memory mappings.
//! Note: Only one VM can exist per process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const c = @import("c.zig");
const Vcpu = @import("vcpu.zig").Vcpu;

/// Memory permission flags for guest mappings.
pub const MemoryFlags = packed struct(u64) {
    read: bool = false,
    write: bool = false,
    exec: bool = false,
    _padding: u61 = 0,

    pub fn toRaw(self: MemoryFlags) c.hv_memory_flags_t {
        var flags: c.hv_memory_flags_t = 0;
        if (self.read) flags |= c.HV_MEMORY_READ;
        if (self.write) flags |= c.HV_MEMORY_WRITE;
        if (self.exec) flags |= c.HV_MEMORY_EXEC;
        return flags;
    }
};

/// Common memory permission presets.
pub const MEM_READ = MemoryFlags{ .read = true };
pub const MEM_READ_WRITE = MemoryFlags{ .read = true, .write = true };
pub const MEM_READ_EXEC = MemoryFlags{ .read = true, .exec = true };
pub const MEM_READ_WRITE_EXEC = MemoryFlags{ .read = true, .write = true, .exec = true };

/// Page size constant - use minimum page size for alignment.
const PAGE_SIZE = 4096; // Standard page size on ARM64/x86_64

/// Memory region tracking.
pub const MemoryRegion = struct {
    host_addr: [*]align(PAGE_SIZE) u8,
    guest_addr: u64,
    size: usize,
    flags: MemoryFlags,
    /// True if this VM allocated host_addr (via map) and must free it on unmap.
    /// False for mapExisting regions where the host memory is caller-owned
    /// (e.g. Venus blob memory owned by virglrenderer) — freeing it is invalid.
    owned: bool = true,
};

/// Virtual Machine instance.
///
/// Wraps Apple's Hypervisor.framework VM APIs.
/// Only one VM can exist per process.
pub const VM = struct {
    alloc: Allocator,
    created: bool,
    regions: std.ArrayListUnmanaged(MemoryRegion),
    vcpus: std.ArrayListUnmanaged(*Vcpu),

    pub const Error = c.Error || Allocator.Error;

    /// Create a new VM.
    ///
    /// Only one VM can exist per process. Creating a second VM will fail.
    /// Requires `com.apple.security.hypervisor` entitlement.
    pub fn create(alloc: Allocator) Error!*VM {
        // Pre-condition: allocator is valid (implicit)

        const ret = c.hv_vm_create(null);
        try c.check(ret);

        const vm = try alloc.create(VM);
        errdefer alloc.destroy(vm);

        vm.* = .{
            .alloc = alloc,
            .created = true,
            .regions = .empty,
            .vcpus = .empty,
        };

        // Post-condition: VM is created
        assert(vm.created);

        return vm;
    }

    /// Destroy the VM and release all resources.
    pub fn destroy(self: *VM) void {
        // Pre-condition: VM was created
        assert(self.created);

        // Destroy all vCPUs first
        for (self.vcpus.items) |vcpu| {
            vcpu.destroy();
        }
        self.vcpus.deinit(self.alloc);

        // Unmap all memory regions
        for (self.regions.items) |region| {
            _ = c.hv_vm_unmap(region.guest_addr, region.size);
            self.alloc.free(region.host_addr[0..region.size]);
        }
        self.regions.deinit(self.alloc);

        // Destroy the VM
        _ = c.hv_vm_destroy();

        self.created = false;
        self.alloc.destroy(self);
    }

    /// Map host memory into guest physical address space.
    ///
    /// The memory is allocated by this function and must be page-aligned.
    /// It will be freed when the VM is destroyed or when unmap is called.
    pub fn map(
        self: *VM,
        guest_addr: u64,
        size: usize,
        flags: MemoryFlags,
    ) Error![]align(PAGE_SIZE) u8 {
        // Pre-conditions
        assert(self.created);
        assert(size > 0);
        assert(guest_addr % PAGE_SIZE == 0);
        assert(size % PAGE_SIZE == 0);

        // Allocate page-aligned memory
        const host_mem = try self.alloc.alignedAlloc(u8, .fromByteUnits(PAGE_SIZE), size);
        errdefer self.alloc.free(host_mem);

        // Zero-initialize for security
        @memset(host_mem, 0);

        // Map into guest
        const ret = c.hv_vm_map(
            @ptrCast(host_mem.ptr),
            guest_addr,
            size,
            flags.toRaw(),
        );
        try c.check(ret);

        // Track the region
        try self.regions.append(self.alloc, .{
            .host_addr = host_mem.ptr,
            .guest_addr = guest_addr,
            .size = size,
            .flags = flags,
        });

        // Post-condition: region is tracked
        assert(self.regions.items.len > 0);

        return host_mem;
    }

    /// Map existing host memory into guest physical address space.
    ///
    /// The caller retains ownership of the memory.
    /// The memory must remain valid for the lifetime of the mapping.
    pub fn mapExisting(
        self: *VM,
        host_addr: []align(PAGE_SIZE) u8,
        guest_addr: u64,
        flags: MemoryFlags,
    ) Error!void {
        // Pre-conditions
        assert(self.created);
        assert(host_addr.len > 0);
        assert(guest_addr % PAGE_SIZE == 0);
        assert(host_addr.len % PAGE_SIZE == 0);

        const ret = c.hv_vm_map(
            @ptrCast(host_addr.ptr),
            guest_addr,
            host_addr.len,
            flags.toRaw(),
        );
        try c.check(ret);

        // Track but don't free (host_addr ownership stays with caller)
        // We track it to ensure proper cleanup order
        try self.regions.append(self.alloc, .{
            .host_addr = host_addr.ptr,
            .guest_addr = guest_addr,
            .size = host_addr.len,
            .flags = flags,
            .owned = false,
        });
    }

    /// Unmap memory from guest.
    pub fn unmap(self: *VM, guest_addr: u64, size: usize) Error!void {
        // Pre-conditions
        assert(self.created);
        assert(size > 0);

        const ret = c.hv_vm_unmap(guest_addr, size);
        try c.check(ret);

        // Remove from tracking
        var i: usize = 0;
        while (i < self.regions.items.len) {
            if (self.regions.items[i].guest_addr == guest_addr) {
                const region = self.regions.swapRemove(i);
                // Only free memory this VM allocated; mapExisting regions are
                // caller-owned (freeing them would be an invalid free).
                if (region.owned)
                    self.alloc.free(region.host_addr[0..region.size]);
            } else {
                i += 1;
            }
        }
    }

    /// Translate guest physical address to host pointer.
    /// Returns null if address is not in any mapped region.
    pub fn guestToHost(self: *const VM, guest_addr: u64) ?*u8 {
        for (self.regions.items) |region| {
            if (guest_addr >= region.guest_addr and
                guest_addr < region.guest_addr + region.size)
            {
                const offset = guest_addr - region.guest_addr;
                return @ptrCast(&region.host_addr[offset]);
            }
        }
        return null;
    }

    /// Create a vCPU for this VM.
    pub fn createVcpu(self: *VM) Error!*Vcpu {
        // Pre-condition: VM is created
        assert(self.created);

        const vcpu = try Vcpu.create(self.alloc);
        errdefer vcpu.destroy();

        try self.vcpus.append(self.alloc, vcpu);

        // Post-condition: vCPU is tracked
        assert(self.vcpus.items.len > 0);

        return vcpu;
    }

    /// Get host memory for a guest physical address.
    pub fn getHostMemory(self: *VM, guest_addr: u64, size: usize) ?[]u8 {
        for (self.regions.items) |region| {
            const region_end = region.guest_addr + region.size;
            const addr_end = guest_addr + size;

            if (guest_addr >= region.guest_addr and addr_end <= region_end) {
                const offset = guest_addr - region.guest_addr;
                return region.host_addr[offset .. offset + size];
            }
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "MemoryFlags to raw conversion" {
    const rw = MEM_READ_WRITE;
    const raw = rw.toRaw();
    try std.testing.expect(raw & c.HV_MEMORY_READ != 0);
    try std.testing.expect(raw & c.HV_MEMORY_WRITE != 0);
    try std.testing.expect(raw & c.HV_MEMORY_EXEC == 0);
}

test "MemoryFlags presets" {
    try std.testing.expect(MEM_READ.read);
    try std.testing.expect(!MEM_READ.write);

    try std.testing.expect(MEM_READ_WRITE.read);
    try std.testing.expect(MEM_READ_WRITE.write);
    try std.testing.expect(!MEM_READ_WRITE.exec);

    try std.testing.expect(MEM_READ_WRITE_EXEC.read);
    try std.testing.expect(MEM_READ_WRITE_EXEC.write);
    try std.testing.expect(MEM_READ_WRITE_EXEC.exec);
}
