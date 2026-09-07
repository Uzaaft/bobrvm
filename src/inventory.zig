//! Read-only discovery of CLI and native-app VM records. Records retain their
//! owning store and identity; discovery never translates launch configuration.
const Inventory = @This();

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("cli/Config.zig");
const global = @import("global.zig");
const file_compat = @import("compat/file.zig");

arena: std.heap.ArenaAllocator,
entries: []const Entry,

pub const Source = enum { cli, app };
pub const DiskStatus = enum { none, available, missing, inaccessible };

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    source: Source,
    backend: []const u8,
    memory_bytes: u64,
    cpus: u8,
    disk_path: ?[]const u8,
    disk_status: DiskStatus,
    config_path: []const u8,
};

/// Optional roots make discovery usable without either store existing.
pub const Roots = struct {
    cli: ?[]const u8 = null,
    app: ?[]const u8 = null,
};

/// C projection; every pointer remains valid only during visit's callback.
pub const CEntry = extern struct {
    id: [*:0]const u8,
    name: [*:0]const u8,
    backend: [*:0]const u8,
    config_path: [*:0]const u8,
    disk_path: ?[*:0]const u8,
    memory_bytes: u64,
    cpus: u8,
    source: u8,
    disk_status: u8,
};

pub fn visit(
    roots: Roots,
    callback: *const fn (?*anyopaque, *const CEntry) callconv(.c) void,
    userdata: ?*anyopaque,
) !void {
    var inventory = if (roots.cli == null and roots.app == null)
        try discover(std.heap.c_allocator)
    else
        try load(std.heap.c_allocator, roots);
    defer inventory.deinit();
    const alloc = inventory.arena.allocator();
    for (inventory.entries) |entry| {
        const projection = CEntry{
            .id = try alloc.dupeZ(u8, entry.id),
            .name = try alloc.dupeZ(u8, entry.name),
            .backend = try alloc.dupeZ(u8, entry.backend),
            .config_path = try alloc.dupeZ(u8, entry.config_path),
            .disk_path = if (entry.disk_path) |p| try alloc.dupeZ(u8, p) else null,
            .memory_bytes = entry.memory_bytes,
            .cpus = entry.cpus,
            .source = @intFromEnum(entry.source),
            .disk_status = @intFromEnum(entry.disk_status),
        };
        callback(userdata, &projection);
    }
}

const AppRecord = struct {
    id: []const u8,
    name: []const u8,
    memoryBytes: u64,
    vcpuCount: u8,
    diskPath: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    guestSystem: ?[]const u8 = null,
};

pub fn deinit(self: *Inventory) void {
    self.arena.deinit();
}

pub fn discover(alloc: std.mem.Allocator) !Inventory {
    const cli_root = try Config.getConfigDir(alloc);
    defer alloc.free(cli_root);
    const app_root: ?[]const u8 = if (builtin.os.tag == .macos) blk: {
        const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHomeDir);
        break :blk try std.fs.path.join(alloc, &.{
            home, "Library", "Application Support", "Bobrvm", "configs",
        });
    } else null;
    defer if (app_root) |path| alloc.free(path);
    return load(alloc, .{ .cli = cli_root, .app = app_root });
}

/// All returned strings belong to the inventory and survive until deinit.
pub fn load(alloc: std.mem.Allocator, roots: Roots) !Inventory {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    if (roots.cli) |path| try readDirectory(arena.allocator(), &entries, path, .cli);
    if (roots.app) |path| try readDirectory(arena.allocator(), &entries, path, .app);
    std.mem.sort(Entry, entries.items, {}, lessThan);
    return .{ .arena = arena, .entries = try entries.toOwnedSlice(arena.allocator()) };
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn readDirectory(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    path: []const u8,
    source: Source,
) !void {
    var dir = std.Io.Dir.cwd().openDir(global.io(), path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(global.io());
    var iter = dir.iterate();
    while (try iter.next(global.io())) |file| {
        if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".json")) continue;
        const config_path = try std.fs.path.join(alloc, &.{ path, file.name });
        const entry = readRecord(alloc, config_path, file.name, source) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            std.log.scoped(.cli).warn("cannot read VM record '{s}': {}", .{ config_path, err });
            continue;
        };
        try entries.append(alloc, entry);
    }
}

fn readRecord(
    alloc: std.mem.Allocator,
    path: []const u8,
    filename: []const u8,
    source: Source,
) !Entry {
    const file = try std.Io.Dir.cwd().openFile(global.io(), path, .{});
    defer file.close(global.io());
    const bytes = try file_compat.readToEndAlloc(file, alloc, 1024 * 1024);
    defer alloc.free(bytes);
    const key = filename[0 .. filename.len - ".json".len];
    if (key.len == 0) return error.InvalidRecord;
    const options: std.json.ParseOptions = .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    };
    if (source == .cli) {
        const parsed = try std.json.parseFromSlice(Config, alloc, bytes, options);
        const config = parsed.value;
        try config.validate();
        return .{
            .id = try std.fmt.allocPrint(alloc, "cli:{s}", .{key}),
            .name = try alloc.dupe(u8, key),
            .source = .cli,
            .backend = "hypervisor",
            .memory_bytes = config.memory_mb * 1024 * 1024,
            .cpus = config.vcpu_count,
            .disk_path = config.disk_path,
            .disk_status = diskStatus(config.disk_path),
            .config_path = path,
        };
    }
    const parsed = try std.json.parseFromSlice(AppRecord, alloc, bytes, options);
    const config = parsed.value;
    if (!validUUID(key) or !std.ascii.eqlIgnoreCase(key, config.id)) return error.InvalidRecord;
    const id = try std.fmt.allocPrint(alloc, "app:{s}", .{key});
    _ = std.ascii.upperString(id[4..], key);
    return .{
        .id = id,
        .name = config.name,
        .source = .app,
        .backend = config.backend orelse if (std.mem.eql(u8, config.guestSystem orelse "", "macOS"))
            "virtualization"
        else
            "hypervisor",
        .memory_bytes = config.memoryBytes,
        .cpus = config.vcpuCount,
        .disk_path = config.diskPath,
        .disk_status = diskStatus(config.diskPath),
        .config_path = path,
    };
}

