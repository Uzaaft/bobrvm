//! VM configuration with JSON serialization.
//!
//! Stored at ~/.config/bobrvm/vms/<name>.json

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const file_compat = @import("../compat/file.zig");
const config_policy = @import("../config.zig");

const Config = @This();

const log = std.log.scoped(.cli);

name: []const u8 = "",
memory_mb: u64 = config_policy.memory_bytes_default / (1024 * 1024),
vcpu_count: u8 = config_policy.vcpu_count_default,
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
enable_snd: bool = false,
display_width: u32 = config_policy.display_width_default,
display_height: u32 = config_policy.display_height_default,
gpu_memory_mb: u64 = config_policy.gpu_memory_bytes_default / (1024 * 1024),
/// Host→guest TCP port forwards (--forward host:guest, repeatable).
forwards: [MAX_FORWARDS]PortForward = @splat(.{}),
forward_count: u8 = 0,
/// Host directory shared with the guest via 9p (--share).
shared_dir: ?[]const u8 = null,
/// Suspend image to restore instead of booting (--restore).
restore_path: ?[]const u8 = null,

pub const MAX_FORWARDS = 8;

pub const PortForward = struct {
    host_port: u16 = 0,
    guest_port: u16 = 0,
};

pub const ParseError = error{
    InvalidArgument,
    InvalidName,
    HelpRequested,
    MissingName,
};

pub fn parseArgs(args: *std.process.Args.Iterator) (Allocator.Error || ParseError)!Config {
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
        } else if (std.mem.eql(u8, arg, "--sound")) {
            config.enable_snd = true;
        } else if (std.mem.eql(u8, arg, "--net")) {
            config.enable_net = true;
        } else if (std.mem.eql(u8, arg, "--share")) {
            config.shared_dir = args.next() orelse {
                log.err("--share requires a directory path", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--restore")) {
            config.restore_path = args.next() orelse {
                log.err("--restore requires a suspend image path", .{});
                return ParseError.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--forward")) {
            const val = args.next() orelse {
                log.err("--forward requires a value (host_port:guest_port)", .{});
                return ParseError.InvalidArgument;
            };
            if (config.forward_count >= MAX_FORWARDS) {
                log.err("too many --forward rules (max {})", .{MAX_FORWARDS});
                return ParseError.InvalidArgument;
            }
            const sep = std.mem.indexOfScalar(u8, val, ':') orelse {
                log.err("--forward format is host_port:guest_port", .{});
                return ParseError.InvalidArgument;
            };
            const hp = std.fmt.parseInt(u16, val[0..sep], 10) catch 0;
            const gp = std.fmt.parseInt(u16, val[sep + 1 ..], 10) catch 0;
            if (hp == 0 or gp == 0) {
                log.err("invalid --forward ports: {s}", .{val});
                return ParseError.InvalidArgument;
            }
            config.forwards[config.forward_count] = .{ .host_port = hp, .guest_port = gp };
            config.forward_count += 1;
            // Forwarding implies networking.
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
        } else if (std.mem.eql(u8, arg, "--gpu-memory")) {
            const val = args.next() orelse {
                log.err("--gpu-memory requires a value in MB", .{});
                return ParseError.InvalidArgument;
            };
            config.gpu_memory_mb = std.fmt.parseInt(u64, val, 10) catch {
                log.err("invalid GPU memory value: {s}", .{val});
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
    if (self.forward_count > MAX_FORWARDS) return ParseError.InvalidArgument;
    for (self.forwards[0..self.forward_count], 0..) |forward, index| {
        if (forward.host_port == 0 or forward.guest_port == 0) {
            return ParseError.InvalidArgument;
        }
        for (self.forwards[0..index]) |earlier| {
            if (earlier.host_port == forward.host_port) return ParseError.InvalidArgument;
        }
    }
    const memory_bytes = std.math.mul(u64, self.memory_mb, 1024 * 1024) catch {
        return ParseError.InvalidArgument;
    };
    config_policy.validate(.{
        .memory_bytes = memory_bytes,
        .vcpu_count = self.vcpu_count,
        .display_width = self.display_width,
        .display_height = self.display_height,
        .gpu_memory_bytes = std.math.mul(u64, self.gpu_memory_mb, 1024 * 1024) catch {
            return ParseError.InvalidArgument;
        },
        .disk_path = self.disk_path,
        .disk_read_only = self.disk_read_only,
        .disk2_path = self.disk2_path,
        .disk2_read_only = self.disk2_read_only,
    }) catch {
        return ParseError.InvalidArgument;
    };
}

pub fn getConfigDir(alloc: Allocator) ![]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHomeDir);
    return std.fs.path.join(alloc, &.{ home, ".config", "bobrvm", "vms" });
}

pub fn ensureConfigDir(alloc: Allocator) ![]const u8 {
    const dir_path = try getConfigDir(alloc);
    std.Io.Dir.createDirAbsolute(global.io(), dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            const parent = std.fs.path.dirname(dir_path) orelse return err;
            std.Io.Dir.createDirAbsolute(global.io(), parent, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            std.Io.Dir.createDirAbsolute(global.io(), dir_path, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        },
    };
    return dir_path;
}

pub fn getConfigPath(alloc: Allocator, name: []const u8) ![]const u8 {
    try validateName(name);
    const dir = try getConfigDir(alloc);
    defer alloc.free(dir);
    const filename = try std.fmt.allocPrint(alloc, "{s}.json", .{name});
    defer alloc.free(filename);
    return std.fs.path.join(alloc, &.{ dir, filename });
}

pub fn getVarsPath(alloc: Allocator, name: []const u8) ![]const u8 {
    try validateName(name);
    const dir = try getConfigDir(alloc);
    defer alloc.free(dir);
    const filename = try std.fmt.allocPrint(alloc, "{s}.vars.fd", .{name});
    defer alloc.free(filename);
    return std.fs.path.join(alloc, &.{ dir, filename });
}

/// Create a private writable UEFI variable store once and return its owned path.
pub fn ensureVars(alloc: Allocator, name: []const u8, template_path: []const u8) ![]const u8 {
    const dir = try ensureConfigDir(alloc);
    defer alloc.free(dir);
    const vars_path = try getVarsPath(alloc, name);
    errdefer alloc.free(vars_path);
    const existing = std.Io.Dir.openFileAbsolute(global.io(), vars_path, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        const template = try std.Io.Dir.cwd().openFile(global.io(), template_path, .{
            .mode = .read_only,
        });
        defer template.close(global.io());
        const bytes = try file_compat.readToEndAlloc(template, alloc, 16 * 1024 * 1024);
        defer alloc.free(bytes);
        if (bytes.len == 0 or bytes.len % std.heap.page_size_min != 0) {
            return error.InvalidFirmwareVariables;
        }
        const output = try std.Io.Dir.createFileAbsolute(global.io(), vars_path, .{});
        defer output.close(global.io());
        try output.writePositionalAll(global.io(), bytes, 0);
        return vars_path;
    };
    existing.close(global.io());
    return vars_path;
}

pub fn save(self: *const Config, alloc: Allocator) !void {
    try validateName(self.name);

    const dir_path = try ensureConfigDir(alloc);
    defer alloc.free(dir_path);

    const config_path = try getConfigPath(alloc, self.name);
    defer alloc.free(config_path);

    const json_bytes = try std.json.Stringify.valueAlloc(alloc, self.*, .{ .whitespace = .indent_2 });
    defer alloc.free(json_bytes);

    const file = try std.Io.Dir.createFileAbsolute(global.io(), config_path, .{});
    defer file.close(global.io());

    try file.writePositionalAll(global.io(), json_bytes, 0);
    try file.writePositionalAll(global.io(), "\n", json_bytes.len);
}

pub fn validateName(name: []const u8) ParseError!void {
    const suffix = ".json";

    if (name.len == 0) return error.MissingName;
    if (name.len > std.Io.Dir.max_name_bytes - suffix.len) return error.InvalidName;
    if (std.mem.indexOfAny(u8, name, "/\x00") != null) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.InvalidName;
    }
}

pub const LoadedConfig = struct {
    config: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LoadedConfig) void {
        self.arena.deinit();
    }
};

pub fn load(alloc: Allocator, name: []const u8) !LoadedConfig {
    try validateName(name);
    const config_path = try getConfigPath(alloc, name);
    defer alloc.free(config_path);

    const file = std.Io.Dir.openFileAbsolute(global.io(), config_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.err("VM '{s}' not found", .{name});
        }
        return err;
    };
    defer file.close(global.io());

    const content = try file_compat.readToEndAlloc(file, alloc, 1024 * 1024);
    defer alloc.free(content);

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSlice(Config, arena.allocator(), content, .{
        .ignore_unknown_fields = true,
    });

    var config = parsed.value;
    config.name = try arena.allocator().dupe(u8, name);
    try config.validate();

    return .{
        .config = config,
        .arena = arena,
    };
}

