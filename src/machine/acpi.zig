//! ACPI tables for the arm64 machine, delivered to the firmware through
//! fw_cfg the way QEMU does it: an "etc/acpi/tables" blob holding every
//! table, an "etc/acpi/rsdp" blob, and an "etc/table-loader" script that
//! tells the firmware where to allocate the blobs, which pointer fields to
//! relocate and which checksums to compute. EDK2's AcpiPlatformDxe replays
//! the script and installs each table it finds through a pointer.
//!
//! Windows on Arm boots only from ACPI (no device tree), so the set here is
//! what Windows needs on an SBSA-like virtual machine: HW-reduced FADT with
//! PSCI, GICv3 MADT, GTDT, MCFG, SPCR, PPTT, and a DSDT describing the
//! UART, RTC, fw_cfg and the PCIe host bridge with INTx routing.
//!
//! References: ACPI 6.5; QEMU hw/arm/virt-acpi-build.c; QEMU
//! docs/specs/acpi_table_loader... (hw/acpi/bios-linker-loader.c).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const Aml = @import("aml.zig");

pub const Layout = struct {
    cpu_count: u8,
    gicd_base: u64,
    gicr_base: u64,
    uart_base: u64,
    uart_gsiv: u32,
    rtc_base: u64,
    rtc_gsiv: u32,
    fw_cfg_base: u64,
    ecam_base: u64,
    ecam_size: u64,
    pci_mmio_base: u64,
    pci_mmio_size: u64,
    pci_io_base: u64,
    pci_io_size: u64,
    /// GSIV of slot 0 INTA#; slot s pin p routes to base + (s + p) % 4.
    pci_intx_gsiv_base: u32,
};

/// The three fw_cfg payloads. Owned by the caller after `build`.
pub const Blobs = struct {
    tables: []u8,
    rsdp: []u8,
    loader: []u8,

    pub fn deinit(self: *Blobs, alloc: Allocator) void {
        alloc.free(self.tables);
        alloc.free(self.rsdp);
        alloc.free(self.loader);
        self.* = undefined;
    }
};

pub const Error = Allocator.Error;

pub const TABLES_FILE = "etc/acpi/tables";
pub const RSDP_FILE = "etc/acpi/rsdp";
pub const LOADER_FILE = "etc/table-loader";

const OEM_ID = "BOBRVM";
const OEM_TABLE_ID = "BOBRVIRT";
const CREATOR_ID = "BOBR";
const HEADER_LEN: usize = 36;
const TABLE_ALIGN: usize = 64;

// Generic Interrupt Controller PPIs (ARM ARM / GICv3 architecture).
const TIMER_SECURE_EL1_GSIV: u32 = 29;
const TIMER_NONSECURE_EL1_GSIV: u32 = 30;
const TIMER_VIRTUAL_GSIV: u32 = 27;
const TIMER_EL2_GSIV: u32 = 26;

const Table = struct {
    offset: usize,
    length: usize,
};

