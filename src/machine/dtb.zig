//! Device Tree Blob (DTB) generator for ARM64 Linux.
//!
//! Generates a Flattened Device Tree (FDT) that describes the virtual
//! hardware to the Linux kernel. Based on QEMU virt machine layout.
//!
//! References:
//! - Devicetree Specification v0.4
//! - Linux Documentation/devicetree/bindings/
//! - QEMU hw/arm/virt.c

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.dtb);

/// FDT header magic.
pub const FDT_MAGIC: u32 = 0xd00dfeed;

/// FDT version we generate.
pub const FDT_VERSION: u32 = 17;

/// FDT tokens.
pub const FDT_BEGIN_NODE: u32 = 0x00000001;
pub const FDT_END_NODE: u32 = 0x00000002;
pub const FDT_PROP: u32 = 0x00000003;
pub const FDT_NOP: u32 = 0x00000004;
pub const FDT_END: u32 = 0x00000009;

/// FDT header structure.
pub const FdtHeader = extern struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

/// DTB configuration for generation.
pub const DtbConfig = struct {
    /// RAM base address.
    ram_base: u64,
    /// RAM size in bytes.
    ram_size: u64,
    /// Number of vCPUs.
    vcpu_count: u8,
    /// Kernel command line.
    cmdline: []const u8,
    /// Initrd start address (0 if none).
    initrd_start: u64 = 0,
    /// Initrd end address (0 if none).
    initrd_end: u64 = 0,
    /// Number of virtio MMIO devices.
    virtio_count: u8 = 1,
    /// Virtio MMIO base address.
    virtio_base: u64 = 0x0A00_0000,
    /// Virtio MMIO size per device.
    virtio_size: u64 = 0x200,
    /// UART base address.
    uart_base: u64 = 0x0900_0000,
    /// GIC distributor base.
    gic_dist_base: u64 = 0x0800_0000,
    /// GIC redistributor base.
    gic_redist_base: u64 = 0x080A_0000,
    /// Enable PCIe host bridge (for UEFI boot).
    pcie_enabled: bool = false,
    /// PCIe ECAM base address.
    pcie_ecam_base: u64 = 0x3c00_0000,
    /// PCIe ECAM size.
    pcie_ecam_size: u64 = 64 * 1024 * 1024,
    /// PCIe MMIO base address.
    pcie_mmio_base: u64 = 0x1000_0000,
    /// PCIe MMIO size.
    pcie_mmio_size: u64 = 0x2c00_0000,
};

