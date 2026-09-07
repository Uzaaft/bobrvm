//! Validate a snapshot against its destination before replacing writable disks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const file_compat = @import("../compat/file.zig");
const snapshot = @import("snapshot.zig");

pub const Config = struct {
    disks: [2]?[]const u8,
    ram_bytes: u64,
    vcpu_count: u32,
    block_present: [2]bool = .{ false, false },
    gpu_present: bool = true,
};

const Meta = struct { disks: []struct { orig: []const u8, copy: []const u8 } };
extern "c" fn clonefile([*:0]const u8, [*:0]const u8, u32) c_int;

/// Returns an owned state-image path. All clones finish before any destination is replaced.
/// Replacement uses atomic rename per disk; it is not a transaction across multiple disks.
pub fn restore(alloc: Allocator, directory: []const u8, config: Config) ![]u8 {
    const state_path = try std.fs.path.join(alloc, &.{ directory, "state.img" });
    errdefer alloc.free(state_path);
    try validateState(state_path, config);
    const meta_path = try std.fs.path.join(alloc, &.{ directory, "meta.json" });
    defer alloc.free(meta_path);
    const io = global.io();
    const file = try std.Io.Dir.cwd().openFile(io, meta_path, .{});
    defer file.close(io);
    const bytes = try file_compat.readToEndAlloc(file, alloc, 32 * 1024);
    defer alloc.free(bytes);
    const meta = try std.json.parseFromSlice(Meta, alloc, bytes, .{});
    defer meta.deinit();
    try validateDisks(meta.value, config);
    try restoreDisks(alloc, directory, meta.value);
    return state_path;
}

fn validateDisks(meta: Meta, config: Config) !void {
    if (meta.disks.len > 2) return error.DiskMismatch;
    var index: usize = 0;
    for (config.disks) |candidate| {
        const path = candidate orelse continue;
        if (index >= meta.disks.len) return error.DiskMismatch;
        const disk = meta.disks[index];
        const copy = if (index == 0) "disk0.raw" else "disk1.raw";
        if (!std.mem.eql(u8, disk.orig, path) or !std.mem.eql(u8, disk.copy, copy)) {
            return error.DiskMismatch;
        }
        index += 1;
    }
    if (index != meta.disks.len) return error.DiskMismatch;
}

fn restoreDisks(alloc: Allocator, directory: []const u8, meta: Meta) !void {
    const io = global.io();
    const cwd = std.Io.Dir.cwd();
    var staged: [2]?[:0]u8 = .{ null, null };
    defer for (staged) |path| {
        if (path) |p| {
            cwd.deleteFile(io, p) catch {};
            alloc.free(p);
        }
    };
    for (meta.disks, 0..) |disk, i| {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const destination = try std.fmt.allocPrintSentinel(
            alloc,
            "{s}.restore-{x}",
            .{ disk.orig, std.mem.readInt(u128, &nonce, .little) },
            0,
        );
        errdefer alloc.free(destination);
        const source = try std.fmt.allocPrintSentinel(
            alloc,
            "{s}/{s}",
            .{ directory, disk.copy },
            0,
        );
        defer alloc.free(source);
        if (clonefile(source.ptr, destination.ptr, 0) != 0) return error.CloneFailed;
        staged[i] = destination;
    }
    for (meta.disks, 0..) |disk, i| {
        try cwd.rename(staged[i].?, cwd, disk.orig, io);
    }
}

fn readExact(file: std.Io.File, bytes: []u8, offset: u64) !void {
    if (try file.readPositionalAll(global.io(), bytes, offset) != bytes.len) {
        return error.BadImage;
    }
}