fn validUUID(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn diskStatus(path: ?[]const u8) DiskStatus {
    const disk_path = path orelse return .none;
    const file = std.Io.Dir.cwd().openFile(global.io(), disk_path, .{}) catch |err| {
        return if (err == error.FileNotFound) .missing else .inaccessible;
    };
    file.close(global.io());
    return .available;
}

fn writeFixture(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(global.io(), path, .{});
    defer file.close(global.io());
    try file.writeStreamingAll(global.io(), bytes);
}

test "inventory discovers both stores without translating or changing records" {
    const alloc = std.testing.allocator;
    const io = global.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "cli");
    try tmp.dir.createDirPath(io, "app");
    const uuid = "01234567-89ab-cdef-0123-456789abcdef";
    const cli_json = "{\"name\":\"ignored\",\"memory_mb\":1024,\"vcpu_count\":2}";
    const app_json = "{\"id\":\"" ++ uuid ++ "\",\"name\":\"same\"," ++
        "\"memoryBytes\":2147483648,\"vcpuCount\":4,\"backend\":\"future-backend\"," ++
        "\"diskPath\":\"/nonexistent-bobrvm-inventory-test.raw\",\"extra\":true}";
    try writeFixture(tmp.dir, "cli/same.json", cli_json);
    try writeFixture(tmp.dir, "app/" ++ uuid ++ ".json", app_json);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const cli_root = try std.fs.path.join(alloc, &.{ root_buffer[0..root_len], "cli" });
    defer alloc.free(cli_root);
    const app_root = try std.fs.path.join(alloc, &.{ root_buffer[0..root_len], "app" });
    defer alloc.free(app_root);
    var inventory = try load(alloc, .{ .cli = cli_root, .app = app_root });
    defer inventory.deinit();
    try std.testing.expectEqual(2, inventory.entries.len);
    const app = inventory.entries[0];
    const cli = inventory.entries[1];
    try std.testing.expectEqualStrings("app:01234567-89AB-CDEF-0123-456789ABCDEF", app.id);
    try std.testing.expectEqualStrings("future-backend", app.backend);
    try std.testing.expectEqual(DiskStatus.missing, app.disk_status);
    try std.testing.expectEqualStrings("cli:same", cli.id);
    try std.testing.expectEqualStrings(app.name, cli.name);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), cli.memory_bytes);
    try std.testing.expectEqual(DiskStatus.none, cli.disk_status);
    const saved = try tmp.dir.openFile(io, "app/" ++ uuid ++ ".json", .{});
    defer saved.close(io);
    const unchanged = try file_compat.readToEndAlloc(saved, alloc, 4096);
    defer alloc.free(unchanged);
    try std.testing.expectEqualStrings(app_json, unchanged);
    var refreshed = try load(alloc, .{ .cli = cli_root, .app = app_root });
    defer refreshed.deinit();
    try std.testing.expectEqualStrings(app.id, refreshed.entries[0].id);
}

test "inventory handles absent roots and disk availability" {
    var inventory = try load(std.testing.allocator, .{});
    defer inventory.deinit();
    try std.testing.expectEqual(0, inventory.entries.len);
    try std.testing.expect(!validUUID("not-a-uuid"));
    try std.testing.expect(!validUUID("01234567-89ab-cdef-0123-456789abcdeg"));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "disk.raw", "disk");
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(global.io(), &root_buffer);
    const path = try std.fs.path.join(std.testing.allocator, &.{
        root_buffer[0..root_len], "disk.raw",
    });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(DiskStatus.available, diskStatus(path));
}

test "inventory skips malformed records and retains valid neighbours" {
    const alloc = std.testing.allocator;
    const io = global.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const uuid = "01234567-89AB-CDEF-0123-456789ABCDEF";
    const app_json = "{\"id\":\"" ++ uuid ++ "\",\"name\":\"mac\"," ++
        "\"memoryBytes\":2147483648,\"vcpuCount\":4,\"guestSystem\":\"macOS\"}";
    try writeFixture(tmp.dir, uuid ++ ".json", app_json);
    try writeFixture(tmp.dir, "broken.json", "{");
    try writeFixture(tmp.dir, "not-a-uuid.json", app_json);
    try writeFixture(tmp.dir, "11234567-89AB-CDEF-0123-456789ABCDEF.json", app_json);
    try writeFixture(tmp.dir, "ignored.part", "{");
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    var inventory = try load(alloc, .{ .app = root_buffer[0..root_len] });
    defer inventory.deinit();
    try std.testing.expectEqual(1, inventory.entries.len);
    try std.testing.expectEqualStrings("virtualization", inventory.entries[0].backend);
    const missing = try std.fs.path.join(alloc, &.{ root_buffer[0..root_len], "absent" });
    defer alloc.free(missing);
    var empty = try load(alloc, .{ .cli = missing, .app = missing });
    defer empty.deinit();
    try std.testing.expectEqual(0, empty.entries.len);
}