/// Build every blob for `layout`.
pub fn build(alloc: Allocator, layout: Layout) Error!Blobs {
    assert(layout.cpu_count > 0);
    var tables = Aml.init(alloc);
    defer tables.deinit();
    var loader = Loader.init(alloc);
    defer loader.deinit();

    try loader.allocate(TABLES_FILE, TABLE_ALIGN, .high);

    const dsdt = try appendTable(&tables, &loader, buildDsdt, layout);
    // EDK2 only installs a pointee whose checksum verifies, so every table
    // needs its checksum command — the DSDT included.
    try loader.addChecksum(TABLES_FILE, dsdt);
    const fadt = try appendTable(&tables, &loader, buildFadt, layout);
    // FADT.X_DSDT holds the DSDT's blob offset until the loader relocates it.
    std.mem.writeInt(u64, tables.bytes.items[fadt.offset + 140 ..][0..8], dsdt.offset, .little);
    try loader.addPointer(TABLES_FILE, TABLES_FILE, @intCast(fadt.offset + 140), 8);
    try loader.addChecksum(TABLES_FILE, fadt);

    const others = [_]Table{
        try appendTable(&tables, &loader, buildMadt, layout),
        try appendTable(&tables, &loader, buildGtdt, layout),
        try appendTable(&tables, &loader, buildMcfg, layout),
        try appendTable(&tables, &loader, buildSpcr, layout),
        try appendTable(&tables, &loader, buildPptt, layout),
    };
    for (others) |table| try loader.addChecksum(TABLES_FILE, table);

    // XSDT: one entry per table other than the DSDT (reached via the FADT).
    try alignTables(&tables);
    const xsdt_offset = tables.items().len;
    var xsdt_body = Aml.init(alloc);
    defer xsdt_body.deinit();
    try xsdt_body.appendInt(u64, fadt.offset);
    for (others) |table| try xsdt_body.appendInt(u64, table.offset);
    try appendHeader(&tables, "XSDT", 1, xsdt_body.items().len);
    try tables.raw(xsdt_body.items());
    const xsdt = Table{ .offset = xsdt_offset, .length = HEADER_LEN + xsdt_body.items().len };
    var entry: usize = 0;
    while (entry < 1 + others.len) : (entry += 1) {
        try loader.addPointer(TABLES_FILE, TABLES_FILE, @intCast(xsdt.offset + HEADER_LEN + entry * 8), 8);
    }
    try loader.addChecksum(TABLES_FILE, xsdt);

    // RSDP in its own blob, pointing at the XSDT.
    var rsdp = Aml.init(alloc);
    defer rsdp.deinit();
    try rsdp.raw("RSD PTR ");
    try rsdp.byte(0); // checksum
    try rsdp.raw(OEM_ID);
    try rsdp.byte(2); // revision
    try rsdp.appendInt(u32, 0); // RSDT address
    try rsdp.appendInt(u32, 36); // length
    try rsdp.appendInt(u64, xsdt.offset); // XSDT address, relocated by loader
    try rsdp.byte(0); // extended checksum
    try rsdp.raw(&.{ 0, 0, 0 });
    assert(rsdp.items().len == 36);
    try loader.allocate(RSDP_FILE, 16, .fseg);
    try loader.addPointer(RSDP_FILE, TABLES_FILE, 24, 8);
    try loader.addChecksumRange(RSDP_FILE, 8, 0, 20);
    try loader.addChecksumRange(RSDP_FILE, 32, 0, 36);

    const tables_owned = try tables.toOwnedSlice();
    errdefer alloc.free(tables_owned);
    const rsdp_owned = try rsdp.toOwnedSlice();
    errdefer alloc.free(rsdp_owned);
    const loader_owned = try loader.bytes.toOwnedSlice(alloc);
    return .{ .tables = tables_owned, .rsdp = rsdp_owned, .loader = loader_owned };
}

fn alignTables(tables: *Aml) Error!void {
    while (tables.items().len % TABLE_ALIGN != 0) try tables.byte(0);
}

/// Standard 36-byte header with a zero checksum (the loader fills it in).
fn appendHeader(out: *Aml, signature: *const [4]u8, revision: u8, body_len: usize) Error!void {
    try out.raw(signature);
    try out.appendInt(u32, @intCast(HEADER_LEN + body_len));
    try out.byte(revision);
    try out.byte(0);
    try out.raw(OEM_ID);
    try out.raw(OEM_TABLE_ID);
    try out.appendInt(u32, 1);
    try out.raw(CREATOR_ID);
    try out.appendInt(u32, 1);
}

const TableBuilder = *const fn (*Aml, Layout) Error!void;

fn appendTable(tables: *Aml, loader: *Loader, builder: TableBuilder, layout: Layout) Error!Table {
    _ = loader;
    try alignTables(tables);
    const offset = tables.items().len;
    try builder(tables, layout);
    return .{ .offset = offset, .length = tables.items().len - offset };
}

// =============================================================================
// Fixed tables
// =============================================================================

