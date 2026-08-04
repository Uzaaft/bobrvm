//! spice-vdagent host-side clipboard channel.
//!
//! Speaks the vdagent protocol (spice-protocol vd_agent.h) over a
//! virtio-console multiport port named "com.redhat.spice.0", directly to
//! the stock spice-vdagent daemon in the guest — no SPICE server
//! involved. Wire format: VDIChunkHeader{port,size} frames carrying a
//! byte stream of VDAgentMessage{protocol,type,opaque,size}+payload
//! (messages may span chunks; chunk payloads are capped at 2048 bytes).
//!
//! Clipboard model (by-demand, no selections — we don't announce the
//! SELECTION capability, so messages carry no selection prefix):
//!   guest copy:  guest GRAB -> we REQUEST(UTF8) -> guest CLIPBOARD data
//!                -> on_guest_clipboard callback (host sets pasteboard).
//!   host copy:   hostClipboardGrab() -> we GRAB -> guest REQUEST ->
//!                request_host_clipboard callback -> owner calls
//!                sendClipboard(text).
//!
//! Transport-agnostic like qga: send fn out, feed() in (vCPU thread).

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.vdagent);

pub const SendFn = *const fn (data: []const u8, userdata: ?*anyopaque) void;

/// VDIChunkHeader routing port (client-originated traffic).
const VDP_CLIENT_PORT: u32 = 1;

/// Max chunk payload (VD_AGENT_MAX_DATA_SIZE).
const CHUNK_MAX: usize = 2048;

pub const MsgType = enum(u32) {
    mouse_state = 1,
    monitors_config = 2,
    reply = 3,
    clipboard = 4,
    display_config = 5,
    announce_capabilities = 6,
    clipboard_grab = 7,
    clipboard_request = 8,
    clipboard_release = 9,
    _,
};

/// Capability bits (VD_AGENT_CAP_*).
pub const CAP_CLIPBOARD_BY_DEMAND: u5 = 5;

/// Clipboard data types.
pub const CLIP_UTF8_TEXT: u32 = 1;

/// VDAgentMessage header (20 bytes, packed little-endian on the wire).
const MSG_HDR = 20;
const PROTOCOL: u32 = 1;

