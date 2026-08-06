const std = @import("std");
const Allocator = std.mem.Allocator;
const callback = @import("../callback.zig");
const protocol = @import("protocol.zig");

pub const protocol_version = protocol.protocol_version;
pub const payload_bytes_max = protocol.payload_bytes_max;
pub const clipboard_text_bytes_max = protocol.clipboard_text_bytes_max;
pub const Header = protocol.Header;
pub const MessageKind = protocol.MessageKind;
pub const Frame = protocol.Frame;
pub const CodecError = protocol.CodecError;
pub const Capability = protocol.Capability;
pub const Clipboard = protocol.Clipboard;
pub const FileChunk = protocol.FileChunk;
pub const FileOffer = protocol.FileOffer;
pub const encode = protocol.encode;
pub const encodeHeader = protocol.encodeHeader;
pub const Decoder = protocol.Decoder;

pub const Status = enum(u8) {
    disconnected,
    connecting,
    ready,
    protocol_error,
};

pub const HostCapability = struct {
    pub const clipboard = Capability.clipboard;
    pub const file_transfer = Capability.file_transfer;
    pub const management: u64 = 1 << 8;
};

pub const Send = callback.Binding1([]const u8, void);
pub const GuestClipboard = callback.Binding1([]const u8, void);
pub const HostClipboardRequest = callback.Binding0(void);

pub const FileTransferError = std.Io.File.OpenError || std.Io.File.LengthError || error{
    Busy,
    FileTooLarge,
    InvalidFileName,
    InvalidPath,
};