/// FADT, ACPI 6.0 layout (276 bytes): hardware-reduced, PSCI via HVC.
fn buildFadt(out: *Aml, layout: Layout) Error!void {
    _ = layout;
    var body = Aml.init(out.alloc);
    defer body.deinit();
    try body.raw(&[_]u8{0} ** (112 - 36)); // FIRMWARE_CTRL .. Reserved
    const HW_REDUCED_ACPI: u32 = 1 << 20;
    const LOW_POWER_S0_IDLE_CAPABLE: u32 = 1 << 21;
    try body.appendInt(u32, HW_REDUCED_ACPI | LOW_POWER_S0_IDLE_CAPABLE); // 112 Flags
    try body.raw(&[_]u8{0} ** 12); // 116 RESET_REG
    try body.byte(0); // 128 RESET_VALUE
    const PSCI_COMPLIANT: u16 = 1 << 0;
    const PSCI_USE_HVC: u16 = 1 << 1;
    try body.appendInt(u16, PSCI_COMPLIANT | PSCI_USE_HVC); // 129 ARM_BOOT_ARCH
    try body.byte(0); // 131 FADT minor version
    try body.appendInt(u64, 0); // 132 X_FIRMWARE_CTRL
    try body.appendInt(u64, 0); // 140 X_DSDT (patched)
    try body.raw(&[_]u8{0} ** (276 - 148));
    assert(body.items().len == 276 - HEADER_LEN);
    try appendHeader(out, "FACP", 6, body.items().len);
    try out.raw(body.items());
}

/// MADT: GICv3 distributor, one GICC per vCPU, redistributor range.
fn buildMadt(out: *Aml, layout: Layout) Error!void {
    var body = Aml.init(out.alloc);
    defer body.deinit();
    try body.appendInt(u32, 0); // local interrupt controller address
    try body.appendInt(u32, 0); // flags

    var cpu: u8 = 0;
    while (cpu < layout.cpu_count) : (cpu += 1) {
        try body.raw(&.{ 0x0B, 80, 0, 0 }); // GICC, length, reserved
        try body.appendInt(u32, cpu); // CPU interface number
        try body.appendInt(u32, cpu); // ACPI processor UID
        try body.appendInt(u32, 1); // flags: enabled
        try body.appendInt(u32, 0); // parking protocol version
        try body.appendInt(u32, 0); // performance interrupt GSIV (no PMU)
        try body.appendInt(u64, 0); // parked address
        try body.appendInt(u64, 0); // physical base address (v3: n/a)
        try body.appendInt(u64, 0); // GICV
        try body.appendInt(u64, 0); // GICH
        try body.appendInt(u32, 0); // VGIC maintenance interrupt
        try body.appendInt(u64, 0); // GICR base (GICR structure instead)
        try body.appendInt(u64, cpu); // MPIDR: HVF numbers Aff0 by creation
        try body.byte(0); // power efficiency class
        try body.byte(0); // reserved
        try body.appendInt(u16, 0); // SPE overflow interrupt
    }

    try body.raw(&.{ 0x0C, 24, 0, 0 }); // GICD
    try body.appendInt(u32, 0); // GIC ID
    try body.appendInt(u64, layout.gicd_base);
    try body.appendInt(u32, 0); // system vector base
    try body.byte(3); // GIC version
    try body.raw(&.{ 0, 0, 0 });

    try body.raw(&.{ 0x0E, 16, 0, 0 }); // GICR
    try body.appendInt(u64, layout.gicr_base);
    try body.appendInt(u32, @as(u32, layout.cpu_count) * 0x20000);

    try appendHeader(out, "APIC", 4, body.items().len);
    try out.raw(body.items());
}

/// GTDT revision 3: architected timers only, no memory-mapped blocks.
fn buildGtdt(out: *Aml, layout: Layout) Error!void {
    _ = layout;
    var body = Aml.init(out.alloc);
    defer body.deinit();
    try body.appendInt(u64, std.math.maxInt(u64)); // CntControlBase: none
    try body.appendInt(u32, 0); // reserved
    const timers = [_]u32{
        TIMER_SECURE_EL1_GSIV,
        TIMER_NONSECURE_EL1_GSIV,
        TIMER_VIRTUAL_GSIV,
        TIMER_EL2_GSIV,
    };
    for (timers) |gsiv| {
        try body.appendInt(u32, gsiv);
        try body.appendInt(u32, 0); // flags: level triggered, active high
    }
    try body.appendInt(u64, std.math.maxInt(u64)); // CntReadBase: none
    try body.appendInt(u32, 0); // platform timer count
    try body.appendInt(u32, 0); // platform timer offset
    try body.appendInt(u32, 0); // virtual EL2 timer GSIV
    try body.appendInt(u32, 0); // virtual EL2 timer flags
    assert(body.items().len == 104 - HEADER_LEN);
    try appendHeader(out, "GTDT", 3, body.items().len);
    try out.raw(body.items());
}

