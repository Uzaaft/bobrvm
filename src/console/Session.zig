const Session = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const callback_binding = @import("../callback.zig");
const global = @import("../global.zig");

output: ?Output = null,
backend: ?Backend = null,
size: Size = .{},
backend_mutex: std.Io.Mutex = .init,

pub const Output = callback_binding.Binding1([]const u8, void);
pub const Write = callback_binding.Binding1([]const u8, void);
pub const Resize = callback_binding.Binding1(Size, void);

/// Guest-visible terminal dimensions measured in character cells.
pub const Size = struct {
    columns: u16 = 80,
    rows: u16 = 25,

    pub const Error = error{InvalidSize};

    pub fn init(columns: u16, rows: u16) Error!Size {
        if (columns == 0 or rows == 0) return error.InvalidSize;
        return .{ .columns = columns, .rows = rows };
    }
};

/// Guest transport operations. Platform runtimes adapt their serial or
/// virtio-console implementation to this interface.
pub const Backend = struct {
    write: Write,
    resize: ?Resize = null,
};

pub const WriteError = error{Detached};

pub fn init() Session {
    return .{};
}

/// Set the frontend output sink before attaching or starting a backend.
/// The sink must remain valid until the session is no longer receiving data.
pub fn setOutput(self: *Session, output: Output) void {
    assert(self.backend == null);
    assert(self.output == null);
    self.output = output;
}

/// Attach only while the backend is quiescent. The binding remains immutable
/// while frontend input and backend output may arrive on different threads.
pub fn attach(self: *Session, backend: Backend) void {
    self.backend_mutex.lockUncancelable(global.io());
    defer self.backend_mutex.unlock(global.io());
    assert(self.backend == null);
    self.backend = backend;
    if (backend.resize) |resize_binding| resize_binding.call(self.size);
}

/// Detach only after the backend can no longer call receive.
pub fn detach(self: *Session) void {
    self.backend_mutex.lockUncancelable(global.io());
    defer self.backend_mutex.unlock(global.io());
    assert(self.backend != null);
    self.backend = null;
}

/// Forward raw guest bytes without assuming an encoding or chunk boundary.
pub fn receive(self: *Session, data: []const u8) void {
    if (data.len == 0) return;
    if (self.output) |output| output.call(data);
}

/// Forward raw input bytes to the attached guest transport.
pub fn write(self: *Session, data: []const u8) WriteError!void {
    if (data.len == 0) return;
    self.backend_mutex.lockUncancelable(global.io());
    defer self.backend_mutex.unlock(global.io());
    const backend = self.backend orelse return error.Detached;
    backend.write.call(data);
}

/// Record terminal dimensions and notify an attached backend when they change.
pub fn resize(self: *Session, size: Size) void {
    assert(size.columns > 0);
    assert(size.rows > 0);
    self.backend_mutex.lockUncancelable(global.io());
    defer self.backend_mutex.unlock(global.io());
    if (std.meta.eql(self.size, size)) return;

    self.size = size;
    const backend = self.backend orelse return;
    if (backend.resize) |resize_binding| resize_binding.call(size);
}

test "session preserves raw bytes across frontend and backend boundaries" {
    const Capture = struct {
        bytes: [8]u8 = undefined,
        length: usize = 0,

        fn append(self: *@This(), data: []const u8) void {
            @memcpy(self.bytes[self.length..][0..data.len], data);
            self.length += data.len;
        }
    };

    var frontend = Capture{};
    var backend = Capture{};
    var session = Session.init();
    session.setOutput(callback_binding.Handler1(
        Capture,
        []const u8,
        void,
        Capture.append,
    ).bind(&frontend));
    session.attach(.{ .write = callback_binding.Handler1(
        Capture,
        []const u8,
        void,
        Capture.append,
    ).bind(&backend) });

    const raw = [_]u8{ 0x1b, '[', 'H', 0xff };
    session.receive(&raw);
    try session.write(&raw);

    try std.testing.expectEqualSlices(u8, &raw, frontend.bytes[0..frontend.length]);
    try std.testing.expectEqualSlices(u8, &raw, backend.bytes[0..backend.length]);
}

test "session retains size and rejects input while detached" {
    const Capture = struct {
        sizes: [2]Size = undefined,
        length: usize = 0,

        fn resize(self: *@This(), size: Size) void {
            self.sizes[self.length] = size;
            self.length += 1;
        }

        fn write(_: *@This(), _: []const u8) void {}
    };

    var capture = Capture{};
    var session = Session.init();
    session.resize(try Size.init(132, 43));
    try std.testing.expectError(error.Detached, session.write("x"));

    session.attach(.{
        .write = callback_binding.Handler1(
            Capture,
            []const u8,
            void,
            Capture.write,
        ).bind(&capture),
        .resize = callback_binding.Handler1(
            Capture,
            Size,
            void,
            Capture.resize,
        ).bind(&capture),
    });
    session.resize(try Size.init(160, 50));
    session.resize(try Size.init(160, 50));

    try std.testing.expectEqual(@as(usize, 2), capture.length);
    try std.testing.expectEqual(Size{ .columns = 132, .rows = 43 }, capture.sizes[0]);
    try std.testing.expectEqual(Size{ .columns = 160, .rows = 50 }, capture.sizes[1]);

    session.detach();
    try std.testing.expectError(error.Detached, session.write("x"));
}
