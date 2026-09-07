//! Forward a private host Unix socket through Virtualization.framework vsock.
//!
//! The accept thread only owns host file descriptors. VZ calls are dispatched
//! to the main queue used by the VM, and completed streams are copied by
//! bounded worker threads without passing through Ethernet, TCP, or MiniNat.

pub const Bridge = @This();

const std = @import("std");
const socket_copy = @import("../net/socket_copy.zig");
const objc = @import("objc");

const global = @import("../global.zig");
const net_compat = @import("../compat/net.zig");
const vz_process_policy = @import("vz_process_policy.zig");

const Allocator = std.mem.Allocator;
const Object = objc.Object;
const id = objc.c.id;

const log = std.log.scoped(.vz_vsock);
const unix_path_bytes_max = @sizeOf(@FieldType(std.posix.sockaddr.un, "path"));
const docker_port: u32 = 62_375;
const ready_port: u32 = 62_376;
const connection_count_max: usize = 64;
const worker_stack_bytes: usize = 256 * 1024;

const DispatchQueue = *anyopaque;
const DispatchWork = *const fn (?*anyopaque) callconv(.c) void;

extern "c" var _dispatch_main_q: anyopaque;
extern "c" fn dispatch_async_f(
    queue: DispatchQueue,
    context: ?*anyopaque,
    work: DispatchWork,
) void;
extern "c" fn close(fd: c_int) c_int;

alloc: Allocator,
path: []u8,
listener: std.posix.socket_t,
state: *State,
accept_thread: ?std.Thread = null,
ready_pipe: net_compat.WakePipe,
ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
ready_listener: ?Object = null,
ready_delegate: ?Object = null,
ready_connection: ?Object = null,

const State = struct {
    alloc: Allocator,
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    connection_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    socket_device: ?Object = null,
    // VM-queue owned. A restore can resume before the guest proxy has started.
    guest_notified: bool = false,
    pending: [connection_count_max]?*Request = @splat(null),
    performance_policy: ?*vz_process_policy.Controller = null,
    proxies_mutex: std.Io.Mutex = .init,
    proxies: [connection_count_max]?*Proxy = @splat(null),

    fn retain(self: *State) void {
        const previous = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
    }

    fn release(self: *State) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        if (self.socket_device) |device| device.release();
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }
};

const Request = struct {
    state: *State,
    client_fd: std.posix.socket_t,
    guest_notified: bool = false,
};

const Proxy = struct {
    state: *State,
    client_fd: std.posix.socket_t,
    connection: Object,
    vsock_fd: std.posix.socket_t,
};

const ConnectBlock = objc.Block(struct {
    request: *Request,
}, .{ id, id }, void);

pub fn create(
    alloc: Allocator,
    path: []const u8,
    performance_policy: ?*vz_process_policy.Controller,
) !*Bridge {
    if (path.len == 0 or path.len >= unix_path_bytes_max) return error.NameTooLong;
    const self = try alloc.create(Bridge);
    errdefer alloc.destroy(self);
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    const state = try alloc.create(State);
    errdefer alloc.destroy(state);
    state.* = .{ .alloc = alloc, .performance_policy = performance_policy };
    const listener = try createListener(owned_path);
    errdefer {
        net_compat.socketClose(listener);
        unlinkSocket(owned_path);
    }
    var ready_pipe = try net_compat.WakePipe.init();
    errdefer ready_pipe.deinit();
    self.* = .{
        .ready_pipe = ready_pipe,
        .alloc = alloc,
        .path = owned_path,
        .listener = listener,
        .state = state,
    };
    self.state.running.store(true, .release);
    errdefer self.state.running.store(false, .release);
    self.accept_thread = try std.Thread.spawn(
        .{ .stack_size = worker_stack_bytes },
        acceptLoop,
        .{self},
    );
    return self;
}

pub fn setSocketDevice(self: *Bridge, device: Object) error{ReadyListenerFailed}!void {
    std.debug.assert(self.state.socket_device == null);
    std.debug.assert(device.value != null);
    const delegate = try createReadyDelegate(self);
    errdefer delegate.release();
    const listener = objc.getClass("VZVirtioSocketListener").?.msgSend(Object, "new", .{});
    if (listener.value == null) return error.ReadyListenerFailed;
    listener.msgSend(void, "setDelegate:", .{delegate.value});
    device.msgSend(void, "setSocketListener:forPort:", .{ listener.value, ready_port });
    self.ready_delegate = delegate;
    self.ready_listener = listener;
    self.state.socket_device = device.retain();
}

/// The guest listener survives a saved-state restore. Called on the VM queue
/// after resume completes; Docker's HTTP response still confirms daemon readiness.
pub fn resumeReady(self: *Bridge) void {
    self.ready.store(true, .release);
    self.ready_pipe.signal();
}