/// MCFG: one ECAM segment covering as many buses as the window holds.
fn buildMcfg(out: *Aml, layout: Layout) Error!void {
    var body = Aml.init(out.alloc);
    defer body.deinit();
    try body.appendInt(u64, 0); // reserved
    try body.appendInt(u64, layout.ecam_base);
    try body.appendInt(u16, 0); // segment group
    try body.byte(0); // start bus
    try body.byte(ecamBusMax(layout)); // end bus
    try body.appendInt(u32, 0); // reserved
    try appendHeader(out, "MCFG", 1, body.items().len);
    try out.raw(body.items());
}

fn ecamBusMax(layout: Layout) u8 {
    const buses = @min(layout.ecam_size / (4096 * 8 * 32), 256);
    assert(buses > 0);
    return @intCast(buses - 1);
}

/// SPCR revision 2: the PL011 as the serial console.
fn buildSpcr(out: *Aml, layout: Layout) Error!void {
    var body = Aml.init(out.alloc);
    defer body.deinit();
    try body.byte(3); // interface type: ARM PL011
    try body.raw(&.{ 0, 0, 0 });
    // Generic address: system memory, 32-bit, dword access.
    try body.raw(&.{ 0, 32, 0, 3 });
    try body.appendInt(u64, layout.uart_base);
    try body.byte(0x08); // interrupt type: ARM GIC
    try body.byte(0); // PC-AT IRQ
    try body.appendInt(u32, layout.uart_gsiv);
    try body.byte(3); // baud rate: 9600
    try body.byte(0); // parity
    try body.byte(1); // stop bits
    try body.byte(0); // flow control
    try body.byte(0); // terminal type: VT100
    try body.byte(0); // language
    try body.appendInt(u16, 0xFFFF); // PCI device id
    try body.appendInt(u16, 0xFFFF); // PCI vendor id
    try body.raw(&.{ 0, 0, 0 }); // PCI bus, device, function
    try body.appendInt(u32, 0); // PCI flags
    try body.byte(0); // PCI segment
    try body.appendInt(u32, 0); // reserved
    assert(body.items().len == 80 - HEADER_LEN);
    try appendHeader(out, "SPCR", 2, body.items().len);
    try out.raw(body.items());
}

/// PPTT revision 2: one package, one leaf core per vCPU.
fn buildPptt(out: *Aml, layout: Layout) Error!void {
    var body = Aml.init(out.alloc);
    defer body.deinit();
    const PHYSICAL_PACKAGE: u32 = 1 << 0;
    const PROCESSOR_ID_VALID: u32 = 1 << 1;
    const NODE_IS_LEAF: u32 = 1 << 3;
    const package_offset: u32 = HEADER_LEN;
    try body.raw(&.{ 0, 20, 0, 0 });
    try body.appendInt(u32, PHYSICAL_PACKAGE);
    try body.appendInt(u32, 0); // parent
    try body.appendInt(u32, 0); // ACPI processor id (unused)
    try body.appendInt(u32, 0); // private resources
    var cpu: u8 = 0;
    while (cpu < layout.cpu_count) : (cpu += 1) {
        try body.raw(&.{ 0, 20, 0, 0 });
        try body.appendInt(u32, PROCESSOR_ID_VALID | NODE_IS_LEAF);
        try body.appendInt(u32, package_offset);
        try body.appendInt(u32, cpu);
        try body.appendInt(u32, 0);
    }
    try appendHeader(out, "PPTT", 2, body.items().len);
    try out.raw(body.items());
}

// =============================================================================
// DSDT
// =============================================================================