/// Host-side state for the bobrvm-native guest channel. The standard QGA
/// channel remains responsible for privileged management operations.
pub const Native = struct {
    decoder: Decoder,
    send: Send,
    advertised_capabilities: u64,
    status_value: std.atomic.Value(u8) = std.atomic.Value(u8).init(
        @intFromEnum(Status.disconnected),
    ),
    guest_capabilities: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    transfer_mutex: std.Io.Mutex = .init,
    transfer: ?Transfer = null,
    next_request_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    pending_host_clipboard_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    on_guest_clipboard: ?GuestClipboard = null,
    request_host_clipboard: ?HostClipboardRequest = null,

    pub const Options = struct {
        capabilities: u64,
    };
    const Transfer = struct {
        file: std.Io.File,
        size: u64,
        offset: u64 = 0,
        request_id: u64,
    };

    pub fn init(alloc: Allocator, send: Send, options: Options) Native {
        return .{
            .decoder = Decoder.init(alloc),
            .send = send,
            .advertised_capabilities = options.capabilities,
        };
    }

    pub fn deinit(self: *Native) void {
        if (self.transfer) |transfer| transfer.file.close(io());
        self.decoder.deinit();
    }

    pub fn status(self: *const Native) Status {
        return @enumFromInt(self.status_value.load(.acquire));
    }

    pub fn capabilities(self: *const Native) u64 {
        return self.guest_capabilities.load(.acquire);
    }

    pub fn begin(self: *Native) void {
        self.status_value.store(@intFromEnum(Status.connecting), .release);
        self.sendCapabilities(.hello);
    }

    pub fn setClipboardHandlers(
        self: *Native,
        on_guest_clipboard: GuestClipboard,
        request_host_clipboard: HostClipboardRequest,
    ) void {
        self.on_guest_clipboard = on_guest_clipboard;
        self.request_host_clipboard = request_host_clipboard;
    }

    pub fn hostClipboardGrab(self: *Native) void {
        if (self.capabilities() & Capability.clipboard == 0) return;
        const request_id = self.next_request_id.fetchAdd(1, .monotonic);
        self.pending_host_clipboard_id.store(request_id, .release);
        self.sendFrame(.clipboard_offer, request_id, &.{});
    }

    pub fn sendClipboard(self: *Native, text: []const u8) void {
        _ = Clipboard.decode(text) catch return;
        const request_id = self.pending_host_clipboard_id.swap(0, .acq_rel);
        if (request_id == 0) return;
        self.sendFrame(.clipboard_data, request_id, text);
    }

    pub fn offerFile(self: *Native, path: []const u8) FileTransferError!void {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
        const name = std.fs.path.basename(path);
        var offer_payload: [FileOffer.header_bytes + FileOffer.name_bytes_max]u8 = undefined;

        self.transfer_mutex.lockUncancelable(io());
        defer self.transfer_mutex.unlock(io());
        if (self.transfer != null) return error.Busy;

        const file = try std.Io.Dir.openFileAbsolute(io(), path, .{});
        errdefer file.close(io());
        const size = try file.length(io());
        const payload = FileOffer.encode(&offer_payload, size, name) catch |err| switch (err) {
            error.FileTooLarge => return error.FileTooLarge,
            error.InvalidFileName => return error.InvalidFileName,
            else => unreachable,
        };
        const request_id = self.next_request_id.fetchAdd(1, .monotonic);
        self.transfer = .{
            .file = file,
            .size = size,
            .request_id = request_id,
        };
        self.sendFileFrame(.file_offer, request_id, payload);
    }

    pub fn feed(self: *Native, data: []const u8) void {
        var remaining = data;
        while (true) {
            const frame = self.decoder.feed(remaining) catch {
                self.status_value.store(@intFromEnum(Status.protocol_error), .release);
                return;
            } orelse return;
            remaining = &.{};
            self.handleFrame(frame);
        }
    }

    fn handleFrame(self: *Native, frame: Frame) void {
        switch (frame.kind) {
            .hello, .hello_ack => {
                if (frame.payload.len != @sizeOf(u64)) {
                    self.status_value.store(@intFromEnum(Status.protocol_error), .release);
                    return;
                }
                const guest_caps = std.mem.readInt(u64, frame.payload[0..8], .little);
                const negotiated = guest_caps & self.advertised_capabilities;
                self.guest_capabilities.store(
                    negotiated,
                    .release,
                );
                self.status_value.store(@intFromEnum(Status.ready), .release);
                if (frame.kind == .hello) self.sendCapabilities(.hello_ack);
                if (negotiated & Capability.clipboard != 0 and
                    self.request_host_clipboard != null)
                {
                    self.hostClipboardGrab();
                }
            },
            .heartbeat => {},
            .clipboard_offer => self.handleClipboardOffer(frame),
            .clipboard_request => self.handleClipboardRequest(frame),
            .clipboard_data => self.handleClipboardData(frame),
            .file_accept => self.handleFileAccept(frame),
            .file_reject, .file_cancel => self.finishFileTransfer(frame.request_id),
            else => {},
        }
    }

    fn handleClipboardOffer(self: *Native, frame: Frame) void {
        if (self.capabilities() & Capability.clipboard == 0) return;
        if (frame.payload.len != 0) return;
        self.sendFrame(.clipboard_request, frame.request_id, &.{});
    }

    fn handleClipboardRequest(self: *Native, frame: Frame) void {
        if (frame.payload.len != 0) return;
        if (self.pending_host_clipboard_id.load(.acquire) != frame.request_id) return;
        if (self.request_host_clipboard) |handler| handler.call();
    }

    fn handleClipboardData(self: *Native, frame: Frame) void {
        const text = Clipboard.decode(frame.payload) catch return;
        if (self.on_guest_clipboard) |handler| handler.call(text);
    }

    fn handleFileAccept(self: *Native, frame: Frame) void {
        if (frame.payload.len != @sizeOf(u64)) return;
        self.transfer_mutex.lockUncancelable(io());
        defer self.transfer_mutex.unlock(io());
        const transfer = &(self.transfer orelse return);
        if (frame.request_id != transfer.request_id) return;
        const acknowledged = std.mem.readInt(u64, frame.payload[0..8], .little);
        if (acknowledged != transfer.offset) {
            self.cancelFileTransferLocked(frame.request_id);
            return;
        }
        self.sendNextFileChunkLocked(transfer);
    }

    fn sendNextFileChunkLocked(self: *Native, transfer: *Transfer) void {
        if (transfer.offset == transfer.size) {
            self.sendFileFrame(.file_complete, transfer.request_id, &.{});
            self.closeFileTransferLocked();
            return;
        }

        var data: [FileChunk.data_bytes_max]u8 = undefined;
        const remaining: usize = @intCast(@min(transfer.size - transfer.offset, data.len));
        const read_len = transfer.file.readStreaming(io(), &.{data[0..remaining]}) catch {
            self.cancelFileTransferLocked(transfer.request_id);
            return;
        };
        if (read_len == 0) {
            self.cancelFileTransferLocked(transfer.request_id);
            return;
        }

        var payload_buffer: [FileChunk.header_bytes + FileChunk.data_bytes_max]u8 = undefined;
        const payload = FileChunk.encode(
            &payload_buffer,
            transfer.offset,
            data[0..read_len],
        ) catch unreachable;
        self.sendFileFrame(.file_chunk, transfer.request_id, payload);
        transfer.offset += read_len;
    }

    fn finishFileTransfer(self: *Native, request_id: u64) void {
        self.transfer_mutex.lockUncancelable(io());
        defer self.transfer_mutex.unlock(io());
        const transfer = self.transfer orelse return;
        if (transfer.request_id == request_id) self.closeFileTransferLocked();
    }

    fn cancelFileTransferLocked(self: *Native, request_id: u64) void {
        self.sendFileFrame(.file_cancel, request_id, &.{});
        self.closeFileTransferLocked();
    }

    fn closeFileTransferLocked(self: *Native) void {
        const transfer = self.transfer orelse return;
        transfer.file.close(io());
        self.transfer = null;
    }

    fn sendFileFrame(
        self: *Native,
        kind: MessageKind,
        request_id: u64,
        payload: []const u8,
    ) void {
        var encoded: [
            Header.bytes + FileChunk.header_bytes +
                FileChunk.data_bytes_max
        ]u8 = undefined;
        const bytes = encode(&encoded, .{
            .kind = kind,
            .request_id = request_id,
            .payload = payload,
        }) catch return;
        self.send.call(bytes);
    }

    fn sendFrame(
        self: *Native,
        kind: MessageKind,
        request_id: u64,
        payload: []const u8,
    ) void {
        const buffer = self.decoder.alloc.alloc(u8, Header.bytes + payload.len) catch return;
        defer self.decoder.alloc.free(buffer);
        const encoded = encode(buffer, .{
            .kind = kind,
            .request_id = request_id,
            .payload = payload,
        }) catch return;
        self.send.call(encoded);
    }

    fn sendCapabilities(self: *Native, kind: MessageKind) void {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, self.advertised_capabilities, .little);
        var encoded: [Header.bytes + payload.len]u8 = undefined;
        const bytes = encode(&encoded, .{
            .kind = kind,
            .request_id = 0,
            .payload = &payload,
        }) catch return;
        self.send.call(bytes);
    }

    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }
};

