//! Context-bound guest physical memory access.
//!
//! Device code receives this value instead of consulting process-global VM
//! state. The callback owns address translation; this wrapper rejects integer
//! overflow and provides bounded copy helpers for guest-controlled ranges.

const std = @import("std");

pub const GuestMemory = struct {
    userdata: *anyopaque,
    get_fn: *const fn (*anyopaque, u64, usize) ?[]u8,

    pub const Error = error{OutOfBounds};

    pub fn bind(
        comptime Context: type,
        context: *Context,
        comptime get_fn: *const fn (*Context, u64, usize) ?[]u8,
    ) GuestMemory {
        const Adapter = struct {
            fn get(userdata: *anyopaque, address: u64, length: usize) ?[]u8 {
                const typed: *Context = @ptrCast(@alignCast(userdata));
                return get_fn(typed, address, length);
            }
        };
        return .{ .userdata = context, .get_fn = Adapter.get };
    }

    pub fn bindGlobal(
        comptime get_fn: *const fn (u64, usize) ?[]u8,
    ) GuestMemory {
        const Adapter = struct {
            var token: u8 = 0;

            fn get(_: *anyopaque, address: u64, length: usize) ?[]u8 {
                return get_fn(address, length);
            }
        };
        return .{ .userdata = &Adapter.token, .get_fn = Adapter.get };
    }

    pub fn get(self: GuestMemory, address: u64, length: usize) ?[]u8 {
        _ = std.math.add(u64, address, length) catch return null;
        return self.get_fn(self.userdata, address, length);
    }

    pub fn read(self: GuestMemory, address: u64, destination: []u8) Error!void {
        const source = self.get(address, destination.len) orelse return error.OutOfBounds;
        @memcpy(destination, source);
    }

    pub fn write(self: GuestMemory, address: u64, source: []const u8) Error!void {
        const destination = self.get(address, source.len) orelse return error.OutOfBounds;
        @memcpy(destination, source);
    }
};

const TestMemory = struct {
    base: u64,
    bytes: []u8,

    fn get(self: *TestMemory, address: u64, length: usize) ?[]u8 {
        if (address < self.base) return null;
        const offset_u64 = address - self.base;
        if (offset_u64 > self.bytes.len) return null;
        const offset: usize = @intCast(offset_u64);
        if (length > self.bytes.len - offset) return null;
        return self.bytes[offset..][0..length];
    }
};

test "guest memory bindings retain independent VM context" {
    var first_bytes = [_]u8{ 1, 2, 3, 4 };
    var second_bytes = [_]u8{ 5, 6, 7, 8 };
    var first_context = TestMemory{ .base = 0x1000, .bytes = &first_bytes };
    var second_context = TestMemory{ .base = 0x1000, .bytes = &second_bytes };
    const first = GuestMemory.bind(TestMemory, &first_context, TestMemory.get);
    const second = GuestMemory.bind(TestMemory, &second_context, TestMemory.get);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, first.get(0x1000, 2).?);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6 }, second.get(0x1000, 2).?);
}

test "guest memory rejects overflow and out-of-range copies" {
    var bytes = [_]u8{0} ** 8;
    var context = TestMemory{ .base = 0x2000, .bytes = &bytes };
    const memory = GuestMemory.bind(TestMemory, &context, TestMemory.get);

    try std.testing.expect(memory.get(std.math.maxInt(u64), 2) == null);
    try std.testing.expectError(error.OutOfBounds, memory.write(0x2007, &.{ 1, 2 }));
    try memory.write(0x2002, &.{ 9, 8, 7 });
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7 }, bytes[2..5]);
}