fn buildDsdt(out: *Aml, layout: Layout) Error!void {
    var sb = Aml.init(out.alloc);
    defer sb.deinit();

    var cpu: u8 = 0;
    while (cpu < layout.cpu_count) : (cpu += 1) {
        var name: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "C{X:0>3}", .{cpu}) catch unreachable;
        var body = Aml.init(out.alloc);
        defer body.deinit();
        try body.nameStringValue("_HID", "ACPI0007");
        try body.nameInteger("_UID", cpu);
        try sb.device(&name, body.items());
    }

    try appendMmioDevice(&sb, "COM0", "ARMH0011", layout.uart_base, 0x1000, layout.uart_gsiv);
    try appendMmioDevice(&sb, "RTC0", "LNRO0013", layout.rtc_base, 0x1000, layout.rtc_gsiv);
    try appendFwCfgDevice(&sb, layout);
    try appendPciHostBridge(&sb, layout);

    var root = Aml.init(out.alloc);
    defer root.deinit();
    try root.scope("\\_SB", sb.items());
    try appendHeader(out, "DSDT", 2, root.items().len);
    try out.raw(root.items());
}

fn appendMmioDevice(
    sb: *Aml,
    name: []const u8,
    hid: []const u8,
    base: u64,
    size: u32,
    gsiv: u32,
) Error!void {
    var body = Aml.init(sb.alloc);
    defer body.deinit();
    try body.nameStringValue("_HID", hid);
    try body.nameInteger("_UID", 0);
    var crs = Aml.init(sb.alloc);
    defer crs.deinit();
    try Aml.Resource.memory32Fixed(&crs, @intCast(base), size, true);
    try Aml.Resource.extendedInterrupt(&crs, .{}, &.{gsiv});
    try body.resourceTemplate("_CRS", crs.items());
    try sb.device(name, body.items());
}

fn appendFwCfgDevice(sb: *Aml, layout: Layout) Error!void {
    var body = Aml.init(sb.alloc);
    defer body.deinit();
    try body.nameStringValue("_HID", "QEMU0002");
    try body.nameInteger("_STA", 0x0B);
    var crs = Aml.init(sb.alloc);
    defer crs.deinit();
    try Aml.Resource.memory32Fixed(&crs, @intCast(layout.fw_cfg_base), 0x18, true);
    try body.resourceTemplate("_CRS", crs.items());
    try sb.device("FWCF", body.items());
}

fn appendPciHostBridge(sb: *Aml, layout: Layout) Error!void {
    var body = Aml.init(sb.alloc);
    defer body.deinit();
    try body.nameStringValue("_HID", "PNP0A08");
    try body.nameStringValue("_CID", "PNP0A03");
    try body.nameInteger("_SEG", 0);
    try body.nameInteger("_BBN", 0);
    try body.nameInteger("_UID", 0);
    try body.nameInteger("_CCA", 1);
    try appendPciRoutingTable(&body, layout);

    var crs = Aml.init(sb.alloc);
    defer crs.deinit();
    try Aml.Resource.wordBusNumber(&crs, 0, ecamBusMax(layout));
    try Aml.Resource.dwordMemory(&crs, @intCast(layout.pci_mmio_base), @intCast(layout.pci_mmio_size), 0);
    try Aml.Resource.dwordIo(&crs, 0, @intCast(layout.pci_io_size), @intCast(layout.pci_io_base));
    try body.resourceTemplate("_CRS", crs.items());

    // Reserve the ECAM window so the OS never hands it to a device.
    var res0 = Aml.init(sb.alloc);
    defer res0.deinit();
    try res0.nameStringValue("_HID", "PNP0C02");
    var res0_crs = Aml.init(sb.alloc);
    defer res0_crs.deinit();
    try Aml.Resource.qwordMemoryConsumer(&res0_crs, layout.ecam_base, layout.ecam_size);
    try res0.resourceTemplate("_CRS", res0_crs.items());
    try body.device("RES0", res0.items());

    try appendPciDsm(&body);
    try sb.device("PCI0", body.items());
}

/// _PRT: every slot's INTA#..INTD# swizzled onto four shared GSIVs.
fn appendPciRoutingTable(body: *Aml, layout: Layout) Error!void {
    var entries = Aml.init(body.alloc);
    defer entries.deinit();
    var slot: u32 = 0;
    while (slot < 32) : (slot += 1) {
        var pin: u32 = 0;
        while (pin < 4) : (pin += 1) {
            var entry = Aml.init(body.alloc);
            defer entry.deinit();
            try entry.integer((slot << 16) | 0xFFFF);
            try entry.integer(pin);
            try entry.integer(0);
            try entry.integer(layout.pci_intx_gsiv_base + (slot + pin) % 4);
            try entries.package(4, entry.items());
        }
    }
    var prt = Aml.init(body.alloc);
    defer prt.deinit();
    try prt.package(128, entries.items());
    try body.nameDecl("_PRT", prt.items());
}

