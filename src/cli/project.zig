//! Project-file workflow: bobrvm.toml discovery and mapping.
//!
//! A bobrvm.toml checked into a repository describes the VM for that
//! project. `bobrvm up` walks up from the current directory to find
//! it, maps it onto a VM configuration, and keeps the project's
//! mutable state (the warm suspend image) under
//! ~/.config/bobrvm/projects/<basename>-<hash>/ so the repository
//! itself stays clean.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const toml = @import("toml.zig");
const global = @import("../global.zig");
const file_compat = @import("../compat/file.zig");

const log = std.log.scoped(.cli);

pub const FILE_NAME = "bobrvm.toml";
/// Project files are small; anything bigger is a mistake, not a VM.
pub const FILE_MAX_BYTES = 64 * 1024;

pub const Error = error{
    ProjectFileUnreadable,
    ProjectFileInvalid,
    NoHomeDir,
    OutOfMemory,
};

pub const Engine = enum { native, vz };

pub const Project = struct {
    /// Absolute project root (the directory holding bobrvm.toml).
    root: []const u8,
    /// Which engine runs this project: the custom Hypervisor.framework
    /// machine (default) or the Virtualization.framework lite engine.
    engine: Engine = .native,
    /// Absolute path of the project file.
    file_path: []const u8,
    /// Per-project state directory.
    state_dir: []const u8,
    /// Warm suspend image inside state_dir: `up` restores it when it
    /// exists, and the console's suspend command writes it on quit.
    warm_image: []const u8,
    config: Config,
};

/// Walk from `start_dir` (absolute) upward looking for bobrvm.toml.
/// Returns the containing directory, allocated from `alloc`, or null.
pub fn findRoot(alloc: Allocator, start_dir: []const u8) Error!?[]const u8 {
    var dir = start_dir;
    while (true) {
        const candidate = std.fs.path.join(alloc, &.{ dir, FILE_NAME }) catch
            return error.OutOfMemory;
        defer alloc.free(candidate);
        if (fileExists(candidate)) {
            return alloc.dupe(u8, dir) catch return error.OutOfMemory;
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

pub fn fileExists(path: []const u8) bool {
    var buf: [1024:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0].ptr, 0) == 0; // F_OK
}

/// Load and map the project file at `root`. All returned memory
/// (paths, config strings) is allocated from `arena` and owned by the
/// caller as a unit — nothing here is individually freed.
pub fn load(arena: Allocator, root: []const u8) Error!Project {
    const io = global.io();
    const file_path = std.fs.path.join(arena, &.{ root, FILE_NAME }) catch
        return error.OutOfMemory;

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch |err| {
        log.warn("cannot open {s}: {}", .{ file_path, err });
        return error.ProjectFileUnreadable;
    };
    defer file.close(io);
    const text = file_compat.readToEndAlloc(file, arena, FILE_MAX_BYTES) catch |err| {
        log.warn("cannot read {s}: {}", .{ file_path, err });
        return error.ProjectFileUnreadable;
    };

    var error_line: usize = 0;
    var table = toml.parse(arena, text, &error_line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateKey => {
            log.warn("{s}:{d}: duplicate key", .{ file_path, error_line });
            return error.ProjectFileInvalid;
        },
        error.Syntax => {
            log.warn(
                "{s}:{d}: unsupported syntax (supported: key = \"string\" | integer | true/false | [\"strings\"])",
                .{ file_path, error_line },
            );
            return error.ProjectFileInvalid;
        },
    };

    var engine: Engine = .native;
    var config = try mapTable(arena, root, &table, &engine);
    if (config.name.len == 0) {
        config.name = arena.dupe(u8, std.fs.path.basename(root)) catch
            return error.OutOfMemory;
    }

    const state_dir = try stateDir(arena, root);
    // The engines' state formats differ, so the images get distinct
    // names — switching engines boots cold rather than feeding one
    // engine the other's state.
    const warm_name = switch (engine) {
        .native => "warm.img",
        .vz => "warm.vzstate",
    };
    const warm_image = std.fs.path.join(arena, &.{ state_dir, warm_name }) catch
        return error.OutOfMemory;
    // The console's suspend-and-quit command writes the warm image, so
    // the next `up` resumes instead of booting.
    config.suspend_path = warm_image;

    return .{
        .root = root,
        .engine = engine,
        .file_path = file_path,
        .state_dir = state_dir,
        .warm_image = warm_image,
        .config = config,
    };
}

/// Per-project state directory: keyed by the root's absolute path (so
/// moving a project gets fresh state) but prefixed with its basename
/// for human navigation.
pub fn stateDir(arena: Allocator, root: []const u8) Error![]const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHomeDir);
    const hash = std.hash.Wyhash.hash(0, root);
    const dir_name = std.fmt.allocPrint(arena, "{s}-{x:0>16}", .{
        std.fs.path.basename(root), hash,
    }) catch return error.OutOfMemory;
    return std.fs.path.join(arena, &.{
        home, ".config", "bobrvm", "projects", dir_name,
    }) catch return error.OutOfMemory;
}