test "native agent codec reassembles fragmented frames and rejects oversized payloads" {
    const testing = std.testing;
    var decoder = Decoder.init(testing.allocator);
    defer decoder.deinit();

    var encoded: [Header.bytes + 5]u8 = undefined;
    const frame = Frame{
        .kind = .hello,
        .request_id = 7,
        .payload = "hello",
    };
    _ = try encode(&encoded, frame);

    try testing.expect((try decoder.feed(encoded[0..3])) == null);
    const decoded = (try decoder.feed(encoded[3..])).?;
    try testing.expectEqual(MessageKind.hello, decoded.kind);
    try testing.expectEqual(@as(u64, 7), decoded.request_id);
    try testing.expectEqualStrings("hello", decoded.payload);

    var hostile = encoded;
    std.mem.writeInt(u32, hostile[20..24], payload_bytes_max + 1, .little);
    try testing.expectError(error.PayloadTooLarge, decoder.feed(&hostile));
}

test "native agent handshake records guest capabilities and acknowledges hello" {
    const testing = std.testing;
    const Sent = struct {
        var bytes: [Header.bytes + 8]u8 = undefined;
        var len: usize = 0;

        fn send(data: []const u8, _: ?*anyopaque) void {
            @memcpy(bytes[0..data.len], data);
            len = data.len;
        }
    };
    Sent.len = 0;

    var agent = Native.init(
        testing.allocator,
        Send.initRaw(Sent.send, null),
        .{ .capabilities = Capability.file_transfer },
    );
    defer agent.deinit();
    var payload: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &payload,
        Capability.clipboard | Capability.file_transfer,
        .little,
    );
    var encoded: [Header.bytes + payload.len]u8 = undefined;
    _ = try encode(&encoded, .{ .kind = .hello, .request_id = 0, .payload = &payload });

    agent.feed(&encoded);

    try testing.expectEqual(Status.ready, agent.status());
    try testing.expectEqual(Capability.file_transfer, agent.capabilities());
    try testing.expectEqual(encoded.len, Sent.len);
    try testing.expectEqual(
        @intFromEnum(MessageKind.hello_ack),
        std.mem.readInt(u16, Sent.bytes[6..8], .little),
    );
}

