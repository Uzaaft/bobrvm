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

const log = std.log.scoped(.qga);

pub const SendFn = *const fn (data: []const u8, userdata: ?*anyopaque) void;

pub const Qga = struct {
    alloc: Allocator,
    send_fn: SendFn,
    send_userdata: ?*anyopaque,

    /// Partial-line assembly for guest→host responses.
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Latest response outcomes (observability + tests).
    responses_seen: u64 = 0,
    last_sync_id: ?i64 = null,
    /// Guest IPv4 addresses reported by guest-network-get-interfaces
    /// (comma-separated, lo excluded).
    guest_ips: std.ArrayListUnmanaged(u8) = .empty,

    pub const LINE_MAX: usize = 64 * 1024;

    pub fn init(alloc: Allocator, send_fn: SendFn, userdata: ?*anyopaque) Qga {
        return .{ .alloc = alloc, .send_fn = send_fn, .send_userdata = userdata };
    }

    pub fn deinit(self: *Qga) void {
        self.line_buf.deinit(self.alloc);
        self.guest_ips.deinit(self.alloc);
    }

    fn send(self: *Qga, json: []const u8) void {
        self.send_fn(json, self.send_userdata);
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

    /// Feed guest→host bytes (console port output). Called on the vCPU
    /// thread; parses complete newline-terminated JSON responses.
    pub fn feed(self: *Qga, data: []const u8) void {
        for (data) |byte| {
            if (byte == '\n') {
                self.handleLine(self.line_buf.items);
                self.line_buf.clearRetainingCapacity();
                continue;
            }
            if (self.line_buf.items.len >= LINE_MAX) {
                // Hostile/corrupt stream: drop the line.
                self.line_buf.clearRetainingCapacity();
                continue;
            }
            self.line_buf.append(self.alloc, byte) catch return;
        }
    }

    fn handleLine(self: *Qga, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) return;

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, trimmed, .{}) catch {
            log.debug("unparseable agent line ({} bytes)", .{trimmed.len});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        if (root.object.get("error")) |err| {
            self.responses_seen += 1;
            if (err == .object) {
                if (err.object.get("desc")) |desc| {
                    if (desc == .string) log.warn("guest agent error: {s}", .{desc.string});
                }
            }
            return;
        }

        const ret = root.object.get("return") orelse return;
        self.responses_seen += 1;

        switch (ret) {
            // guest-sync echoes the id.
            .integer => |id| {
                self.last_sync_id = id;
                log.info("guest agent sync id={d}", .{id});
            },
            // guest-network-get-interfaces returns an array of interfaces.
            .array => |ifaces| self.parseInterfaces(ifaces),
            else => log.debug("guest agent response ok", .{}),
        }
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

// =============================================================================
// Tests
// =============================================================================

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
    var qga = Qga.init(testing.allocator, testSend, null);
    defer qga.deinit();

    qga.sync(42);
    qga.shutdown("powerdown");
    qga.setTime(1_700_000_000_000_000_000);

    const expected =
        "{\"execute\":\"guest-sync\",\"arguments\":{\"id\":42}}\n" ++
        "{\"execute\":\"guest-shutdown\",\"arguments\":{\"mode\":\"powerdown\"}}\n" ++
        "{\"execute\":\"guest-set-time\",\"arguments\":{\"time\":1700000000000000000}}\n";
    try testing.expectEqualStrings(expected, test_sent.items);
    try testing.expectEqual(@as(usize, 3), test_send_calls);
}

test "qga: feed parses split responses and sync ids" {
    var qga = Qga.init(testing.allocator, testSend, null);
    defer qga.deinit();

    // Response arrives split across feeds, plus a trailing partial line.
    qga.feed("{\"return\"");
    qga.feed(": 42}\n{\"return\": {}}\n{\"ret");
    try testing.expectEqual(@as(u64, 2), qga.responses_seen);
    try testing.expectEqual(@as(i64, 42), qga.last_sync_id.?);
    qga.feed("urn\": 7}\n");
    try testing.expectEqual(@as(u64, 3), qga.responses_seen);
    try testing.expectEqual(@as(i64, 7), qga.last_sync_id.?);

    // Garbage lines don't count or crash.
    qga.feed("not json at all\n");
    try testing.expectEqual(@as(u64, 3), qga.responses_seen);
}

test "qga: guest-network-get-interfaces parses ipv4 addresses" {
    var qga = Qga.init(testing.allocator, testSend, null);
    defer qga.deinit();

    qga.feed("{\"return\": [" ++
        "{\"name\": \"lo\", \"ip-addresses\": [{\"ip-address-type\": \"ipv4\", \"ip-address\": \"127.0.0.1\"}]}," ++
        "{\"name\": \"eth0\", \"ip-addresses\": [" ++
        "{\"ip-address-type\": \"ipv6\", \"ip-address\": \"fe80::1\"}," ++
        "{\"ip-address-type\": \"ipv4\", \"ip-address\": \"10.0.2.15\"}]}" ++
        "]}\n");
    try testing.expectEqualStrings("10.0.2.15", qga.guest_ips.items);
}
