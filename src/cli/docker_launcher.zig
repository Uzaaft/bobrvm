//! Fast path from the bundled Docker entry points to the upstream clients.
//!
//! A live shared runtime needs only environment selection and an exec. Cold
//! starts and compatibility fallbacks go through the full bobrvm CLI.

const std = @import("std");

const path_bytes_max = std.posix.PATH_MAX + 1;
const argument_count_max: usize = 4096;

const Invocation = enum { docker, compose };

const Tool = enum {
    docker,
    compose,
    buildx,

    fn fileName(self: Tool) [:0]const u8 {
        return switch (self) {
            .docker => "docker-cli",
            .compose => "docker-compose-cli",
            .buildx => "docker-buildx-cli",
        };
    }

    fn argv0(self: Tool) [:0]const u8 {
        return switch (self) {
            .docker => "docker",
            .compose => "docker-compose",
            .buildx => "docker-buildx",
        };
    }
};

const Selection = struct {
    tool: Tool,
    argument_start: usize,
    fallback: bool = false,
};

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub fn main(minimal: std.process.Init.Minimal) !void {
    const arguments = minimal.args.vector;
    if (arguments.len == 0 or arguments.len > argument_count_max) {
        return error.InvalidArgument;
    }
    const invocation: Invocation = if (std.mem.eql(
        u8,
        std.fs.path.basename(std.mem.span(arguments[0])),
        "docker-compose",
    )) .compose else .docker;
    const selection = select(invocation, arguments);

    var executable_buffer: [path_bytes_max]u8 = undefined;
    const tool_dir = try executableDirectory(&executable_buffer);
    const endpoint_required = requiresEndpoint(selection, arguments);
    const explicit_host = explicitDockerHost();
    var socket_buffer: [path_bytes_max]u8 = undefined;
    const socket_path = if (!explicit_host and endpoint_required)
        try sharedSocketPath(&socket_buffer)
    else
        null;
    if (selection.fallback or
        (endpoint_required and !explicit_host and !pathExists(socket_path.?)))
    {
        var bobrvm_buffer: [path_bytes_max]u8 = undefined;
        const bobrvm = try std.fmt.bufPrintZ(
            &bobrvm_buffer,
            "{s}/../bin/bobrvm",
            .{tool_dir},
        );
        const argv0: [:0]const u8 = if (invocation == .compose)
            "docker-compose"
        else
            "docker";
        return exec(arguments, bobrvm, argv0, 1);
    }

    var docker_host_buffer: [path_bytes_max]u8 = undefined;
    try configureEnvironment(socket_path, explicit_host, &docker_host_buffer);
    var tool_buffer: [path_bytes_max]u8 = undefined;
    const tool_path = try std.fmt.bufPrintZ(
        &tool_buffer,
        "{s}/{s}",
        .{ tool_dir, selection.tool.fileName() },
    );
    return exec(
        arguments,
        tool_path,
        selection.tool.argv0(),
        selection.argument_start,
    );
}

fn executableDirectory(buffer: *[path_bytes_max]u8) ![]const u8 {
    var symlink_buffer: [path_bytes_max]u8 = undefined;
    var size: u32 = symlink_buffer.len;
    if (std.c._NSGetExecutablePath(&symlink_buffer, &size) != 0) {
        return error.NameTooLong;
    }
    const path = std.c.realpath(@ptrCast(&symlink_buffer), buffer) orelse {
        return error.ExecutablePathUnavailable;
    };
    const executable = std.mem.span(path);
    return std.fs.path.dirname(executable) orelse error.ExecutablePathUnavailable;
}

fn select(invocation: Invocation, args: []const [*:0]const u8) Selection {
    if (invocation == .compose) return .{ .tool = .compose, .argument_start = 1 };
    if (args.len < 2) return .{ .tool = .docker, .argument_start = 1 };
    const first = std.mem.span(args[1]);
    if (std.mem.eql(u8, first, "compose")) {
        return .{ .tool = .compose, .argument_start = 2 };
    }
    if (std.mem.eql(u8, first, "buildx")) {
        return .{ .tool = .buildx, .argument_start = 2 };
    }
    if (first.len > 0 and first[0] == '-' and
        !std.mem.eql(u8, first, "--help") and
        !std.mem.eql(u8, first, "--version") and
        !std.mem.eql(u8, first, "-v"))
    {
        return .{ .tool = .docker, .argument_start = 1, .fallback = true };
    }
    return .{ .tool = .docker, .argument_start = 1 };
}

