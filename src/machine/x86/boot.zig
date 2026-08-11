//! Linux x86 bzImage boot protocol parsing.
//!
//! Offsets match `arch/x86/include/uapi/asm/bootparam.h`. Parsing operates on
//! bounded byte slices because the kernel image is external input.

const std = @import("std");

pub const setup_header_offset: usize = 0x1f1;
pub const boot_flag_offset: usize = 0x1fe;
pub const header_magic_offset: usize = 0x202;
pub const protocol_version_offset: usize = 0x206;
pub const loadflags_offset: usize = 0x211;
pub const code32_start_offset: usize = 0x214;
pub const initrd_addr_max_offset: usize = 0x22c;
pub const kernel_alignment_offset: usize = 0x230;
pub const xloadflags_offset: usize = 0x236;
pub const cmdline_size_offset: usize = 0x238;
pub const pref_address_offset: usize = 0x258;
pub const init_size_offset: usize = 0x260;
pub const setup_header_end: usize = 0x26c;

pub const boot_flag: u16 = 0xaa55;
pub const header_magic: u32 = 0x5372_6448;
pub const protocol_version_min: u16 = 0x0206;
pub const loaded_high: u8 = 1 << 0;
pub const kernel_64: u16 = 1 << 0;
pub const boot_params_address: u64 = 0x7000;
pub const boot_params_bytes: usize = 4096;
pub const command_line_address: u64 = 0x2_0000;
pub const kernel_load_address: u64 = 0x10_0000;

const type_of_loader_offset: usize = 0x210;
const ramdisk_image_offset: usize = 0x218;
const ramdisk_size_offset: usize = 0x21c;
const command_line_pointer_offset: usize = 0x228;
const alt_memory_kib_offset: usize = 0x1e0;
const e820_count_offset: usize = 0x1e8;
const e820_table_offset: usize = 0x2d0;
const e820_entry_bytes: usize = 20;
const e820_ram: u32 = 1;
const e820_reserved: u32 = 2;

pub const ParseError = error{
    Truncated,
    InvalidBootFlag,
    InvalidHeaderMagic,
    UnsupportedProtocol,
    KernelNotLoadedHigh,
    KernelNot64Bit,
    InvalidSetupSize,
    EmptyProtectedKernel,
    InvalidKernelAlignment,
};

pub const LoadError = error{
    CommandLineTooLong,
    GuestMemoryTooSmall,
    KernelTooLarge,
    InitrdTooLarge,
    AddressOverflow,
};

pub const Layout = struct {
    entry_address: u64,
    boot_params_address: u64,
    command_line_address: u64,
    initrd_address: ?u64,
};

