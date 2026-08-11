//! Bounded manager-to-VMM packet protocol.
//!
//! Each Unix `SOCK_SEQPACKET` record contains one header and body. File
//! descriptors are passed with `SCM_RIGHTS`; every kind has a fixed descriptor
//! count so malformed control messages are rejected before dispatch.

const std = @import("std");

pub const magic = [4]u8{ 'B', 'R', 'V', 'M' };
pub const version: u16 = 1;
pub const header_bytes: usize = 20;
pub const packet_bytes_max: usize = 64 * 1024;
pub const body_bytes_max: usize = packet_bytes_max - header_bytes;

pub const MessageKind = enum(u16) {
    command_start = 1,
    command_stop = 2,
    command_pause = 3,
    command_resume = 4,
    command_resize = 5,
    command_input = 6,
    command_clipboard = 7,

    event_state = 0x100,
    event_console = 0x101,
    event_frame = 0x102,
    event_metrics = 0x103,
    event_failure = 0x104,

    pub fn fdCount(self: MessageKind) u8 {
        return switch (self) {
            .event_frame => 1,
            else => 0,
        };
    }
};

pub const Header = struct {
    kind: MessageKind,
    body_bytes: u32,
    request_id: u64,
};

pub const Packet = struct {
    header: Header,
    body: []const u8,
};

pub const DecodeError = error{
    Truncated,
    InvalidMagic,
    UnsupportedVersion,
    UnknownKind,
    BodyTooLarge,
    LengthMismatch,
    InvalidFdCount,
};

pub fn encodeHeader(destination: []u8, header: Header) error{BufferTooSmall}!void {
    if (destination.len < header_bytes) return error.BufferTooSmall;
    @memcpy(destination[0..4], &magic);
    std.mem.writeInt(u16, destination[4..6], version, .little);
    std.mem.writeInt(u16, destination[6..8], @intFromEnum(header.kind), .little);
    std.mem.writeInt(u32, destination[8..12], header.body_bytes, .little);
    std.mem.writeInt(u64, destination[12..20], header.request_id, .little);
}

pub fn decode(bytes: []const u8, received_fd_count: u8) DecodeError!Packet {
    if (bytes.len < header_bytes) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidMagic;

    const packet_version = std.mem.readInt(u16, bytes[4..6], .little);
    if (packet_version != version) return error.UnsupportedVersion;

    const kind_value = std.mem.readInt(u16, bytes[6..8], .little);
    const kind: MessageKind = switch (kind_value) {
        @intFromEnum(MessageKind.command_start) => .command_start,
        @intFromEnum(MessageKind.command_stop) => .command_stop,
        @intFromEnum(MessageKind.command_pause) => .command_pause,
        @intFromEnum(MessageKind.command_resume) => .command_resume,
        @intFromEnum(MessageKind.command_resize) => .command_resize,
        @intFromEnum(MessageKind.command_input) => .command_input,
        @intFromEnum(MessageKind.command_clipboard) => .command_clipboard,
        @intFromEnum(MessageKind.event_state) => .event_state,
        @intFromEnum(MessageKind.event_console) => .event_console,
        @intFromEnum(MessageKind.event_frame) => .event_frame,
        @intFromEnum(MessageKind.event_metrics) => .event_metrics,
        @intFromEnum(MessageKind.event_failure) => .event_failure,
        else => return error.UnknownKind,
    };
    const body_bytes = std.mem.readInt(u32, bytes[8..12], .little);
    if (body_bytes > body_bytes_max) return error.BodyTooLarge;
    if (bytes.len != header_bytes + @as(usize, body_bytes)) return error.LengthMismatch;
    if (received_fd_count != kind.fdCount()) return error.InvalidFdCount;

    return .{
        .header = .{
            .kind = kind,
            .body_bytes = body_bytes,
            .request_id = std.mem.readInt(u64, bytes[12..20], .little),
        },
        .body = bytes[header_bytes..],
    };
}

pub const VmState = enum(u8) {
    created,
    starting,
    running,
    paused,
    stopping,
    stopped,
    failed,
};

pub const Resize = extern struct {
    width: u32,
    height: u32,
    scale_milli: u32,
};

pub const Metrics = extern struct {
    monotonic_time_ns: u64,
    exits_total: u64,
    io_exits_total: u64,
    mmio_exits_total: u64,
    boot_time_ns: u64,
};

test "worker header round trips with a bounded body" {
    var bytes: [header_bytes + 4]u8 = undefined;
    try encodeHeader(&bytes, .{
        .kind = .command_resize,
        .body_bytes = 4,
        .request_id = 42,
    });
    const body = [4]u8{ 1, 2, 3, 4 };
    @memcpy(bytes[header_bytes..], &body);

    const packet = try decode(&bytes, 0);
    try std.testing.expectEqual(MessageKind.command_resize, packet.header.kind);
    try std.testing.expectEqual(@as(u64, 42), packet.header.request_id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, packet.body);
}

test "worker packets reject malformed lengths and magic" {
    var bytes: [header_bytes]u8 = undefined;
    try encodeHeader(&bytes, .{
        .kind = .command_stop,
        .body_bytes = 1,
        .request_id = 7,
    });
    try std.testing.expectError(error.LengthMismatch, decode(&bytes, 0));

    bytes[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decode(&bytes, 0));
}

test "worker frame events require exactly one file descriptor" {
    var bytes: [header_bytes]u8 = undefined;
    try encodeHeader(&bytes, .{
        .kind = .event_frame,
        .body_bytes = 0,
        .request_id = 9,
    });
    try std.testing.expectError(error.InvalidFdCount, decode(&bytes, 0));
    _ = try decode(&bytes, 1);
    try std.testing.expectError(error.InvalidFdCount, decode(&bytes, 2));
}
