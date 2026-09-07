//! Lifecycle for the one shared Virtualization.framework Docker host.
//!
//! Docker needs one Linux kernel on macOS, not one VM per Compose project.
//! This module gives that kernel a stable config directory, process, state,
//! and socket which the bundled clients can use from any working directory.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctl = @import("ctl.zig");
const global = @import("../global.zig");
const docker_readiness = @import("docker_readiness.zig");
const project = @import("project.zig");
const up = @import("up.zig");

const log = std.log.scoped(.docker_host);

extern "c" fn flock(fd: c_int, operation: c_int) c_int;

const lock_exclusive: c_int = 2;
const lock_unlock: c_int = 8;

pub const Error = project.Error || error{
    DockerHostInvalid,
    DockerHostNotConfigured,
    InvalidArgument,
};

const Verb = enum {
    start,
    run,
    status,
    stop,
    @"suspend",
};

pub fn execute(
    alloc: Allocator,
    args: *std.process.Args.Iterator,
    environ: std.process.Environ,
) !void {
    const verb_text = args.next() orelse {
        printHelp();
        return error.InvalidArgument;
    };
    if (isHelp(verb_text)) {
        printHelp();
        return;
    }
    const verb = parseVerb(verb_text) orelse {
        log.err("unknown Docker host command: {s}", .{verb_text});
        return error.InvalidArgument;
    };

    var fresh = false;
    var detached_child = false;
    while (args.next()) |arg| {
        if (isHelp(arg)) {
            printHelp();
            return;
        }
        if (std.mem.eql(u8, arg, "--detached-child") and verb == .run) {
            detached_child = true;
        } else if (std.mem.eql(u8, arg, "--fresh") and
            (verb == .start or verb == .run))
        {
            fresh = true;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }
    if (detached_child) try up.detachSession();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var host = try load(arena);

    switch (verb) {
        .start => {
            if (ctl.runningPid(arena, &host) != null) {
                log.info("shared Docker host is already running", .{});
            } else {
                deleteReadyFile(arena, &host);
                try up.startProject(
                    alloc,
                    arena,
                    &host,
                    fresh,
                    true,
                    environ,
                    &.{ "docker-host", "run", "--detached-child" },
                );
            }
            try waitUntilReady(arena, &host);
            try writeReadyFile(arena, &host);
        },
        .run => {
            defer if (detached_child) {
                deleteReadyFile(arena, &host);
                deleteRunnerPid(arena, &host);
            };
            deleteReadyFile(arena, &host);
            try up.startProject(
                alloc,
                arena,
                &host,
                fresh,
                false,
                environ,
                &.{},
            );
        },
        .status => try ctl.executeProject(arena, &host, .status),
        .stop => try ctl.executeProject(arena, &host, .halt),
        .@"suspend" => try ctl.executeProject(arena, &host, .@"suspend"),
    }
}

pub fn isConfigured(arena: Allocator) Error!bool {
    return project.fileExists(try configPath(arena));
}

pub fn ensureRunning(
    alloc: Allocator,
    arena: Allocator,
    environ: std.process.Environ,
) !void {
    var host = try load(arena);
    try project.ensureStateDir(&host);

    const lock_path = try std.fs.path.join(arena, &.{ host.state_dir, "start.lock" });
    const lock_file = try std.Io.Dir.cwd().createFile(global.io(), lock_path, .{
        .truncate = false,
    });
    defer lock_file.close(global.io());
    if (flock(lock_file.handle, lock_exclusive) != 0) return error.DockerHostLockFailed;
    defer _ = flock(lock_file.handle, lock_unlock);

    const ready_path = try std.fs.path.join(arena, &.{ host.state_dir, "docker.ready" });
    if (ctl.runningPid(arena, &host) != null and project.fileExists(ready_path)) return;
    if (ctl.runningPid(arena, &host) == null) {
        deleteFile(ready_path);
        try up.startProject(
            alloc,
            arena,
            &host,
            false,
            true,
            environ,
            &.{ "docker-host", "run", "--detached-child" },
        );
    }
    try waitUntilReady(arena, &host);
    try writeReadyFile(arena, &host);
}

pub fn socketPath(arena: Allocator) Error![]const u8 {
    const path = try std.fs.path.join(arena, &.{ try rootPath(arena), "docker.sock" });
    const path_bytes_max = @sizeOf(@FieldType(std.posix.sockaddr.un, "path"));
    if (path.len >= path_bytes_max) {
        log.err("shared Docker socket path is too long: {s}", .{path});
        return error.DockerHostInvalid;
    }
    return path;
}

pub fn configPath(arena: Allocator) Error![]const u8 {
    return std.fs.path.join(arena, &.{ try rootPath(arena), project.FILE_NAME });
}

fn rootPath(arena: Allocator) Error![]const u8 {
    if (std.c.getenv("BOBRVM_DOCKER_HOST_DIR")) |value_ptr| {
        const value = std.mem.span(value_ptr);
        if (value.len == 0 or !std.fs.path.isAbsolute(value)) {
            log.err("BOBRVM_DOCKER_HOST_DIR must be an absolute path", .{});
            return error.DockerHostInvalid;
        }
        return arena.dupe(u8, value) catch return error.OutOfMemory;
    }
    return std.fs.path.join(arena, &.{ try project.configHome(arena), "bobrvm", "docker" });
}

fn load(arena: Allocator) Error!project.Project {
    const root = try rootPath(arena);
    if (!project.fileExists(try configPath(arena))) {
        log.err("shared Docker host is not configured in {s}", .{root});
        return error.DockerHostNotConfigured;
    }
    var host = try project.load(arena, root);
    if (host.engine != .vz or !host.config.docker_enabled or !host.config.docker_vsock) {
        log.err(
            "shared Docker host requires engine=\"vz\", docker=true, and docker-vsock=true",
            .{},
        );
        return error.DockerHostInvalid;
    }

    host.state_dir = root;
    host.warm_image = try std.fs.path.join(arena, &.{ root, "warm.vzstate" });
    host.config.suspend_path = host.warm_image;
    host.config.docker_socket_path = try socketPath(arena);
    host.config.docker_idle_sleep = true;
    return host;
}

fn waitUntilReady(arena: Allocator, host: *const project.Project) !void {
    const pid = ctl.runningPid(arena, host) orelse return error.DockerHostStartFailed;
    try docker_readiness.wait(host.config.docker_socket_path.?, pid, 30 * std.time.ns_per_s);
}

fn deleteFile(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(global.io(), path) catch {};
}

fn deleteReadyFile(arena: Allocator, host: *const project.Project) void {
    const path = std.fs.path.join(arena, &.{ host.state_dir, "docker.ready" }) catch return;
    deleteFile(path);
}

fn writeReadyFile(arena: Allocator, host: *const project.Project) !void {
    const path = try std.fs.path.join(arena, &.{ host.state_dir, "docker.ready" });
    const file = try std.Io.Dir.cwd().createFile(global.io(), path, .{});
    file.close(global.io());
}

fn deleteRunnerPid(arena: Allocator, host: *const project.Project) void {
    const path = std.fs.path.join(arena, &.{ host.state_dir, "runner.pid" }) catch return;
    deleteFile(path);
}

fn parseVerb(text: []const u8) ?Verb {
    const map = std.StaticStringMap(Verb).initComptime(.{
        .{ "start", .start },
        .{ "up", .start },
        .{ "run", .run },
        .{ "status", .status },
        .{ "stop", .stop },
        .{ "halt", .stop },
        .{ "suspend", .@"suspend" },
    });
    return map.get(text);
}

fn isHelp(text: []const u8) bool {
    return std.mem.eql(u8, text, "--help") or std.mem.eql(u8, text, "-h");
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm docker-host <start|run|status|stop|suspend> [--fresh]
        \\
        \\Manage the single shared Virtualization.framework Linux runtime
        \\used by Docker and Compose. Its configuration and state live in
        \\$XDG_CONFIG_HOME/bobrvm/docker (default ~/.config/bobrvm/docker).
        \\
        \\  start [--fresh]   Start the shared runtime in the background
        \\  run [--fresh]     Run it in the foreground
        \\  status            Show its process and warm-state status
        \\  stop              Stop it without saving runtime state
        \\  suspend           Save runtime state and stop it
        \\
        \\The directory must contain a bobrvm.toml with engine = "vz",
        \\docker = true, and docker-vsock = true.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}

const testing = std.testing;

test "docker host: command aliases map to one lifecycle" {
    try testing.expectEqual(Verb.start, parseVerb("up").?);
    try testing.expectEqual(Verb.stop, parseVerb("halt").?);
    try testing.expectEqual(Verb.@"suspend", parseVerb("suspend").?);
    try testing.expect(parseVerb("unknown") == null);
}