pub fn ensureStateDir(project: *const Project) !void {
    try std.Io.Dir.cwd().createDirPath(global.io(), project.state_dir);
}

const Key = enum {
    engine,
    name,
    memory,
    cpus,
    kernel,
    initrd,
    cmdline,
    firmware,
    vars,
    disk,
    disk_readonly,
    disk2,
    disk2_writable,
    gpu,
    virgl,
    sound,
    net,
    share,
    forwards,
    display,
    gpu_memory,
};

const key_map = std.StaticStringMap(Key).initComptime(.{
    .{ "engine", .engine },
    .{ "name", .name },
    .{ "memory", .memory },
    .{ "cpus", .cpus },
    .{ "kernel", .kernel },
    .{ "initrd", .initrd },
    .{ "cmdline", .cmdline },
    .{ "firmware", .firmware },
    .{ "vars", .vars },
    .{ "disk", .disk },
    .{ "disk-readonly", .disk_readonly },
    .{ "disk2", .disk2 },
    .{ "disk2-writable", .disk2_writable },
    .{ "gpu", .gpu },
    .{ "virgl", .virgl },
    .{ "sound", .sound },
    .{ "net", .net },
    .{ "share", .share },
    .{ "forwards", .forwards },
    .{ "display", .display },
    .{ "gpu-memory", .gpu_memory },
});

fn mapTable(
    arena: Allocator,
    root: []const u8,
    table: *const toml.Table,
    engine_out: *Engine,
) Error!Config {
    var config = Config{};
    var share_set = false;

    var iter = table.map.iterator();
    while (iter.next()) |entry| {
        const key_name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const key = key_map.get(key_name) orelse {
            log.warn("{s}: unknown key '{s}'", .{ FILE_NAME, key_name });
            return error.ProjectFileInvalid;
        };
        switch (key) {
            .engine => {
                const text = try wantString(key_name, value);
                engine_out.* = std.meta.stringToEnum(Engine, text) orelse {
                    log.warn("{s}: engine must be \"native\" or \"vz\"", .{FILE_NAME});
                    return error.ProjectFileInvalid;
                };
            },
            .name => config.name = try wantString(key_name, value),
            .memory => config.memory_mb = @intCast(try wantInt(key_name, value, 1, 1024 * 1024)),
            .cpus => config.vcpu_count = @intCast(try wantInt(key_name, value, 1, 255)),
            .kernel => config.kernel_path = try resolvePath(arena, root, try wantString(key_name, value)),
            .initrd => config.initrd_path = try resolvePath(arena, root, try wantString(key_name, value)),
            .cmdline => config.cmdline = try wantString(key_name, value),
            .firmware => config.firmware_path = try resolvePath(arena, root, try wantString(key_name, value)),
            .vars => config.vars_path = try resolvePath(arena, root, try wantString(key_name, value)),
            .disk => config.disk_path = try resolvePath(arena, root, try wantString(key_name, value)),
            .disk_readonly => config.disk_read_only = try wantBool(key_name, value),
            .disk2 => config.disk2_path = try resolvePath(arena, root, try wantString(key_name, value)),
            .disk2_writable => config.disk2_read_only = !(try wantBool(key_name, value)),
            .gpu => config.enable_gpu = try wantBool(key_name, value),
            .virgl => config.enable_virgl = try wantBool(key_name, value),
            .sound => config.enable_snd = try wantBool(key_name, value),
            .net => config.enable_net = try wantBool(key_name, value),
            .share => {
                share_set = true;
                switch (value) {
                    .string => |s| config.shared_dir = try resolvePath(arena, root, s),
                    // `share = false` opts out of the default project share.
                    .boolean => |b| config.shared_dir = if (b)
                        arena.dupe(u8, root) catch return error.OutOfMemory
                    else
                        null,
                    else => {
                        log.warn("{s}: 'share' must be a path or false", .{FILE_NAME});
                        return error.ProjectFileInvalid;
                    },
                }
            },
            .forwards => try mapForwards(&config, key_name, value),
            .display => try mapDisplay(&config, key_name, value),
            .gpu_memory => config.gpu_memory_mb = @intCast(try wantInt(key_name, value, 64, 2048)),
        }
    }

    // The Vagrant contract: the project directory is shared by default.
    if (!share_set) {
        config.shared_dir = arena.dupe(u8, root) catch return error.OutOfMemory;
    }
    if (config.enable_virgl) config.enable_gpu = true;
    if (config.forward_count > 0) config.enable_net = true;

    // The lite engine's device set is much smaller; reject what it
    // cannot match rather than silently degrading.
    if (engine_out.* == .vz) {
        if (config.enable_gpu or config.enable_snd or config.enable_net or
            config.forward_count > 0 or config.disk_path != null or
            config.disk2_path != null or config.firmware_path != null)
        {
            log.warn(
                "{s}: gpu/sound/net/forwards/disks/firmware are not supported on the vz engine yet",
                .{FILE_NAME},
            );
            return error.ProjectFileInvalid;
        }
        if (share_set and config.shared_dir != null) {
            log.warn("{s}: 'share' is not supported on the vz engine yet", .{FILE_NAME});
            return error.ProjectFileInvalid;
        }
        config.shared_dir = null;
        if (config.kernel_path == null) {
            log.warn("{s}: the vz engine requires 'kernel'", .{FILE_NAME});
            return error.ProjectFileInvalid;
        }
    }

    config.validate() catch return error.ProjectFileInvalid;
    return config;
}