fn createReadyDelegate(self: *Bridge) error{ReadyListenerFailed}!Object {
    const name = "BobrvmDockerReadyDelegate";
    const class = objc.getClass(name) orelse blk: {
        const class = objc.allocateClassPair(objc.getClass("NSObject"), name) orelse
            return error.ReadyListenerFailed;
        errdefer objc.disposeClassPair(class);
        const alignment_log2 = @ctz(@as(usize, @alignOf(*Bridge)));
        const added_ivar = objc.c.class_addIvar(
            class.value,
            "bridge",
            @sizeOf(*Bridge),
            @intCast(alignment_log2),
            "^v",
        );
        if (added_ivar == 0 or
            !class.addMethod("listener:shouldAcceptNewConnection:fromSocketDevice:", readyNotification))
        {
            return error.ReadyListenerFailed;
        }
        objc.registerClassPair(class);
        break :blk class;
    };
    const delegate = class.msgSend(Object, "new", .{});
    if (delegate.value == null) return error.ReadyListenerFailed;
    _ = objc.c.object_setInstanceVariable(delegate.value, "bridge", self);
    return delegate;
}

fn readyNotification(
    delegate: id,
    _: objc.c.SEL,
    _: id,
    connection: id,
    _: id,
) callconv(.c) objc.c.BOOL {
    var pointer: ?*anyopaque = null;
    _ = objc.c.object_getInstanceVariable(delegate, "bridge", &pointer);
    const self: *Bridge = @ptrCast(@alignCast(pointer.?));
    if (!self.state.running.load(.acquire)) return 0;
    if (self.ready_connection) |previous| {
        previous.msgSend(void, "close", .{});
        previous.release();
    }
    self.ready_connection = Object.fromId(connection).retain();
    self.state.guest_notified = true;
    for (&self.state.pending) |*slot| {
        const request = slot.* orelse continue;
        slot.* = null;
        connectRequest(request);
    }
    self.resumeReady();
    return 1;
}

pub fn connectionCount(self: *const Bridge) u32 {
    return self.state.connection_count.load(.acquire);
}

pub fn destroy(self: *Bridge) void {
    self.state.running.store(false, .release);
    self.ready_pipe.signal();
    for (&self.state.pending) |*slot| {
        if (slot.*) |request| failRequest(request);
        slot.* = null;
    }
    if (self.ready_listener) |listener| {
        self.state.socket_device.?.msgSend(void, "removeSocketListenerForPort:", .{ready_port});
        listener.msgSend(void, "setDelegate:", .{@as(id, null)});
        listener.release();
    }
    if (self.ready_delegate) |delegate| delegate.release();
    if (self.ready_connection) |connection| {
        connection.msgSend(void, "close", .{});
        connection.release();
    }
    wakeAccept(self.path);
    if (self.accept_thread) |thread| thread.join();
    self.ready_pipe.deinit();
    self.closeActive();
    net_compat.socketClose(self.listener);
    unlinkSocket(self.path);
    const alloc = self.alloc;
    alloc.free(self.path);
    self.state.release();
    self.* = undefined;
    alloc.destroy(self);
}

fn closeActive(self: *Bridge) void {
    self.state.proxies_mutex.lockUncancelable(global.io());
    defer self.state.proxies_mutex.unlock(global.io());
    for (self.state.proxies) |proxy_optional| {
        const proxy = proxy_optional orelse continue;
        proxy.connection.msgSend(void, "close", .{});
        _ = std.c.shutdown(proxy.client_fd, 2);
    }
}

fn createListener(path: []const u8) !std.posix.socket_t {
    try net_compat.removeStaleUnixSocket(path);
    var pending_buffer: [unix_path_bytes_max]u8 = undefined;
    // A same-length sibling preserves the Unix socket path limit during
    // atomic publication, including paths that already fill sun_path.
    const pending = pending_buffer[0..path.len];
    @memcpy(pending, path);
    pending[pending.len - 1] = if (pending[pending.len - 1] == '~') '^' else '~';
    try net_compat.removeStaleUnixSocket(pending);
    const listener = try net_compat.socketCreate(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        0,
    );
    errdefer net_compat.socketClose(listener);
    var address: std.posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..pending.len], pending);
    const address_len = @offsetOf(std.posix.sockaddr.un, "path") + pending.len + 1;
    try net_compat.bind(listener, @ptrCast(&address), @intCast(address_len));
    errdefer unlinkSocket(pending);
    try chmodSocket(pending);
    try net_compat.listen(listener, 32);
    // Publish only after listen: a directory watcher must never observe a
    // socket which is bound but still refuses connections.
    try std.Io.Dir.renameAbsolute(pending, path, global.io());
    return listener;
}

