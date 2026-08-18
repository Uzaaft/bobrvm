//! qemu-guest-agent host-side channel.
//!
//! Speaks the qemu-ga JSON protocol (newline-delimited JSON-RPC-ish:
//! `{"execute": "...", "arguments": {...}}` → `{"return": ...}`) over a
//! virtio-console multiport port named "org.qemu.guest_agent.0". Stock
//! qemu-guest-agent — packaged in every distro — attaches in the guest,
//! so bobrvm ships zero custom guest software.
//!
//! Transport-agnostic: the owner provides a send function (host→guest
//! bytes) and feeds guest→host bytes into feed(). feed() runs on the
//! vCPU thread (console output callback); send may be called from any
//! thread the transport tolerates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const callback = @import("../callback.zig");

const log = std.log.scoped(.qga);

pub const Send = callback.Binding1([]const u8, void);

pub const Qga = struct {
    alloc: Allocator,
    sender: Send,

    /// Partial-line assembly for guest→host responses.
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Latest response outcomes (observability + tests).
    responses_seen: u64 = 0,
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next_request_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    watched_request_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    watched_response_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    watched_response_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_sync_id: ?i64 = null,
    /// Guest IPv4 addresses reported by guest-network-get-interfaces
    /// (comma-separated, lo excluded).
    guest_ips: std.ArrayListUnmanaged(u8) = .empty,
    /// pid returned by the last guest-exec spawn; -1 = none yet.
    /// Written on the vCPU thread before its watched response becomes
    /// ready, so a waiter that observes readiness also sees the pid.
    exec_pid: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1),
    /// Last guest-exec-status payload plus its decoded output streams.
    /// Valid once the matching watched response is ready; the buffers
    /// are reused by the next poll.
    exec_status: ExecStatus = .{},
    exec_out: std.ArrayListUnmanaged(u8) = .empty,
    exec_err: std.ArrayListUnmanaged(u8) = .empty,

    /// Line-buffer bound. Sized so a full guest-exec-status response
    /// fits: qemu-ga caps each captured stream at 16 MiB by default,
    /// which is ~21.4 MiB once base64-encoded. Grown on demand, never
    /// preallocated, so ordinary responses cost nothing extra.
    pub const LINE_MAX: usize = 24 * 1024 * 1024;
    const parse_scratch_bytes = 8 * 1024;
    pub const WatchedRequest = struct {
        id: u64,
    };

    pub const ExecStatus = struct {
        exited: bool = false,
        exit_code: ?i64 = null,
        signal: ?i64 = null,
        out_truncated: bool = false,
        err_truncated: bool = false,
    };

    pub const ExecResult = struct {
        status: ExecStatus,
        out: []const u8,
        err: []const u8,
    };

    pub fn init(alloc: Allocator, sender: Send) Qga {
        return .{ .alloc = alloc, .sender = sender };
    }

    pub fn deinit(self: *Qga) void {
        self.line_buf.deinit(self.alloc);
        self.guest_ips.deinit(self.alloc);
        self.exec_out.deinit(self.alloc);
        self.exec_err.deinit(self.alloc);
    }

    fn send(self: *Qga, json: []const u8) void {
        self.sender.call(json);
    }

    /// guest-sync: flushes the guest's parser state; the response echoes
    /// the id, confirming a live agent.
    pub fn sync(self: *Qga, id: i64) void {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "{{\"execute\":\"guest-sync\",\"arguments\":{{\"id\":{d}}}}}\n",
            .{id},
        ) catch return;
        self.send(msg);
    }

    /// guest-ping: liveness probe (empty return on success).
    pub fn ping(self: *Qga) void {
        self.send("{\"execute\":\"guest-ping\"}\n");
    }

    pub fn isConnected(self: *const Qga) bool {
        return self.connected.load(.acquire);
    }

    pub fn watchedResponseReady(self: *const Qga, request: WatchedRequest) bool {
        return self.watched_response_id.load(.acquire) == request.id;
    }

    pub fn watchedResponseFailed(self: *const Qga, request: WatchedRequest) bool {
        if (!self.watchedResponseReady(request)) return false;
        return self.watched_response_error.load(.acquire);
    }

    /// Graceful guest shutdown ("powerdown"), reboot ("reboot") or
    /// halt ("halt"). The agent acks and then systemd powers off — the
    /// machine stops via the existing PSCI SYSTEM_OFF path.
    pub fn shutdown(self: *Qga, mode: []const u8) void {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "{{\"execute\":\"guest-shutdown\",\"arguments\":{{\"mode\":\"{s}\"}}}}\n",
            .{mode},
        ) catch return;
        self.send(msg);
    }

    /// Set the guest's wall clock to `epoch_ns` (host time). Needed after
    /// restore-from-disk; an in-memory pause keeps time correct by itself
    /// (CNTVCT is host-based).
    pub fn setTime(self: *Qga, epoch_ns: i64) void {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "{{\"execute\":\"guest-set-time\",\"arguments\":{{\"time\":{d}}}}}\n",
            .{epoch_ns},
        ) catch return;
        self.send(msg);
    }

    /// Ask for the guest's interfaces; the parsed IPv4 list lands in
    /// guest_ips via feed().
    pub fn queryNetworkInterfaces(self: *Qga) void {
        self.send("{\"execute\":\"guest-network-get-interfaces\"}\n");
    }

    pub fn trimFilesystems(self: *Qga) void {
        self.send("{\"execute\":\"guest-fstrim\"}\n");
    }

    pub fn freezeFilesystems(self: *Qga) WatchedRequest {
        return self.sendWatched("guest-fsfreeze-freeze");
    }

    pub fn thawFilesystems(self: *Qga) WatchedRequest {
        return self.sendWatched("guest-fsfreeze-thaw");
    }

    /// Spawn a program in the guest via guest-exec with output capture.
    /// argv[0] is the program path. The pid arrives in execPid() once
    /// the watched response is ready; poll completion through
    /// execStatusRequest(). The guest must allow the RPC
    /// (automation.enable in the guest module).
    pub fn exec(self: *Qga, argv: []const []const u8) !WatchedRequest {
        if (argv.len == 0) return error.InvalidArgument;
        const request_id = self.next_request_id.fetchAdd(1, .monotonic);
        self.watched_request_id.store(request_id, .release);
        self.exec_pid.store(-1, .release);

        // Serialized through std.json so arbitrary argv bytes (quotes,
        // backslashes, control characters) are escaped correctly.
        const Payload = struct {
            execute: []const u8,
            arguments: struct {
                path: []const u8,
                arg: []const []const u8,
                @"capture-output": bool,
            },
            id: u64,
        };
        const json = try std.json.Stringify.valueAlloc(self.alloc, Payload{
            .execute = "guest-exec",
            .arguments = .{
                .path = argv[0],
                .arg = argv[1..],
                .@"capture-output" = true,
            },
            .id = request_id,
        }, .{});
        defer self.alloc.free(json);
        const line = try std.mem.concat(self.alloc, u8, &.{ json, "\n" });
        defer self.alloc.free(line);
        self.send(line);
        return .{ .id = request_id };
    }

    /// Poll a spawned process; the payload lands in execResult() once
    /// the watched response is ready.
    pub fn execStatusRequest(self: *Qga, pid: i64) WatchedRequest {
        const request_id = self.next_request_id.fetchAdd(1, .monotonic);
        self.watched_request_id.store(request_id, .release);
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "{{\"execute\":\"guest-exec-status\",\"arguments\":{{\"pid\":{d}}},\"id\":{d}}}\n",
            .{ pid, request_id },
        ) catch unreachable;
        self.send(message);
        return .{ .id = request_id };
    }

    pub fn execPid(self: *const Qga) ?i64 {
        const pid = self.exec_pid.load(.acquire);
        return if (pid < 0) null else pid;
    }

    /// Valid only after the corresponding execStatusRequest's watched
    /// response is ready; the slices alias buffers reused by the next
    /// poll — copy before issuing another request.
    pub fn execResult(self: *const Qga) ExecResult {
        return .{
            .status = self.exec_status,
            .out = self.exec_out.items,
            .err = self.exec_err.items,
        };
    }

    /// Feed guest→host bytes (console port output). Called on the vCPU
    /// thread; parses complete newline-terminated JSON responses.
    pub fn feed(self: *Qga, data: []const u8) void {
        var remaining = data;
        while (remaining.len > 0) {
            if (std.mem.indexOfScalar(u8, remaining, '\n')) |newline| {
                if (!self.appendLineSegment(remaining[0..newline])) return;
                self.handleLine(self.line_buf.items);
                self.line_buf.clearRetainingCapacity();
                remaining = remaining[newline + 1 ..];
                continue;
            }
            if (!self.appendLineSegment(remaining)) return;
            return;
        }
    }

    fn appendLineSegment(self: *Qga, data: []const u8) bool {
        std.debug.assert(self.line_buf.items.len <= LINE_MAX);
        const available = LINE_MAX - self.line_buf.items.len;
        if (data.len <= available) {
            self.line_buf.appendSlice(self.alloc, data) catch return false;
            return true;
        }
        for (data) |byte| {
            if (self.line_buf.items.len >= LINE_MAX) {
                // Hostile/corrupt stream: drop the line.
                self.line_buf.clearRetainingCapacity();
            }
            self.line_buf.append(self.alloc, byte) catch return false;
        }
        return true;
    }

    fn handleLine(self: *Qga, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) return;

        var stack_allocator = std.heap.stackFallback(parse_scratch_bytes, self.alloc);
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            stack_allocator.get(),
            trimmed,
            .{},
        ) catch {
            log.debug("unparseable agent line ({} bytes)", .{trimmed.len});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;
        self.connected.store(true, .release);

        if (root.object.get("error")) |err| {
            self.responses_seen += 1;
            if (err == .object) {
                if (err.object.get("desc")) |desc| {
                    if (desc == .string) log.warn("guest agent error: {s}", .{desc.string});
                }
            }
            self.recordWatchedResponse(root, true);
            return;
        }

        if (root.object.get("return")) |ret| {
            self.responses_seen += 1;
            switch (ret) {
                // guest-sync echoes the id.
                .integer => |id| {
                    self.last_sync_id = id;
                    log.info("guest agent sync id={d}", .{id});
                },
                // guest-network-get-interfaces returns an array of interfaces.
                .array => |ifaces| self.parseInterfaces(ifaces),
                // guest-exec / guest-exec-status return objects.
                .object => |obj| self.parseExecObject(obj),
                else => log.debug("guest agent response ok", .{}),
            }
        }

        // Signal readiness only after the payload above is stored, so a
        // waiter that observes the watched id also sees the parsed data.
        self.recordWatchedResponse(root, false);
    }

    /// guest-exec returns {"pid":N}; guest-exec-status returns
    /// {"exited":bool, ...} with optional base64 output streams.
    fn parseExecObject(self: *Qga, obj: std.json.ObjectMap) void {
        if (obj.get("pid")) |pid| {
            if (pid == .integer and pid.integer >= 0) {
                self.exec_pid.store(pid.integer, .release);
            }
            return;
        }
        const exited = obj.get("exited") orelse return;
        if (exited != .bool) return;
        self.exec_status = .{ .exited = exited.bool };
        if (obj.get("exitcode")) |value| {
            if (value == .integer) self.exec_status.exit_code = value.integer;
        }
        if (obj.get("signal")) |value| {
            if (value == .integer) self.exec_status.signal = value.integer;
        }
        if (obj.get("out-truncated")) |value| {
            if (value == .bool) self.exec_status.out_truncated = value.bool;
        }
        if (obj.get("err-truncated")) |value| {
            if (value == .bool) self.exec_status.err_truncated = value.bool;
        }
        self.decodeExecData(obj, "out-data", &self.exec_out);
        self.decodeExecData(obj, "err-data", &self.exec_err);
    }

    fn decodeExecData(
        self: *Qga,
        obj: std.json.ObjectMap,
        field: []const u8,
        dst: *std.ArrayListUnmanaged(u8),
    ) void {
        dst.clearRetainingCapacity();
        const value = obj.get(field) orelse return;
        if (value != .string) return;
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(value.string) catch return;
        dst.resize(self.alloc, size) catch return;
        decoder.decode(dst.items, value.string) catch {
            dst.clearRetainingCapacity();
        };
    }

    fn sendWatched(self: *Qga, command: []const u8) WatchedRequest {
        const request_id = self.next_request_id.fetchAdd(1, .monotonic);
        self.watched_request_id.store(request_id, .release);
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "{{\"execute\":\"{s}\",\"id\":{}}}\n",
            .{ command, request_id },
        ) catch unreachable;
        self.send(message);
        return .{ .id = request_id };
    }

    fn recordWatchedResponse(self: *Qga, root: std.json.Value, failed: bool) void {
        const id_value = root.object.get("id") orelse return;
        if (id_value != .integer or id_value.integer < 0) return;
        const request_id: u64 = @intCast(id_value.integer);
        if (self.watched_request_id.load(.acquire) != request_id) return;
        self.watched_response_error.store(failed, .release);
        self.watched_response_id.store(request_id, .release);
    }

    fn parseInterfaces(self: *Qga, ifaces: std.json.Array) void {
        self.guest_ips.clearRetainingCapacity();
        for (ifaces.items) |iface| {
            if (iface != .object) continue;
            if (iface.object.get("name")) |name| {
                if (name == .string and std.mem.eql(u8, name.string, "lo")) continue;
            }
            const addrs = iface.object.get("ip-addresses") orelse continue;
            if (addrs != .array) continue;
            for (addrs.array.items) |addr| {
                if (addr != .object) continue;
                const kind = addr.object.get("ip-address-type") orelse continue;
                if (kind != .string or !std.mem.eql(u8, kind.string, "ipv4")) continue;
                const ip = addr.object.get("ip-address") orelse continue;
                if (ip != .string) continue;
                if (self.guest_ips.items.len > 0) {
                    self.guest_ips.append(self.alloc, ',') catch return;
                }
                self.guest_ips.appendSlice(self.alloc, ip.string) catch return;
            }
        }
        if (self.guest_ips.items.len > 0) {
            log.info("guest ips: {s}", .{self.guest_ips.items});
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

test "qga: commands serialize as newline-delimited JSON" {
    defer {
        test_sent.deinit(testing.allocator);
        test_sent = .empty;
        test_send_calls = 0;
    }
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();

    qga.sync(42);
    qga.shutdown("powerdown");
    qga.setTime(1_700_000_000_000_000_000);
    qga.trimFilesystems();
    _ = qga.freezeFilesystems();
    _ = qga.thawFilesystems();

    const expected =
        "{\"execute\":\"guest-sync\",\"arguments\":{\"id\":42}}\n" ++
        "{\"execute\":\"guest-shutdown\",\"arguments\":{\"mode\":\"powerdown\"}}\n" ++
        "{\"execute\":\"guest-set-time\",\"arguments\":{\"time\":1700000000000000000}}\n" ++
        "{\"execute\":\"guest-fstrim\"}\n" ++
        "{\"execute\":\"guest-fsfreeze-freeze\",\"id\":1}\n" ++
        "{\"execute\":\"guest-fsfreeze-thaw\",\"id\":2}\n";
    try testing.expectEqualStrings(expected, test_sent.items);
    try testing.expectEqual(@as(usize, 6), test_send_calls);
}

test "qga: watched requests ignore unrelated responses" {
    defer {
        test_sent.deinit(testing.allocator);
        test_sent = .empty;
        test_send_calls = 0;
    }
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();
    test_sent.clearRetainingCapacity();
    const request = qga.freezeFilesystems();

    qga.feed("{\"return\":{},\"id\":99}\n");
    try testing.expect(!qga.watchedResponseReady(request));
    qga.feed("{\"return\":{},\"id\":1}\n");
    try testing.expect(qga.watchedResponseReady(request));
    try testing.expect(!qga.watchedResponseFailed(request));
}

test "qga: feed parses split responses and sync ids" {
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();

    // Response arrives split across feeds, plus a trailing partial line.
    qga.feed("{\"return\"");
    qga.feed(": 42}\n{\"return\": {}}\n{\"ret");
    try testing.expectEqual(@as(u64, 2), qga.responses_seen);
    try testing.expectEqual(@as(i64, 42), qga.last_sync_id.?);
    qga.feed("urn\": 7}\n");
    try testing.expectEqual(@as(u64, 3), qga.responses_seen);
    try testing.expectEqual(@as(i64, 7), qga.last_sync_id.?);
    try testing.expect(qga.isConnected());

    // Garbage lines don't count or crash.
    qga.feed("not json at all\n");
    try testing.expectEqual(@as(u64, 3), qga.responses_seen);
}

test "qga: partial line assembly allocation profile" {
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    var qga = Qga.init(counted.allocator(), Send.initRaw(testSend, null));
    defer qga.deinit();
    var input: [1024]u8 = @splat('x');

    qga.feed(&input);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(@as(usize, 1664), counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);
    try testing.expectEqual(input.len, qga.line_buf.items.len);
}

test "qga: sync response JSON parse allocation profile" {
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();
    try qga.line_buf.ensureTotalCapacity(testing.allocator, 64);
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    qga.alloc = counted.allocator();

    qga.feed("{\"return\":42}\n");
    qga.alloc = testing.allocator;
    try testing.expectEqual(@as(usize, 0), counted.allocations);
    try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), counted.resize_index);
    try testing.expectEqual(@as(i64, 42), qga.last_sync_id.?);
}

