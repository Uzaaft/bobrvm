//! Guest-side endpoint for the bobrvm-native virtio-console channel.

const std = @import("std");
const protocol = @import("guest_protocol");

const port_path = "/dev/virtio-ports/org.bobrvm.agent.0";
const touch_id_socket_path = "/run/bobrvm/touch-id.sock";

pub fn main(minimal: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const options = parseOptions(minimal);
    const port = try std.Io.Dir.openFileAbsolute(io, port_path, .{ .mode = .read_write });
    defer port.close(io);

    var broker = Broker{
        .port = port,
        .io = io,
        .options = options,
        .decoder = protocol.Decoder.init(std.heap.c_allocator),
    };
    defer broker.deinit();
    try broker.run();
}

const Options = struct {
    inbox: ?[]const u8 = null,
    touch_id: bool = false,
};

fn parseOptions(minimal: std.process.Init.Minimal) Options {
    var options = Options{};
    var args = minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--inbox")) options.inbox = args.next();
        if (std.mem.eql(u8, arg, "--touch-id")) options.touch_id = true;
    }
    return options;
}

fn capabilities(options: Options) u64 {
    const file_transfer = if (options.inbox != null) protocol.Capability.file_transfer else 0;
    const authentication = if (options.touch_id) protocol.Capability.authentication_v1 else 0;
    return file_transfer | authentication;
}

fn handleInput(
    port: std.Io.File,
    io: std.Io,
    decoder: *protocol.Decoder,
    input: []const u8,
    options: Options,
    transfer: *?Transfer,
    authentication: *AuthenticationClient,
    host_capabilities: *u64,
) !void {
    var remaining = input;
    while (true) {
        const frame = (try decoder.feed(remaining)) orelse return;
        remaining = &.{};
        switch (frame.kind) {
            .hello => {
                host_capabilities.* = try decodeCapabilities(frame.payload);
                try sendCapabilities(port, io, .hello_ack, capabilities(options));
            },
            .hello_ack => host_capabilities.* = try decodeCapabilities(frame.payload),
            .heartbeat => try sendFrame(port, io, .heartbeat, frame.request_id, &.{}),
            .file_offer => acceptFile(port, io, options.inbox, transfer, frame) catch {
                abortTransfer(io, transfer);
                try sendFrame(port, io, .file_reject, frame.request_id, &.{});
            },
            .file_chunk => receiveFileChunk(port, io, transfer, frame) catch {
                abortTransfer(io, transfer);
                try sendFrame(port, io, .file_cancel, frame.request_id, &.{});
            },
            .file_complete => completeFile(io, transfer, frame) catch {
                abortTransfer(io, transfer);
                try sendFrame(port, io, .file_cancel, frame.request_id, &.{});
            },
            .file_cancel => abortTransfer(io, transfer),
            .authentication_result => authentication.finish(frame),
            else => {},
        }
    }
}

