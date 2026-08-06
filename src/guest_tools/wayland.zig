//! Minimal Wayland data-control client for the bobrvm session agent.
//!
//! The client speaks ext-data-control-v1 and the compatible wlroots v1
//! protocol directly. Keeping the wire client here avoids a runtime dependency
//! while still making clipboard ownership live in the graphical user session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const log = std.log.scoped(.wayland_clipboard);

extern "c" fn close(fd: c_int) c_int;

pub const SelectionChanged = *const fn (?*anyopaque) void;
pub const ClipboardData = *const fn (u64, []const u8, ?*anyopaque) void;

const input_bytes_max: usize = 1024 * 1024;
const clipboard_bytes_max: usize = 48 * 1024;
const received_fds_max: usize = 16;
const sources_max: usize = 16;
const interface_bytes_max: usize = 64;

pub const Client = struct {
    alloc: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    input: std.ArrayListUnmanaged(u8) = .empty,
    received_fds: std.ArrayListUnmanaged(posix.fd_t) = .empty,
    on_selection_changed: SelectionChanged,
    on_clipboard_data: ClipboardData,
    userdata: ?*anyopaque,

    next_object_id: u32 = 4,
    registry_sync_done: bool = false,
    seat_global: u32 = 0,
    ext_manager_global: u32 = 0,
    wlr_manager_global: u32 = 0,
    seat_id: u32 = 0,
    manager_id: u32 = 0,
    device_id: u32 = 0,
    current_offer_id: u32 = 0,
    current_mime: [interface_bytes_max]u8 = undefined,
    current_mime_len: usize = 0,
    pending_offer_id: u32 = 0,
    pending_mime: [interface_bytes_max]u8 = undefined,
    pending_mime_len: usize = 0,
    pending_mime_priority: u8 = 0,
    sources: [sources_max]?Source = @splat(null),
    pending_read: ?PendingRead = null,

    const display_id: u32 = 1;
    const registry_id: u32 = 2;
    const registry_sync_id: u32 = 3;

    const Source = struct {
        id: u32,
        text: []u8,
    };

    const PendingRead = struct {
        fd: posix.fd_t,
        request_id: u64,
        data: std.ArrayListUnmanaged(u8) = .empty,
    };

    pub fn connect(
        alloc: Allocator,
        on_selection_changed: SelectionChanged,
        on_clipboard_data: ClipboardData,
        userdata: ?*anyopaque,
    ) !Client {
        const io = std.Io.Threaded.global_single_threaded.io();
        var path_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
        const path = try displayPath(&path_buffer);
        const address = try std.Io.net.UnixAddress.init(path);
        const stream = try address.connect(io);
        return .{
            .alloc = alloc,
            .io = io,
            .stream = stream,
            .on_selection_changed = on_selection_changed,
            .on_clipboard_data = on_clipboard_data,
            .userdata = userdata,
        };
    }

    pub fn deinit(self: *Client) void {
        self.abortRead();
        for (&self.sources) |*entry| self.removeSource(entry);
        for (self.received_fds.items) |fd| closeFd(fd);
        self.received_fds.deinit(self.alloc);
        self.input.deinit(self.alloc);
        self.stream.close(self.io);
    }

    pub fn initialize(self: *Client) !void {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, registry_id, .little);
        try self.sendRequest(display_id, 1, &payload, null);
        std.mem.writeInt(u32, &payload, registry_sync_id, .little);
        try self.sendRequest(display_id, 0, &payload, null);
        while (!self.registry_sync_done) try self.receiveEvents();

        if (self.seat_global == 0) return error.WaylandSeatUnavailable;
        if (self.ext_manager_global == 0 and self.wlr_manager_global == 0) {
            return error.DataControlUnavailable;
        }

        self.seat_id = self.nextObjectId();
        try self.bindGlobal(self.seat_global, "wl_seat", 1, self.seat_id);
        self.manager_id = self.nextObjectId();
        if (self.ext_manager_global != 0) {
            try self.bindGlobal(
                self.ext_manager_global,
                "ext_data_control_manager_v1",
                1,
                self.manager_id,
            );
            log.info("using ext-data-control-v1", .{});
        } else {
            try self.bindGlobal(
                self.wlr_manager_global,
                "zwlr_data_control_manager_v1",
                1,
                self.manager_id,
            );
            log.info("using wlr-data-control-unstable-v1", .{});
        }

        self.device_id = self.nextObjectId();
        var device_payload: [8]u8 = undefined;
        std.mem.writeInt(u32, device_payload[0..4], self.device_id, .little);
        std.mem.writeInt(u32, device_payload[4..8], self.seat_id, .little);
        try self.sendRequest(self.manager_id, 1, &device_payload, null);
    }

    pub fn socketFd(self: *const Client) posix.fd_t {
        return self.stream.socket.handle;
    }

    pub fn clipboardFd(self: *const Client) ?posix.fd_t {
        const pending = self.pending_read orelse return null;
        return pending.fd;
    }

    pub fn receiveEvents(self: *Client) !void {
        var data: [64 * 1024]u8 = undefined;
        var control: [256]u8 align(@alignOf(posix.system.cmsghdr)) = undefined;
        var iovec: posix.iovec = .{ .base = &data, .len = data.len };
        var message: posix.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = (&iovec)[0..1],
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };
        const received = while (true) {
            const rc = posix.system.recvmsg(self.socketFd(), &message, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                else => return error.WaylandReadFailed,
            }
        };
        if (received == 0) return error.WaylandDisconnected;
        if (message.flags & posix.MSG.CTRUNC != 0) return error.TooManyWaylandFds;
        try self.collectFds(control[0..message.controllen]);
        try self.appendInput(data[0..@intCast(received)]);
        try self.dispatchMessages();
    }

    pub fn beginClipboardRead(self: *Client, request_id: u64) !void {
        if (self.pending_read != null) return error.ClipboardReadInProgress;
        if (self.current_offer_id == 0 or self.current_mime_len == 0) {
            return error.ClipboardUnavailable;
        }

        var pipe_fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        errdefer {
            closeFd(pipe_fds[0]);
            closeFd(pipe_fds[1]);
        }
        setNonBlocking(pipe_fds[0]);

        var payload: [4 + interface_bytes_max]u8 = undefined;
        var payload_len: usize = 0;
        try appendString(&payload, &payload_len, self.current_mime[0..self.current_mime_len]);
        try self.sendRequest(
            self.current_offer_id,
            0,
            payload[0..payload_len],
            pipe_fds[1],
        );
        closeFd(pipe_fds[1]);
        self.pending_read = .{ .fd = pipe_fds[0], .request_id = request_id };
    }

    pub fn receiveClipboard(self: *Client) !void {
        const pending = &(self.pending_read orelse return);
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const read_len = posix.read(pending.fd, &buffer) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return error.ClipboardReadFailed,
            };
            if (read_len == 0) {
                const request_id = pending.request_id;
                var data = pending.data;
                closeFd(pending.fd);
                self.pending_read = null;
                defer data.deinit(self.alloc);
                if (!std.unicode.utf8ValidateSlice(data.items)) {
                    return error.InvalidClipboardText;
                }
                self.on_clipboard_data(request_id, data.items, self.userdata);
                return;
            }
            if (pending.data.items.len + read_len > clipboard_bytes_max) {
                self.abortRead();
                return error.ClipboardTooLarge;
            }
            try pending.data.appendSlice(self.alloc, buffer[0..read_len]);
        }
    }

    pub fn setSelection(self: *Client, text: []const u8) !void {
        if (text.len > clipboard_bytes_max) return error.ClipboardTooLarge;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidClipboardText;
        const slot = self.emptySourceSlot() orelse return error.TooManyClipboardSources;
        const source_id = self.nextObjectId();
        const owned_text = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned_text);

        var id_payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &id_payload, source_id, .little);
        try self.sendRequest(self.manager_id, 0, &id_payload, null);
        try self.sendStringRequest(source_id, 0, "text/plain;charset=utf-8");
        try self.sendStringRequest(source_id, 0, "text/plain");
        try self.sendRequest(self.device_id, 0, &id_payload, null);
        slot.* = .{ .id = source_id, .text = owned_text };
    }

    pub fn clearSelection(self: *Client) !void {
        var payload: [4]u8 = @splat(0);
        try self.sendRequest(self.device_id, 0, &payload, null);
    }

    fn appendInput(self: *Client, data: []const u8) !void {
        const new_len = std.math.add(usize, self.input.items.len, data.len) catch {
            return error.WaylandMessageTooLarge;
        };
        if (new_len > input_bytes_max) return error.WaylandMessageTooLarge;
        try self.input.appendSlice(self.alloc, data);
    }

    fn dispatchMessages(self: *Client) !void {
        while (self.input.items.len >= 8) {
            const size_opcode = std.mem.readInt(u32, self.input.items[4..8], .little);
            const size: usize = size_opcode >> 16;
            if (size < 8 or size % 4 != 0 or size > input_bytes_max) {
                return error.InvalidWaylandMessage;
            }
            if (self.input.items.len < size) return;
            const object_id = std.mem.readInt(u32, self.input.items[0..4], .little);
            const opcode: u16 = @truncate(size_opcode);
            try self.handleMessage(object_id, opcode, self.input.items[8..size]);
            self.input.replaceRangeAssumeCapacity(0, size, &.{});
        }
    }

    fn handleMessage(
        self: *Client,
        object_id: u32,
        opcode: u16,
        payload: []const u8,
    ) !void {
        if (object_id == display_id) return self.handleDisplay(opcode, payload);
        if (object_id == registry_id) return self.handleRegistry(opcode, payload);
        if (object_id == registry_sync_id) {
            if (opcode == 0) self.registry_sync_done = true;
            return;
        }
        if (object_id == self.device_id) return self.handleDevice(opcode, payload);
        if (self.sourceForId(object_id)) |source| {
            return self.handleSource(source, opcode, payload);
        }
        if (object_id == self.pending_offer_id or object_id == self.current_offer_id) {
            return self.handleOffer(object_id, opcode, payload);
        }
    }

    fn handleDisplay(self: *Client, opcode: u16, payload: []const u8) !void {
        _ = self;
        if (opcode == 0) {
            if (payload.len < 8) return error.InvalidWaylandMessage;
            return error.WaylandProtocolError;
        }
    }

    fn handleRegistry(self: *Client, opcode: u16, payload: []const u8) !void {
        if (opcode != 0) return;
        if (payload.len < 12) return error.InvalidWaylandMessage;
        const name = std.mem.readInt(u32, payload[0..4], .little);
        const parsed = try parseString(payload, 4);
        if (parsed.next + 4 > payload.len) return error.InvalidWaylandMessage;
        if (std.mem.eql(u8, parsed.value, "wl_seat") and self.seat_global == 0) {
            self.seat_global = name;
        } else if (std.mem.eql(u8, parsed.value, "ext_data_control_manager_v1")) {
            self.ext_manager_global = name;
        } else if (std.mem.eql(u8, parsed.value, "zwlr_data_control_manager_v1")) {
            self.wlr_manager_global = name;
        }
    }

    fn handleDevice(self: *Client, opcode: u16, payload: []const u8) !void {
        switch (opcode) {
            0 => {
                if (payload.len != 4) return error.InvalidWaylandMessage;
                self.pending_offer_id = std.mem.readInt(u32, payload[0..4], .little);
                self.pending_mime_len = 0;
                self.pending_mime_priority = 0;
            },
            1 => try self.useSelection(payload),
            2 => return error.DataControlFinished,
            3 => try self.discardPrimarySelection(payload),
            else => {},
        }
    }

    fn handleOffer(
        self: *Client,
        object_id: u32,
        opcode: u16,
        payload: []const u8,
    ) !void {
        if (opcode != 0 or object_id != self.pending_offer_id) return;
        const parsed = try parseString(payload, 0);
        if (parsed.next != payload.len) return error.InvalidWaylandMessage;
        const priority = mimePriority(parsed.value);
        if (priority <= self.pending_mime_priority) return;
        if (parsed.value.len > self.pending_mime.len) return;
        @memcpy(self.pending_mime[0..parsed.value.len], parsed.value);
        self.pending_mime_len = parsed.value.len;
        self.pending_mime_priority = priority;
    }

    fn useSelection(self: *Client, payload: []const u8) !void {
        if (payload.len != 4) return error.InvalidWaylandMessage;
        const offer_id = std.mem.readInt(u32, payload[0..4], .little);
        if (self.current_offer_id != 0) try self.destroyOffer(self.current_offer_id);
        self.abortRead();
        self.current_offer_id = offer_id;
        if (offer_id == 0) {
            self.current_mime_len = 0;
            return;
        }
        if (offer_id != self.pending_offer_id) return error.InvalidWaylandMessage;
        self.pending_offer_id = 0;
        @memcpy(
            self.current_mime[0..self.pending_mime_len],
            self.pending_mime[0..self.pending_mime_len],
        );
        self.current_mime_len = self.pending_mime_len;
        if (self.current_mime_len > 0) self.on_selection_changed(self.userdata);
    }

    fn discardPrimarySelection(self: *Client, payload: []const u8) !void {
        if (payload.len != 4) return error.InvalidWaylandMessage;
        const offer_id = std.mem.readInt(u32, payload[0..4], .little);
        if (offer_id != 0) try self.destroyOffer(offer_id);
        if (offer_id == self.pending_offer_id) {
            self.pending_offer_id = 0;
            self.pending_mime_len = 0;
            self.pending_mime_priority = 0;
        }
    }

    fn handleSource(
        self: *Client,
        source: *Source,
        opcode: u16,
        payload: []const u8,
    ) !void {
        switch (opcode) {
            0 => {
                const parsed = try parseString(payload, 0);
                if (parsed.next != payload.len) return error.InvalidWaylandMessage;
                const fd = self.popFd() orelse return error.MissingWaylandFd;
                if (mimePriority(parsed.value) == 0) {
                    closeFd(fd);
                    return;
                }
                try self.spawnClipboardWriter(fd, source.text);
            },
            1 => {
                try self.sendRequest(source.id, 1, &.{}, null);
                self.removeSource(self.sourceEntryForId(source.id).?);
            },
            else => {},
        }
    }

    fn spawnClipboardWriter(self: *Client, fd: posix.fd_t, text: []const u8) !void {
        errdefer closeFd(fd);
        const context = try self.alloc.create(WriterContext);
        errdefer self.alloc.destroy(context);
        context.* = .{
            .alloc = self.alloc,
            .fd = fd,
            .text = try self.alloc.dupe(u8, text),
        };
        errdefer self.alloc.free(context.text);
        const thread = try std.Thread.spawn(.{}, clipboardWriter, .{context});
        thread.detach();
    }

    fn bindGlobal(
        self: *Client,
        name: u32,
        interface: []const u8,
        version: u32,
        object_id: u32,
    ) !void {
        var payload: [4 + 4 + interface_bytes_max + 8]u8 = undefined;
        var len: usize = 0;
        try appendU32(&payload, &len, name);
        try appendString(&payload, &len, interface);
        try appendU32(&payload, &len, version);
        try appendU32(&payload, &len, object_id);
        try self.sendRequest(registry_id, 0, payload[0..len], null);
    }

    fn sendStringRequest(
        self: *Client,
        object_id: u32,
        opcode: u16,
        value: []const u8,
    ) !void {
        var payload: [4 + interface_bytes_max]u8 = undefined;
        var len: usize = 0;
        try appendString(&payload, &len, value);
        try self.sendRequest(object_id, opcode, payload[0..len], null);
    }

    fn sendRequest(
        self: *Client,
        object_id: u32,
        opcode: u16,
        payload: []const u8,
        fd: ?posix.fd_t,
    ) !void {
        if (payload.len % 4 != 0) return error.InvalidWaylandMessage;
        var message: [512]u8 = undefined;
        const size = 8 + payload.len;
        if (size > message.len or size > std.math.maxInt(u16)) {
            return error.WaylandMessageTooLarge;
        }
        std.mem.writeInt(u32, message[0..4], object_id, .little);
        const size_opcode = (@as(u32, @intCast(size)) << 16) | opcode;
        std.mem.writeInt(u32, message[4..8], size_opcode, .little);
        @memcpy(message[8..size], payload);
        try sendMessage(self.socketFd(), message[0..size], fd);
    }

    fn collectFds(self: *Client, control: []const u8) !void {
        var offset: usize = 0;
        while (offset + @sizeOf(posix.system.cmsghdr) <= control.len) {
            const header: *const posix.system.cmsghdr = @ptrCast(
                @alignCast(control[offset..].ptr),
            );
            const data_offset = std.mem.alignForward(
                usize,
                @sizeOf(posix.system.cmsghdr),
                @sizeOf(usize),
            );
            const header_len: usize = @intCast(header.len);
            if (header_len < data_offset or offset + header_len > control.len) {
                return error.InvalidWaylandControlMessage;
            }
            if (header.level == posix.SOL.SOCKET and header.type == posix.SCM.RIGHTS) {
                const data = control[offset + data_offset .. offset + header_len];
                if (data.len % @sizeOf(posix.fd_t) != 0) {
                    return error.InvalidWaylandControlMessage;
                }
                var fd_offset: usize = 0;
                while (fd_offset < data.len) : (fd_offset += @sizeOf(posix.fd_t)) {
                    if (self.received_fds.items.len >= received_fds_max) {
                        return error.TooManyWaylandFds;
                    }
                    const fd = std.mem.bytesToValue(
                        posix.fd_t,
                        data[fd_offset..][0..@sizeOf(posix.fd_t)],
                    );
                    try self.received_fds.append(self.alloc, fd);
                }
            }
            offset += std.mem.alignForward(usize, header_len, @sizeOf(usize));
        }
    }

    fn destroyOffer(self: *Client, offer_id: u32) !void {
        try self.sendRequest(offer_id, 1, &.{}, null);
    }

    fn nextObjectId(self: *Client) u32 {
        const id = self.next_object_id;
        self.next_object_id +%= 1;
        if (self.next_object_id < 4) self.next_object_id = 4;
        return id;
    }

    fn popFd(self: *Client) ?posix.fd_t {
        if (self.received_fds.items.len == 0) return null;
        return self.received_fds.orderedRemove(0);
    }

    fn sourceForId(self: *Client, id: u32) ?*Source {
        const entry = self.sourceEntryForId(id) orelse return null;
        return &(entry.*.?);
    }

    fn sourceEntryForId(self: *Client, id: u32) ?*?Source {
        for (&self.sources) |*entry| {
            if (entry.*) |source| if (source.id == id) return entry;
        }
        return null;
    }

    fn emptySourceSlot(self: *Client) ?*?Source {
        for (&self.sources) |*entry| if (entry.* == null) return entry;
        return null;
    }

    fn removeSource(self: *Client, entry: *?Source) void {
        const source = entry.* orelse return;
        self.alloc.free(source.text);
        entry.* = null;
    }

    fn abortRead(self: *Client) void {
        var pending = self.pending_read orelse return;
        closeFd(pending.fd);
        pending.data.deinit(self.alloc);
        self.pending_read = null;
    }
};

