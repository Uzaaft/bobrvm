//! Install app-bundled command-line entry points without replacing working
//! files owned by Docker Desktop, OrbStack, or another package manager.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");

const log = std.log.scoped(.install_cli);

const Link = struct {
    source: []const u8,
    target: []const u8,
};

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    var app_path: []const u8 = "/Applications/Bobrvm.app";
    var prefix: []const u8 = "/usr/local/bin";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--app")) {
            app_path = args.next() orelse return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            prefix = args.next() orelse return error.InvalidArgument;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }
    if (!std.fs.path.isAbsolute(app_path) or !std.fs.path.isAbsolute(prefix)) {
        log.err("--app and --prefix must be absolute paths", .{});
        return error.InvalidArgument;
    }

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const links = [_]Link{
        try link(arena, app_path, prefix, "bin/bobrvm", "bobrvm"),
        try link(arena, app_path, prefix, "xbin/docker", "docker"),
        try link(arena, app_path, prefix, "xbin/docker-compose", "docker-compose"),
        try link(arena, app_path, prefix, "xbin/docker-buildx", "docker-buildx"),
        try link(
            arena,
            app_path,
            prefix,
            "xbin/docker-credential-osxkeychain",
            "docker-credential-osxkeychain",
        ),
    };
    try install(&links);
}

fn link(
    arena: Allocator,
    app_path: []const u8,
    prefix: []const u8,
    source_suffix: []const u8,
    name: []const u8,
) !Link {
    return .{
        .source = try std.fs.path.join(arena, &.{
            app_path,
            "Contents/MacOS",
            source_suffix,
        }),
        .target = try std.fs.path.join(arena, &.{ prefix, name }),
    };
}

fn install(links: []const Link) !void {
    const io = global.io();
    for (links) |entry| {
        std.Io.Dir.accessAbsolute(io, entry.source, .{}) catch {
            log.err("bundled command is missing: {s}", .{entry.source});
            return error.SourceMissing;
        };
        const state = try linkState(io, entry);
        if (state == .conflict) {
            log.err("refusing to replace existing path: {s}", .{entry.target});
            return error.TargetExists;
        }
    }
    for (links) |entry| {
        switch (try linkState(io, entry)) {
            .installed => continue,
            .conflict => return error.TargetExists,
            .dangling => {
                std.Io.Dir.deleteFileAbsolute(io, entry.target) catch |err| {
                    logPermissionError(err);
                    return err;
                };
                log.info("removed dangling symlink: {s}", .{entry.target});
            },
            .missing => {},
        }
        std.Io.Dir.symLinkAbsolute(io, entry.source, entry.target, .{}) catch |err| {
            logPermissionError(err);
            return err;
        };
        log.info("installed {s} -> {s}", .{ entry.target, entry.source });
    }
}

fn logPermissionError(err: anyerror) void {
    if (err == error.AccessDenied) {
        log.err("permission denied; rerun this command with sudo", .{});
    }
}

const LinkState = enum { missing, installed, dangling, conflict };

fn linkState(io: std.Io, entry: Link) !LinkState {
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = std.Io.Dir.readLinkAbsolute(
        io,
        entry.target,
        &target_buffer,
    ) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        error.NotLink => return .conflict,
        else => return err,
    };
    const destination = target_buffer[0..target_len];
    if (std.mem.eql(u8, destination, entry.source)) return .installed;
    if (!std.fs.path.isAbsolute(destination)) return .conflict;
    std.Io.Dir.accessAbsolute(io, destination, .{}) catch |err| switch (err) {
        error.FileNotFound => return .dangling,
        else => return err,
    };
    return .conflict;
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm install-cli [--app Bobrvm.app] [--prefix /usr/local/bin]
        \\
        \\Install bobrvm, Docker, Compose, Buildx, and credential-helper
        \\symlinks. Valid existing paths are never replaced; dangling absolute
        \\symlinks are repaired. The default prefix normally requires sudo.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}

test "install-cli: existing foreign links are conflicts" {
    const io = global.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const foreign = try temporary.dir.createFile(io, "foreign-docker", .{});
    foreign.close(io);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(io, &path_buffer);
    const foreign_path = try std.fs.path.join(std.testing.allocator, &.{
        path_buffer[0..root_len],
        "foreign-docker",
    });
    defer std.testing.allocator.free(foreign_path);
    try temporary.dir.symLink(io, foreign_path, "docker", .{});
    const target = try std.fs.path.join(std.testing.allocator, &.{
        path_buffer[0..root_len],
        "docker",
    });
    defer std.testing.allocator.free(target);
    try std.testing.expectEqual(
        LinkState.conflict,
        try linkState(io, .{ .source = "/ours/docker", .target = target }),
    );
}

test "install-cli: dangling absolute links can be repaired" {
    const io = global.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(io, &path_buffer);
    const missing = try std.fs.path.join(std.testing.allocator, &.{
        path_buffer[0..root_len],
        "missing-docker",
    });
    defer std.testing.allocator.free(missing);
    try temporary.dir.symLink(io, missing, "docker", .{});
    const target = try std.fs.path.join(std.testing.allocator, &.{
        path_buffer[0..root_len],
        "docker",
    });
    defer std.testing.allocator.free(target);

    try std.testing.expectEqual(
        LinkState.dangling,
        try linkState(io, .{ .source = "/ours/docker", .target = target }),
    );
}