const Broker = struct {
    port: std.Io.File,
    io: std.Io,
    options: Options,
    decoder: protocol.Decoder,
    transfer: ?Transfer = null,
    listener: std.posix.fd_t = -1,
    authentication: AuthenticationClient = .{},
    next_request_id: u64 = 1,
    host_capabilities: u64 = 0,

    fn deinit(self: *Broker) void {
        abortTransfer(self.io, &self.transfer);
        self.authentication.close();
        if (self.listener >= 0) _ = std.c.close(self.listener);
        if (self.options.touch_id) _ = std.c.unlink(touch_id_socket_path);
        self.decoder.deinit();
    }

    fn run(self: *Broker) !void {
        if (self.options.touch_id) self.listener = try openTouchIDListener();
        try sendCapabilities(self.port, self.io, .hello, capabilities(self.options));

        while (true) {
            var poll_fds = [_]std.posix.pollfd{
                .{ .fd = self.port.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.listener, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.authentication.fd(), .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = try std.posix.poll(&poll_fds, -1);
            try checkPollErrors(&poll_fds);
            if (poll_fds[0].revents & std.posix.POLL.HUP != 0) return error.HostDisconnected;
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) try self.receiveHost();
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) try self.acceptAuthentication();
            const client_events = std.posix.POLL.IN | std.posix.POLL.HUP;
            if (self.authentication.fd() == poll_fds[2].fd and
                poll_fds[2].fd >= 0 and
                poll_fds[2].revents & client_events != 0)
            {
                try self.receiveAuthentication();
            }
        }
    }

    fn receiveHost(self: *Broker) !void {
        var input: [64 * 1024]u8 = undefined;
        const read_len = self.port.readStreaming(self.io, &.{&input}) catch |err| switch (err) {
            error.EndOfStream => return error.HostDisconnected,
            else => return err,
        };
        if (read_len == 0) return error.HostDisconnected;
        try handleInput(
            self.port,
            self.io,
            &self.decoder,
            input[0..read_len],
            self.options,
            &self.transfer,
            &self.authentication,
            &self.host_capabilities,
        );
    }

    fn acceptAuthentication(self: *Broker) !void {
        const fd = std.c.accept(self.listener, null, null);
        if (fd < 0) return error.AcceptFailed;
        if (self.authentication.fd() >= 0) {
            const failed = [_]u8{@intFromEnum(protocol.AuthenticationResult.failed)};
            _ = std.c.write(fd, &failed, failed.len);
            _ = std.c.close(fd);
            return;
        }
        self.authentication.attach(fd);
    }

    fn receiveAuthentication(self: *Broker) !void {
        const client = &self.authentication;
        const read_len = std.posix.read(client.fd(), client.buffer[client.length..]) catch |err| {
            client.cancel(self.port, self.io);
            return err;
        };
        if (read_len == 0) {
            client.cancel(self.port, self.io);
            return;
        }
        client.length += read_len;
        if (client.length < protocol.AuthenticationRequest.header_bytes) return;
        const message_len = protocol.AuthenticationRequest.header_bytes + client.buffer[1];
        if (message_len > client.buffer.len or client.length > message_len) {
            client.fail();
            return;
        }
        if (client.length < message_len) return;
        _ = protocol.AuthenticationRequest.decode(client.buffer[0..message_len]) catch {
            client.fail();
            return;
        };
        if (self.host_capabilities & protocol.Capability.host_authentication == 0) {
            client.respond(.unavailable);
            return;
        }
        const request_id = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        if (!client.begin(request_id)) {
            client.fail();
            return;
        }
        try sendFrame(
            self.port,
            self.io,
            .authentication_request,
            request_id,
            client.buffer[0..message_len],
        );
    }
};

const SocketAuthenticationFrontend = struct {
    fd: std.posix.fd_t = -1,

    pub fn available(self: *const SocketAuthenticationFrontend) bool {
        return self.fd >= 0;
    }

    pub fn complete(
        self: *SocketAuthenticationFrontend,
        result: protocol.AuthenticationResult,
    ) void {
        if (self.fd < 0) return;
        const response = [_]u8{@intFromEnum(result)};
        _ = std.c.write(self.fd, &response, response.len);
        self.close();
    }

    pub fn close(self: *SocketAuthenticationFrontend) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

const AuthenticationSession = protocol.AuthenticationFrontendSession(
    SocketAuthenticationFrontend,
);

const AuthenticationClient = struct {
    session: AuthenticationSession = .{ .frontend = .{} },
    buffer: [
        protocol.AuthenticationRequest.header_bytes +
            protocol.authentication_principal_bytes_max
    ]u8 = undefined,
    length: usize = 0,

    fn fd(self: *const AuthenticationClient) std.posix.fd_t {
        return self.session.frontend.fd;
    }

    fn attach(self: *AuthenticationClient, fd_value: std.posix.fd_t) void {
        std.debug.assert(self.fd() < 0);
        self.* = .{};
        self.session.frontend.fd = fd_value;
    }

    fn begin(self: *AuthenticationClient, request_id: u64) bool {
        return self.session.begin(request_id);
    }

    fn finish(self: *AuthenticationClient, frame: protocol.Frame) void {
        const result = protocol.AuthenticationResponse.decode(frame.payload) catch .failed;
        if (!self.session.complete(frame.request_id, result)) return;
        self.* = .{};
    }

    fn fail(self: *AuthenticationClient) void {
        self.respond(.failed);
    }

    fn respond(self: *AuthenticationClient, result: protocol.AuthenticationResult) void {
        self.session.frontend.complete(result);
        self.* = .{};
    }

    fn cancel(self: *AuthenticationClient, port: std.Io.File, io: std.Io) void {
        const request_id = self.session.close();
        self.* = .{};
        if (request_id) |id| sendFrame(port, io, .authentication_cancel, id, &.{}) catch {};
    }

    fn close(self: *AuthenticationClient) void {
        _ = self.session.close();
        self.* = .{};
    }
};

fn decodeCapabilities(payload: []const u8) !u64 {
    if (payload.len != @sizeOf(u64)) return error.InvalidCapabilities;
    return std.mem.readInt(u64, payload[0..8], .little);
}

fn openTouchIDListener() !std.posix.fd_t {
    _ = std.c.unlink(touch_id_socket_path);
    const fd = std.c.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    );
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);

    var address: std.posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..touch_id_socket_path.len], touch_id_socket_path);
    const address_len = @offsetOf(std.posix.sockaddr.un, "path") + touch_id_socket_path.len + 1;
    if (@hasField(std.posix.sockaddr.un, "len")) address.len = @intCast(address_len);
    if (std.c.bind(fd, @ptrCast(&address), @intCast(address_len)) != 0) {
        return error.BindFailed;
    }
    if (std.c.chmod(touch_id_socket_path, 0o600) != 0) return error.ChmodFailed;
    if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
    return fd;
}