/// DTB builder.
pub const DtbBuilder = struct {
    alloc: Allocator,
    struct_buf: std.ArrayListUnmanaged(u8),
    strings_buf: std.ArrayListUnmanaged(u8),
    string_offsets: std.StringHashMapUnmanaged(u32),

    pub fn init(alloc: Allocator) DtbBuilder {
        return .{
            .alloc = alloc,
            .struct_buf = .empty,
            .strings_buf = .empty,
            .string_offsets = .empty,
        };
    }

    pub fn deinit(self: *DtbBuilder) void {
        self.struct_buf.deinit(self.alloc);
        self.strings_buf.deinit(self.alloc);
        self.string_offsets.deinit(self.alloc);
    }

    /// Generate DTB for the given configuration.
    pub fn generate(self: *DtbBuilder, config: DtbConfig) ![]u8 {
        assert(config.ram_size > 0);
        assert(config.vcpu_count > 0);

        // Build the device tree structure
        try self.buildTree(config);

        // Calculate sizes and offsets
        const header_size: u32 = @sizeOf(FdtHeader);
        const rsvmap_size: u32 = 16; // One empty entry (16 bytes)
        const struct_size: u32 = @intCast(self.struct_buf.items.len);
        const strings_size: u32 = @intCast(self.strings_buf.items.len);

        const off_mem_rsvmap = header_size;
        const off_dt_struct = off_mem_rsvmap + rsvmap_size;
        const off_dt_strings = off_dt_struct + struct_size;
        const totalsize = off_dt_strings + strings_size;

        // Allocate final buffer
        const dtb = try self.alloc.alloc(u8, totalsize);
        errdefer self.alloc.free(dtb);

        // Write header
        const header = @as(*FdtHeader, @ptrCast(@alignCast(dtb.ptr)));
        header.* = .{
            .magic = std.mem.nativeToBig(u32, FDT_MAGIC),
            .totalsize = std.mem.nativeToBig(u32, totalsize),
            .off_dt_struct = std.mem.nativeToBig(u32, off_dt_struct),
            .off_dt_strings = std.mem.nativeToBig(u32, off_dt_strings),
            .off_mem_rsvmap = std.mem.nativeToBig(u32, off_mem_rsvmap),
            .version = std.mem.nativeToBig(u32, FDT_VERSION),
            .last_comp_version = std.mem.nativeToBig(u32, 16),
            .boot_cpuid_phys = 0,
            .size_dt_strings = std.mem.nativeToBig(u32, strings_size),
            .size_dt_struct = std.mem.nativeToBig(u32, struct_size),
        };

        // Write memory reservation map (empty)
        @memset(dtb[off_mem_rsvmap..][0..rsvmap_size], 0);

        // Write structure block
        @memcpy(dtb[off_dt_struct..][0..struct_size], self.struct_buf.items);

        // Write strings block
        @memcpy(dtb[off_dt_strings..][0..strings_size], self.strings_buf.items);

        log.debug("generated DTB: {} bytes", .{totalsize});
        return dtb;
    }

    fn buildTree(self: *DtbBuilder, config: DtbConfig) !void {
        // Root node
        try self.beginNode("");
        try self.prop_u32("#address-cells", 2);
        try self.prop_u32("#size-cells", 2);
        try self.prop_string("compatible", "linux,dummy-virt");
        try self.prop_u32("interrupt-parent", 0x8001); // phandle for GIC

        // Chosen node (boot parameters)
        try self.beginNode("chosen");
        try self.prop_string("bootargs", config.cmdline);
        try self.prop_string("stdout-path", "/pl011@9000000");
        if (config.initrd_start != 0 and config.initrd_end != 0) {
            try self.prop_u64("linux,initrd-start", config.initrd_start);
            try self.prop_u64("linux,initrd-end", config.initrd_end);
        }
        try self.endNode();

        // Memory node
        try self.beginNode("memory@40000000");
        try self.prop_string("device_type", "memory");
        try self.prop_reg64(config.ram_base, config.ram_size);
        try self.endNode();

        // CPUs node
        try self.beginNode("cpus");
        try self.prop_u32("#address-cells", 1);
        try self.prop_u32("#size-cells", 0);
        for (0..config.vcpu_count) |i| {
            var cpu_name: [16]u8 = undefined;
            const cpu_name_len = std.fmt.bufPrint(&cpu_name, "cpu@{}", .{i}) catch unreachable;
            try self.beginNode(cpu_name[0..cpu_name_len.len]);
            try self.prop_string("device_type", "cpu");
            try self.prop_string("compatible", "arm,cortex-a72");
            try self.prop_u32("reg", @intCast(i));
            try self.prop_string("enable-method", "psci");
            try self.endNode();
        }
        try self.endNode();

        // PSCI node (Power State Coordination Interface)
        try self.beginNode("psci");
        try self.prop_string("compatible", "arm,psci-1.0");
        try self.prop_string("method", "hvc");
        try self.endNode();

        // Timer node
        try self.beginNode("timer");
        try self.prop_string("compatible", "arm,armv8-timer");
        try self.prop_empty("always-on");
        // Interrupts: secure phys, non-secure phys, virt, hyp
        const timer_irqs = [_]u32{
            1, 13, 0xf04, // Secure physical timer
            1, 14, 0xf04, // Non-secure physical timer
            1, 11, 0xf04, // Virtual timer
            1, 10, 0xf04, // Hypervisor timer
        };
        try self.prop_u32_array("interrupts", &timer_irqs);
        try self.endNode();

        // GIC (interrupt controller)
        try self.beginNode("intc@8000000");
        try self.prop_string("compatible", "arm,gic-v3");
        try self.prop_u32("#interrupt-cells", 3);
        try self.prop_empty("interrupt-controller");
        try self.prop_u32("phandle", 0x8001);
        try self.prop_u32("#address-cells", 2);
        try self.prop_u32("#size-cells", 2);
        try self.prop_empty("ranges");
        // reg: distributor (64KB), redistributor (128KB per CPU)
        const redist_size: u64 = @as(u64, config.vcpu_count) * 0x20000;
        const gic_reg = [_]u64{
            config.gic_dist_base,   0x10000,
            config.gic_redist_base, redist_size,
        };
        try self.prop_u64_array("reg", &gic_reg);
        try self.endNode();

        // UART (PL011)
        try self.beginNode("pl011@9000000");
        try self.prop_string("compatible", "arm,pl011\x00arm,primecell");
        try self.prop_reg64(config.uart_base, 0x1000);
        const uart_irqs = [_]u32{ 0, 1, 4 }; // SPI 1, level high
        try self.prop_u32_array("interrupts", &uart_irqs);
        try self.prop_u32_array("clocks", &[_]u32{ 0x8002, 0x8002 });
        try self.prop_string_list("clock-names", &[_][]const u8{ "uartclk", "apb_pclk" });
        try self.endNode();

        // Fixed clock for UART
        try self.beginNode("apb-pclk");
        try self.prop_string("compatible", "fixed-clock");
        try self.prop_u32("#clock-cells", 0);
        try self.prop_u32("clock-frequency", 24000000);
        try self.prop_u32("phandle", 0x8002);
        try self.endNode();

        // Virtio MMIO devices
        for (0..config.virtio_count) |i| {
            const idx: u32 = @intCast(i);
            const base = config.virtio_base + idx * config.virtio_size;

            var node_name: [32]u8 = undefined;
            const name_len = std.fmt.bufPrint(&node_name, "virtio_mmio@{x}", .{base}) catch unreachable;
            try self.beginNode(node_name[0..name_len.len]);
            try self.prop_string("compatible", "virtio,mmio");
            try self.prop_reg64(base, config.virtio_size);
            // IRQ: SPI (32 + i), level high
            const virtio_irq = [_]u32{ 0, 32 + idx, 1 };
            try self.prop_u32_array("interrupts", &virtio_irq);
            try self.prop_empty("dma-coherent");
            try self.endNode();
        }

        // PCIe host bridge (for UEFI boot)
        if (config.pcie_enabled) {
            try self.buildPcieNode(config);
        }

        try self.endNode(); // End root
        try self.writeToken(FDT_END);
    }

    fn buildPcieNode(self: *DtbBuilder, config: DtbConfig) !void {
        // PCIe host bridge node
        // Based on QEMU virt machine and pci-host-ecam-generic binding
        try self.beginNode("pcie@3c000000");
        try self.prop_string("compatible", "pci-host-ecam-generic");
        try self.prop_string("device_type", "pci");
        try self.prop_u32("#address-cells", 3);
        try self.prop_u32("#size-cells", 2);
        try self.prop_u32("#interrupt-cells", 1);

        // ECAM configuration space
        try self.prop_reg64(config.pcie_ecam_base, config.pcie_ecam_size);

        // Bus range: 0-255
        const bus_range = [_]u32{ 0, 0xFF };
        try self.prop_u32_array("bus-range", &bus_range);

        // Ranges: PCI MMIO 32-bit space
        // Format: phys.hi phys.mid phys.lo cpu_addr.hi cpu_addr.lo size.hi size.lo
        // phys.hi bits: ss=00 (config), 01 (I/O), 10 (32-bit MMIO), 11 (64-bit MMIO)
        //              n=0 (non-prefetchable), p=0 (non-relocatable)
        // 0x02000000 = 32-bit MMIO space, non-prefetchable
        const ranges = [_]u32{
            0x02000000, // flags: 32-bit MMIO
            0, // PCI addr high
            @truncate(config.pcie_mmio_base), // PCI addr low
            @truncate(config.pcie_mmio_base >> 32), // CPU addr high
            @truncate(config.pcie_mmio_base), // CPU addr low
            @truncate(config.pcie_mmio_size >> 32), // size high
            @truncate(config.pcie_mmio_size), // size low
        };
        try self.prop_u32_array("ranges", &ranges);

        // MSI parent (use GIC)
        try self.prop_u32("msi-parent", 0x8001);

        // Interrupt map mask (extract device number for IRQ routing)
        // PCI address: bus(8) device(5) function(3) reg(12) = 28 bits in 3 cells
        const interrupt_map_mask = [_]u32{
            0x1800, // device bits in phys.hi
            0,
            0,
            7, // 3-bit interrupt
        };
        try self.prop_u32_array("interrupt-map-mask", &interrupt_map_mask);

        // Interrupt map: route all PCI interrupts to GIC SPI 48-51
        // Format: child_unit child_irq parent_phandle parent_irq...
        // We map device slots to SPIs 48-51 (INTA# through INTD#)
        const interrupt_map = [_]u32{
            // Device 0, INTA# -> SPI 48
            0x0000, 0, 0, 1, 0x8001, 0, 48, 4,
            // Device 0, INTB# -> SPI 49
            0x0000, 0, 0, 2, 0x8001, 0, 49, 4,
            // Device 0, INTC# -> SPI 50
            0x0000, 0, 0, 3, 0x8001, 0, 50, 4,
            // Device 0, INTD# -> SPI 51
            0x0000, 0, 0, 4, 0x8001, 0, 51, 4,
            // Device 1, INTA# -> SPI 49
            0x0800, 0, 0, 1, 0x8001, 0, 49, 4,
            // Device 1, INTB# -> SPI 50
            0x0800, 0, 0, 2, 0x8001, 0, 50, 4,
            // Device 1, INTC# -> SPI 51
            0x0800, 0, 0, 3, 0x8001, 0, 51, 4,
            // Device 1, INTD# -> SPI 48
            0x0800, 0, 0, 4, 0x8001, 0, 48, 4,
        };
        try self.prop_u32_array("interrupt-map", &interrupt_map);

        try self.prop_empty("dma-coherent");
        try self.endNode();
    }

    // =========================================================================
    // Node/Property helpers
    // =========================================================================

    fn beginNode(self: *DtbBuilder, name: []const u8) !void {
        try self.writeToken(FDT_BEGIN_NODE);
        try self.writeString(name);
    }

    fn endNode(self: *DtbBuilder) !void {
        try self.writeToken(FDT_END_NODE);
    }

    fn prop_u32(self: *DtbBuilder, name: []const u8, value: u32) !void {
        try self.writePropHeader(name, 4);
        try self.writeU32(value);
    }

    fn prop_u64(self: *DtbBuilder, name: []const u8, value: u64) !void {
        try self.writePropHeader(name, 8);
        try self.writeU32(@truncate(value >> 32));
        try self.writeU32(@truncate(value));
    }

    fn prop_string(self: *DtbBuilder, name: []const u8, value: []const u8) !void {
        try self.writePropHeader(name, @intCast(value.len + 1));
        try self.struct_buf.appendSlice(self.alloc, value);
        try self.struct_buf.append(self.alloc, 0);
        try self.align4();
    }

    fn prop_string_list(self: *DtbBuilder, name: []const u8, values: []const []const u8) !void {
        var total_len: u32 = 0;
        for (values) |v| {
            total_len += @intCast(v.len + 1);
        }
        try self.writePropHeader(name, total_len);
        for (values) |v| {
            try self.struct_buf.appendSlice(self.alloc, v);
            try self.struct_buf.append(self.alloc, 0);
        }
        try self.align4();
    }

    fn prop_empty(self: *DtbBuilder, name: []const u8) !void {
        try self.writePropHeader(name, 0);
    }

    fn prop_u32_array(self: *DtbBuilder, name: []const u8, values: []const u32) !void {
        try self.writePropHeader(name, @intCast(values.len * 4));
        for (values) |v| {
            try self.writeU32(v);
        }
    }

    fn prop_u64_array(self: *DtbBuilder, name: []const u8, values: []const u64) !void {
        try self.writePropHeader(name, @intCast(values.len * 8));
        for (values) |v| {
            try self.writeU32(@truncate(v >> 32));
            try self.writeU32(@truncate(v));
        }
    }

    fn prop_reg64(self: *DtbBuilder, addr: u64, size: u64) !void {
        try self.writePropHeader("reg", 16);
        try self.writeU32(@truncate(addr >> 32));
        try self.writeU32(@truncate(addr));
        try self.writeU32(@truncate(size >> 32));
        try self.writeU32(@truncate(size));
    }

    // =========================================================================
    // Low-level write helpers
    // =========================================================================

    fn writeToken(self: *DtbBuilder, token: u32) !void {
        try self.writeU32(token);
    }

    fn writeU32(self: *DtbBuilder, value: u32) !void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, value));
        try self.struct_buf.appendSlice(self.alloc, &bytes);
    }

    fn writeString(self: *DtbBuilder, s: []const u8) !void {
        try self.struct_buf.appendSlice(self.alloc, s);
        try self.struct_buf.append(self.alloc, 0);
        try self.align4();
    }

    fn writePropHeader(self: *DtbBuilder, name: []const u8, len: u32) !void {
        const name_off = try self.getStringOffset(name);
        try self.writeToken(FDT_PROP);
        try self.writeU32(len);
        try self.writeU32(name_off);
    }

    fn getStringOffset(self: *DtbBuilder, name: []const u8) !u32 {
        if (self.string_offsets.get(name)) |off| {
            return off;
        }

        const off: u32 = @intCast(self.strings_buf.items.len);
        try self.strings_buf.appendSlice(self.alloc, name);
        try self.strings_buf.append(self.alloc, 0);
        try self.string_offsets.put(self.alloc, name, off);
        return off;
    }

    fn align4(self: *DtbBuilder) !void {
        const padding = (4 - (self.struct_buf.items.len % 4)) % 4;
        for (0..padding) |_| {
            try self.struct_buf.append(self.alloc, 0);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DtbBuilder basic generation" {
    const alloc = std.testing.allocator;
    var builder = DtbBuilder.init(alloc);
    defer builder.deinit();

    const config = DtbConfig{
        .ram_base = 0x40000000,
        .ram_size = 512 * 1024 * 1024,
        .vcpu_count = 2,
        .cmdline = "console=ttyAMA0",
    };

    const dtb = try builder.generate(config);
    defer alloc.free(dtb);

    // Verify magic
    const header = @as(*const FdtHeader, @ptrCast(@alignCast(dtb.ptr)));
    try std.testing.expectEqual(FDT_MAGIC, std.mem.bigToNative(u32, header.magic));
    try std.testing.expectEqual(FDT_VERSION, std.mem.bigToNative(u32, header.version));
}

test "DtbConfig defaults" {
    const config = DtbConfig{
        .ram_base = 0x40000000,
        .ram_size = 512 * 1024 * 1024,
        .vcpu_count = 1,
        .cmdline = "console=ttyAMA0",
    };

    try std.testing.expectEqual(@as(u64, 0x0A00_0000), config.virtio_base);
    try std.testing.expectEqual(@as(u8, 1), config.virtio_count);
}