pub const Image = struct {
    bytes: []const u8,
    setup_bytes: usize,
    protocol_version: u16,
    code32_start: u32,
    initrd_addr_max: u32,
    kernel_alignment: u32,
    cmdline_size: u32,
    preferred_address: u64,
    init_size: u32,

    pub fn parse(bytes: []const u8) ParseError!Image {
        if (bytes.len < setup_header_end) return error.Truncated;
        if (readInt(u16, bytes, boot_flag_offset) != boot_flag) {
            return error.InvalidBootFlag;
        }
        if (readInt(u32, bytes, header_magic_offset) != header_magic) {
            return error.InvalidHeaderMagic;
        }

        const protocol_version = readInt(u16, bytes, protocol_version_offset);
        if (protocol_version < protocol_version_min) return error.UnsupportedProtocol;
        if (bytes[loadflags_offset] & loaded_high == 0) return error.KernelNotLoadedHigh;
        if (readInt(u16, bytes, xloadflags_offset) & kernel_64 == 0) {
            return error.KernelNot64Bit;
        }

        const setup_sectors = if (bytes[setup_header_offset] == 0)
            4
        else
            bytes[setup_header_offset];
        const setup_bytes = (@as(usize, setup_sectors) + 1) * 512;
        if (setup_bytes > bytes.len) return error.InvalidSetupSize;
        if (setup_bytes == bytes.len) return error.EmptyProtectedKernel;

        const kernel_alignment = readInt(u32, bytes, kernel_alignment_offset);
        if (kernel_alignment == 0 or !std.math.isPowerOfTwo(kernel_alignment)) {
            return error.InvalidKernelAlignment;
        }

        return .{
            .bytes = bytes,
            .setup_bytes = setup_bytes,
            .protocol_version = protocol_version,
            .code32_start = readInt(u32, bytes, code32_start_offset),
            .initrd_addr_max = readInt(u32, bytes, initrd_addr_max_offset),
            .kernel_alignment = kernel_alignment,
            .cmdline_size = readInt(u32, bytes, cmdline_size_offset),
            .preferred_address = readInt(u64, bytes, pref_address_offset),
            .init_size = readInt(u32, bytes, init_size_offset),
        };
    }

    pub fn protectedKernel(self: Image) []const u8 {
        return self.bytes[self.setup_bytes..];
    }

    pub fn setupHeader(self: Image) []const u8 {
        return self.bytes[setup_header_offset..setup_header_end];
    }

    pub fn load(
        self: Image,
        guest_memory: []u8,
        command_line: []const u8,
        initrd: ?[]const u8,
    ) LoadError!Layout {
        return self.loadWithHighMemory(guest_memory, 0, command_line, initrd);
    }

    pub fn loadWithHighMemory(
        self: Image,
        guest_memory: []u8,
        high_memory_bytes: usize,
        command_line: []const u8,
        initrd: ?[]const u8,
    ) LoadError!Layout {
        if (command_line.len + 1 > self.cmdline_size) return error.CommandLineTooLong;

        const kernel = self.protectedKernel();
        const kernel_reservation = @max(kernel.len, self.init_size);
        const kernel_end = std.math.add(
            u64,
            kernel_load_address,
            kernel_reservation,
        ) catch return error.AddressOverflow;
        if (kernel_end > guest_memory.len) return error.KernelTooLarge;

        @memcpy(try guestRange(guest_memory, kernel_load_address, kernel.len), kernel);
        try self.writeBootParams(guest_memory, high_memory_bytes, command_line);
        const initrd_address = if (initrd) |bytes|
            try self.loadInitrd(guest_memory, bytes, kernel_end)
        else
            null;

        return .{
            .entry_address = kernel_load_address,
            .boot_params_address = boot_params_address,
            .command_line_address = command_line_address,
            .initrd_address = initrd_address,
        };
    }

    fn writeBootParams(
        self: Image,
        guest_memory: []u8,
        high_memory_bytes: usize,
        command_line: []const u8,
    ) LoadError!void {
        const params = try guestRange(
            guest_memory,
            boot_params_address,
            boot_params_bytes,
        );
        @memset(params, 0);
        @memcpy(
            params[setup_header_offset..setup_header_end],
            self.setupHeader(),
        );
        params[type_of_loader_offset] = 0xff;
        writeInt(u32, params, code32_start_offset, @intCast(kernel_load_address));
        writeInt(u32, params, command_line_pointer_offset, @intCast(command_line_address));
        writeInt(
            u32,
            params,
            alt_memory_kib_offset,
            memoryAboveOneMib(guest_memory.len, high_memory_bytes),
        );
        writeE820(params, guest_memory.len, high_memory_bytes);

        const command_buffer = try guestRange(
            guest_memory,
            command_line_address,
            command_line.len + 1,
        );
        @memcpy(command_buffer[0..command_line.len], command_line);
        command_buffer[command_line.len] = 0;
    }

    fn loadInitrd(
        self: Image,
        guest_memory: []u8,
        initrd: []const u8,
        kernel_end: u64,
    ) LoadError!u64 {
        const limit = @min(
            @as(u64, guest_memory.len),
            @as(u64, self.initrd_addr_max) + 1,
        );
        if (initrd.len > limit) return error.InitrdTooLarge;
        const address = std.mem.alignBackward(u64, limit - initrd.len, 4096);
        if (address < kernel_end) return error.InitrdTooLarge;
        @memcpy(try guestRange(guest_memory, address, initrd.len), initrd);

        const params = try guestRange(
            guest_memory,
            boot_params_address,
            boot_params_bytes,
        );
        writeInt(u32, params, ramdisk_image_offset, @intCast(address));
        writeInt(u32, params, ramdisk_size_offset, @intCast(initrd.len));
        return address;
    }
};

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn guestRange(memory: []u8, address: u64, length: usize) LoadError![]u8 {
    if (address > std.math.maxInt(usize)) return error.AddressOverflow;
    const offset: usize = @intCast(address);
    if (offset > memory.len) return error.GuestMemoryTooSmall;
    if (length > memory.len - offset) return error.GuestMemoryTooSmall;
    return memory[offset..][0..length];
}