fn checkPollErrors(poll_fds: []const std.posix.pollfd) !void {
    for (poll_fds) |poll_fd| {
        if (poll_fd.fd < 0) continue;
        if (poll_fd.revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            return error.PollFailed;
        }
    }
}

fn sendCapabilities(
    port: std.Io.File,
    io: std.Io,
    kind: protocol.MessageKind,
    guest_capabilities: u64,
) !void {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u64, &payload, guest_capabilities, .little);
    try sendFrame(port, io, kind, 0, &payload);
}

fn acceptFile(
    port: std.Io.File,
    io: std.Io,
    inbox: ?[]const u8,
    transfer: *?Transfer,
    frame: protocol.Frame,
) !void {
    const directory = inbox orelse return error.FileTransferDisabled;
    if (transfer.* != null) return error.TransferInProgress;
    const offer = try protocol.FileOffer.decode(frame.payload);

    var next = Transfer{ .file = undefined, .size = offer.size, .request_id = frame.request_id };
    const final_path = try std.fmt.bufPrint(&next.final_path, "{s}/{s}", .{
        directory,
        offer.name,
    });
    next.final_path_len = final_path.len;
    if (std.Io.Dir.accessAbsolute(io, final_path, .{})) {
        return error.PathAlreadyExists;
    } else |_| {}
    const temporary_path = try std.fmt.bufPrint(&next.temporary_path, "{s}/.{s}.part-{}", .{
        directory,
        offer.name,
        frame.request_id,
    });
    next.temporary_path_len = temporary_path.len;
    next.file = try std.Io.Dir.createFileAbsolute(io, temporary_path, .{ .exclusive = true });
    transfer.* = next;
    try sendFileAcknowledgement(port, io, frame.request_id, 0);
}

fn receiveFileChunk(
    port: std.Io.File,
    io: std.Io,
    transfer: *?Transfer,
    frame: protocol.Frame,
) !void {
    const active = &(transfer.* orelse return error.NoTransfer);
    if (active.request_id != frame.request_id) return error.WrongTransfer;
    const chunk = try protocol.FileChunk.decode(frame.payload);
    if (chunk.data.len == 0) return error.InvalidChunk;
    if (chunk.offset != active.offset) return error.InvalidOffset;
    if (chunk.data.len > active.size - active.offset) return error.FileTooLarge;
    try active.file.writeStreamingAll(io, chunk.data);
    active.offset += chunk.data.len;
    try sendFileAcknowledgement(port, io, frame.request_id, active.offset);
}

fn completeFile(io: std.Io, transfer: *?Transfer, frame: protocol.Frame) !void {
    const active = transfer.* orelse return error.NoTransfer;
    if (active.request_id != frame.request_id) return error.WrongTransfer;
    if (active.offset != active.size) return error.IncompleteTransfer;
    active.file.close(io);
    transfer.* = null;
    const cwd = std.Io.Dir.cwd();
    cwd.renamePreserve(
        active.temporary_path[0..active.temporary_path_len],
        cwd,
        active.final_path[0..active.final_path_len],
        io,
    ) catch |err| {
        std.Io.Dir.deleteFileAbsolute(
            io,
            active.temporary_path[0..active.temporary_path_len],
        ) catch {};
        return err;
    };
}