fn mapForwards(config: *Config, key_name: []const u8, value: toml.Value) Error!void {
    if (value != .string_array) {
        log.warn("{s}: '{s}' must be an array of \"host:guest\" strings", .{ FILE_NAME, key_name });
        return error.ProjectFileInvalid;
    }
    for (value.string_array) |spec| {
        if (config.forward_count >= Config.MAX_FORWARDS) {
            log.warn("{s}: at most {d} forwards", .{ FILE_NAME, Config.MAX_FORWARDS });
            return error.ProjectFileInvalid;
        }
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse
            return badForward(spec);
        const host_port = std.fmt.parseInt(u16, spec[0..colon], 10) catch
            return badForward(spec);
        const guest_port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch
            return badForward(spec);
        if (host_port == 0 or guest_port == 0) return badForward(spec);
        config.forwards[config.forward_count] = .{
            .host_port = host_port,
            .guest_port = guest_port,
        };
        config.forward_count += 1;
    }
}

fn badForward(spec: []const u8) Error {
    log.warn("{s}: forward '{s}' must be \"host:guest\" with nonzero ports", .{ FILE_NAME, spec });
    return error.ProjectFileInvalid;
}

fn mapDisplay(config: *Config, key_name: []const u8, value: toml.Value) Error!void {
    const text = try wantString(key_name, value);
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse {
        log.warn("{s}: 'display' must be \"WxH\"", .{FILE_NAME});
        return error.ProjectFileInvalid;
    };
    config.display_width = std.fmt.parseInt(u32, text[0..x], 10) catch
        return error.ProjectFileInvalid;
    config.display_height = std.fmt.parseInt(u32, text[x + 1 ..], 10) catch
        return error.ProjectFileInvalid;
}

fn wantString(key: []const u8, value: toml.Value) Error![]const u8 {
    if (value != .string) {
        log.warn("{s}: '{s}' must be a string", .{ FILE_NAME, key });
        return error.ProjectFileInvalid;
    }
    return value.string;
}

fn wantBool(key: []const u8, value: toml.Value) Error!bool {
    if (value != .boolean) {
        log.warn("{s}: '{s}' must be true or false", .{ FILE_NAME, key });
        return error.ProjectFileInvalid;
    }
    return value.boolean;
}

fn wantInt(key: []const u8, value: toml.Value, min: i64, max: i64) Error!i64 {
    if (value != .integer or value.integer < min or value.integer > max) {
        log.warn("{s}: '{s}' must be an integer in [{d}, {d}]", .{ FILE_NAME, key, min, max });
        return error.ProjectFileInvalid;
    }
    return value.integer;
}

fn resolvePath(arena: Allocator, root: []const u8, path: []const u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return arena.dupe(u8, path) catch return error.OutOfMemory;
    }
    return std.fs.path.join(arena, &.{ root, path }) catch return error.OutOfMemory;
}

const testing = std.testing;