fn acceptLoop(self: *Bridge) void {
    // Keep early clients in the Unix listen backlog until the guest proxy can
    // accept them. Readiness is a latched notification, never a retry timer.
    while (self.state.running.load(.acquire) and !self.ready.load(.acquire)) {
        self.ready_pipe.wait(null) catch return;
    }
    while (self.state.running.load(.acquire)) {
        const client_fd = std.c.accept(self.listener, null, null);
        if (client_fd < 0) {
            const socket_error = std.c.errno(@as(c_int, -1));
            if (socket_error == .INTR) continue;
            if (socket_error == .AGAIN) {
                waitForAccept(self.listener);
                continue;
            }
            if (self.state.running.load(.acquire)) log.warn("Docker socket accept failed", .{});
            return;
        }
        if (!self.state.running.load(.acquire)) {
            _ = close(client_fd);
            return;
        }
        if (!setBlocking(client_fd)) {
            _ = close(client_fd);
            continue;
        }
        if (self.state.performance_policy) |policy| policy.activity();
        const previous = self.state.connection_count.fetchAdd(1, .acq_rel);
        if (previous >= connection_count_max) {
            _ = self.state.connection_count.fetchSub(1, .acq_rel);
            _ = close(client_fd);
            continue;
        }
        const request = self.state.alloc.create(Request) catch {
            _ = self.state.connection_count.fetchSub(1, .acq_rel);
            _ = close(client_fd);
            continue;
        };
        self.state.retain();
        request.* = .{ .state = self.state, .client_fd = client_fd };
        dispatch_async_f(@ptrCast(&_dispatch_main_q), request, connectRequest);
    }
}

fn waitForAccept(listener: std.posix.socket_t) void {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = listener,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = std.posix.poll(&poll_fds, -1) catch {};
}

/// Wake the blocking listener wait without racing file-descriptor reuse during
/// teardown. The accept loop discards this stream after observing shutdown.
fn wakeAccept(path: []const u8) void {
    const socket = net_compat.socketCreate(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
        0,
    ) catch return;
    defer net_compat.socketClose(socket);

    var address: std.posix.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&address), 0);
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len = @offsetOf(std.posix.sockaddr.un, "path") + path.len + 1;
    net_compat.connect(socket, @ptrCast(&address), @intCast(address_len)) catch {};
}

fn setBlocking(fd: std.posix.socket_t) bool {
    const current = std.c.fcntl(fd, std.c.F.GETFL);
    if (current < 0) return false;
    var flags: std.c.O = @bitCast(@as(u32, @intCast(current)));
    flags.NONBLOCK = false;
    return std.c.fcntl(fd, std.c.F.SETFL, @as(u32, @bitCast(flags))) >= 0;
}

fn connectRequest(context: ?*anyopaque) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(context.?));
    const state = request.state;
    if (!state.running.load(.acquire)) return failRequest(request);
    const device = state.socket_device orelse return failRequest(request);
    request.guest_notified = state.guest_notified;
    var block = ConnectBlock.init(.{ .request = request }, connectCompletion);
    device.msgSend(void, "connectToPort:completionHandler:", .{ docker_port, &block });
}

fn connectCompletion(
    block: *const ConnectBlock.Context,
    connection_id: id,
    error_id: id,
) callconv(.c) void {
    const request = block.request;
    const state = request.state;
    if (!state.running.load(.acquire)) return failRequest(request);
    if (error_id != null or connection_id == null) {
        // Resume is an opportunity to connect, not proof that a snapshot was
        // taken after proxy startup. Park failures until its actual notification.
        if (!request.guest_notified and state.guest_notified) return connectRequest(request);
        if (!state.guest_notified) {
            for (&state.pending) |*slot| {
                if (slot.* != null) continue;
                slot.* = request;
                return;
            }
        }
        return failRequest(request);
    }
    const connection = Object.fromId(connection_id).retain();
    const vsock_fd = connection.msgSend(c_int, "fileDescriptor", .{});
    if (vsock_fd < 0) {
        connection.release();
        return failRequest(request);
    }
    startProxy(request, connection, vsock_fd) catch {
        connection.msgSend(void, "close", .{});
        connection.release();
        return failRequest(request);
    };
    finishRequest(request, false);
}

fn startProxy(request: *Request, connection: Object, vsock_fd: c_int) !void {
    const state = request.state;
    const proxy = try state.alloc.create(Proxy);
    errdefer state.alloc.destroy(proxy);
    proxy.* = .{
        .state = state,
        .client_fd = request.client_fd,
        .connection = connection,
        .vsock_fd = vsock_fd,
    };
    const slot = try registerProxy(state, proxy);
    errdefer unregisterProxy(state, proxy, slot);
    state.retain();
    errdefer state.release();
    const thread = try std.Thread.spawn(
        .{ .stack_size = worker_stack_bytes },
        proxyLoop,
        .{ proxy, slot },
    );
    thread.detach();
}

