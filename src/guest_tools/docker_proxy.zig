//! Bridge host-initiated virtio-vsock streams to the guest Docker socket.
//!
//! Only the VMM host CID is accepted. Each connection gets a bounded pair of
//! copy loops so Docker's HTTP hijack and half-close behavior remain intact.

const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;

const docker_socket_default = "/run/docker.sock";
pub const port_default: u32 = 62_375;
const host_cid: u32 = 2;
const any_cid: u32 = std.math.maxInt(u32);
const connection_count_max: u32 = 64;
const backlog: c_int = 64;
const copy_buffer_bytes: usize = 64 * 1024;

const Error = error{
    AcceptFailed,
    BindFailed,
    ConnectFailed,
    InvalidArgument,
    ListenFailed,
    SocketFailed,
    ThreadFailed,
};

const Config = struct {
    port: u32 = port_default,
    docker_socket: []const u8 = docker_socket_default,
};

const Connection = struct {
    vsock_fd: posix.socket_t,
    docker_socket: []const u8,
};

const Direction = struct {
    source_fd: posix.socket_t,
    destination_fd: posix.socket_t,
};

var connection_count = std.atomic.Value(u32).init(0);

extern "c" fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;
extern "c" fn accept4(
    socket_fd: c_int,
    address: ?*posix.sockaddr,
    address_len: ?*posix.socklen_t,
    flags: c_int,
) c_int;
extern "c" fn close(fd: c_int) c_int;

pub fn main(minimal: std.process.Init.Minimal) Error!void {
    const config = try parseConfig(minimal);
    const listener = try createListener(config.port);
    defer closeSocket(listener);
    try acceptLoop(listener, config);
}

fn parseConfig(minimal: std.process.Init.Minimal) Error!Config {
    var config = Config{};
    var args = minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--port")) {
            const value = args.next() orelse return error.InvalidArgument;
            config.port = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidArgument;
        } else if (std.mem.eql(u8, argument, "--socket")) {
            config.docker_socket = args.next() orelse return error.InvalidArgument;
        } else {
            return error.InvalidArgument;
        }
    }
    if (config.port == 0 or
        !std.fs.path.isAbsolute(config.docker_socket) or
        config.docker_socket.len >= @sizeOf(@FieldType(posix.sockaddr.un, "path")))
    {
        return error.InvalidArgument;
    }
    return config;
}

fn createListener(port: u32) Error!posix.socket_t {
    const listener = socket(
        @intCast(posix.AF.VSOCK),
        @intCast(posix.SOCK.STREAM | posix.SOCK.CLOEXEC),
        0,
    );
    if (listener < 0) return error.SocketFailed;
    errdefer closeSocket(listener);

    var address = linux.sockaddr.vm{
        .port = port,
        .cid = any_cid,
        .flags = 0,
    };
    if (std.c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
        return error.BindFailed;
    }
    if (std.c.listen(listener, backlog) != 0) return error.ListenFailed;
    return listener;
}

fn acceptLoop(listener: posix.socket_t, config: Config) Error!void {
    while (true) {
        const vsock_fd = try acceptHost(listener);
        const previous = connection_count.fetchAdd(1, .acq_rel);
        if (previous >= connection_count_max) {
            _ = connection_count.fetchSub(1, .acq_rel);
            closeSocket(vsock_fd);
            continue;
        }
        const thread = std.Thread.spawn(.{}, serveConnection, .{Connection{
            .vsock_fd = vsock_fd,
            .docker_socket = config.docker_socket,
        }}) catch {
            _ = connection_count.fetchSub(1, .acq_rel);
            closeSocket(vsock_fd);
            return error.ThreadFailed;
        };
        thread.detach();
    }
}

fn acceptHost(listener: posix.socket_t) Error!posix.socket_t {
    while (true) {
        var peer = linux.sockaddr.vm{ .port = 0, .cid = 0, .flags = 0 };
        var peer_len: posix.socklen_t = @sizeOf(@TypeOf(peer));
        const accepted = accept4(
            listener,
            @ptrCast(&peer),
            &peer_len,
            @intCast(posix.SOCK.CLOEXEC),
        );
        if (accepted >= 0) {
            if (peer.cid == host_cid) return accepted;
            closeSocket(accepted);
            continue;
        }
        if (std.c.errno(@as(c_int, -1)) == .INTR) continue;
        return error.AcceptFailed;
    }
}

fn serveConnection(connection: Connection) void {
    defer _ = connection_count.fetchSub(1, .acq_rel);
    defer closeSocket(connection.vsock_fd);
    const docker_fd = connectDockerSocket(connection.docker_socket) catch return;
    defer closeSocket(docker_fd);
    const upload = std.Thread.spawn(.{}, copyDirection, .{Direction{
        .source_fd = connection.vsock_fd,
        .destination_fd = docker_fd,
    }}) catch {
        shutdownBoth(connection.vsock_fd, docker_fd);
        return;
    };
    copyDirection(.{ .source_fd = docker_fd, .destination_fd = connection.vsock_fd });
    upload.join();
}

fn connectDockerSocket(path: []const u8) Error!posix.socket_t {
    const docker_fd = socket(
        @intCast(posix.AF.UNIX),
        @intCast(posix.SOCK.STREAM | posix.SOCK.CLOEXEC),
        0,
    );
    if (docker_fd < 0) return error.SocketFailed;
    errdefer closeSocket(docker_fd);

    var address: posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    address.family = posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len = @offsetOf(posix.sockaddr.un, "path") + path.len + 1;
    if (std.c.connect(docker_fd, @ptrCast(&address), @intCast(address_len)) != 0) {
        return error.ConnectFailed;
    }
    return docker_fd;
}

fn copyDirection(direction: Direction) void {
    var buffer: [copy_buffer_bytes]u8 = undefined;
    while (true) {
        const count = readRetry(direction.source_fd, &buffer) orelse {
            shutdownBoth(direction.source_fd, direction.destination_fd);
            return;
        };
        if (count == 0) {
            shutdownSend(direction.destination_fd);
            return;
        }
        if (!sendAll(direction.destination_fd, buffer[0..count])) {
            shutdownBoth(direction.source_fd, direction.destination_fd);
            return;
        }
    }
}

fn readRetry(fd: posix.socket_t, buffer: []u8) ?usize {
    while (true) {
        const count = std.c.read(fd, buffer.ptr, buffer.len);
        if (count >= 0) return @intCast(count);
        if (std.c.errno(@as(c_int, -1)) != .INTR) return null;
    }
}

fn sendAll(fd: posix.socket_t, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.send(
            fd,
            bytes[offset..].ptr,
            bytes.len - offset,
            posix.MSG.NOSIGNAL,
        );
        if (count > 0) {
            offset += @intCast(count);
        } else if (count == 0 or std.c.errno(@as(c_int, -1)) != .INTR) {
            return false;
        }
    }
    return true;
}

fn shutdownSend(fd: posix.socket_t) void {
    _ = std.c.shutdown(fd, 1);
}

fn shutdownBoth(first: posix.socket_t, second: posix.socket_t) void {
    _ = std.c.shutdown(first, 2);
    _ = std.c.shutdown(second, 2);
}

fn closeSocket(fd: posix.socket_t) void {
    _ = close(fd);
}