test "project: maps the full schema onto a config" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\name = "webapp"
        \\memory = 2048
        \\cpus = 1
        \\kernel = "boot/Image"
        \\initrd = "/abs/initrd"
        \\cmdline = "console=hvc0 root=/dev/vda"
        \\disk = "root.raw"
        \\virgl = true
        \\sound = true
        \\forwards = ["2222:22", "8080:80"]
        \\display = "1920x1080"
        \\gpu-memory = 1024
        \\
    ;
    var table = try toml.parse(arena, text, null);
    var engine: Engine = .native;
    const config = try mapTable(arena, "/proj", &table, &engine);

    try testing.expectEqualStrings("webapp", config.name);
    try testing.expectEqual(@as(u64, 2048), config.memory_mb);
    try testing.expectEqual(@as(u8, 1), config.vcpu_count);
    try testing.expectEqualStrings("/proj/boot/Image", config.kernel_path.?);
    try testing.expectEqualStrings("/abs/initrd", config.initrd_path.?);
    try testing.expectEqualStrings("/proj/root.raw", config.disk_path.?);
    try testing.expect(config.enable_virgl);
    try testing.expect(config.enable_gpu); // implied by virgl
    try testing.expect(config.enable_snd);
    try testing.expect(config.enable_net); // implied by forwards
    try testing.expectEqual(@as(u8, 2), config.forward_count);
    try testing.expectEqual(@as(u16, 2222), config.forwards[0].host_port);
    try testing.expectEqual(@as(u16, 80), config.forwards[1].guest_port);
    try testing.expectEqual(@as(u32, 1920), config.display_width);
    try testing.expectEqual(@as(u64, 1024), config.gpu_memory_mb);
    // Project dir shared by default.
    try testing.expectEqualStrings("/proj", config.shared_dir.?);
}

test "project: share=false opts out and unknown keys fail loudly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opted_out = try toml.parse(arena, "share = false\n", null);
    var engine: Engine = .native;
    const config = try mapTable(arena, "/proj", &opted_out, &engine);
    try testing.expectEqual(@as(?[]const u8, null), config.shared_dir);

    var unknown = try toml.parse(arena, "memroy = 2048\n", null);
    try testing.expectError(error.ProjectFileInvalid, mapTable(arena, "/proj", &unknown, &engine));

    var bad_forward = try toml.parse(arena, "forwards = [\"22\"]\n", null);
    try testing.expectError(error.ProjectFileInvalid, mapTable(arena, "/proj", &bad_forward, &engine));

    var bad_type = try toml.parse(arena, "memory = \"lots\"\n", null);
    try testing.expectError(error.ProjectFileInvalid, mapTable(arena, "/proj", &bad_type, &engine));
}

test "project: findRoot walks up and load wires the warm image" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = global.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/src/deep");
    {
        const file = try tmp.dir.createFile(io, "repo/" ++ FILE_NAME, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "memory = 1024\ncpus = 1\n");
    }

    // tmpDir paths are relative to the zig-cache tmp root; make them
    // absolute for the walk.
    var real_buf: [1024]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &real_buf);
    const tmp_root = try arena.dupe(u8, real_buf[0..real_len]);
    const deep = try std.fs.path.join(arena, &.{ tmp_root, "repo", "src", "deep" });
    const expected_root = try std.fs.path.join(arena, &.{ tmp_root, "repo" });

    const found = (try findRoot(arena, deep)).?;
    try testing.expectEqualStrings(expected_root, found);

    const outside = try findRoot(arena, tmp_root);
    try testing.expect(outside == null);

    const project = try load(arena, found);
    try testing.expectEqual(@as(u64, 1024), project.config.memory_mb);
    try testing.expectEqualStrings("repo", project.config.name);
    try testing.expect(std.mem.endsWith(u8, project.warm_image, "warm.img"));
    try testing.expectEqualStrings(project.warm_image, project.config.suspend_path.?);
    // State dir is keyed by the absolute root path.
    try testing.expect(std.mem.indexOf(u8, project.state_dir, "/projects/repo-") != null);
}

test "project: vz engine parses and rejects unsupported devices" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var engine: Engine = .native;

    var minimal = try toml.parse(arena, "engine = \"vz\"\nkernel = \"Image\"\n", null);
    const config = try mapTable(arena, "/proj", &minimal, &engine);
    try testing.expectEqual(Engine.vz, engine);
    // No 9p device on the lite engine: the default project share is off.
    try testing.expectEqual(@as(?[]const u8, null), config.shared_dir);

    var gpu = try toml.parse(arena, "engine = \"vz\"\nkernel = \"Image\"\ngpu = true\n", null);
    try testing.expectError(error.ProjectFileInvalid, mapTable(arena, "/proj", &gpu, &engine));

    var no_kernel = try toml.parse(arena, "engine = \"vz\"\n", null);
    try testing.expectError(error.ProjectFileInvalid, mapTable(arena, "/proj", &no_kernel, &engine));

    var bogus = try toml.parse(arena, "engine = \"qemu\"\n", null);
    try testing.expectError(error.ProjectFileInvalid, mapTable(arena, "/proj", &bogus, &engine));
}
