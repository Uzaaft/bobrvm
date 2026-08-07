//! Guest-side endpoint for the bobrvm-native virtio-console channel.

const std = @import("std");
const protocol = @import("guest_protocol");

const port_path = "/dev/virtio-ports/org.bobrvm.agent.0";

pub fn main(minimal: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const inbox = parseInbox(minimal);
    const port = try std.Io.Dir.openFileAbsolute(io, port_path, .{ .mode = .read_write });
    defer port.close(io);

    try sendCapabilities(port, io, .hello, capabilities(inbox));
    var decoder = protocol.Decoder.init(std.heap.c_allocator);
    defer decoder.deinit();
    var transfer: ?Transfer = null;
    defer abortTransfer(io, &transfer);

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_len = port.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (read_len == 0) return;
        try handleInput(port, io, &decoder, buffer[0..read_len], inbox, &transfer);
    }
}

fn parseInbox(minimal: std.process.Init.Minimal) ?[]const u8 {
    var args = minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--inbox")) return args.next();
    }
    return null;
}

fn capabilities(inbox: ?[]const u8) u64 {
    return if (inbox != null) protocol.Capability.file_transfer else 0;
}

fn handleInput(
    port: std.Io.File,
    io: std.Io,
    decoder: *protocol.Decoder,
    input: []const u8,
    inbox: ?[]const u8,
    transfer: *?Transfer,
) !void {
    var remaining = input;
    while (true) {
        const frame = (try decoder.feed(remaining)) orelse return;
        remaining = &.{};
        switch (frame.kind) {
            .hello => try sendCapabilities(port, io, .hello_ack, capabilities(inbox)),
            .heartbeat => try sendFrame(port, io, .heartbeat, frame.request_id, &.{}),
            .file_offer => acceptFile(port, io, inbox, transfer, frame) catch {
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
            else => {},
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
    var buffer: [protocol.Header.bytes + 8]u8 = undefined;
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
