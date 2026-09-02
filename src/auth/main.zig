//! Host-backed authentication shared across platform adapters.

const std = @import("std");

pub const principal_bytes_max: usize = 64;

pub const Capability = struct {
    pub const bind: u64 = 1 << 0;
    pub const authenticate: u64 = 1 << 1;
    pub const match_on_device: u64 = 1 << 2;
    pub const cancellation: u64 = 1 << 3;
    pub const fingerprint: u64 = 1 << 4;
};

pub const Operation = enum(u8) {
    bind = 1,
    authenticate = 2,
};

pub const Result = enum(u8) {
    success = 1,
    no_match = 2,
    cancelled = 3,
    unavailable = 4,
    locked = 5,
    failed = 6,
};

pub const CodecError = error{
    BufferTooSmall,
    InvalidAuthenticationRequest,
    InvalidAuthenticationResult,
};

pub const Request = struct {
    operation: Operation,
    principal: []const u8,

    pub const header_bytes: usize = 2;

    pub fn encode(output: []u8, request: Request) CodecError![]u8 {
        if (!validPrincipal(request.principal)) return error.InvalidAuthenticationRequest;
        const encoded_len = header_bytes + request.principal.len;
        if (output.len < encoded_len) return error.BufferTooSmall;
        output[0] = @intFromEnum(request.operation);
        output[1] = @intCast(request.principal.len);
        @memcpy(output[header_bytes..encoded_len], request.principal);
        return output[0..encoded_len];
    }

    pub fn decode(payload: []const u8) CodecError!Request {
        if (payload.len < header_bytes) return error.InvalidAuthenticationRequest;
        const operation: Operation = switch (payload[0]) {
            @intFromEnum(Operation.bind) => .bind,
            @intFromEnum(Operation.authenticate) => .authenticate,
            else => return error.InvalidAuthenticationRequest,
        };
        const principal_len: usize = payload[1];
        if (payload.len != header_bytes + principal_len) {
            return error.InvalidAuthenticationRequest;
        }
        const principal = payload[header_bytes..];
        if (!validPrincipal(principal)) return error.InvalidAuthenticationRequest;
        return .{ .operation = operation, .principal = principal };
    }
};

pub const Response = struct {
    pub fn encode(output: []u8, result: Result) CodecError![]u8 {
        if (output.len < 1) return error.BufferTooSmall;
        output[0] = @intFromEnum(result);
        return output[0..1];
    }

    pub fn decode(payload: []const u8) CodecError!Result {
        if (payload.len != 1) return error.InvalidAuthenticationResult;
        return switch (payload[0]) {
            @intFromEnum(Result.success) => .success,
            @intFromEnum(Result.no_match) => .no_match,
            @intFromEnum(Result.cancelled) => .cancelled,
            @intFromEnum(Result.unavailable) => .unavailable,
            @intFromEnum(Result.locked) => .locked,
            @intFromEnum(Result.failed) => .failed,
            else => error.InvalidAuthenticationResult,
        };
    }
};

pub const Start = enum {
    started,
    busy,
    unavailable,
    invalid,
};

/// Serializes requests for a host backend selected at compile time. A backend
/// owns only platform invocation; the broker owns correlation and cancellation.
pub fn Broker(comptime Backend: type) type {
    comptime validateBackend(Backend);
    return struct {
        backend: Backend,
        pending_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        const Self = @This();

        pub fn start(self: *Self, request_id: u64, request: Request) Start {
            if (request_id == 0 or !validPrincipal(request.principal)) return .invalid;
            if (!self.backend.available()) return .unavailable;
            if (self.pending_id.cmpxchgStrong(
                0,
                request_id,
                .acq_rel,
                .acquire,
            ) != null) return .busy;
            self.backend.start(request_id, request);
            return .started;
        }

        pub fn complete(self: *Self, request_id: u64) bool {
            if (request_id == 0) return false;
            return self.pending_id.cmpxchgStrong(
                request_id,
                0,
                .acq_rel,
                .acquire,
            ) == null;
        }

        pub fn cancel(self: *Self, request_id: u64) bool {
            if (!self.complete(request_id)) return false;
            self.backend.cancel(request_id);
            return true;
        }
    };
}