fn memoryAboveOneMib(low_memory_bytes: usize, high_memory_bytes: usize) u32 {
    const total_bytes = std.math.add(
        usize,
        low_memory_bytes,
        high_memory_bytes,
    ) catch return std.math.maxInt(u32);
    if (total_bytes <= kernel_load_address) return 0;
    return @intCast(@min(
        (total_bytes - @as(usize, kernel_load_address)) / 1024,
        std.math.maxInt(u32),
    ));
}

fn writeE820(params: []u8, low_memory_bytes: usize, high_memory_bytes: usize) void {
    const Entry = struct { address: u64, size: u64, kind: u32 };
    var entries: [5]Entry = undefined;
    entries[0] = .{ .address = 0, .size = 0x9_fc00, .kind = e820_ram };
    entries[1] = .{ .address = 0x9_fc00, .size = 0x400, .kind = e820_reserved };
    entries[2] = .{ .address = 0xf_0000, .size = 0x1_0000, .kind = e820_reserved };
    entries[3] = .{
        .address = kernel_load_address,
        .size = low_memory_bytes - @as(usize, kernel_load_address),
        .kind = e820_ram,
    };
    var count: u8 = 4;
    if (high_memory_bytes > 0) {
        entries[count] = .{
            .address = 0x1_0000_0000,
            .size = high_memory_bytes,
            .kind = e820_ram,
        };
        count += 1;
    }
    params[e820_count_offset] = count;
    for (entries[0..count], 0..) |entry, index| {
        const offset = e820_table_offset + index * e820_entry_bytes;
        writeInt(u64, params, offset, entry.address);
        writeInt(u64, params, offset + 8, entry.size);
        writeInt(u32, params, offset + 16, entry.kind);
    }
}

fn validImage(storage: []u8) void {
    @memset(storage, 0);
    storage[setup_header_offset] = 1;
    std.mem.writeInt(u16, storage[boot_flag_offset..][0..2], boot_flag, .little);
    std.mem.writeInt(u32, storage[header_magic_offset..][0..4], header_magic, .little);
    std.mem.writeInt(u16, storage[protocol_version_offset..][0..2], 0x020f, .little);
    storage[loadflags_offset] = loaded_high;
    std.mem.writeInt(u32, storage[code32_start_offset..][0..4], 0x10_0000, .little);
    std.mem.writeInt(u32, storage[initrd_addr_max_offset..][0..4], 0x37ff_ffff, .little);
    std.mem.writeInt(u32, storage[kernel_alignment_offset..][0..4], 0x20_0000, .little);
    std.mem.writeInt(u16, storage[xloadflags_offset..][0..2], kernel_64, .little);
    std.mem.writeInt(u32, storage[cmdline_size_offset..][0..4], 2048, .little);
    std.mem.writeInt(u64, storage[pref_address_offset..][0..8], 0x100_0000, .little);
    std.mem.writeInt(u32, storage[init_size_offset..][0..4], 0x80_0000, .little);
}

test "bzImage parser exposes the protected kernel and boot limits" {
    var storage: [2048]u8 = undefined;
    validImage(&storage);

    const image = try Image.parse(&storage);
    try std.testing.expectEqual(@as(usize, 1024), image.setup_bytes);
    try std.testing.expectEqual(@as(usize, 1024), image.protectedKernel().len);
    try std.testing.expectEqual(@as(u32, 0x10_0000), image.code32_start);
    try std.testing.expectEqual(@as(u32, 2048), image.cmdline_size);
    try std.testing.expectEqual(@as(u64, 0x100_0000), image.preferred_address);
}