const WriterContext = struct {
    alloc: Allocator,
    fd: posix.fd_t,
    text: []u8,
};

fn clipboardWriter(context: *WriterContext) void {
    defer {
        closeFd(context.fd);
        context.alloc.free(context.text);
        context.alloc.destroy(context);
    }
    var offset: usize = 0;
    while (offset < context.text.len) {
        const written = std.c.write(
            context.fd,
            context.text[offset..].ptr,
            context.text.len - offset,
        );
        if (written < 0) {
            if (std.c.errno(written) == .INTR) continue;
            return;
        }
        if (written == 0) return;
        offset += @intCast(written);
    }
}

fn displayPath(output: []u8) ![]const u8 {
    const display_ptr = std.c.getenv("WAYLAND_DISPLAY") orelse {
        return error.WaylandDisplayMissing;
    };
    const display = std.mem.span(display_ptr);
    if (std.fs.path.isAbsolute(display)) {
        if (display.len > output.len) return error.NameTooLong;
        @memcpy(output[0..display.len], display);
        return output[0..display.len];
    }
    const runtime_ptr = std.c.getenv("XDG_RUNTIME_DIR") orelse {
        return error.RuntimeDirectoryMissing;
    };
    const runtime = std.mem.span(runtime_ptr);
    return std.fmt.bufPrint(output, "{s}/{s}", .{ runtime, display });
}

