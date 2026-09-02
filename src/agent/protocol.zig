//! Versioned framing shared by bobrvm host and Linux guest tools.

const std = @import("std");
const Allocator = std.mem.Allocator;
const authentication = @import("../auth/main.zig");

pub const protocol_version: u16 = 1;
pub const payload_bytes_max: u32 = 32 * 1024 * 1024;
pub const clipboard_text_bytes_max: u32 = 48 * 1024;
pub const authentication_principal_bytes_max = authentication.principal_bytes_max;

pub const Header = struct {
    pub const magic: u32 = 0x4252_564d;
    pub const bytes: usize = 24;
};

pub const MessageKind = enum(u16) {
    hello = 1,
    hello_ack = 2,
    heartbeat = 3,
    status = 4,
    clipboard_offer = 16,
    clipboard_request = 17,
    clipboard_data = 18,
    clipboard_clear = 19,
    file_offer = 32,
    file_accept = 33,
    file_reject = 34,
    file_chunk = 35,
    file_complete = 36,
    file_cancel = 37,
    authentication_request = 48,
    authentication_cancel = 49,
    authentication_result = 50,
    _,
};

pub const Frame = struct {
    kind: MessageKind,
    flags: u16 = 0,
    request_id: u64,
    payload: []const u8,
};

pub const CodecError = Allocator.Error || error{
    BufferTooSmall,
    FileChunkTooLarge,
    FileTooLarge,
    InvalidClipboardText,
    InvalidMagic,
    InvalidFileName,
    UnsupportedVersion,
    UnsupportedFlags,
    PayloadTooLarge,
} || authentication.CodecError;

pub const Capability = struct {
    pub const clipboard: u64 = 1 << 0;
    pub const file_transfer: u64 = 1 << 1;
    pub const host_authentication: u64 = 1 << 2;
    pub const authentication_bind: u64 = AuthenticationCapability.bind << 3;
    pub const authentication_authenticate: u64 = AuthenticationCapability.authenticate << 3;
    pub const authentication_match_on_device: u64 =
        AuthenticationCapability.match_on_device << 3;
    pub const authentication_cancellation: u64 = AuthenticationCapability.cancellation << 3;
    pub const authentication_fingerprint: u64 = AuthenticationCapability.fingerprint << 3;
    pub const authentication_v1: u64 = host_authentication |
        authentication_bind |
        authentication_authenticate |
        authentication_match_on_device |
        authentication_cancellation |
        authentication_fingerprint;
};

pub const AuthenticationCapability = authentication.Capability;
pub const AuthenticationOperation = authentication.Operation;
pub const AuthenticationResult = authentication.Result;
pub const AuthenticationRequest = authentication.Request;
pub const AuthenticationResponse = authentication.Response;
pub const AuthenticationFrontendSession = authentication.FrontendSession;

pub fn authenticationCapabilities(capabilities: u64) u64 {
    if (capabilities & Capability.host_authentication == 0) return 0;
    return (capabilities >> 3) & 0x1f;
}

test "authentication capabilities retain the negotiated feature set" {
    const testing = std.testing;
    const features = authenticationCapabilities(Capability.authentication_v1);
    try testing.expect(features & AuthenticationCapability.bind != 0);
    try testing.expect(features & AuthenticationCapability.authenticate != 0);
    try testing.expect(features & AuthenticationCapability.match_on_device != 0);
    try testing.expect(features & AuthenticationCapability.cancellation != 0);
    try testing.expect(features & AuthenticationCapability.fingerprint != 0);
}

test "authentication wire identifiers remain backward compatible" {
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 48), @intFromEnum(MessageKind.authentication_request));
    try testing.expectEqual(@as(u16, 49), @intFromEnum(MessageKind.authentication_cancel));
    try testing.expectEqual(@as(u16, 50), @intFromEnum(MessageKind.authentication_result));
    try testing.expectEqual(@as(u64, 1 << 2), Capability.host_authentication);
}

pub const Clipboard = struct {
    pub fn decode(payload: []const u8) CodecError![]const u8 {
        if (payload.len > clipboard_text_bytes_max) return error.PayloadTooLarge;
        if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidClipboardText;
        return payload;
    }
};