pub const Vdagent = struct {
    alloc: Allocator,
    send_fn: SendFn,
    send_userdata: ?*anyopaque,

    /// Raw inbound byte stream (chunk headers + payloads, reassembled).
    in_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Chunk payloads concatenated = the VDAgentMessage stream.
    msg_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// Guest agent announced its capabilities (channel is live).
    guest_caps_seen: bool = false,
    /// Guest currently owns the clipboard (sent a GRAB with UTF8).
    guest_owns_clipboard: bool = false,

    /// Guest copied text; host should set its pasteboard.
    on_guest_clipboard: ?*const fn (text: []const u8, userdata: ?*anyopaque) void = null,
    on_guest_clipboard_userdata: ?*anyopaque = null,
    /// Guest wants the host clipboard; owner responds with sendClipboard().
    request_host_clipboard: ?*const fn (userdata: ?*anyopaque) void = null,
    request_host_clipboard_userdata: ?*anyopaque = null,

    pub const BUF_MAX: usize = 4 * 1024 * 1024;

    pub fn init(alloc: Allocator, send_fn: SendFn, userdata: ?*anyopaque) Vdagent {
        return .{ .alloc = alloc, .send_fn = send_fn, .send_userdata = userdata };
    }

    pub fn deinit(self: *Vdagent) void {
        self.in_buf.deinit(self.alloc);
        self.msg_buf.deinit(self.alloc);
    }

    /// Frame and send one VDAgentMessage, split into <=2048-byte chunks.
    fn sendMsg(self: *Vdagent, msg_type: MsgType, payload: []const u8) void {
        self.sendMsgParts(msg_type, &.{payload});
    }

    fn sendMsgParts(self: *Vdagent, msg_type: MsgType, payload_parts: []const []const u8) void {
        std.debug.assert(payload_parts.len > 0);
        std.debug.assert(CHUNK_MAX <= std.math.maxInt(u32));
        var payload_len: usize = 0;
        for (payload_parts) |part| {
            payload_len = std.math.add(usize, payload_len, part.len) catch return;
        }
        if (payload_len > std.math.maxInt(u32)) return;

        var hdr: [MSG_HDR]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], PROTOCOL, .little);
        std.mem.writeInt(u32, hdr[4..8], @intFromEnum(msg_type), .little);
        std.mem.writeInt(u64, hdr[8..16], 0, .little); // opaque
        std.mem.writeInt(u32, hdr[16..20], @intCast(payload_len), .little);

        var chunk: [8 + CHUNK_MAX]u8 = undefined;
        var remaining_hdr: []const u8 = &hdr;
        var part_index: usize = 0;
        var part_offset: usize = 0;
        var remaining = MSG_HDR + payload_len;
        while (remaining > 0) {
            const chunk_len = @min(remaining, CHUNK_MAX);
            std.mem.writeInt(u32, chunk[0..4], VDP_CLIENT_PORT, .little);
            std.mem.writeInt(u32, chunk[4..8], @intCast(chunk_len), .little);
            var copied: usize = 0;
            if (remaining_hdr.len > 0) {
                const n = @min(remaining_hdr.len, chunk_len);
                @memcpy(chunk[8..][0..n], remaining_hdr[0..n]);
                remaining_hdr = remaining_hdr[n..];
                copied += n;
            }
            while (copied < chunk_len) {
                const part = payload_parts[part_index][part_offset..];
                const n = @min(part.len, chunk_len - copied);
                @memcpy(chunk[8 + copied ..][0..n], part[0..n]);
                copied += n;
                part_offset += n;
                if (part_offset == payload_parts[part_index].len) {
                    part_index += 1;
                    part_offset = 0;
                }
            }
            std.debug.assert(copied == chunk_len);
            self.send_fn(chunk[0 .. 8 + chunk_len], self.send_userdata);
            remaining -= chunk_len;
        }
    }

    fn sendCaps(self: *Vdagent) void {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], 0, .little); // request = 0
        std.mem.writeInt(u32, payload[4..8], 1 << CAP_CLIPBOARD_BY_DEMAND, .little);
        self.sendMsg(.announce_capabilities, &payload);
    }

    /// Announce that the HOST clipboard changed; the guest requests the
    /// data when it wants to paste.
    pub fn hostClipboardGrab(self: *Vdagent) void {
        if (!self.guest_caps_seen) return;
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], CLIP_UTF8_TEXT, .little);
        self.sendMsg(.clipboard_grab, &payload);
    }

    /// Deliver host clipboard text (answers the guest's REQUEST).
    pub fn sendClipboard(self: *Vdagent, text: []const u8) void {
        var data_type: [4]u8 = undefined;
        std.mem.writeInt(u32, &data_type, CLIP_UTF8_TEXT, .little);
        self.sendMsgParts(.clipboard, &.{ &data_type, text });
    }

    /// Feed guest→host port bytes (vCPU thread).
    pub fn feed(self: *Vdagent, data: []const u8) void {
        if (self.in_buf.items.len == 0 and self.msg_buf.items.len == 0) {
            if (self.handleCompleteChunk(data)) return;
        }
        if (self.in_buf.items.len + data.len > BUF_MAX) {
            // Hostile/corrupt stream: reset framing.
            self.in_buf.clearRetainingCapacity();
            self.msg_buf.clearRetainingCapacity();
            return;
        }
        self.in_buf.appendSlice(self.alloc, data) catch return;

        // Peel complete chunks into the message stream.
        while (self.in_buf.items.len >= 8) {
            const size = std.mem.readInt(u32, self.in_buf.items[4..8], .little);
            if (size > BUF_MAX) {
                self.in_buf.clearRetainingCapacity();
                self.msg_buf.clearRetainingCapacity();
                return;
            }
            if (self.in_buf.items.len < 8 + size) break;
            self.msg_buf.appendSlice(self.alloc, self.in_buf.items[8 .. 8 + size]) catch return;
            self.in_buf.replaceRangeAssumeCapacity(0, 8 + size, &.{});
        }

        // Peel complete messages.
        while (self.msg_buf.items.len >= MSG_HDR) {
            const size = std.mem.readInt(u32, self.msg_buf.items[16..20], .little);
            if (size > BUF_MAX) {
                self.msg_buf.clearRetainingCapacity();
                return;
            }
            if (self.msg_buf.items.len < MSG_HDR + size) break;
            const msg_type = std.mem.readInt(u32, self.msg_buf.items[4..8], .little);
            self.handleMsg(@enumFromInt(msg_type), self.msg_buf.items[MSG_HDR..][0..size]);
            self.msg_buf.replaceRangeAssumeCapacity(0, MSG_HDR + size, &.{});
        }
    }

    fn handleCompleteChunk(self: *Vdagent, data: []const u8) bool {
        std.debug.assert(self.in_buf.items.len == 0);
        std.debug.assert(self.msg_buf.items.len == 0);
        if (data.len < 8 + MSG_HDR) return false;
        const chunk_size = std.mem.readInt(u32, data[4..8], .little);
        if (chunk_size > BUF_MAX or data.len != 8 + chunk_size) return false;
        const message = data[8..];
        const payload_size = std.mem.readInt(u32, message[16..20], .little);
        if (payload_size > BUF_MAX or message.len != MSG_HDR + payload_size) return false;
        const msg_type = std.mem.readInt(u32, message[4..8], .little);
        self.handleMsg(@enumFromInt(msg_type), message[MSG_HDR..]);
        return true;
    }

    fn handleMsg(self: *Vdagent, msg_type: MsgType, payload: []const u8) void {
        switch (msg_type) {
            .announce_capabilities => {
                if (payload.len < 4) return;
                const request = std.mem.readInt(u32, payload[0..4], .little);
                self.guest_caps_seen = true;
                log.info("guest vdagent connected (caps request={})", .{request});
                if (request != 0) self.sendCaps();
            },
            .clipboard_grab => {
                // Guest copied something; request UTF8 if offered.
                var off: usize = 0;
                while (off + 4 <= payload.len) : (off += 4) {
                    if (std.mem.readInt(u32, payload[off..][0..4], .little) == CLIP_UTF8_TEXT) {
                        self.guest_owns_clipboard = true;
                        var req: [4]u8 = undefined;
                        std.mem.writeInt(u32, req[0..4], CLIP_UTF8_TEXT, .little);
                        self.sendMsg(.clipboard_request, &req);
                        return;
                    }
                }
            },
            .clipboard => {
                if (payload.len < 4) return;
                const kind = std.mem.readInt(u32, payload[0..4], .little);
                if (kind != CLIP_UTF8_TEXT) return;
                log.info("guest clipboard: {} bytes", .{payload.len - 4});
                if (self.on_guest_clipboard) |cb| {
                    cb(payload[4..], self.on_guest_clipboard_userdata);
                }
            },
            .clipboard_request => {
                if (payload.len < 4) return;
                const kind = std.mem.readInt(u32, payload[0..4], .little);
                if (kind != CLIP_UTF8_TEXT) return;
                if (self.request_host_clipboard) |cb| {
                    cb(self.request_host_clipboard_userdata);
                }
            },
            .clipboard_release => self.guest_owns_clipboard = false,
            else => {},
        }
    }
};