test "qga: guest-exec serializes argv with JSON escaping" {
    defer {
        test_sent.deinit(testing.allocator);
        test_sent = .empty;
        test_send_calls = 0;
    }
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();

    _ = try qga.exec(&.{ "/bin/sh", "-c", "echo \"hi\"" });
    const expected =
        "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\"," ++
        "\"arg\":[\"-c\",\"echo \\\"hi\\\"\"],\"capture-output\":true},\"id\":1}\n";
    try testing.expectEqualStrings(expected, test_sent.items);
}

test "qga: guest-exec pid and status round-trip" {
    defer {
        test_sent.deinit(testing.allocator);
        test_sent = .empty;
        test_send_calls = 0;
    }
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();

    const spawn = try qga.exec(&.{"/bin/true"});
    try testing.expectEqual(@as(?i64, null), qga.execPid());
    qga.feed("{\"return\":{\"pid\":123},\"id\":1}\n");
    try testing.expect(qga.watchedResponseReady(spawn));
    try testing.expect(!qga.watchedResponseFailed(spawn));
    try testing.expectEqual(@as(i64, 123), qga.execPid().?);

    // Still-running poll: exited=false, no output.
    const running = qga.execStatusRequest(123);
    qga.feed("{\"return\":{\"exited\":false},\"id\":2}\n");
    try testing.expect(qga.watchedResponseReady(running));
    try testing.expect(!qga.execResult().status.exited);

    // Completed poll: exit code plus base64 stdout/stderr and a
    // truncation flag ("hello\n" / "boom").
    const done = qga.execStatusRequest(123);
    qga.feed("{\"return\":{\"exited\":true,\"exitcode\":2," ++
        "\"out-data\":\"aGVsbG8K\",\"err-data\":\"Ym9vbQ==\"," ++
        "\"out-truncated\":true},\"id\":3}\n");
    try testing.expect(qga.watchedResponseReady(done));
    const result = qga.execResult();
    try testing.expect(result.status.exited);
    try testing.expectEqual(@as(i64, 2), result.status.exit_code.?);
    try testing.expectEqual(@as(?i64, null), result.status.signal);
    try testing.expect(result.status.out_truncated);
    try testing.expect(!result.status.err_truncated);
    try testing.expectEqualStrings("hello\n", result.out);
    try testing.expectEqualStrings("boom", result.err);
}