pub const FileOffer = struct {
    pub const header_bytes: usize = 10;
    pub const name_bytes_max: usize = 255;
    pub const size_bytes_max: u64 = 16 * 1024 * 1024 * 1024;

    size: u64,
    name: []const u8,

    pub fn encode(output: []u8, size: u64, name: []const u8) CodecError![]u8 {
        if (size > size_bytes_max) return error.FileTooLarge;
        try validateFileName(name);
        const encoded_len = header_bytes + name.len;
        if (output.len < encoded_len) return error.BufferTooSmall;
        std.mem.writeInt(u64, output[0..8], size, .little);
        std.mem.writeInt(u16, output[8..10], @intCast(name.len), .little);
        @memcpy(output[header_bytes..encoded_len], name);
        return output[0..encoded_len];
    }

    pub fn decode(payload: []const u8) CodecError!FileOffer {
        if (payload.len < header_bytes) return error.BufferTooSmall;
        const size = std.mem.readInt(u64, payload[0..8], .little);
        const name_len = std.mem.readInt(u16, payload[8..10], .little);
        if (size > size_bytes_max) return error.FileTooLarge;
        if (payload.len != header_bytes + @as(usize, name_len)) {
            return error.InvalidFileName;
        }
        const name = payload[header_bytes..];
        try validateFileName(name);
        return .{ .size = size, .name = name };
    }

    fn validateFileName(name: []const u8) CodecError!void {
        if (name.len == 0 or name.len > name_bytes_max) return error.InvalidFileName;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return error.InvalidFileName;
        }
        for (name) |byte| {
            if (byte < ' ' or byte == '/' or byte == '\\') return error.InvalidFileName;
        }
    }
};

pub const FileChunk = struct {
    pub const header_bytes: usize = 8;
    pub const data_bytes_max: usize = 48 * 1024;

    offset: u64,
    data: []const u8,

    pub fn encode(output: []u8, offset: u64, data: []const u8) CodecError![]u8 {
        if (data.len > data_bytes_max) return error.FileChunkTooLarge;
        const encoded_len = header_bytes + data.len;
        if (output.len < encoded_len) return error.BufferTooSmall;
        std.mem.writeInt(u64, output[0..8], offset, .little);
        @memcpy(output[header_bytes..encoded_len], data);
        return output[0..encoded_len];
    }

    pub fn decode(payload: []const u8) CodecError!FileChunk {
        if (payload.len < header_bytes) return error.BufferTooSmall;
        const data = payload[header_bytes..];
        if (data.len > data_bytes_max) return error.FileChunkTooLarge;
        return .{
            .offset = std.mem.readInt(u64, payload[0..8], .little),
            .data = data,
        };
    }
};

pub fn encode(output: []u8, frame: Frame) CodecError![]u8 {
    if (frame.payload.len > payload_bytes_max) return error.PayloadTooLarge;
    const encoded_len = Header.bytes + frame.payload.len;
    if (output.len < encoded_len) return error.BufferTooSmall;

    _ = try encodeHeader(output[0..Header.bytes], frame, @intCast(frame.payload.len));
    @memcpy(output[Header.bytes..encoded_len], frame.payload);
    return output[0..encoded_len];
}

pub fn encodeHeader(
    output: []u8,
    frame: Frame,
    payload_len: u32,
) CodecError![]u8 {
    if (payload_len > payload_bytes_max) return error.PayloadTooLarge;
    if (output.len < Header.bytes) return error.BufferTooSmall;
    std.mem.writeInt(u32, output[0..4], Header.magic, .little);
    std.mem.writeInt(u16, output[4..6], protocol_version, .little);
    std.mem.writeInt(u16, output[6..8], @intFromEnum(frame.kind), .little);
    std.mem.writeInt(u16, output[8..10], frame.flags, .little);
    std.mem.writeInt(u16, output[10..12], 0, .little);
    std.mem.writeInt(u64, output[12..20], frame.request_id, .little);
    std.mem.writeInt(u32, output[20..24], payload_len, .little);
    return output[0..Header.bytes];
}