fn sendMessage(fd: posix.fd_t, data: []const u8, passed_fd: ?posix.fd_t) !void {
    var iovec: posix.iovec_const = .{ .base = @constCast(data.ptr), .len = data.len };
    var control: [32]u8 align(@alignOf(posix.system.cmsghdr)) = @splat(0);
    var message: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = (&iovec)[0..1],
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    if (passed_fd) |value| {
        const data_offset = std.mem.alignForward(
            usize,
            @sizeOf(posix.system.cmsghdr),
            @sizeOf(usize),
        );
        const control_len = data_offset + @sizeOf(posix.fd_t);
        const header: *posix.system.cmsghdr = @ptrCast(@alignCast(&control));
        header.* = .{
            .len = @intCast(control_len),
            .level = posix.SOL.SOCKET,
            .type = posix.SCM.RIGHTS,
        };
        @memcpy(control[data_offset..control_len], std.mem.asBytes(&value));
        message.control = &control;
        message.controllen = @intCast(
            std.mem.alignForward(usize, control_len, @sizeOf(usize)),
        );
    }

    const sent = while (true) {
        const rc = posix.system.sendmsg(fd, &message, posix.MSG.NOSIGNAL);
        switch (posix.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            else => return error.WaylandWriteFailed,
        }
    };
    if (sent == 0) return error.WaylandWriteFailed;
    var offset: usize = @intCast(sent);
    while (offset < data.len) {
        const written = std.c.write(fd, data[offset..].ptr, data.len - offset);
        if (written < 0) {
            if (std.c.errno(written) == .INTR) continue;
            return error.WaylandWriteFailed;
        }
        if (written == 0) return error.WaylandWriteFailed;
        offset += @intCast(written);
    }
}