/// _DSM for the PCI host bridge: only function 0 (the query) is supported.
fn appendPciDsm(body: *Aml) Error!void {
    const Op = Aml.Op;
    var inner_if = Aml.init(body.alloc);
    defer inner_if.deinit();
    // If (LEqual (Arg2, Zero)) { Return (Buffer (One) { 0x01 }) }
    try inner_if.raw(&.{ Op.RETURN, Op.BUFFER, 0x03, Op.ONE, 0x01 });
    var outer_body = Aml.init(body.alloc);
    defer outer_body.deinit();
    try outer_body.ifBlock(&.{ Op.LEQUAL, Op.ARG0 + 2, Op.ZERO }, inner_if.items());

    var predicate = Aml.init(body.alloc);
    defer predicate.deinit();
    try predicate.raw(&.{ Op.LEQUAL, Op.ARG0 });
    try predicate.uuidBuffer("e5c937d0-3553-4d7a-9117-ea4d19c3434d");

    var method = Aml.init(body.alloc);
    defer method.deinit();
    try method.ifBlock(predicate.items(), outer_body.items());
    try method.raw(&.{ Op.RETURN, Op.BUFFER, 0x03, Op.ONE, 0x00 });
    try body.method("_DSM", 4, false, method.items());
}

// =============================================================================
// Table loader script (QEMU BIOS linker/loader format, 128-byte commands)
// =============================================================================