pub const Decoder = struct {
    alloc: Allocator,
    input: std.ArrayListUnmanaged(u8) = .empty,
    decoded_payload: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(alloc: Allocator) Decoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Decoder) void {
        self.input.deinit(self.alloc);
        self.decoded_payload.deinit(self.alloc);
    }

    /// Returned payload storage is owned by the decoder and remains valid
    /// until the next call to `feed` or `deinit`.
    pub fn feed(self: *Decoder, data: []const u8) CodecError!?Frame {
        self.decoded_payload.clearRetainingCapacity();
        const buffered_len = std.math.add(usize, self.input.items.len, data.len) catch {
            self.input.clearRetainingCapacity();
            return error.PayloadTooLarge;
        };
        if (buffered_len > Header.bytes + payload_bytes_max) {
            self.input.clearRetainingCapacity();
            return error.PayloadTooLarge;
        }
        try self.input.appendSlice(self.alloc, data);
        if (self.input.items.len < Header.bytes) return null;

        const header = self.input.items[0..Header.bytes];
        try validateHeader(self, header);
        const payload_len = std.mem.readInt(u32, header[20..24], .little);
        if (payload_len > payload_bytes_max) {
            self.input.clearRetainingCapacity();
            return error.PayloadTooLarge;
        }
        const frame_len = Header.bytes + @as(usize, payload_len);
        if (self.input.items.len < frame_len) return null;

        try self.decoded_payload.appendSlice(
            self.alloc,
            self.input.items[Header.bytes..frame_len],
        );
        const frame = Frame{
            .kind = @enumFromInt(std.mem.readInt(u16, header[6..8], .little)),
            .flags = std.mem.readInt(u16, header[8..10], .little),
            .request_id = std.mem.readInt(u64, header[12..20], .little),
            .payload = self.decoded_payload.items,
        };
        self.input.replaceRangeAssumeCapacity(0, frame_len, &.{});
        return frame;
    }

    fn validateHeader(self: *Decoder, header: []const u8) CodecError!void {
        if (std.mem.readInt(u32, header[0..4], .little) != Header.magic) {
            self.input.clearRetainingCapacity();
            return error.InvalidMagic;
        }
        if (std.mem.readInt(u16, header[4..6], .little) != protocol_version) {
            self.input.clearRetainingCapacity();
            return error.UnsupportedVersion;
        }
        if (std.mem.readInt(u16, header[8..10], .little) != 0 or
            std.mem.readInt(u16, header[10..12], .little) != 0)
        {
            self.input.clearRetainingCapacity();
            return error.UnsupportedFlags;
        }
    }
};

test "file offer codec accepts basenames and rejects traversal" {
    const testing = std.testing;
    var encoded: [FileOffer.header_bytes + 8]u8 = undefined;
    const bytes = try FileOffer.encode(&encoded, 4096, "disk.raw");
    const offer = try FileOffer.decode(bytes);

    try testing.expectEqual(@as(u64, 4096), offer.size);
    try testing.expectEqualStrings("disk.raw", offer.name);
    try testing.expectError(error.InvalidFileName, FileOffer.encode(&encoded, 1, "../x.raw"));
}

test "file chunk codec preserves offset and bounds chunk size" {
    const testing = std.testing;
    var encoded: [FileChunk.header_bytes + 4]u8 = undefined;
    const bytes = try FileChunk.encode(&encoded, 512, "data");
    const chunk = try FileChunk.decode(bytes);

    try testing.expectEqual(@as(u64, 512), chunk.offset);
    try testing.expectEqualStrings("data", chunk.data);
    var oversized: [FileChunk.data_bytes_max + 1]u8 = undefined;
    try testing.expectError(error.FileChunkTooLarge, FileChunk.encode(
        &encoded,
        0,
        &oversized,
    ));
}

test "clipboard codec accepts bounded UTF-8 text" {
    const testing = std.testing;
    try testing.expectEqualStrings("hei ø", try Clipboard.decode("hei ø"));
    try testing.expectError(error.InvalidClipboardText, Clipboard.decode("\xff"));

    var oversized: [clipboard_text_bytes_max + 1]u8 = undefined;
    try testing.expectError(error.PayloadTooLarge, Clipboard.decode(&oversized));
}