fn appendU32(output: []u8, len: *usize, value: u32) !void {
    if (len.* + 4 > output.len) return error.BufferTooSmall;
    std.mem.writeInt(u32, output[len.*..][0..4], value, .little);
    len.* += 4;
}

fn appendString(output: []u8, len: *usize, value: []const u8) !void {
    const string_len = std.math.add(usize, value.len, 1) catch return error.BufferTooSmall;
    const padded_len = std.mem.alignForward(usize, string_len, 4);
    try appendU32(output, len, @intCast(string_len));
    if (len.* + padded_len > output.len) return error.BufferTooSmall;
    @memcpy(output[len.*..][0..value.len], value);
    @memset(output[len.* + value.len .. len.* + padded_len], 0);
    len.* += padded_len;
}

const ParsedString = struct {
    value: []const u8,
    next: usize,
};

fn parseString(input: []const u8, offset: usize) !ParsedString {
    if (offset + 4 > input.len) return error.InvalidWaylandMessage;
    const encoded_len = std.mem.readInt(u32, input[offset..][0..4], .little);
    if (encoded_len == 0) return error.InvalidWaylandMessage;
    const padded_len = std.mem.alignForward(usize, encoded_len, 4);
    const start = offset + 4;
    if (start + padded_len > input.len) return error.InvalidWaylandMessage;
    const encoded = input[start..][0..encoded_len];
    if (encoded[encoded.len - 1] != 0) return error.InvalidWaylandMessage;
    const value = encoded[0 .. encoded.len - 1];
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidWaylandMessage;
    return .{ .value = value, .next = start + padded_len };
}