test "native file transfer waits for each guest acknowledgement" {
    const testing = std.testing;
    const Sent = struct {
        var bytes: [Header.bytes + FileChunk.header_bytes + FileChunk.data_bytes_max]u8 = undefined;
        var len: usize = 0;

        fn send(data: []const u8, _: ?*anyopaque) void {
            @memcpy(bytes[0..data.len], data);
            len = data.len;
        }

        fn kind() MessageKind {
            return @enumFromInt(std.mem.readInt(u16, bytes[6..8], .little));
        }

        fn requestId() u64 {
            return std.mem.readInt(u64, bytes[12..20], .little);
        }
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_io = Native.io();
    const file = try tmp.dir.createFile(test_io, "hello.txt", .{});
    try file.writeStreamingAll(test_io, "payload");
    file.close(test_io);
    var directory: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(test_io, &directory);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/hello.txt", .{
        directory[0..directory_len],
    });

    var agent = Native.init(
        testing.allocator,
        Send.initRaw(Sent.send, null),
        .{ .capabilities = Capability.file_transfer },
    );
    defer agent.deinit();
    try agent.offerFile(path);
    try testing.expectEqual(MessageKind.file_offer, Sent.kind());
    const request_id = Sent.requestId();

    var acknowledgement: [8]u8 = @splat(0);
    var encoded: [Header.bytes + acknowledgement.len]u8 = undefined;
    _ = try encode(&encoded, .{
        .kind = .file_accept,
        .request_id = request_id,
        .payload = &acknowledgement,
    });
    agent.feed(&encoded);
    try testing.expectEqual(MessageKind.file_chunk, Sent.kind());
    const chunk = try FileChunk.decode(Sent.bytes[Header.bytes..Sent.len]);
    try testing.expectEqualStrings("payload", chunk.data);

    std.mem.writeInt(u64, &acknowledgement, chunk.data.len, .little);
    _ = try encode(&encoded, .{
        .kind = .file_accept,
        .request_id = request_id,
        .payload = &acknowledgement,
    });
    agent.feed(&encoded);
    try testing.expectEqual(MessageKind.file_complete, Sent.kind());
}

test "native clipboard negotiates by demand in both directions" {
    const testing = std.testing;
    const State = struct {
        var sent: [Header.bytes + 64]u8 = undefined;
        var sent_len: usize = 0;
        var host_requested = false;
        var guest_text: [32]u8 = undefined;
        var guest_text_len: usize = 0;

        fn send(data: []const u8, _: ?*anyopaque) void {
            @memcpy(sent[sent_len..][0..data.len], data);
            sent_len += data.len;
        }

        fn requestHost(_: ?*anyopaque) void {
            host_requested = true;
        }

        fn guestClipboard(text: []const u8, _: ?*anyopaque) void {
            @memcpy(guest_text[0..text.len], text);
            guest_text_len = text.len;
        }

        fn resetSent() void {
            sent_len = 0;
        }
    };
    State.resetSent();
    State.host_requested = false;
    State.guest_text_len = 0;

    var native = Native.init(
        testing.allocator,
        Send.initRaw(State.send, null),
        .{ .capabilities = Capability.clipboard },
    );
    defer native.deinit();
    native.setClipboardHandlers(
        GuestClipboard.initRaw(State.guestClipboard, null),
        HostClipboardRequest.initRaw(State.requestHost, null),
    );

    var capabilities: [8]u8 = undefined;
    std.mem.writeInt(u64, &capabilities, Capability.clipboard, .little);
    var frame_buffer: [Header.bytes + 32]u8 = undefined;
    const hello_bytes = try encode(&frame_buffer, .{
        .kind = .hello,
        .request_id = 0,
        .payload = &capabilities,
    });
    native.feed(hello_bytes);
    try testing.expectEqual(Capability.clipboard, native.capabilities());

    State.resetSent();
    native.hostClipboardGrab();
    var decoder = Decoder.init(testing.allocator);
    defer decoder.deinit();
    const offer = (try decoder.feed(State.sent[0..State.sent_len])).?;
    try testing.expectEqual(MessageKind.clipboard_offer, offer.kind);

    State.resetSent();
    const host_request_bytes = try encode(&frame_buffer, .{
        .kind = .clipboard_request,
        .request_id = offer.request_id,
        .payload = &.{},
    });
    native.feed(host_request_bytes);
    try testing.expect(State.host_requested);
    native.sendClipboard("host text");
    const host_data = (try decoder.feed(State.sent[0..State.sent_len])).?;
    try testing.expectEqual(MessageKind.clipboard_data, host_data.kind);
    try testing.expectEqualStrings("host text", host_data.payload);

    State.resetSent();
    const guest_offer_bytes = try encode(&frame_buffer, .{
        .kind = .clipboard_offer,
        .request_id = 77,
        .payload = &.{},
    });
    native.feed(guest_offer_bytes);
    const request = (try decoder.feed(State.sent[0..State.sent_len])).?;
    try testing.expectEqual(MessageKind.clipboard_request, request.kind);
    try testing.expectEqual(@as(u64, 77), request.request_id);

    const guest_data_bytes = try encode(&frame_buffer, .{
        .kind = .clipboard_data,
        .request_id = 77,
        .payload = "guest text",
    });
    native.feed(guest_data_bytes);
    try testing.expectEqualStrings("guest text", State.guest_text[0..State.guest_text_len]);
}
