//! Docker CLI compatibility wrapper for bobrvm's shared Linux runtime.
//!
//! The app bundle keeps the upstream clients under xbin with names that
//! cannot recurse into this multicall entry point. The wrapper selects the
//! shared daemon socket and then execs the unmodified client. An explicit
//! nonempty `DOCKER_HOST` remains authoritative; existing per-project sockets
//! are a fallback until a shared host is configured.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const shared_host = @import("docker_host.zig");
const project = @import("project.zig");

const log = std.log.scoped(.docker);

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const Invocation = enum { docker, compose };

const Tool = enum {
    docker,
    compose,
    buildx,

    fn fileName(self: Tool) []const u8 {
        return switch (self) {
            .docker => "docker-cli",
            .compose => "docker-compose-cli",
            .buildx => "docker-buildx-cli",
        };
    }

    fn argv0(self: Tool) []const u8 {
        return switch (self) {
            .docker => "docker",
            .compose => "docker-compose",
            .buildx => "docker-buildx",
        };
    }
};

const Selection = struct {
    tool: Tool,
    args: []const []const u8,
    config_dir: ?[]const u8 = null,
};

pub fn execute(
    alloc: Allocator,
    minimal: std.process.Init.Minimal,
    invocation: Invocation,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = minimal.args.iterate();
    _ = args.skip();
    var forwarded: std.ArrayListUnmanaged([]const u8) = .empty;
    while (args.next()) |arg| try forwarded.append(arena, arg);
    rejectEndpointOptions(forwarded.items) catch |err| {
        log.err("Docker endpoint overrides are disabled for bobrvm", .{});
        return err;
    };
    const selection = if (invocation == .compose)
        Selection{ .tool = .compose, .args = forwarded.items }
    else
        try selectDockerTool(forwarded.items);

    const tool_dir = try findToolDir(arena);
    const tool_path = try std.fs.path.join(arena, &.{ tool_dir, selection.tool.fileName() });
    if (!project.fileExists(tool_path)) {
        log.err("bundled Docker tool is missing: {s}", .{tool_path});
        return error.DockerToolMissing;
    }
    const preserve_docker_host = explicitDockerHost();
    const socket_path = if (requiresEndpoint(selection) and !preserve_docker_host)
        try endpointPath(alloc, arena, minimal.environ)
    else
        null;
    try configureEnvironment(
        arena,
        socket_path,
        preserve_docker_host,
        tool_dir,
        selection.config_dir,
    );
    try execTool(arena, selection.tool, tool_path, selection.args);
}

fn requiresEndpoint(selection: Selection) bool {
    const command = if (selection.tool == .docker)
        firstDockerArgument(selection.args) orelse return false
    else if (selection.args.len > 0)
        selection.args[0]
    else
        return false;
    if (std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "help"))
    {
        return false;
    }
    if (selection.tool == .docker and std.mem.eql(u8, command, "-v")) return false;
    if (selection.tool != .docker and std.mem.eql(u8, command, "version")) return false;
    return true;
}

fn endpointPath(
    alloc: Allocator,
    arena: Allocator,
    environ: std.process.Environ,
) ![]const u8 {
    if (try shared_host.isConfigured(arena)) {
        try shared_host.ensureRunning(alloc, arena, environ);
        return shared_host.socketPath(arena);
    }

    const proj = try currentProject(arena);
    if (!proj.config.docker_enabled) {
        log.err(
            "shared Docker host is not configured and Docker is disabled in {s}",
            .{project.FILE_NAME},
        );
        return error.DockerDisabled;
    }
    return proj.config.docker_socket_path.?;
}

fn firstDockerArgument(args: []const []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (isGlobalFlag(arg) or
            std.mem.startsWith(u8, arg, "--config=") or
            (isGlobalValueOption(arg) and std.mem.indexOfScalar(u8, arg, '=') != null) or
            (std.mem.startsWith(u8, arg, "-l") and arg.len > 2))
        {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or isGlobalValueOption(arg)) {
            if (index + 1 >= args.len) return null;
            index += 2;
            continue;
        }
        return arg;
    }
    return null;
}

fn selectDockerTool(args: []const []const u8) !Selection {
    var index: usize = 0;
    var config_dir: ?[]const u8 = null;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "compose")) {
            return .{
                .tool = .compose,
                .args = args[index + 1 ..],
                .config_dir = config_dir,
            };
        }
        if (std.mem.eql(u8, arg, "buildx")) {
            return .{
                .tool = .buildx,
                .args = args[index + 1 ..],
                .config_dir = config_dir,
            };
        }
        if (isGlobalFlag(arg)) {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index == args.len) return error.InvalidArgument;
            config_dir = args[index];
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=")) {
            config_dir = arg["--config=".len..];
            if (config_dir.?.len == 0) return error.InvalidArgument;
            index += 1;
            continue;
        }
        if (isGlobalValueOption(arg)) {
            if (std.mem.indexOfScalar(u8, arg, '=') == null) {
                index += 1;
                if (index == args.len) return error.InvalidArgument;
            }
            index += 1;
            continue;
        }
        break;
    }
    return .{ .tool = .docker, .args = args };
}

