//! VM configuration with JSON serialization.
//!
//! Stored at ~/.config/bobrvm/vms/<name>.json

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const Config = @This();

const log = std.log.scoped(.cli);

name: []const u8 = "",
memory_mb: u64 = 512,
vcpu_count: u8 = 2,
firmware_path: ?[]const u8 = null,
vars_path: ?[]const u8 = null,
disk_path: ?[]const u8 = null,
disk_read_only: bool = false,
disk2_path: ?[]const u8 = null,
disk2_read_only: bool = true,
kernel_path: ?[]const u8 = null,
initrd_path: ?[]const u8 = null,
cmdline: []const u8 = "console=hvc0 earlycon=pl011,0x09000000",
enable_gpu: bool = false,
enable_virgl: bool = false,
enable_net: bool = false,
display_width: u32 = 1280,
display_height: u32 = 800,

pub const ParseError = error{
    InvalidArgument,
    HelpRequested,
    MissingName,
};

pub fn parseArgs(args: *std.process.ArgIterator) (Allocator.Error || ParseError)!Config {
    var config = Config{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return ParseError.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--memory") or std.mem.eql(u8, arg, "-m")) {
            const val = args.next() orelse {
                log.err("--memory requires a value", .{});
                return ParseError.InvalidArgument;
            };
            config.memory_mb = std.fmt.parseInt(u64, val, 10) catch {
                log.err("invalid memory value: {s}", .{val});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--cpus") or std.mem.eql(u8, arg, "-c")) {
            const val = args.next() orelse {
                log.err("--cpus requires a value", .{});
                return ParseError.InvalidArgument;
            };
            config.vcpu_count = std.fmt.parseInt(u8, val, 10) catch {
                log.err("invalid cpus value: {s}", .{val});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--firmware")) {
            config.firmware_path = args.next() orelse {
                log.err("--firmware requires a value", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--vars")) {
            config.vars_path = args.next() orelse {
                log.err("--vars requires a value", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--disk") or std.mem.eql(u8, arg, "-d")) {
            config.disk_path = args.next() orelse {
                log.err("--disk requires a value", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--disk-readonly")) {
            config.disk_read_only = true;
        } else if (std.mem.eql(u8, arg, "--disk2")) {
            config.disk2_path = args.next() orelse {
                log.err("--disk2 requires a value", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--disk2-readonly")) {
            config.disk2_read_only = true;
        } else if (std.mem.eql(u8, arg, "--disk2-writable")) {
            config.disk2_read_only = false;
        } else if (std.mem.eql(u8, arg, "--kernel") or std.mem.eql(u8, arg, "-k")) {
            config.kernel_path = args.next() orelse {
                log.err("--kernel requires a value", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--initrd") or std.mem.eql(u8, arg, "-i")) {
            config.initrd_path = args.next() orelse {
                log.err("--initrd requires a value", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--cmdline")) {
            config.cmdline = args.next() orelse {
                log.err("--cmdline requires a value", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            config.enable_gpu = true;
        } else if (std.mem.eql(u8, arg, "--virgl")) {
            config.enable_gpu = true;
            config.enable_virgl = true;
        } else if (std.mem.eql(u8, arg, "--net")) {
            config.enable_net = true;
        } else if (std.mem.eql(u8, arg, "--display")) {
            const val = args.next() orelse {
                log.err("--display requires a value (e.g. 1280x800)", .{});
                return ParseError.InvalidArgument;
            };
            const sep = std.mem.indexOfScalar(u8, val, 'x') orelse {
                log.err("--display format is WIDTHxHEIGHT", .{});
                return ParseError.InvalidArgument;
            };
            config.display_width = std.fmt.parseInt(u32, val[0..sep], 10) catch {
                log.err("invalid display width", .{});
                return ParseError.InvalidArgument;
            };
            config.display_height = std.fmt.parseInt(u32, val[sep + 1 ..], 10) catch {
                log.err("invalid display height", .{});
                return ParseError.InvalidArgument;
            };
        } else {
            log.warn("unknown argument: {s}", .{arg});
        }
    }

    try config.validate();
    return config;
}

pub fn validate(self: *const Config) ParseError!void {
    if (self.disk_path) |disk_path| {
        if (std.mem.endsWith(u8, disk_path, ".iso") and !self.disk_read_only) {
            log.err("ISO images must be opened read-only (use --disk-readonly)", .{});
            return ParseError.InvalidArgument;
        }
    }

    if (self.disk2_path) |disk2_path| {
        if (std.mem.endsWith(u8, disk2_path, ".iso") and !self.disk2_read_only) {
            log.err("ISO images must be opened read-only (use --disk2-readonly)", .{});
            return ParseError.InvalidArgument;
        }
    }
}

pub fn getConfigDir(alloc: Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fs.path.join(alloc, &.{ home, ".config", "bobrvm", "vms" });
}

pub fn ensureConfigDir(alloc: Allocator) ![]const u8 {
    const dir_path = try getConfigDir(alloc);
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            const parent = std.fs.path.dirname(dir_path) orelse return err;
            std.fs.makeDirAbsolute(parent) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        },
    };
    return dir_path;
}

pub fn getConfigPath(alloc: Allocator, name: []const u8) ![]const u8 {
    const dir = try getConfigDir(alloc);
    defer alloc.free(dir);
    const filename = try std.fmt.allocPrint(alloc, "{s}.json", .{name});
    defer alloc.free(filename);
    return std.fs.path.join(alloc, &.{ dir, filename });
}

pub fn save(self: *const Config, alloc: Allocator) !void {
    if (self.name.len == 0) return ParseError.MissingName;

    const dir_path = try ensureConfigDir(alloc);
    defer alloc.free(dir_path);

    const config_path = try getConfigPath(alloc, self.name);
    defer alloc.free(config_path);

    const json_bytes = try std.json.Stringify.valueAlloc(alloc, self.*, .{ .whitespace = .indent_2 });
    defer alloc.free(json_bytes);

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    _ = try file.write(json_bytes);
    _ = try file.write("\n");
}

pub const LoadedConfig = struct {
    config: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LoadedConfig) void {
        self.arena.deinit();
    }
};

pub fn load(alloc: Allocator, name: []const u8) !LoadedConfig {
    const config_path = try getConfigPath(alloc, name);
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.err("VM '{s}' not found", .{name});
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSlice(Config, arena.allocator(), content, .{
        .ignore_unknown_fields = true,
    });

    var config = parsed.value;
    config.name = try arena.allocator().dupe(u8, name);

    return .{
        .config = config,
        .arena = arena,
    };
}

pub fn delete(alloc: Allocator, name: []const u8) !void {
    const config_path = try getConfigPath(alloc, name);
    defer alloc.free(config_path);

    std.fs.deleteFileAbsolute(config_path) catch |err| {
        if (err == error.FileNotFound) {
            log.err("VM '{s}' not found", .{name});
        }
        return err;
    };
}

pub fn listAll(alloc: Allocator) ![][]const u8 {
    const dir_path = try getConfigDir(alloc);
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return &.{};
        }
        return err;
    };
    defer dir.close();

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const name = entry.name[0 .. entry.name.len - 5];
        try names.append(alloc, try alloc.dupe(u8, name));
    }

    return names.toOwnedSlice(alloc);
}

pub fn printOptions() void {
    const help =
        \\VM Configuration Options:
        \\  -m, --memory <MB>     RAM size in MB (default: 512)
        \\  -c, --cpus <N>        Number of vCPUs (default: 2)
        \\  --firmware <path>     UEFI firmware (e.g., QEMU_EFI.fd)
        \\  --vars <path>         UEFI variables file
        \\  -d, --disk <path>     Primary disk image
        \\  --disk-readonly       Open primary disk read-only
        \\  --disk2 <path>        Secondary disk (e.g., ISO)
        \\  --disk2-readonly      Open secondary disk read-only
        \\  --disk2-writable      Open secondary disk read-write
        \\  -k, --kernel <path>   Kernel image (direct boot)
        \\  -i, --initrd <path>   Initrd image
        \\  --cmdline <str>       Kernel command line
        \\
    ;
    _ = std.posix.write(std.posix.STDOUT_FILENO, help) catch {};
}
