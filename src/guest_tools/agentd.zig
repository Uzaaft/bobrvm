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
    std.Io.Dir.renameAbsolute(
        active.temporary_path[0..active.temporary_path_len],
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
