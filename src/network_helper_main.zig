//! Root-only shared-network helper. The only client capability is one Ethernet
//! interface; no client-provided paths, commands, routes, or host interfaces.
const std = @import("std");
const net = @import("compat/net.zig");
const protocol = @import("net/shared_protocol.zig");
const Interface = @import("net/vmnet.zig");

const Session = struct {
    busy: std.atomic.Value(bool) = .init(false),
    control: c_int = -1,
    mac: [6]u8 = @splat(0),
    ipv4: std.atomic.Value(u32) = .init(0),
};
var sessions: [32]Session = @splat(.{});
extern "c" fn geteuid() u32;
extern "c" fn chmod([*:0]const u8, u16) c_int;

const Error = net.Error || net.UnixSocketPathError || std.fmt.ParseIntError || error{
    MissingUid,
    InvalidInvocation,
    SocketPermissions,
    UnsafeRuntimeDirectory,
    AcceptFailed,
};
const SessionError = protocol.Error || std.Thread.SpawnError || error{
    Unauthorized,
    InvalidRequest,
    QueryFailed,
    DuplicateMac,
    TooManyInterfaces,
};

pub fn main(init: std.process.Init.Minimal) Error!void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const uid = try std.fmt.parseInt(u32, args.next() orelse return error.MissingUid, 10);
    if (args.next() != null or uid == 0 or geteuid() != 0) return error.InvalidInvocation;
    try prepareRuntimeDirectory();
    const listener = try net.socketCreate(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer net.socketClose(listener);
    try net.removeStaleUnixSocket(protocol.socket_path);
    var address = protocol.address();
    try net.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address)));
    defer _ = std.c.unlink(protocol.socket_path);
    // The containing directory is root-owned. Every connection is authenticated
    // with kernel-provided credentials before it can create an interface.
    if (chmod(protocol.socket_path, 0o666) != 0) return error.SocketPermissions;
    try net.listen(listener, 32);
    while (true) {
        const control = std.c.accept(listener, null, null);
        if (control < 0) {
            if (std.c.errno(@as(c_int, -1)) == .INTR) continue;
            return error.AcceptFailed;
        }
        acceptSession(control, uid) catch net.socketClose(control);
    }
}

fn prepareRuntimeDirectory() error{UnsafeRuntimeDirectory}!void {
    const path = "/var/run/bobrvm-network";
    if (std.c.mkdir(path, 0o755) != 0 and std.c.errno(@as(c_int, -1)) != .EXIST)
        return error.UnsafeRuntimeDirectory;
    var stat: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path, &stat, std.c.AT.SYMLINK_NOFOLLOW) != 0 or
        stat.uid != 0 or stat.mode & 0o022 != 0 or !std.posix.S.ISDIR(stat.mode))
        return error.UnsafeRuntimeDirectory;
}

fn acceptSession(control: c_int, uid: u32) SessionError!void {
    if (protocol.peerUid(control) != uid) return error.Unauthorized;
    try protocol.configure(control);
    var hello: protocol.Hello = undefined;
    try protocol.readExact(control, std.mem.asBytes(&hello));
    if (std.mem.eql(u8, &hello.version, "BOBRIP01")) {
        var ip: u32 = 0;
        for (&sessions) |*session| {
            if (session.busy.load(.acquire) and std.mem.eql(u8, &session.mac, &hello.mac))
                ip = session.ipv4.load(.acquire);
        }
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, ip, .big);
        if (std.c.send(control, &bytes, bytes.len, 0) != bytes.len) return error.QueryFailed;
        net.socketClose(control);
        return;
    }
    if (!hello.valid()) return error.InvalidRequest;
    // Only this thread allocates slots and writes MACs. Workers release slots
    // after interface destruction, so duplicate MACs cannot coexist.
    for (&sessions) |*session| {
        if (session.busy.load(.acquire) and std.mem.eql(u8, &session.mac, &hello.mac))
            return error.DuplicateMac;
    }
    for (&sessions) |*session| {
        if (session.busy.load(.acquire)) continue;
        session.mac = hello.mac;
        session.control = control;
        session.ipv4.store(0, .release);
        session.busy.store(true, .release);
        errdefer session.busy.store(false, .release);
        const thread = try std.Thread.spawn(.{}, runSession, .{session});
        thread.detach();
        return;
    }
    return error.TooManyInterfaces;
}

fn runSession(session: *Session) void {
    defer session.busy.store(false, .release);
    defer net.socketClose(session.control);
    serve(session) catch |err| std.log.err("network session failed: {}", .{err});
}

const ServeError = protocol.Error || error{ InterfaceFailed, SocketFailed, PollFailed };

fn serve(session: *Session) ServeError!void {
    var interface: Interface = undefined;
    try interface.init();
    defer interface.deinit();
    var sockets: [2]c_int = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.DGRAM, 0, &sockets) != 0)
        return error.SocketFailed;
    defer net.socketClose(sockets[0]);
    {
        defer net.socketClose(sockets[1]);
        try protocol.configure(sockets[0]);
        try protocol.sendDescriptor(session.control, sockets[1]);
    }
    var buffer: [protocol.frame_bytes_max + 1]u8 = undefined;
    while (true) {
        var fds = [_]std.c.pollfd{
            .{ .fd = session.control, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = sockets[0], .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = interface.wake.read_fd, .events = std.c.POLL.IN, .revents = 0 },
        };
        if (std.c.poll(&fds, fds.len, -1) < 0) {
            if (std.c.errno(@as(c_int, -1)) == .INTR) continue;
            return error.PollFailed;
        }
        if (fds[0].revents != 0) return;
        if (fds[1].revents & std.c.POLL.IN != 0) {
            const count = std.c.recv(sockets[0], &buffer, buffer.len, std.posix.MSG.DONTWAIT);
            if (count >= 14 and count <= protocol.frame_bytes_max and
                std.mem.eql(u8, buffer[6..12], &session.mac))
            {
                const frame = buffer[0..@intCast(count)];
                if (@import("net/shared.zig").sourceAddress(frame, session.mac)) |ip|
                    session.ipv4.store(ip, .release);
                interface.write(frame);
            }
        }
        if (fds[2].revents & std.c.POLL.IN != 0) {
            interface.wake.drain();
            interface.read(sockets[0]);
        }
    }
}