const testing = std.testing;

var test_sent: std.ArrayListUnmanaged(u8) = .empty;
var test_send_calls: usize = 0;
fn testSend(data: []const u8, _: ?*anyopaque) void {
    test_send_calls += 1;
    test_sent.appendSlice(testing.allocator, data) catch {};
}

fn clearSent() void {
    test_sent.deinit(testing.allocator);
    test_sent = .empty;
    test_send_calls = 0;
}

/// Build a chunked guest message for feeding.
fn guestMsg(alloc: Allocator, msg_type: MsgType, payload: []const u8) ![]u8 {
    const total = 8 + MSG_HDR + payload.len;
    const buf = try alloc.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], VDP_CLIENT_PORT, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(MSG_HDR + payload.len), .little);
    std.mem.writeInt(u32, buf[8..12], PROTOCOL, .little);
    std.mem.writeInt(u32, buf[12..16], @intFromEnum(msg_type), .little);
    std.mem.writeInt(u64, buf[16..24], 0, .little);
    std.mem.writeInt(u32, buf[24..28], @intCast(payload.len), .little);
    @memcpy(buf[28..], payload);
    return buf;
}

/// Parse the first sent message (skipping chunk headers) for asserts.
fn firstSentMsg() struct { msg_type: u32, payload: []const u8 } {
    // Single-chunk assumption for test-sized messages.
    const s = test_sent.items;
    const msg_type = std.mem.readInt(u32, s[12..16], .little);
    const size = std.mem.readInt(u32, s[24..28], .little);
    return .{ .msg_type = msg_type, .payload = s[28 .. 28 + size] };
}

var test_guest_clip: std.ArrayListUnmanaged(u8) = .empty;
fn testGuestClip(text: []const u8, _: ?*anyopaque) void {
    test_guest_clip.appendSlice(testing.allocator, text) catch {};
}

var test_host_requested: bool = false;
fn testHostReq(_: ?*anyopaque) void {
    test_host_requested = true;
}

test "vdagent: caps handshake replies with by-demand clipboard" {
    defer clearSent();
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    var vd = Vdagent.init(counted.allocator(), testSend, null);
    defer vd.deinit();

    var caps_payload: [8]u8 = undefined;
    std.mem.writeInt(u32, caps_payload[0..4], 1, .little); // request=1
    std.mem.writeInt(u32, caps_payload[4..8], 0xFFFF, .little);
    const msg = try guestMsg(testing.allocator, .announce_capabilities, &caps_payload);
    defer testing.allocator.free(msg);
    vd.feed(msg);

    try testing.expectEqual(@as(usize, 0), counted.allocations);
    try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);
    try testing.expectEqual(@as(usize, 0), vd.in_buf.capacity);
    try testing.expectEqual(@as(usize, 0), vd.msg_buf.capacity);
    try testing.expect(vd.guest_caps_seen);
    const reply = firstSentMsg();
    try testing.expectEqual(@intFromEnum(MsgType.announce_capabilities), reply.msg_type);
    const caps = std.mem.readInt(u32, reply.payload[4..8], .little);
    try testing.expect(caps & (1 << CAP_CLIPBOARD_BY_DEMAND) != 0);
}

