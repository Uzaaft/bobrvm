//! `bobrvm ssh [-- <ssh args>]` - Open an SSH session to the project's
//! guest through a forwarded port.
//!
//! bobrvm does not implement SSH; it selects the forwarded host port
//! that maps to guest port 22, builds a hardened `ssh` command line,
//! and execs the system client. The guest must run sshd and the
//! project must forward a host port to 22 (forwards = ["2222:22"] in
//! bobrvm.toml); start it first with `bobrvm up` / `up --detach`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const project = @import("project.zig");

const log = std.log.scoped(.cli);

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    var saw_separator = false;
    while (args.next()) |arg| {
        if (!saw_separator and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            printHelp();
            return;
        }
        if (!saw_separator and std.mem.eql(u8, arg, "--")) {
            saw_separator = true;
            continue;
        }
        try extra.append(arena, try arena.dupe(u8, arg));
    }

    var cwd_buf: [1024]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    const root = (try project.findRoot(arena, cwd)) orelse {
        log.err("no {s} found in {s} or any parent directory", .{ project.FILE_NAME, cwd });
        return error.NoProjectFile;
    };
    const proj = try project.load(arena, root);

    const host_port = guestPort22Forward(&proj.config) orelse {
        log.err(
            "no forward to guest port 22; add forwards = [\"2222:22\"] to {s} and re-run bobrvm up",
            .{project.FILE_NAME},
        );
        return error.NoSshForward;
    };

    const argv = try buildArgv(arena, proj.config.ssh_user, host_port, extra.items);
    // Null-terminated argv for execvp.
    var c_argv = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |a, i| c_argv[i] = try arena.dupeZ(u8, a);
    c_argv[argv.len] = null;

    log.info("ssh {s}@127.0.0.1:{d}", .{ proj.config.ssh_user, host_port });
    _ = execvp(c_argv[0].?, @ptrCast(c_argv.ptr));
    // Only reached if exec failed (ssh not installed).
    log.err("cannot exec ssh — is the OpenSSH client installed?", .{});
    return error.SshExecFailed;
}

/// The host port of the forward whose guest side is port 22, or null.
fn guestPort22Forward(config: *const Config) ?u16 {
    for (config.forwards[0..config.forward_count]) |f| {
        if (f.guest_port == 22) return f.host_port;
    }
    return null;
}

/// Build the ssh argv: connect to the forwarded port on localhost with
/// options suited to short-lived guests — no host-key persistence
/// (guest identities are ephemeral) and keepalives well under the NAT's
/// 300 s idle window so a quiet session does not wedge. Extra args are
/// appended verbatim (e.g. a remote command).
fn buildArgv(
    arena: Allocator,
    user: []const u8,
    host_port: u16,
    extra: []const []const u8,
) ![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "ssh",
        "-p",
        try std.fmt.allocPrint(arena, "{d}", .{host_port}),
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        "-o",
        "ServerAliveInterval=30",
        try std.fmt.allocPrint(arena, "{s}@127.0.0.1", .{user}),
    });
    try argv.appendSlice(arena, extra);
    return argv.items;
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm ssh [-- <ssh args>]
        \\
        \\Open an SSH session to the project's guest through the host port
        \\forwarded to guest port 22. The guest must run sshd and the
        \\project must declare the forward:
        \\
        \\  forwards = ["2222:22"]
        \\  ssh-user = "root"          # default: root
        \\
        \\Start the guest first (bobrvm up or up --detach). Arguments after
        \\`--` are passed to ssh, e.g:
        \\
        \\  bobrvm ssh -- uptime
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}

const testing = std.testing;

test "ssh: selects the host port forwarded to guest 22" {
    var config = Config{};
    config.forwards[0] = .{ .host_port = 8080, .guest_port = 80 };
    config.forwards[1] = .{ .host_port = 2222, .guest_port = 22 };
    config.forward_count = 2;
    try testing.expectEqual(@as(?u16, 2222), guestPort22Forward(&config));

    var none = Config{};
    none.forwards[0] = .{ .host_port = 8080, .guest_port = 80 };
    none.forward_count = 1;
    try testing.expectEqual(@as(?u16, null), guestPort22Forward(&none));
}

test "ssh: builds a hardened argv with the forwarded port and extra args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try buildArgv(arena, "dev", 2222, &.{ "uptime", "-p" });
    try testing.expectEqualStrings("ssh", argv[0]);
    try testing.expectEqualStrings("-p", argv[1]);
    try testing.expectEqualStrings("2222", argv[2]);
    try testing.expectEqualStrings("dev@127.0.0.1", argv[argv.len - 3]);
    try testing.expectEqualStrings("uptime", argv[argv.len - 2]);
    try testing.expectEqualStrings("-p", argv[argv.len - 1]);

    // The keepalive is present and under the NAT's 300 s idle window.
    var has_keepalive = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "ServerAliveInterval=30")) has_keepalive = true;
    }
    try testing.expect(has_keepalive);
}