fn registerProxy(state: *State, proxy: *Proxy) !usize {
    state.proxies_mutex.lockUncancelable(global.io());
    defer state.proxies_mutex.unlock(global.io());
    for (&state.proxies, 0..) |*slot, index| {
        if (slot.* != null) continue;
        slot.* = proxy;
        return index;
    }
    return error.ConnectionLimit;
}

fn unregisterProxy(state: *State, proxy: *Proxy, slot: usize) void {
    state.proxies_mutex.lockUncancelable(global.io());
    std.debug.assert(state.proxies[slot] == proxy);
    state.proxies[slot] = null;
    state.proxies_mutex.unlock(global.io());
}

fn proxyLoop(proxy: *Proxy, slot: usize) void {
    const state = proxy.state;
    const alloc = state.alloc;
    defer state.release();
    defer _ = state.connection_count.fetchSub(1, .acq_rel);
    defer alloc.destroy(proxy);
    defer unregisterProxy(state, proxy, slot);
    defer proxy.connection.release();
    defer proxy.connection.msgSend(void, "close", .{});
    defer _ = close(proxy.client_fd);
    const upload = std.Thread.spawn(.{}, socket_copy.copyDirection, .{socket_copy.Direction{
        .source_fd = proxy.client_fd,
        .destination_fd = proxy.vsock_fd,
    }}) catch {
        socket_copy.shutdownBoth(proxy.client_fd, proxy.vsock_fd);
        return;
    };
    socket_copy.copyDirection(.{ .source_fd = proxy.vsock_fd, .destination_fd = proxy.client_fd });
    upload.join();
}

fn failRequest(request: *Request) void {
    _ = close(request.client_fd);
    finishRequest(request, true);
}

fn finishRequest(request: *Request, release_connection: bool) void {
    const state = request.state;
    const alloc = state.alloc;
    alloc.destroy(request);
    if (release_connection) _ = state.connection_count.fetchSub(1, .acq_rel);
    state.release();
}

fn unlinkSocket(path: []const u8) void {
    var buffer: [unix_path_bytes_max:0]u8 = undefined;
    if (path.len >= buffer.len) return;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    _ = std.c.unlink(buffer[0..path.len :0].ptr);
}

fn chmodSocket(path: []const u8) !void {
    var buffer: [unix_path_bytes_max:0]u8 = undefined;
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    if (std.c.chmod(buffer[0..path.len :0].ptr, 0o600) != 0) {
        return error.AccessDenied;
    }
}

test "VZ vsock bridge creates a private Unix listener" {
    if (@import("builtin").os.tag != .macos) return;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = global.io();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ path_buffer[0..root_len], "docker.sock" },
    );
    defer std.testing.allocator.free(path);
    const bridge = try Bridge.create(std.testing.allocator, path, null);
    bridge.destroy();
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, path, .{}),
    );
}

test "VZ vsock bridge refuses to unlink a live Unix listener" {
    if (@import("builtin").os.tag != .macos) return;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = global.io();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ path_buffer[0..root_len], "docker.sock" },
    );
    defer std.testing.allocator.free(path);
    const first = try createListener(path);
    defer {
        net_compat.socketClose(first);
        unlinkSocket(path);
    }

    try std.testing.expectError(
        error.AddressInUse,
        createListener(path),
    );
    try std.Io.Dir.accessAbsolute(io, path, .{});
}

test "VZ vsock bridge stops with early clients filling its backlog" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(global.io(), &path_buffer);
    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ path_buffer[0..root_len], "docker.sock" },
    );
    defer std.testing.allocator.free(path);
    const bridge = try Bridge.create(std.testing.allocator, path, null);
    errdefer bridge.destroy();
    var clients: [64]?c_int = @splat(null);
    defer for (clients) |client| {
        if (client) |fd| net_compat.socketClose(fd);
    };
    var address = std.mem.zeroes(std.posix.sockaddr.un);
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..path.len], path);
    const address_len = @offsetOf(std.posix.sockaddr.un, "path") + path.len + 1;
    var connected: usize = 0;
    for (&clients) |*client| {
        const fd = try net_compat.socketCreate(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        client.* = fd;
        if (std.c.connect(fd, @ptrCast(&address), @intCast(address_len)) == 0) connected += 1;
    }
    try std.testing.expect(connected > 0);
    try std.testing.expectEqual(@as(u32, 0), bridge.connectionCount());
    // No guest notification was delivered. Teardown must not make a blocking
    // connection to a full backlog whose accept thread is still gated.
    bridge.destroy();
}