test "bzImage parser applies the legacy setup sector default" {
    var storage: [3072]u8 = undefined;
    validImage(&storage);
    storage[setup_header_offset] = 0;

    const image = try Image.parse(&storage);
    try std.testing.expectEqual(@as(usize, 5 * 512), image.setup_bytes);
}

test "bzImage parser rejects invalid and unsupported images" {
    var storage: [2048]u8 = undefined;
    validImage(&storage);

    storage[boot_flag_offset] = 0;
    try std.testing.expectError(error.InvalidBootFlag, Image.parse(&storage));
    validImage(&storage);
    storage[xloadflags_offset] = 0;
    try std.testing.expectError(error.KernelNot64Bit, Image.parse(&storage));
    try std.testing.expectError(error.Truncated, Image.parse(storage[0..128]));
}

test "bzImage loader writes kernel command line and E820 map" {
    var image_storage: [2048]u8 = undefined;
    validImage(&image_storage);
    image_storage[1024] = 0xcc;
    std.mem.writeInt(u32, image_storage[init_size_offset..][0..4], 0x20_0000, .little);
    const image = try Image.parse(&image_storage);

    const memory = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(memory);
    @memset(memory, 0xa5);
    const layout = try image.load(memory, "console=ttyS0", null);

    try std.testing.expectEqual(kernel_load_address, layout.entry_address);
    try std.testing.expectEqual(@as(u8, 0xcc), memory[kernel_load_address]);
    try std.testing.expectEqualStrings(
        "console=ttyS0\x00",
        memory[command_line_address..][0..14],
    );
    try std.testing.expectEqual(@as(u8, 4), memory[boot_params_address + e820_count_offset]);
    try std.testing.expectEqual(
        @as(u32, @intCast(kernel_load_address)),
        readInt(u32, memory, boot_params_address + code32_start_offset),
    );
}

test "bzImage loader reports high RAM above the four GiB hole" {
    var image_storage: [2048]u8 = undefined;
    validImage(&image_storage);
    std.mem.writeInt(u32, image_storage[init_size_offset..][0..4], 0x20_0000, .little);
    const image = try Image.parse(&image_storage);

    const memory = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(memory);
    @memset(memory, 0);
    const high_memory_bytes: usize = 1024 * 1024 * 1024;
    _ = try image.loadWithHighMemory(
        memory,
        high_memory_bytes,
        "console=ttyS0",
        null,
    );

    const params = memory[boot_params_address..][0..boot_params_bytes];
    try std.testing.expectEqual(@as(u8, 5), params[e820_count_offset]);
    const high_entry = e820_table_offset + 4 * e820_entry_bytes;
    try std.testing.expectEqual(
        @as(u64, 0x1_0000_0000),
        readInt(u64, params, high_entry),
    );
    try std.testing.expectEqual(
        @as(u64, high_memory_bytes),
        readInt(u64, params, high_entry + 8),
    );
    try std.testing.expectEqual(e820_ram, readInt(u32, params, high_entry + 16));
}

test "bzImage loader places initrd below the kernel limit" {
    var image_storage: [2048]u8 = undefined;
    validImage(&image_storage);
    std.mem.writeInt(u32, image_storage[init_size_offset..][0..4], 0x20_0000, .little);
    const image = try Image.parse(&image_storage);
    const memory = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(memory);
    const initrd = [_]u8{0x5a} ** 8192;

    const layout = try image.load(memory, "console=ttyS0", &initrd);
    const address = layout.initrd_address.?;
    try std.testing.expectEqual(@as(u64, 0), address % 4096);
    try std.testing.expectEqualSlices(u8, &initrd, memory[address..][0..initrd.len]);
}

test "bzImage loader rejects unbounded command lines" {
    var image_storage: [2048]u8 = undefined;
    validImage(&image_storage);
    std.mem.writeInt(u32, image_storage[cmdline_size_offset..][0..4], 4, .little);
    const image = try Image.parse(&image_storage);
    var memory: [4096]u8 = undefined;
    try std.testing.expectError(
        error.CommandLineTooLong,
        image.load(&memory, "1234", null),
    );
}
