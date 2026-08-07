//! Intel MultiProcessor Specification tables for direct x86 Linux boot.
//!
//! The tables live in the legacy BIOS search window so a protected-mode
//! kernel can discover CPU and interrupt topology without ACPI firmware.

const std = @import("std");

pub const table_address: u64 = 0x000f_0000;
pub const bytes_max: usize = 64 * 1024;
pub const cpu_count_max: u8 = 64;

const floating_bytes: usize = 16;
const config_header_bytes: usize = 44;
const processor_entry_bytes: usize = 20;
const bus_entry_bytes: usize = 8;
const io_apic_entry_bytes: usize = 8;
const interrupt_entry_bytes: usize = 8;
const isa_irq_count: usize = 16;
const pci_device_count: usize = 8;

pub const WriteError = error{
    BufferTooSmall,
    InvalidCpuCount,
};

pub fn write(memory: []u8, cpu_count: u8) WriteError!usize {
    if (cpu_count == 0 or cpu_count > cpu_count_max) return error.InvalidCpuCount;
    const table_bytes = configTableBytes(cpu_count);
    const total_bytes = floating_bytes + table_bytes;
    if (memory.len < total_bytes) return error.BufferTooSmall;
    @memset(memory[0..total_bytes], 0);

    const config_address = table_address + floating_bytes;
    writeFloatingPointer(memory[0..floating_bytes], config_address);
    writeConfigTable(memory[floating_bytes..total_bytes], cpu_count);
    return total_bytes;
}

fn configTableBytes(cpu_count: u8) usize {
    return config_header_bytes + @as(usize, cpu_count) * processor_entry_bytes +
        2 * bus_entry_bytes + io_apic_entry_bytes +
        (isa_irq_count + pci_device_count) * interrupt_entry_bytes;
}

fn writeFloatingPointer(bytes: []u8, config_address: u64) void {
    std.debug.assert(bytes.len == floating_bytes);
    std.debug.assert(config_address <= std.math.maxInt(u32));
    @memcpy(bytes[0..4], "_MP_");
    writeInt(u32, bytes, 4, @intCast(config_address));
    bytes[8] = 1;
    bytes[9] = 4;
    bytes[10] = checksum(bytes);
}

fn writeConfigTable(bytes: []u8, cpu_count: u8) void {
    std.debug.assert(bytes.len == configTableBytes(cpu_count));
    @memcpy(bytes[0..4], "PCMP");
    writeInt(u16, bytes, 4, @intCast(bytes.len));
    bytes[6] = 4;
    @memcpy(bytes[8..16], "BOBRVM  ");
    @memcpy(bytes[16..28], "BOBRVM KVM  ");
    writeInt(u16, bytes, 34, @intCast(cpu_count + 2 + 1 + isa_irq_count + pci_device_count));
    writeInt(u32, bytes, 36, 0xfee0_0000);

    var offset: usize = config_header_bytes;
    for (0..cpu_count) |cpu_id| {
        writeProcessor(bytes[offset..][0..processor_entry_bytes], @intCast(cpu_id));
        offset += processor_entry_bytes;
    }
    writeBus(bytes[offset..][0..bus_entry_bytes], 0, "PCI   ");
    offset += bus_entry_bytes;
    writeBus(bytes[offset..][0..bus_entry_bytes], 1, "ISA   ");
    offset += bus_entry_bytes;

    const io_apic_id = cpu_count;
    writeIoApic(bytes[offset..][0..io_apic_entry_bytes], io_apic_id);
    offset += io_apic_entry_bytes;
    for (0..isa_irq_count) |irq| {
        writeInterrupt(
            bytes[offset..][0..interrupt_entry_bytes],
            1,
            @intCast(irq),
            io_apic_id,
            @intCast(irq),
        );
        offset += interrupt_entry_bytes;
    }
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 2 << 2, io_apic_id, 11);
    offset += interrupt_entry_bytes;
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 3 << 2, io_apic_id, 10);
    offset += interrupt_entry_bytes;
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 5 << 2, io_apic_id, 5);
    offset += interrupt_entry_bytes;
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 6 << 2, io_apic_id, 6);
    offset += interrupt_entry_bytes;
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 7 << 2, io_apic_id, 7);
    offset += interrupt_entry_bytes;
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 8 << 2, io_apic_id, 12);
    offset += interrupt_entry_bytes;
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 9 << 2, io_apic_id, 13);
    offset += interrupt_entry_bytes;
    writeInterrupt(bytes[offset..][0..interrupt_entry_bytes], 0, 10 << 2, io_apic_id, 9);
    offset += interrupt_entry_bytes;
    std.debug.assert(offset == bytes.len);
    bytes[7] = checksum(bytes);
}

fn writeProcessor(bytes: []u8, cpu_id: u8) void {
    bytes[0] = 0;
    bytes[1] = cpu_id;
    bytes[2] = 0x14;
    bytes[3] = 1 | if (cpu_id == 0) @as(u8, 2) else 0;
    writeInt(u32, bytes, 4, 0x0000_0600);
}

fn writeBus(bytes: []u8, id: u8, kind: *const [6]u8) void {
    bytes[0] = 1;
    bytes[1] = id;
    @memcpy(bytes[2..8], kind);
}

fn writeIoApic(bytes: []u8, id: u8) void {
    bytes[0] = 2;
    bytes[1] = id;
    bytes[2] = 0x11;
    bytes[3] = 1;
    writeInt(u32, bytes, 4, 0xfec0_0000);
}

fn writeInterrupt(bytes: []u8, bus: u8, source: u8, apic: u8, input: u8) void {
    bytes[0] = 3;
    bytes[1] = 0;
    writeInt(u16, bytes, 2, 0);
    bytes[4] = bus;
    bytes[5] = source;
    bytes[6] = apic;
    bytes[7] = input;
}

fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    return 0 -% sum;
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

test "MP tables publish each CPU and have valid checksums" {
    var memory: [bytes_max]u8 = undefined;
    const written = try write(&memory, 4);
    const table = memory[floating_bytes..written];

    try std.testing.expectEqual(@as(u8, 0), 0 -% checksum(memory[0..floating_bytes]));
    try std.testing.expectEqual(@as(u8, 0), 0 -% checksum(table));
    try std.testing.expectEqual(@as(u16, 30), std.mem.readInt(u16, table[34..36], .little));
    for (0..4) |index| {
        const offset = config_header_bytes + index * processor_entry_bytes;
        try std.testing.expectEqual(@as(u8, 0), table[offset]);
        try std.testing.expectEqual(@as(u8, @intCast(index)), table[offset + 1]);
    }
}

test "MP table writer rejects invalid CPU counts and short buffers" {
    var memory: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidCpuCount, write(&memory, 0));
    try std.testing.expectError(error.BufferTooSmall, write(&memory, 2));
}