fn validateState(path: []const u8, config: Config) !void {
    const io = global.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var header: [28]u8 = undefined;
    try readExact(file, &header, 0);
    if (!std.mem.eql(u8, header[0..8], "BBRVSUSP")) return error.BadImage;
    if (std.mem.readInt(u32, header[8..12], .little) != 1) return error.BadVersion;
    const state_bytes = std.mem.readInt(u64, header[12..20], .little);
    const ram_bytes = std.mem.readInt(u64, header[20..28], .little);
    if (ram_bytes != config.ram_bytes) return error.RamSizeMismatch;
    const state_end = std.math.add(u64, 28, state_bytes) catch return error.BadImage;
    const end = std.math.add(u64, state_end, ram_bytes) catch return error.BadImage;
    if ((try file.stat(io)).size != end or state_bytes < 12) return error.BadImage;
    var container: [12]u8 = undefined;
    try readExact(file, &container, 28);
    if (!std.mem.eql(u8, container[0..8], snapshot.MAGIC)) return error.BadImage;
    if (std.mem.readInt(u32, container[8..12], .little) != snapshot.VERSION) {
        return error.BadVersion;
    }
    try validateSections(file, state_end, config);
}

fn validateSections(file: std.Io.File, end: u64, config: Config) !void {
    var offset: u64 = 40;
    var seen: u64 = 0;
    var count: usize = 0;
    var devices: [3]bool = @splat(false);
    while (offset < end) {
        count += 1;
        if (count > 128) return error.BadImage;
        var length: [1]u8 = undefined;
        try readExact(file, &length, offset);
        offset += 1;
        if (length[0] == 0 or @as(u64, length[0]) + 8 > end - offset) {
            return error.BadImage;
        }
        var name_buffer: [255]u8 = undefined;
        const name = name_buffer[0..length[0]];
        try readExact(file, name, offset);
        offset += name.len;
        var size_buffer: [8]u8 = undefined;
        try readExact(file, &size_buffer, offset);
        offset += 8;
        const size = std.mem.readInt(u64, &size_buffer, .little);
        if (size > end - offset) return error.BadImage;
        if (std.mem.startsWith(u8, name, "vcpu")) {
            const cpu = std.fmt.parseInt(u32, name[4..], 10) catch return error.BadImage;
            if (cpu >= config.vcpu_count or cpu >= 64) return error.VcpuCountMismatch;
            const mask = @as(u64, 1) << @intCast(cpu);
            if (seen & mask != 0 or size != @sizeOf(snapshot.VcpuState)) return error.BadImage;
            seen |= mask;
        }
        inline for (.{ "blk1", "blk2", "gpu" }, 0..) |device, i| {
            if (std.mem.eql(u8, name, device)) {
                if (devices[i]) return error.BadImage;
                devices[i] = true;
            }
        }
        offset += size;
    }
    if (seen & 1 == 0) return error.BadImage;
    const expected = [3]bool{ config.block_present[0], config.block_present[1], config.gpu_present };
    if (!std.mem.eql(bool, &devices, &expected)) return error.DeviceMismatch;
}

fn writeFixture(directory: std.Io.Dir, config: Config) !void {
    const alloc = std.testing.allocator;
    var builder = try snapshot.Builder.init(alloc);
    defer builder.deinit();
    const cpu = snapshot.VcpuState{};
    try builder.section("vcpu0", std.mem.asBytes(&cpu));
    inline for (.{ "blk1", "blk2", "gpu" }, 0..) |name, i| {
        const present = if (i < 2) config.block_present[i] else config.gpu_present;
        if (present) try builder.section(name, "");
    }
    const state = try builder.finish();
    defer alloc.free(state);
    const io = global.io();
    const file = try directory.createFile(io, "state.img", .{});
    defer file.close(io);
    var header: [28]u8 = undefined;
    @memcpy(header[0..8], "BBRVSUSP");
    std.mem.writeInt(u32, header[8..12], 1, .little);
    std.mem.writeInt(u64, header[12..20], state.len, .little);
    std.mem.writeInt(u64, header[20..28], config.ram_bytes, .little);
    try file.writePositionalAll(io, &header, 0);
    try file.writePositionalAll(io, state, 28);
    if (std.c.ftruncate(file.handle, @intCast(28 + state.len + config.ram_bytes)) != 0) {
        return error.Truncate;
    }
}