fn mimePriority(mime: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(mime, "text/plain;charset=utf-8")) return 3;
    if (std.ascii.eqlIgnoreCase(mime, "text/plain")) return 2;
    if (std.ascii.eqlIgnoreCase(mime, "UTF8_STRING")) return 1;
    return 0;
}

fn setNonBlocking(fd: posix.fd_t) void {
    const current = std.c.fcntl(fd, std.c.F.GETFL);
    if (current == -1) return;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(current)));
    flags.NONBLOCK = true;
    _ = std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags)));
}

fn closeFd(fd: posix.fd_t) void {
    _ = close(fd);
}

test "Wayland strings are padded and reject malformed input" {
    const testing = std.testing;
    var encoded: [32]u8 = undefined;
    var len: usize = 0;
    try appendString(&encoded, &len, "text/plain");
    const parsed = try parseString(encoded[0..len], 0);
    try testing.expectEqualStrings("text/plain", parsed.value);
    try testing.expectEqual(len, parsed.next);

    encoded[4 + "text/plain".len] = 'x';
    try testing.expectError(error.InvalidWaylandMessage, parseString(encoded[0..len], 0));
}

test "Wayland MIME selection prefers UTF-8 text" {
    const testing = std.testing;
    try testing.expect(mimePriority("image/png") == 0);
    try testing.expect(mimePriority("UTF8_STRING") < mimePriority("text/plain"));
    try testing.expect(mimePriority("text/plain") < mimePriority("text/plain;charset=UTF-8"));
}