fn rejectEndpointOptions(args: []const []const u8) !void {
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (isEndpointOption(arg)) return error.DockerEndpointOverride;
        if (isGlobalFlag(arg)) {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config") or
            (isGlobalValueOption(arg) and std.mem.indexOfScalar(u8, arg, '=') == null and
                !(std.mem.startsWith(u8, arg, "-l") and arg.len > 2)))
        {
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--config=") or isGlobalValueOption(arg)) {
            index += 1;
            continue;
        }

        // Docker's global options end at the subcommand. Everything after
        // that belongs to the subcommand or to the program run in a
        // container; for example, `docker exec app sh -c ...` must not treat
        // the shell's `-c` as Docker's global context option.
        break;
    }
}

fn isGlobalFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--debug") or
        std.mem.eql(u8, arg, "-D");
}

fn isGlobalValueOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--log-level") or
        std.mem.startsWith(u8, arg, "--log-level=") or
        std.mem.eql(u8, arg, "-l") or
        (std.mem.startsWith(u8, arg, "-l") and arg.len > 2);
}

fn isEndpointOption(arg: []const u8) bool {
    const names = [_][]const u8{
        "--context", "--host", "--tls", "--tlscacert", "--tlscert", "--tlskey", "--tlsverify",
    };
    for (names) |name| {
        if (std.mem.eql(u8, arg, name) or
            (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '='))
        {
            return true;
        }
    }
    return std.mem.eql(u8, arg, "-c") or
        (std.mem.startsWith(u8, arg, "-c") and arg.len > 2) or
        std.mem.eql(u8, arg, "-H") or
        (std.mem.startsWith(u8, arg, "-H") and arg.len > 2);
}

fn currentProject(arena: Allocator) !project.Project {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buffer, cwd_buffer.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    const root = (try project.findRoot(arena, cwd)) orelse {
        log.err("no {s} found in {s} or any parent directory", .{ project.FILE_NAME, cwd });
        return error.NoProjectFile;
    };
    return project.load(arena, root);
}

fn findToolDir(arena: Allocator) ![]const u8 {
    if (std.c.getenv("BOBRVM_DOCKER_CLI_DIR")) |value_ptr| {
        const value = std.mem.span(value_ptr);
        if (value.len == 0 or !std.fs.path.isAbsolute(value)) {
            return error.InvalidDockerToolDirectory;
        }
        return arena.dupe(u8, value);
    }

    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_len = try std.process.executablePath(global.io(), &executable_buffer);
    const executable = executable_buffer[0..executable_len];
    const executable_dir = std.fs.path.dirname(executable) orelse return error.Unexpected;
    if (std.mem.eql(u8, std.fs.path.basename(executable_dir), "bin")) {
        const macos_dir = std.fs.path.dirname(executable_dir) orelse return error.Unexpected;
        return std.fs.path.join(arena, &.{ macos_dir, "xbin" });
    }
    return arena.dupe(u8, executable_dir);
}

fn explicitDockerHost() bool {
    const value_ptr = std.c.getenv("DOCKER_HOST") orelse return false;
    return isExplicitDockerHost(std.mem.span(value_ptr));
}

fn isExplicitDockerHost(value: []const u8) bool {
    return value.len > 0;
}

fn configureEnvironment(
    arena: Allocator,
    socket_path: ?[]const u8,
    preserve_docker_host: bool,
    tool_dir: []const u8,
    config_dir: ?[]const u8,
) !void {
    // The clients are short-lived and mostly wait on the Docker API. Avoiding
    // a host-wide Go scheduler cuts their startup CPU without limiting the
    // daemon, while an explicit user setting remains authoritative.
    if (setenv("GOMAXPROCS", "1", 0) != 0) return error.SetEnvironmentFailed;
    if (!preserve_docker_host) {
        if (socket_path) |value| {
            const docker_host_text = try std.fmt.allocPrint(arena, "unix://{s}", .{value});
            const docker_host = try arena.dupeZ(u8, docker_host_text);
            if (setenv("DOCKER_HOST", docker_host.ptr, 1) != 0) {
                return error.SetEnvironmentFailed;
            }
        } else {
            _ = unsetenv("DOCKER_HOST");
        }
        _ = unsetenv("DOCKER_CONTEXT");
        _ = unsetenv("DOCKER_TLS_VERIFY");
        _ = unsetenv("DOCKER_CERT_PATH");
    }
    if (config_dir) |value| {
        const config = try arena.dupeZ(u8, value);
        if (setenv("DOCKER_CONFIG", config.ptr, 1) != 0) return error.SetEnvironmentFailed;
    }

    const old_path = if (std.c.getenv("PATH")) |path| std.mem.span(path) else "";
    const path_text = try std.fmt.allocPrint(arena, "{s}:{s}", .{ tool_dir, old_path });
    const path = try arena.dupeZ(u8, path_text);
    if (setenv("PATH", path.ptr, 1) != 0) return error.SetEnvironmentFailed;
}