test "vdagent: guest grab triggers request; clipboard data reaches callback" {
    defer clearSent();
    defer {
        test_guest_clip.deinit(testing.allocator);
        test_guest_clip = .empty;
    }
    var vd = Vdagent.init(testing.allocator, testSend, null);
    defer vd.deinit();
    vd.on_guest_clipboard = testGuestClip;

    // GRAB offering [png, utf8] → we must REQUEST utf8.
    var grab: [8]u8 = undefined;
    std.mem.writeInt(u32, grab[0..4], 2, .little); // IMAGE_PNG
    std.mem.writeInt(u32, grab[4..8], CLIP_UTF8_TEXT, .little);
    const grab_msg = try guestMsg(testing.allocator, .clipboard_grab, &grab);
    defer testing.allocator.free(grab_msg);
    vd.feed(grab_msg);

    try testing.expect(vd.guest_owns_clipboard);
    const req = firstSentMsg();
    try testing.expectEqual(@intFromEnum(MsgType.clipboard_request), req.msg_type);
    try testing.expectEqual(CLIP_UTF8_TEXT, std.mem.readInt(u32, req.payload[0..4], .little));

    // Guest answers with the data — split across two feeds mid-message.
    var clip_payload: [4 + 5]u8 = undefined;
    std.mem.writeInt(u32, clip_payload[0..4], CLIP_UTF8_TEXT, .little);
    @memcpy(clip_payload[4..], "hello");
    const clip_msg = try guestMsg(testing.allocator, .clipboard, &clip_payload);
    defer testing.allocator.free(clip_msg);
    vd.feed(clip_msg[0..10]);
    try testing.expectEqualStrings("", test_guest_clip.items);
    vd.feed(clip_msg[10..]);
    try testing.expectEqualStrings("hello", test_guest_clip.items);
}

test "vdagent: host grab + guest request + data delivery" {
    defer clearSent();
    var vd = Vdagent.init(testing.allocator, testSend, null);
    defer vd.deinit();
    vd.request_host_clipboard = testHostReq;
    test_host_requested = false;

    // Channel not live yet: grab is a no-op.
    vd.hostClipboardGrab();
    try testing.expectEqual(@as(usize, 0), test_sent.items.len);

    vd.guest_caps_seen = true;
    vd.hostClipboardGrab();
    const grab = firstSentMsg();
    try testing.expectEqual(@intFromEnum(MsgType.clipboard_grab), grab.msg_type);

    // Guest requests; owner responds with sendClipboard.
    clearSent();
    var req: [4]u8 = undefined;
    std.mem.writeInt(u32, req[0..4], CLIP_UTF8_TEXT, .little);
    const req_msg = try guestMsg(testing.allocator, .clipboard_request, &req);
    defer testing.allocator.free(req_msg);
    vd.feed(req_msg);
    try testing.expect(test_host_requested);

    vd.sendClipboard("mac text");
    const clip = firstSentMsg();
    try testing.expectEqual(@intFromEnum(MsgType.clipboard), clip.msg_type);
    try testing.expectEqual(CLIP_UTF8_TEXT, std.mem.readInt(u32, clip.payload[0..4], .little));
    try testing.expectEqualStrings("mac text", clip.payload[4..]);
}

test "vdagent: large message splits into 2048-byte chunks" {
    defer clearSent();
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    var vd = Vdagent.init(counted.allocator(), testSend, null);
    defer vd.deinit();

    const big = try testing.allocator.alloc(u8, 5000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    vd.sendClipboard(big);

    // Walk the chunk stream: every chunk <= 2048, payload total = 20+4+5000.
    var off: usize = 0;
    var payload_total: usize = 0;
    var chunks: usize = 0;
    while (off < test_sent.items.len) {
        const size = std.mem.readInt(u32, test_sent.items[off + 4 ..][0..4], .little);
        try testing.expect(size <= CHUNK_MAX);
        payload_total += size;
        off += 8 + size;
        chunks += 1;
    }
    try testing.expectEqual(@as(usize, MSG_HDR + 4 + 5000), payload_total);
    try testing.expect(chunks >= 3);
    try testing.expectEqual(@as(usize, 0), counted.allocations);
    try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 3), test_send_calls);
}