fn abortTransfer(io: std.Io, transfer: *?Transfer) void {
    const active = transfer.* orelse return;
    active.file.close(io);
    std.Io.Dir.deleteFileAbsolute(
        io,
        active.temporary_path[0..active.temporary_path_len],
    ) catch {};
    transfer.* = null;
}

fn sendFileAcknowledgement(
    port: std.Io.File,
    io: std.Io,
    request_id: u64,
    offset: u64,
) !void {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u64, &payload, offset, .little);
    try sendFrame(port, io, .file_accept, request_id, &payload);
}

fn sendFrame(
    port: std.Io.File,
    io: std.Io,
    kind: protocol.MessageKind,
    request_id: u64,
    payload: []const u8,
) !void {
    var buffer: [
        protocol.Header.bytes + protocol.AuthenticationRequest.header_bytes +
            protocol.authentication_principal_bytes_max
    ]u8 = undefined;
    const encoded = try protocol.encode(&buffer, .{
        .kind = kind,
        .request_id = request_id,
        .payload = payload,
    });
    try port.writeStreamingAll(io, encoded);
}

const Transfer = struct {
    file: std.Io.File,
    size: u64,
    offset: u64 = 0,
    request_id: u64,
    temporary_path: [std.fs.max_path_bytes]u8 = undefined,
    temporary_path_len: usize = 0,
    final_path: [std.fs.max_path_bytes]u8 = undefined,
    final_path_len: usize = 0,
};

fn expectFileAcknowledgement(fd: std.posix.fd_t, request_id: u64, offset: u64) !void {
    var encoded: [protocol.Header.bytes + 8]u8 = undefined;
    var read_len: usize = 0;
    while (read_len < encoded.len) {
        const count = try std.posix.read(fd, encoded[read_len..]);
        if (count == 0) return error.EndOfStream;
        read_len += count;
    }

    try std.testing.expectEqual(
        protocol.Header.magic,
        std.mem.readInt(u32, encoded[0..4], .little),
    );
    try std.testing.expectEqual(
        @intFromEnum(protocol.MessageKind.file_accept),
        std.mem.readInt(u16, encoded[6..8], .little),
    );
    try std.testing.expectEqual(request_id, std.mem.readInt(u64, encoded[12..20], .little));
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, encoded[20..24], .little));
    try std.testing.expectEqual(offset, std.mem.readInt(u64, encoded[24..32], .little));
}

test "guest file transfer commits complete ordered payloads atomically" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];

    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);
    const port = std.Io.File{
        .handle = pipe_fds[1],
        .flags = .{ .nonblocking = false },
    };

    var transfer: ?Transfer = null;
    defer abortTransfer(io, &transfer);
    var offer_buffer: [protocol.FileOffer.header_bytes + "hello.txt".len]u8 = undefined;
    const offer = try protocol.FileOffer.encode(&offer_buffer, 5, "hello.txt");
    const offer_frame = protocol.Frame{ .kind = .file_offer, .request_id = 42, .payload = offer };
    try acceptFile(port, io, directory, &transfer, offer_frame);
    try expectFileAcknowledgement(pipe_fds[0], 42, 0);

    var chunk_buffer: [protocol.FileChunk.header_bytes + 3]u8 = undefined;
    const first = try protocol.FileChunk.encode(&chunk_buffer, 0, "hel");
    try receiveFileChunk(port, io, &transfer, .{
        .kind = .file_chunk,
        .request_id = 42,
        .payload = first,
    });
    try expectFileAcknowledgement(pipe_fds[0], 42, 3);
    try std.testing.expectError(error.IncompleteTransfer, completeFile(io, &transfer, .{
        .kind = .file_complete,
        .request_id = 42,
        .payload = &.{},
    }));

    const second = try protocol.FileChunk.encode(&chunk_buffer, 3, "lo");
    try receiveFileChunk(port, io, &transfer, .{
        .kind = .file_chunk,
        .request_id = 42,
        .payload = second,
    });
    try expectFileAcknowledgement(pipe_fds[0], 42, 5);
    try completeFile(io, &transfer, .{
        .kind = .file_complete,
        .request_id = 42,
        .payload = &.{},
    });

    var final_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const final_path = try std.fmt.bufPrint(&final_path_buffer, "{s}/hello.txt", .{directory});
    const file = try std.Io.Dir.openFileAbsolute(io, final_path, .{});
    defer file.close(io);
    var contents: [5]u8 = undefined;
    try std.testing.expectEqual(contents.len, try file.readPositionalAll(io, &contents, 0));
    try std.testing.expectEqualStrings("hello", &contents);
    try std.testing.expectError(
        error.PathAlreadyExists,
        acceptFile(port, io, directory, &transfer, offer_frame),
    );
}