fn execTool(
    arena: Allocator,
    tool: Tool,
    tool_path: []const u8,
    args: []const []const u8,
) !void {
    var argv = try arena.alloc(?[*:0]const u8, args.len + 2);
    argv[0] = (try arena.dupeZ(u8, tool.argv0())).ptr;
    for (args, 0..) |arg, index| argv[index + 1] = (try arena.dupeZ(u8, arg)).ptr;
    argv[args.len + 1] = null;
    const path = try arena.dupeZ(u8, tool_path);
    _ = execv(path.ptr, @ptrCast(argv.ptr));
    log.err("cannot execute bundled Docker tool: {s}", .{tool_path});
    return error.DockerToolExecFailed;
}

test "docker: app bundle executable resolves its xbin directory" {
    // The path transform itself is intentionally kept visible here: release
    // packaging places bobrvm in MacOS/bin and the third-party tools in xbin.
    const path = "/Applications/Bobrvm.app/Contents/MacOS/bin/bobrvm";
    const executable_dir = std.fs.path.dirname(path).?;
    const macos_dir = std.fs.path.dirname(executable_dir).?;
    const actual = try std.fs.path.join(std.testing.allocator, &.{ macos_dir, "xbin" });
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(
        "/Applications/Bobrvm.app/Contents/MacOS/xbin",
        actual,
    );
}

test "docker: bundled plugins are selected after global flags" {
    const compose = try selectDockerTool(&.{ "--debug", "compose", "version" });
    try std.testing.expectEqual(Tool.compose, compose.tool);
    try std.testing.expectEqualStrings("version", compose.args[0]);

    const buildx = try selectDockerTool(&.{ "--log-level", "debug", "buildx", "version" });
    try std.testing.expectEqual(Tool.buildx, buildx.tool);
    try std.testing.expectEqualStrings("version", buildx.args[0]);
    try std.testing.expectError(
        error.DockerEndpointOverride,
        rejectEndpointOptions(&.{ "--context", "orbstack", "ps" }),
    );
}

test "docker: endpoint checks stop at the subcommand" {
    try rejectEndpointOptions(&.{ "run", "--rm", "alpine", "sh", "-c", "false" });
    try rejectEndpointOptions(&.{ "exec", "app", "sh", "-c", "echo ok" });
    try rejectEndpointOptions(&.{ "run", "--rm", "app", "--host", "guest-name" });

    try std.testing.expectError(
        error.DockerEndpointOverride,
        rejectEndpointOptions(&.{ "--debug", "-c", "orbstack", "ps" }),
    );
    try std.testing.expectError(
        error.DockerEndpointOverride,
        rejectEndpointOptions(&.{ "--config", "/tmp/docker", "--host=tcp://other", "ps" }),
    );
}

test "docker: client information commands do not require an endpoint" {
    try std.testing.expect(!requiresEndpoint(.{ .tool = .docker, .args = &.{"--version"} }));
    try std.testing.expect(!requiresEndpoint(.{
        .tool = .docker,
        .args = &.{ "--config", "/tmp/docker", "--version" },
    }));
    try std.testing.expect(!requiresEndpoint(.{ .tool = .docker, .args = &.{"--help"} }));
    try std.testing.expect(!requiresEndpoint(.{ .tool = .compose, .args = &.{"version"} }));
    try std.testing.expect(!requiresEndpoint(.{ .tool = .buildx, .args = &.{"version"} }));
    try std.testing.expect(requiresEndpoint(.{ .tool = .docker, .args = &.{"version"} }));
    try std.testing.expect(requiresEndpoint(.{ .tool = .compose, .args = &.{"ps"} }));
}

test "docker: a nonempty DOCKER_HOST remains authoritative" {
    try std.testing.expect(isExplicitDockerHost("unix:///tmp/external.sock"));
    try std.testing.expect(!isExplicitDockerHost(""));
}