pub const Loader = struct {
    alloc: Allocator,
    bytes: std.ArrayList(u8),

    pub const COMMAND_SIZE: usize = 128;
    const CMD_ALLOCATE: u32 = 1;
    const CMD_ADD_POINTER: u32 = 2;
    const CMD_ADD_CHECKSUM: u32 = 3;
    const FILE_NAME_LEN: usize = 56;

    pub const Zone = enum(u8) { high = 1, fseg = 2 };

    fn init(alloc: Allocator) Loader {
        return .{ .alloc = alloc, .bytes = .empty };
    }

    fn deinit(self: *Loader) void {
        self.bytes.deinit(self.alloc);
    }

    fn fileName(name: []const u8) [FILE_NAME_LEN]u8 {
        assert(name.len < FILE_NAME_LEN);
        var out: [FILE_NAME_LEN]u8 = @splat(0);
        @memcpy(out[0..name.len], name);
        return out;
    }

    fn command(self: *Loader, kind: u32, payload: []const u8) Error!void {
        assert(payload.len <= COMMAND_SIZE - 4);
        var buf: [COMMAND_SIZE]u8 = @splat(0);
        std.mem.writeInt(u32, buf[0..4], kind, .little);
        @memcpy(buf[4 .. 4 + payload.len], payload);
        try self.bytes.appendSlice(self.alloc, &buf);
    }

    fn allocate(self: *Loader, file: []const u8, alignment: u32, zone: Zone) Error!void {
        var payload: [FILE_NAME_LEN + 5]u8 = undefined;
        payload[0..FILE_NAME_LEN].* = fileName(file);
        std.mem.writeInt(u32, payload[FILE_NAME_LEN..][0..4], alignment, .little);
        payload[FILE_NAME_LEN + 4] = @intFromEnum(zone);
        try self.command(CMD_ALLOCATE, &payload);
    }

    fn addPointer(self: *Loader, dest: []const u8, src: []const u8, offset: u32, size: u8) Error!void {
        var payload: [2 * FILE_NAME_LEN + 5]u8 = undefined;
        payload[0..FILE_NAME_LEN].* = fileName(dest);
        payload[FILE_NAME_LEN..][0..FILE_NAME_LEN].* = fileName(src);
        std.mem.writeInt(u32, payload[2 * FILE_NAME_LEN ..][0..4], offset, .little);
        payload[2 * FILE_NAME_LEN + 4] = size;
        try self.command(CMD_ADD_POINTER, &payload);
    }

    fn addChecksumRange(self: *Loader, file: []const u8, result_offset: u32, start: u32, length: u32) Error!void {
        var payload: [FILE_NAME_LEN + 12]u8 = undefined;
        payload[0..FILE_NAME_LEN].* = fileName(file);
        std.mem.writeInt(u32, payload[FILE_NAME_LEN..][0..4], result_offset, .little);
        std.mem.writeInt(u32, payload[FILE_NAME_LEN + 4 ..][0..4], start, .little);
        std.mem.writeInt(u32, payload[FILE_NAME_LEN + 8 ..][0..4], length, .little);
        try self.command(CMD_ADD_CHECKSUM, &payload);
    }

    /// Checksum of a standard-header table: byte 9 over the whole table.
    fn addChecksum(self: *Loader, file: []const u8, table: Table) Error!void {
        try self.addChecksumRange(file, @intCast(table.offset + 9), @intCast(table.offset), @intCast(table.length));
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const test_layout = Layout{
    .cpu_count = 2,
    .gicd_base = 0x0800_0000,
    .gicr_base = 0x080A_0000,
    .uart_base = 0x0900_0000,
    .uart_gsiv = 33,
    .rtc_base = 0x0901_0000,
    .rtc_gsiv = 34,
    .fw_cfg_base = 0x0902_0000,
    .ecam_base = 0x3C00_0000,
    .ecam_size = 64 * 1024 * 1024,
    .pci_mmio_base = 0x1000_0000,
    .pci_mmio_size = 0x2BFF_0000,
    .pci_io_base = 0x3BFF_0000,
    .pci_io_size = 0x1_0000,
    .pci_intx_gsiv_base = 80,
};

fn findTable(tables: []const u8, signature: *const [4]u8) ?Table {
    var offset: usize = 0;
    while (offset + HEADER_LEN <= tables.len) : (offset += TABLE_ALIGN) {
        if (std.mem.eql(u8, tables[offset..][0..4], signature)) {
            return .{
                .offset = offset,
                .length = std.mem.readInt(u32, tables[offset + 4 ..][0..4], .little),
            };
        }
    }
    return null;
}

test "tables blob carries every table with QEMU-compatible sizes" {
    var blobs = try build(testing.allocator, test_layout);
    defer blobs.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 276), findTable(blobs.tables, "FACP").?.length);
    try testing.expectEqual(@as(usize, 104), findTable(blobs.tables, "GTDT").?.length);
    try testing.expectEqual(@as(usize, 60), findTable(blobs.tables, "MCFG").?.length);
    try testing.expectEqual(@as(usize, 80), findTable(blobs.tables, "SPCR").?.length);
    try testing.expectEqual(@as(usize, 36 + 8 + 2 * 80 + 24 + 16), findTable(blobs.tables, "APIC").?.length);
    try testing.expectEqual(@as(usize, 36 + 3 * 20), findTable(blobs.tables, "PPTT").?.length);
    try testing.expect(findTable(blobs.tables, "DSDT") != null);

    const xsdt = findTable(blobs.tables, "XSDT").?;
    try testing.expectEqual(@as(usize, 36 + 6 * 8), xsdt.length);
    // First entry is the FADT; the FADT's X_DSDT names the DSDT.
    const fadt = findTable(blobs.tables, "FACP").?;
    try testing.expectEqual(fadt.offset, std.mem.readInt(u64, blobs.tables[xsdt.offset + 36 ..][0..8], .little));
    const dsdt = findTable(blobs.tables, "DSDT").?;
    try testing.expectEqual(dsdt.offset, std.mem.readInt(u64, blobs.tables[fadt.offset + 140 ..][0..8], .little));
    // Hardware-reduced with PSCI over HVC.
    try testing.expectEqual(@as(u32, 0x30_0000), std.mem.readInt(u32, blobs.tables[fadt.offset + 112 ..][0..4], .little));
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, blobs.tables[fadt.offset + 129 ..][0..2], .little));
}

