//! Per-user Wayland clipboard bridge for the bobrvm native channel.

const std = @import("std");
const protocol = @import("guest_protocol");
const wayland = @import("wayland_client");

const port_path = "/dev/virtio-ports/org.bobrvm.clipboard.0";

pub fn main(_: std.process.Init.Minimal) !void {
    const alloc = std.heap.c_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const port = try std.Io.Dir.openFileAbsolute(io, port_path, .{ .mode = .read_write });
    defer port.close(io);

    var client = try wayland.Client.connect(
        alloc,
        Session.selectionChanged,
        Session.clipboardData,
        null,
    );
    defer client.deinit();
    try client.initialize();

    var session = Session{
        .port = port,
        .io = io,
        .decoder = protocol.Decoder.init(alloc),
        .wayland = &client,
    };
    defer session.decoder.deinit();
    client.userdata = &session;
    try session.sendCapabilities(.hello);
    try session.run();
}

const Session = struct {
    port: std.Io.File,
    io: std.Io,
    decoder: protocol.Decoder,
    wayland: *wayland.Client,
    next_request_id: u64 = 1,

    fn run(self: *Session) !void {
        while (true) {
            var poll_fds = [_]std.posix.pollfd{
                .{ .fd = self.port.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wayland.socketFd(), .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = -1, .events = std.posix.POLL.IN, .revents = 0 },
            };
            if (self.wayland.clipboardFd()) |fd| poll_fds[2].fd = fd;
            _ = try std.posix.poll(&poll_fds, -1);
            try checkPollErrors(&poll_fds);
            if (poll_fds[0].revents & std.posix.POLL.HUP != 0) {
                return error.HostDisconnected;
            }
            if (poll_fds[1].revents & std.posix.POLL.HUP != 0) {
                return error.WaylandDisconnected;
            }
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) try self.receiveHost();
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                try self.wayland.receiveEvents();
            }
            const clipboard_events = std.posix.POLL.IN | std.posix.POLL.HUP;
            if (poll_fds[2].fd >= 0 and poll_fds[2].revents & clipboard_events != 0) {
                try self.wayland.receiveClipboard();
            }
        }
    }

    fn receiveHost(self: *Session) !void {
        var input: [64 * 1024]u8 = undefined;
        const read_len = self.port.readStreaming(self.io, &.{&input}) catch |err| switch (err) {
            error.EndOfStream => return error.HostDisconnected,
            else => return err,
        };
        if (read_len == 0) return error.HostDisconnected;
        var remaining = input[0..read_len];
        while (true) {
            const frame = (try self.decoder.feed(remaining)) orelse return;
            remaining = &.{};
            try self.handleFrame(frame);
        }
    }

    fn handleFrame(self: *Session, frame: protocol.Frame) !void {
        switch (frame.kind) {
            .hello => try self.sendCapabilities(.hello_ack),
            .hello_ack => {},
            .heartbeat => try self.sendFrame(.heartbeat, frame.request_id, &.{}),
            .clipboard_offer => {
                if (frame.payload.len != 0) return error.InvalidClipboardMessage;
                try self.sendFrame(.clipboard_request, frame.request_id, &.{});
            },
            .clipboard_request => {
                if (frame.payload.len != 0) return error.InvalidClipboardMessage;
                try self.wayland.beginClipboardRead(frame.request_id);
            },
            .clipboard_data => {
                const text = try protocol.Clipboard.decode(frame.payload);
                try self.wayland.setSelection(text);
            },
            .clipboard_clear => try self.wayland.clearSelection(),
            else => {},
        }
    }

    fn selectionChanged(userdata: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(userdata orelse return));
        const request_id = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        self.sendFrame(.clipboard_offer, request_id, &.{}) catch {};
    }

    fn clipboardData(request_id: u64, text: []const u8, userdata: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(userdata orelse return));
        self.sendFrame(.clipboard_data, request_id, text) catch {};
    }

    fn sendCapabilities(self: *Session, kind: protocol.MessageKind) !void {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, protocol.Capability.clipboard, .little);
        try self.sendFrame(kind, 0, &payload);
    }

    fn sendFrame(
        self: *Session,
        kind: protocol.MessageKind,
        request_id: u64,
        payload: []const u8,
    ) !void {
        var header: [protocol.Header.bytes]u8 = undefined;
        _ = try protocol.encodeHeader(&header, .{
            .kind = kind,
            .request_id = request_id,
            .payload = &.{},
        }, @intCast(payload.len));
        try self.port.writeStreamingAll(self.io, &header);
        if (payload.len > 0) try self.port.writeStreamingAll(self.io, payload);
    }
};

fn checkPollErrors(poll_fds: []const std.posix.pollfd) !void {
    for (poll_fds) |poll_fd| {
        if (poll_fd.fd < 0) continue;
        if (poll_fd.revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            return error.PollFailed;
        }
    }
}
