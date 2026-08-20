const std = @import("std");

const TempHome = struct {
    io: std.Io,
    parent: std.Io.Dir,
    dir: std.Io.Dir,
    name: [name_len]u8,
    path: [std.fs.max_path_bytes]u8,
    path_len: usize,

    const random_len = 12;
    const name_len = std.base64.url_safe.Encoder.calcSize(random_len);

    fn init(io: std.Io) !TempHome {
        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/cli-smoke", .{});
        errdefer parent.close(io);
        var random: [random_len]u8 = undefined;
        io.random(&random);
        var name: [name_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random);
        const dir = try parent.createDirPathOpen(io, &name, .{});
        errdefer dir.close(io);
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const path_len = try dir.realPath(io, &path);
        return .{
            .io = io,
            .parent = parent,
            .dir = dir,
            .name = name,
            .path = path,
            .path_len = path_len,
        };
    }

    fn deinit(self: *TempHome) void {
        self.dir.close(self.io);
        self.parent.deleteTree(self.io, &self.name) catch {};
        self.parent.close(self.io);
        self.* = undefined;
    }

    fn home(self: *const TempHome) []const u8 {
        return self.path[0..self.path_len];
    }
};

fn run(
    init: std.process.Init,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
) !std.process.RunResult {
    return std.process.run(init.gpa, init.io, .{
        .argv = argv,
        .environ_map = environ,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
}

fn deinitResult(alloc: std.mem.Allocator, result: *std.process.RunResult) void {
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    result.* = undefined;
}

fn expectExit(result: std.process.RunResult, expected: u8) !void {
    switch (result.term) {
        .exited => |actual| if (actual != expected) {
            std.debug.print("expected exit {}, got {}\nstdout:\n{s}\nstderr:\n{s}\n", .{
                expected,
                actual,
                result.stdout,
                result.stderr,
            });
            return error.UnexpectedExit;
        },
        else => {
            std.debug.print("unexpected termination {any}\nstdout:\n{s}\nstderr:\n{s}\n", .{
                result.term,
                result.stdout,
                result.stderr,
            });
            return error.UnexpectedTermination;
        },
    }
}

fn expectEqual(expected: []const u8, actual: []const u8) !void {
    if (std.mem.eql(u8, expected, actual)) return;
    std.debug.print("expected:\n{s}\nactual:\n{s}\n", .{ expected, actual });
    return error.UnexpectedOutput;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("expected output to contain '{s}':\n{s}\n", .{ needle, haystack });
    return error.UnexpectedOutput;
}

fn checkDispatch(
    init: std.process.Init,
    environ: *const std.process.Environ.Map,
    cli: []const u8,
) !void {
    var version = try run(init, environ, &.{ cli, "version" });
    defer deinitResult(init.gpa, &version);
    try expectExit(version, 0);
    try expectEqual("bobrvm 0.1.0\n", version.stdout);

    var help = try run(init, environ, &.{cli});
    defer deinitResult(init.gpa, &help);
    try expectExit(help, 0);
    try expectContains(help.stdout, "Usage: bobrvm <command> [options]");

    var unknown = try run(init, environ, &.{ cli, "unknown" });
    defer deinitResult(init.gpa, &unknown);
    try expectExit(unknown, 1);
    try expectContains(unknown.stderr, "unknown subcommand: unknown");
}

fn checkPersistence(
    init: std.process.Init,
    environ: *const std.process.Environ.Map,
    cli: []const u8,
) !void {
    var create = try run(init, environ, &.{
        cli,
        "create",
        "vm-a",
        "--memory",
        "1024",
        "--cpus",
        "3",
        "--disk",
        "disk.raw",
    });
    defer deinitResult(init.gpa, &create);
    try expectExit(create, 0);
    try expectEqual("Created VM 'vm-a'\n", create.stdout);

    var duplicate = try run(init, environ, &.{
        cli,
        "create",
        "vm-a",
        "--memory",
        "2048",
    });
    defer deinitResult(init.gpa, &duplicate);
    try expectExit(duplicate, 1);

    var list = try run(init, environ, &.{ cli, "ls" });
    defer deinitResult(init.gpa, &list);
    try expectExit(list, 0);
    try expectContains(list.stdout, "vm-a");
    try expectContains(list.stdout, "1024");
    try expectContains(list.stdout, "3");
    try expectContains(list.stdout, "disk.raw");

    var delete = try run(init, environ, &.{ cli, "rm", "vm-a" });
    defer deinitResult(init.gpa, &delete);
    try expectExit(delete, 0);
    try expectEqual("Deleted VM 'vm-a'\n", delete.stdout);

    var empty = try run(init, environ, &.{ cli, "list" });
    defer deinitResult(init.gpa, &empty);
    try expectExit(empty, 0);
    try expectEqual(
        "No VMs configured.\nUse 'bobrvm create <name> [options]' to create one.\n",
        empty.stdout,
    );
}

fn runLimitedChild(init: std.process.Init, cli: []const u8) !void {
    const ignore_file_size = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.XFSZ, &ignore_file_size, null);
    try std.posix.setrlimit(.FSIZE, .{ .cur = 0, .max = 0 });
    var result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ cli, "create", "vm-fault" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer deinitResult(init.gpa, &result);
    if (result.term == .exited and result.term.exited == 0) return error.ExpectedWriteFailure;
}

fn expectNoConfigFiles(home: *const TempHome) !void {
    var dir = try home.dir.openDir(home.io, ".config/bobrvm/vms", .{ .iterate = true });
    defer dir.close(home.io);
    var entries = dir.iterate();
    if (try entries.next(home.io) != null) return error.UnexpectedConfigFile;
}

fn checkAtomicFailure(
    init: std.process.Init,
    environ: *const std.process.Environ.Map,
    executable: []const u8,
    cli: []const u8,
    home: *const TempHome,
) !void {
    var failed = try run(init, environ, &.{ executable, "--limited-child", cli });
    defer deinitResult(init.gpa, &failed);
    try expectExit(failed, 0);
    try expectNoConfigFiles(home);

    var retry = try run(init, environ, &.{ cli, "create", "vm-fault" });
    defer deinitResult(init.gpa, &retry);
    try expectExit(retry, 0);

    var delete = try run(init, environ, &.{ cli, "rm", "vm-fault" });
    defer deinitResult(init.gpa, &delete);
    try expectExit(delete, 0);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    const executable = args.next() orelse return error.MissingExecutablePath;
    const cli = args.next() orelse return error.MissingCliPath;
    if (std.mem.eql(u8, cli, "--limited-child")) {
        return runLimitedChild(init, args.next() orelse return error.MissingCliPath);
    }

    var home = try TempHome.init(init.io);
    defer home.deinit();
    var environ = try std.process.Environ.createMap(init.minimal.environ, init.gpa);
    defer environ.deinit();
    try environ.put("HOME", home.home());

    try checkDispatch(init, &environ, cli);
    try checkAtomicFailure(init, &environ, executable, cli, &home);
    try checkPersistence(init, &environ, cli);
}