test "rsdp points at the xsdt and the loader relocates it" {
    var blobs = try build(testing.allocator, test_layout);
    defer blobs.deinit(testing.allocator);

    try testing.expectEqualStrings("RSD PTR ", blobs.rsdp[0..8]);
    try testing.expectEqual(@as(u8, 2), blobs.rsdp[15]);
    const xsdt = findTable(blobs.tables, "XSDT").?;
    try testing.expectEqual(xsdt.offset, std.mem.readInt(u64, blobs.rsdp[24..32], .little));

    try testing.expectEqual(@as(usize, 0), blobs.loader.len % Loader.COMMAND_SIZE);
    const count = blobs.loader.len / Loader.COMMAND_SIZE;
    // allocate tables, DSDT checksum, FADT pointer+checksum, 5 checksums,
    // 6 XSDT pointers, XSDT checksum, allocate rsdp, rsdp pointer, 2 rsdp
    // checksums.
    try testing.expectEqual(@as(usize, 1 + 1 + 2 + 5 + 6 + 1 + 1 + 1 + 2), count);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, blobs.loader[0..4], .little));
    try testing.expectEqualStrings(TABLES_FILE, std.mem.sliceTo(blobs.loader[4..60], 0));
    // The DSDT's checksum command covers exactly the DSDT.
    const dsdt = findTable(blobs.tables, "DSDT").?;
    const second = blobs.loader[Loader.COMMAND_SIZE..][0..Loader.COMMAND_SIZE];
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, second[0..4], .little));
    try testing.expectEqual(@as(u32, @intCast(dsdt.offset + 9)), std.mem.readInt(u32, second[60..64], .little));
    try testing.expectEqual(@as(u32, @intCast(dsdt.offset)), std.mem.readInt(u32, second[64..68], .little));
    try testing.expectEqual(@as(u32, @intCast(dsdt.length)), std.mem.readInt(u32, second[68..72], .little));

    const last = blobs.loader[(count - 1) * Loader.COMMAND_SIZE ..][0..Loader.COMMAND_SIZE];
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, last[0..4], .little));
    try testing.expectEqualStrings(RSDP_FILE, std.mem.sliceTo(last[4..60], 0));
    try testing.expectEqual(@as(u32, 32), std.mem.readInt(u32, last[60..64], .little));
    try testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, last[68..72], .little));
}

test "madt describes each vCPU with its MPIDR and the redistributor range" {
    var blobs = try build(testing.allocator, test_layout);
    defer blobs.deinit(testing.allocator);
    const madt = findTable(blobs.tables, "APIC").?;
    const body = blobs.tables[madt.offset + 44 ..][0 .. madt.length - 44];
    try testing.expectEqual(@as(u8, 0x0B), body[0]);
    // `body` starts after the 8-byte MADT preamble: 80-byte GICCs, MPIDR at +68.
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, body[68..76], .little)); // MPIDR cpu0
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, body[80 + 68 ..][0..8], .little));
    const gicd = body[160..184];
    try testing.expectEqual(@as(u8, 0x0C), gicd[0]);
    try testing.expectEqual(test_layout.gicd_base, std.mem.readInt(u64, gicd[8..16], .little));
    try testing.expectEqual(@as(u8, 3), gicd[20]);
    const gicr = body[184..200];
    try testing.expectEqual(@as(u8, 0x0E), gicr[0]);
    try testing.expectEqual(@as(u32, 2 * 0x20000), std.mem.readInt(u32, gicr[12..16], .little));
}

test "dsdt begins with a root scope and names the PCIe bridge" {
    var blobs = try build(testing.allocator, test_layout);
    defer blobs.deinit(testing.allocator);
    const dsdt = findTable(blobs.tables, "DSDT").?;
    const aml = blobs.tables[dsdt.offset + HEADER_LEN ..][0 .. dsdt.length - HEADER_LEN];
    try testing.expectEqual(Aml.Op.SCOPE, aml[0]);
    try testing.expect(std.mem.indexOf(u8, aml, "PNP0A08") != null);
    try testing.expect(std.mem.indexOf(u8, aml, "ARMH0011") != null);
    try testing.expect(std.mem.indexOf(u8, aml, "QEMU0002") != null);
    try testing.expect(std.mem.indexOf(u8, aml, "C001") != null);
    try testing.expect(std.mem.indexOf(u8, aml, "_PRT") != null);
    try testing.expectEqual(@as(u8, 2), blobs.tables[dsdt.offset + 8]);
}