fn requiresEndpoint(selection: Selection, args: []const [*:0]const u8) bool {
    if (selection.argument_start >= args.len) return false;
    const command = std.mem.span(args[selection.argument_start]);
    if (std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-v") or
        std.mem.eql(u8, command, "help"))
    {
        return false;
    }
    return selection.tool == .docker or !std.mem.eql(u8, command, "version");
}

fn explicitDockerHost() bool {
    const value = std.c.getenv("DOCKER_HOST") orelse return false;
    return std.mem.span(value).len > 0;
}

fn sharedSocketPath(buffer: *[path_bytes_max]u8) ![:0]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |value_ptr| {
        const value = std.mem.span(value_ptr);
        if (std.fs.path.isAbsolute(value)) {
            return std.fmt.bufPrintZ(buffer, "{s}/bobrvm/docker/docker.sock", .{value});
        }
    }
    const home_ptr = std.c.getenv("HOME") orelse return error.HomeMissing;
    const home = std.mem.span(home_ptr);
    if (!std.fs.path.isAbsolute(home)) return error.HomeMissing;
    return std.fmt.bufPrintZ(buffer, "{s}/.config/bobrvm/docker/docker.sock", .{home});
}

fn pathExists(path: [:0]const u8) bool {
    return std.c.access(path.ptr, 0) == 0;
}

fn configureEnvironment(
    socket_path: ?[:0]const u8,
    explicit_host: bool,
    docker_host_buffer: *[path_bytes_max]u8,
) !void {
    if (setenv("GOMAXPROCS", "1", 0) != 0) return error.SetEnvironmentFailed;
    if (explicit_host) return;
    if (socket_path) |value| {
        const docker_host = try std.fmt.bufPrintZ(
            docker_host_buffer,
            "unix://{s}",
            .{value},
        );
        if (setenv("DOCKER_HOST", docker_host.ptr, 1) != 0) {
            return error.SetEnvironmentFailed;
        }
    }
    _ = unsetenv("DOCKER_CONTEXT");
    _ = unsetenv("DOCKER_TLS_VERIFY");
    _ = unsetenv("DOCKER_CERT_PATH");
}

fn exec(
    args: []const [*:0]const u8,
    path: [:0]const u8,
    argv0: [:0]const u8,
    argument_start: usize,
) !void {
    const forwarded_count = args.len - argument_start;
    var argv: [argument_count_max + 1]?[*:0]const u8 = undefined;
    argv[0] = argv0.ptr;
    for (args[argument_start..], 1..) |argument, index| argv[index] = argument;
    argv[forwarded_count + 1] = null;
    _ = execv(path.ptr, @ptrCast(&argv));
    return error.ExecFailed;
}

test "Docker launcher selects direct plugin entry points" {
    const compose_args = [_][*:0]const u8{ "docker", "compose", "ps" };
    const compose = select(.docker, &compose_args);
    try std.testing.expectEqual(Tool.compose, compose.tool);
    try std.testing.expectEqual(@as(usize, 2), compose.argument_start);
    const buildx_args = [_][*:0]const u8{ "docker", "buildx", "version" };
    const buildx = select(.docker, &buildx_args);
    try std.testing.expectEqual(Tool.buildx, buildx.tool);
    try std.testing.expect(!buildx.fallback);
}

test "Docker launcher defers complex global options to bobrvm" {
    const context_args = [_][*:0]const u8{ "docker", "--context", "test", "ps" };
    try std.testing.expect(select(.docker, &context_args).fallback);
    const version_args = [_][*:0]const u8{ "docker", "--version" };
    try std.testing.expect(!select(.docker, &version_args).fallback);
    const compose_args = [_][*:0]const u8{ "docker-compose", "version" };
    const compose = select(.compose, &compose_args);
    try std.testing.expect(!requiresEndpoint(compose, &compose_args));
}
