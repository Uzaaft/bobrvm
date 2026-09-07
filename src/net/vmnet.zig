//! vmnet framework ownership for the privileged helper. Callbacks only signal
//! a pipe; packet I/O and interface destruction belong to the session thread.
pub const Interface = @This();
const std = @import("std");
const objc = @import("objc");
const net = @import("../compat/net.zig");
const protocol = @import("shared_protocol.zig");

handle: ?*anyopaque = null,
queue: *anyopaque,
completion: *anyopaque,
wake: net.WakePipe,
ok: bool = false,

const Start = objc.Block(struct { self: *Interface }, .{ u32, ?*anyopaque }, void);
const Stop = objc.Block(struct { self: *Interface }, .{u32}, void);
const Event = objc.Block(struct { self: *Interface }, .{ u32, ?*anyopaque }, void);
const Packet = extern struct { size: usize, iov: *std.posix.iovec, count: u32 = 1, flags: u32 = 0 };
extern "c" fn dispatch_queue_create([*:0]const u8, ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_semaphore_create(isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(*anyopaque, u64) isize;
extern "c" fn dispatch_semaphore_signal(*anyopaque) isize;
extern "c" fn dispatch_time(u64, i64) u64;
extern "c" fn dispatch_release(*anyopaque) void;
extern "c" fn xpc_dictionary_create(?*anyopaque, ?*anyopaque, usize) ?*anyopaque;
extern "c" fn xpc_dictionary_set_uint64(*anyopaque, [*:0]const u8, u64) void;
extern "c" fn xpc_dictionary_set_bool(*anyopaque, [*:0]const u8, bool) void;
extern "c" fn xpc_dictionary_get_uint64(*anyopaque, [*:0]const u8) u64;
extern "c" fn xpc_release(*anyopaque) void;
extern "c" var vmnet_operation_mode_key: [*:0]const u8;
extern "c" var vmnet_allocate_mac_address_key: [*:0]const u8;
extern "c" var vmnet_mtu_key: [*:0]const u8;
extern "c" var vmnet_max_packet_size_key: [*:0]const u8;
extern "c" fn vmnet_start_interface(*anyopaque, *anyopaque, *const anyopaque) ?*anyopaque;
extern "c" fn vmnet_stop_interface(*anyopaque, *anyopaque, *const anyopaque) u32;
extern "c" fn vmnet_interface_set_event_callback(*anyopaque, u32, *anyopaque, ?*const anyopaque) u32;
extern "c" fn vmnet_read(*anyopaque, [*]Packet, *c_int) u32;
extern "c" fn vmnet_write(*anyopaque, [*]Packet, *c_int) u32;

pub fn init(self: *Interface) error{InterfaceFailed}!void {
    self.* = .{
        .queue = dispatch_queue_create("as.polymath.bobrvm.network", null) orelse
            return error.InterfaceFailed,
        .completion = undefined,
        .wake = .{},
    };
    errdefer dispatch_release(self.queue);
    self.completion = dispatch_semaphore_create(0) orelse return error.InterfaceFailed;
    errdefer dispatch_release(self.completion);
    self.wake = net.WakePipe.init() catch return error.InterfaceFailed;
    errdefer self.wake.deinit();
    const description = xpc_dictionary_create(null, null, 0) orelse return error.InterfaceFailed;
    defer xpc_release(description);
    xpc_dictionary_set_uint64(description, vmnet_operation_mode_key, 1001);
    xpc_dictionary_set_bool(description, vmnet_allocate_mac_address_key, false);
    xpc_dictionary_set_uint64(description, vmnet_mtu_key, 1500);
    var start = Start.init(.{ .self = self }, started);
    self.handle = vmnet_start_interface(description, self.queue, &start) orelse
        return error.InterfaceFailed;
    self.waitCompletion();
    errdefer self.stop();
    if (!self.ok) return error.InterfaceFailed;
    var event = Event.init(.{ .self = self }, available);
    if (vmnet_interface_set_event_callback(self.handle.?, 1, self.queue, &event) != 1000)
        return error.InterfaceFailed;
}

fn started(context: *const Start.Context, status: u32, parameters: ?*anyopaque) callconv(.c) void {
    const self = context.self;
    self.ok = status == 1000 and parameters != null and
        xpc_dictionary_get_uint64(parameters.?, vmnet_max_packet_size_key) <= protocol.frame_bytes_max;
    _ = dispatch_semaphore_signal(self.completion);
}

fn available(context: *const Event.Context, _: u32, _: ?*anyopaque) callconv(.c) void {
    context.self.wake.signal();
}

fn stopped(context: *const Stop.Context, _: u32) callconv(.c) void {
    _ = dispatch_semaphore_signal(context.self.completion);
}

fn waitCompletion(self: *Interface) void {
    // The framework owns callback copies referring to self. On timeout exit
    // the daemon rather than freeing a context that may still be referenced.
    if (dispatch_semaphore_wait(self.completion, dispatch_time(0, 10 * std.time.ns_per_s)) != 0)
        std.process.exit(1);
}

fn stop(self: *Interface) void {
    const handle = self.handle orelse return;
    _ = vmnet_interface_set_event_callback(handle, 1, self.queue, null);
    var block = Stop.init(.{ .self = self }, stopped);
    if (vmnet_stop_interface(handle, self.queue, &block) != 1000) std.process.exit(1);
    self.waitCompletion();
    self.handle = null;
}

pub fn deinit(self: *Interface) void {
    self.stop();
    self.wake.deinit();
    dispatch_release(self.completion);
    dispatch_release(self.queue);
}

/// Borrow frame storage for one bounded write; drop packets if vmnet cannot accept them.
pub fn writeBatch(self: *Interface, frames: []const []u8) void {
    const capacity = @import("packet_batch.zig").capacity;
    std.debug.assert(frames.len <= capacity);
    if (frames.len == 0) return;
    var iov: [capacity]std.posix.iovec = undefined;
    var packets: [capacity]Packet = undefined;
    for (frames, iov[0..frames.len], packets[0..frames.len]) |frame, *vector, *packet| {
        vector.* = .{ .base = frame.ptr, .len = frame.len };
        packet.* = .{ .size = frame.len, .iov = vector };
    }
    var count: c_int = @intCast(frames.len);
    _ = vmnet_write(self.handle.?, &packets, &count);
}

/// Bounded batch per wakeup. Rearm our pipe if more packets may be waiting.
pub fn read(self: *Interface, socket: c_int) void {
    var frames: [32][protocol.frame_bytes_max]u8 = undefined;
    var iov: [32]std.posix.iovec = undefined;
    var packets: [32]Packet = undefined;
    for (&frames, &iov, &packets) |*frame, *vector, *packet| {
        vector.* = .{ .base = frame, .len = frame.len };
        packet.* = .{ .size = frame.len, .iov = vector };
    }
    var count: c_int = packets.len;
    if (vmnet_read(self.handle.?, &packets, &count) != 1000 or count < 0 or count > packets.len) return;
    for (packets[0..@intCast(count)]) |packet| {
        if (packet.size < 14 or packet.size > protocol.frame_bytes_max) continue;
        _ = std.c.send(socket, packet.iov.base, packet.size, std.posix.MSG.DONTWAIT);
    }
    if (count == packets.len) self.wake.signal();
}