/// Correlates host results with an operating-system frontend selected at
/// compile time. Frontends translate only their platform's device ABI.
pub fn FrontendSession(comptime Frontend: type) type {
    comptime validateFrontend(Frontend);
    return struct {
        frontend: Frontend,
        request_id: u64 = 0,

        const Self = @This();

        pub fn begin(self: *Self, request_id: u64) bool {
            if (request_id == 0 or self.request_id != 0 or !self.frontend.available()) {
                return false;
            }
            self.request_id = request_id;
            return true;
        }

        pub fn complete(self: *Self, request_id: u64, result: Result) bool {
            if (request_id == 0 or request_id != self.request_id) return false;
            self.request_id = 0;
            self.frontend.complete(result);
            return true;
        }

        pub fn close(self: *Self) ?u64 {
            const pending_id = if (self.request_id == 0) null else self.request_id;
            self.request_id = 0;
            self.frontend.close();
            return pending_id;
        }
    };
}

fn validateBackend(comptime Backend: type) void {
    const available: *const fn (*const Backend) bool = Backend.available;
    const start: *const fn (*Backend, u64, Request) void = Backend.start;
    const cancel: *const fn (*Backend, u64) void = Backend.cancel;
    _ = .{ available, start, cancel };
}

fn validateFrontend(comptime Frontend: type) void {
    const available: *const fn (*const Frontend) bool = Frontend.available;
    const complete: *const fn (*Frontend, Result) void = Frontend.complete;
    const close: *const fn (*Frontend) void = Frontend.close;
    _ = .{ available, complete, close };
}

fn validPrincipal(principal: []const u8) bool {
    if (principal.len == 0 or principal.len > principal_bytes_max) return false;
    return std.unicode.utf8ValidateSlice(principal);
}

test "authentication request codec preserves stable wire values" {
    const testing = std.testing;
    var buffer: [Request.header_bytes + principal_bytes_max]u8 = undefined;
    const encoded = try Request.encode(&buffer, .{
        .operation = .authenticate,
        .principal = "alice",
    });
    try testing.expectEqualSlices(u8, &.{ 2, 5, 'a', 'l', 'i', 'c', 'e' }, encoded);
    const decoded = try Request.decode(encoded);
    try testing.expectEqual(Operation.authenticate, decoded.operation);
    try testing.expectEqualStrings("alice", decoded.principal);
    try testing.expectError(error.InvalidAuthenticationRequest, Request.decode(&.{ 9, 1, 'a' }));
}

test "broker serializes, correlates, and cancels requests" {
    const testing = std.testing;
    const Backend = struct {
        started_id: u64 = 0,
        cancelled_id: u64 = 0,

        fn available(_: *const @This()) bool {
            return true;
        }

        fn start(self: *@This(), request_id: u64, _: Request) void {
            self.started_id = request_id;
        }

        fn cancel(self: *@This(), request_id: u64) void {
            self.cancelled_id = request_id;
        }
    };
    var broker = Broker(Backend){ .backend = .{} };
    const request = Request{ .operation = .authenticate, .principal = "alice" };

    try testing.expectEqual(Start.started, broker.start(7, request));
    try testing.expectEqual(@as(u64, 7), broker.backend.started_id);
    try testing.expectEqual(Start.busy, broker.start(8, request));
    try testing.expect(!broker.complete(8));
    try testing.expect(broker.cancel(7));
    try testing.expectEqual(@as(u64, 7), broker.backend.cancelled_id);
}

test "frontend session rejects stale host results" {
    const testing = std.testing;
    const Frontend = struct {
        result: ?Result = null,
        closed: bool = false,

        pub fn available(_: *const @This()) bool {
            return true;
        }

        pub fn complete(self: *@This(), result: Result) void {
            self.result = result;
        }

        pub fn close(self: *@This()) void {
            self.closed = true;
        }
    };
    var session = FrontendSession(Frontend){ .frontend = .{} };

    try testing.expect(session.begin(11));
    try testing.expect(!session.complete(12, .failed));
    try testing.expect(session.complete(11, .success));
    try testing.expectEqual(Result.success, session.frontend.result.?);
    try testing.expect(session.close() == null);
    try testing.expect(session.frontend.closed);
}