fn writeTestFile(directory: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try directory.createFile(global.io(), path, .{});
    defer file.close(global.io());
    try file.writePositionalAll(global.io(), bytes, 0);
}

fn expectTestFile(directory: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const file = try directory.openFile(global.io(), path, .{});
    defer file.close(global.io());
    const bytes = try file_compat.readToEndAlloc(file, std.testing.allocator, 128);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "snapshot directory validates state and topology before disk writes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(global.io(), &buffer)];
    const disk = try std.fs.path.join(alloc, &.{ root, "original.raw" });
    defer alloc.free(disk);
    const config = Config{
        .disks = .{ disk, null },
        .ram_bytes = 4096,
        .vcpu_count = 1,
        .block_present = .{ true, false },
    };
    try writeFixture(tmp.dir, config);
    try writeTestFile(tmp.dir, "original.raw", "original");
    try writeTestFile(tmp.dir, "disk0.raw", "snapshot");
    const metadata = try std.fmt.allocPrint(
        alloc,
        "{{\"disks\":[{{\"orig\":\"{s}\",\"copy\":\"disk0.raw\"}}]}}",
        .{disk},
    );
    defer alloc.free(metadata);
    try writeTestFile(tmp.dir, "meta.json", metadata);
    var wrong = config;
    wrong.ram_bytes *= 2;
    try std.testing.expectError(error.RamSizeMismatch, restore(alloc, root, wrong));
    wrong = config;
    wrong.block_present = .{ false, false };
    try std.testing.expectError(error.DeviceMismatch, restore(alloc, root, wrong));
    wrong = config;
    wrong.disks = .{ "/unrelated.raw", null };
    try std.testing.expectError(error.DiskMismatch, restore(alloc, root, wrong));
    const image = try tmp.dir.openFile(global.io(), "state.img", .{ .mode = .read_write });
    try image.writePositionalAll(global.io(), "1", 45);
    try std.testing.expectError(error.VcpuCountMismatch, restore(alloc, root, config));
    try image.writePositionalAll(global.io(), "0", 45);
    const size = (try image.stat(global.io())).size;
    try image.writePositionalAll(global.io(), "extra", size);
    try std.testing.expectError(error.BadImage, restore(alloc, root, config));
    image.close(global.io());
    try writeFixture(tmp.dir, config);
    try expectTestFile(tmp.dir, "original.raw", "original");
    const path = try restore(alloc, root, config);
    defer alloc.free(path);
    try expectTestFile(tmp.dir, "original.raw", "snapshot");
}

test "snapshot directory rejects manifest destinations and stages all clones" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(global.io(), &buffer)];
    const first = try std.fs.path.join(alloc, &.{ root, "first.raw" });
    defer alloc.free(first);
    const second = try std.fs.path.join(alloc, &.{ root, "second.raw" });
    defer alloc.free(second);
    const config = Config{
        .disks = .{ first, second },
        .ram_bytes = 4096,
        .vcpu_count = 1,
        .block_present = .{ true, true },
    };
    try writeFixture(tmp.dir, config);
    try writeTestFile(tmp.dir, "first.raw", "first original");
    try writeTestFile(tmp.dir, "second.raw", "second original");
    try writeTestFile(tmp.dir, "disk0.raw", "snapshot");
    try writeTestFile(tmp.dir, "meta.json", "{\"disks\":[]}");
    try std.testing.expectError(error.DiskMismatch, restore(alloc, root, config));
    const metadata = try std.fmt.allocPrint(alloc, "{{\"disks\":[{{\"orig\":\"{s}\",\"copy\":\"disk0.raw\"}}," ++
        "{{\"orig\":\"{s}\",\"copy\":\"disk1.raw\"}}]}}", .{ first, second });
    defer alloc.free(metadata);
    try writeTestFile(tmp.dir, "meta.json", metadata);
    try std.testing.expectError(error.CloneFailed, restore(alloc, root, config));
    try expectTestFile(tmp.dir, "first.raw", "first original");
    try expectTestFile(tmp.dir, "second.raw", "second original");
}