pub fn delete(alloc: Allocator, name: []const u8) !void {
    try validateName(name);
    const config_path = try getConfigPath(alloc, name);
    defer alloc.free(config_path);

    std.Io.Dir.deleteFileAbsolute(global.io(), config_path) catch |err| {
        if (err == error.FileNotFound) {
            log.err("VM '{s}' not found", .{name});
        }
        return err;
    };
    const vars_path = try getVarsPath(alloc, name);
    defer alloc.free(vars_path);
    std.Io.Dir.deleteFileAbsolute(global.io(), vars_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn listAll(alloc: Allocator) ![][]const u8 {
    const dir_path = try getConfigDir(alloc);
    defer alloc.free(dir_path);

    var dir = std.Io.Dir.openDirAbsolute(global.io(), dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return try alloc.alloc([]const u8, 0);
        }
        return err;
    };
    defer dir.close(global.io());

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var iter = dir.iterate();
    while (try iter.next(global.io())) |entry| {
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
        \\  --display <WxH>       Initial display resolution (default: 1280x800)
        \\  --gpu-memory <MB>    Graphics memory budget (default: 512)
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}

test "persisted config uses shared GPU memory validation" {
    const too_small = Config{ .gpu_memory_mb = 32 };
    try std.testing.expectError(error.InvalidArgument, too_small.validate());

    const valid = Config{ .gpu_memory_mb = 2048 };
    try valid.validate();
}
test "config paths reject names outside the VM directory" {
    const invalid_names = [_][]const u8{
        "../escape",
        "nested/vm",
        "/absolute",
    };

    for (invalid_names) |name| {
        const result = getConfigPath(std.testing.allocator, name);
        if (result) |path| {
            std.testing.allocator.free(path);
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expectEqual(error.InvalidName, err);
        }
    }
}

test "config paths enforce filename boundaries" {
    try std.testing.expectError(
        error.MissingName,
        getConfigPath(std.testing.allocator, ""),
    );
    try std.testing.expectError(
        error.InvalidName,
        getConfigPath(std.testing.allocator, "nul\x00name"),
    );

    const name_bytes_max = std.Io.Dir.max_name_bytes - ".json".len;
    var name: [name_bytes_max + 1]u8 = @splat('a');
    const path = try getConfigPath(std.testing.allocator, name[0..name_bytes_max]);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, ".json"));
    try std.testing.expectError(
        error.InvalidName,
        getConfigPath(std.testing.allocator, &name),
    );
}