test "guest file transfer never replaces a destination created in flight" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temporary.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];

    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);
    const port = std.Io.File{
        .handle = pipe_fds[1],
        .flags = .{ .nonblocking = false },
    };

    var transfer: ?Transfer = null;
    defer abortTransfer(io, &transfer);
    var offer_buffer: [protocol.FileOffer.header_bytes + "race.txt".len]u8 = undefined;
    const offer = try protocol.FileOffer.encode(&offer_buffer, 0, "race.txt");
    try acceptFile(port, io, directory, &transfer, .{
        .kind = .file_offer,
        .request_id = 43,
        .payload = offer,
    });
    try expectFileAcknowledgement(pipe_fds[0], 43, 0);

    var final_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const final_path = try std.fmt.bufPrint(&final_path_buffer, "{s}/race.txt", .{directory});
    const existing = try std.Io.Dir.createFileAbsolute(io, final_path, .{ .exclusive = true });
    try existing.writeStreamingAll(io, "keep");
    existing.close(io);

    try std.testing.expectError(error.PathAlreadyExists, completeFile(io, &transfer, .{
        .kind = .file_complete,
        .request_id = 43,
        .payload = &.{},
    }));
    const preserved = try std.Io.Dir.openFileAbsolute(io, final_path, .{});
    defer preserved.close(io);
    var contents: [4]u8 = undefined;
    try std.testing.expectEqual(contents.len, try preserved.readPositionalAll(io, &contents, 0));
    try std.testing.expectEqualStrings("keep", &contents);
}

test "guest authentication bridge returns the correlated host result" {
    var response_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&response_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(response_fds[0]);

    var client = AuthenticationClient{};
    client.attach(response_fds[1]);
    try std.testing.expect(client.begin(17));
    client.finish(.{
        .kind = .authentication_result,
        .request_id = 16,
        .payload = &.{@intFromEnum(protocol.AuthenticationResult.failed)},
    });
    try std.testing.expectEqual(@as(std.posix.fd_t, response_fds[1]), client.fd());
    client.finish(.{
        .kind = .authentication_result,
        .request_id = 17,
        .payload = &.{@intFromEnum(protocol.AuthenticationResult.success)},
    });
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), client.fd());

    var result: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(response_fds[0], &result));
    try std.testing.expectEqual(@intFromEnum(protocol.AuthenticationResult.success), result[0]);
}

test "guest authentication disconnect cancels the matching host request" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var port_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&port_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(port_fds[0]);
    defer _ = std.c.close(port_fds[1]);
    var client_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&client_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(client_fds[0]);

    const port = std.Io.File{ .handle = port_fds[1], .flags = .{ .nonblocking = false } };
    var client = AuthenticationClient{};
    client.attach(client_fds[1]);
    try std.testing.expect(client.begin(23));
    client.cancel(port, io);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), client.fd());

    var encoded: [protocol.Header.bytes]u8 = undefined;
    var read_len: usize = 0;
    while (read_len < encoded.len) {
        const count = try std.posix.read(port_fds[0], encoded[read_len..]);
        if (count == 0) return error.EndOfStream;
        read_len += count;
    }
    try std.testing.expectEqual(
        @intFromEnum(protocol.MessageKind.authentication_cancel),
        std.mem.readInt(u16, encoded[6..8], .little),
    );
    try std.testing.expectEqual(@as(u64, 23), std.mem.readInt(u64, encoded[12..20], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, encoded[20..24], .little));
}