test "qga: guest-exec rejects an empty argv and bad base64" {
    defer {
        test_sent.deinit(testing.allocator);
        test_sent = .empty;
        test_send_calls = 0;
    }
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();

    try testing.expectError(error.InvalidArgument, qga.exec(&.{}));

    _ = qga.execStatusRequest(5);
    qga.feed("{\"return\":{\"exited\":true,\"exitcode\":0," ++
        "\"out-data\":\"@@not base64@@\"},\"id\":1}\n");
    // Undecodable output is dropped rather than half-written.
    try testing.expect(qga.execResult().status.exited);
    try testing.expectEqualStrings("", qga.execResult().out);
}

test "qga: guest-network-get-interfaces parses ipv4 addresses" {
    var qga = Qga.init(testing.allocator, Send.initRaw(testSend, null));
    defer qga.deinit();

    qga.feed("{\"return\": [" ++
        "{\"name\": \"lo\", \"ip-addresses\": [{\"ip-address-type\": \"ipv4\", \"ip-address\": \"127.0.0.1\"}]}," ++
        "{\"name\": \"eth0\", \"ip-addresses\": [" ++
        "{\"ip-address-type\": \"ipv6\", \"ip-address\": \"fe80::1\"}," ++
        "{\"ip-address-type\": \"ipv4\", \"ip-address\": \"10.0.2.15\"}]}" ++
        "]}\n");
    try testing.expectEqualStrings("10.0.2.15", qga.guest_ips.items);
}