test "Wayland data-control events publish a negotiated text selection" {
    const testing = std.testing;
    const State = struct {
        var changed = false;

        fn selectionChanged(_: ?*anyopaque) void {
            changed = true;
        }

        fn clipboardData(_: u64, _: []const u8, _: ?*anyopaque) void {}
    };
    State.changed = false;
    var client = Client{
        .alloc = testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .stream = undefined,
        .on_selection_changed = State.selectionChanged,
        .on_clipboard_data = State.clipboardData,
        .userdata = null,
        .device_id = 10,
    };
    defer client.input.deinit(testing.allocator);

    var object_payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &object_payload, 20, .little);
    try appendTestEvent(&client.input, testing.allocator, 10, 0, &object_payload);
    var mime_payload: [interface_bytes_max]u8 = undefined;
    var mime_len: usize = 0;
    try appendString(&mime_payload, &mime_len, "text/plain;charset=utf-8");
    try appendTestEvent(
        &client.input,
        testing.allocator,
        20,
        0,
        mime_payload[0..mime_len],
    );
    try appendTestEvent(&client.input, testing.allocator, 10, 1, &object_payload);
    try client.dispatchMessages();

    try testing.expect(State.changed);
    try testing.expectEqual(@as(u32, 20), client.current_offer_id);
    try testing.expectEqualStrings(
        "text/plain;charset=utf-8",
        client.current_mime[0..client.current_mime_len],
    );
}

fn appendTestEvent(
    input: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
    object_id: u32,
    opcode: u16,
    payload: []const u8,
) !void {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], object_id, .little);
    const size_opcode = (@as(u32, @intCast(header.len + payload.len)) << 16) | opcode;
    std.mem.writeInt(u32, header[4..8], size_opcode, .little);
    try input.appendSlice(alloc, &header);
    try input.appendSlice(alloc, payload);
}
