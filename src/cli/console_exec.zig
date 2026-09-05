//! Run a command in a guest over its interactive console, with no
//! guest agent required.
//!
//! Scripts are encoded for a separate shell with stdin disconnected. The outer
//! console shell emits the exit marker, so script syntax cannot swallow it.
//! Both in-process sessions and MCP child pipes share encoding and matching.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const machine = @import("../machine/main.zig");
const thread_compat = @import("../compat/thread.zig");

const log = std.log.scoped(.cli);

pub const MARKER_PREFIX = "__BRVM_";

pub const MarkerHit = struct {
    /// Offset in the window where the marker line begins (captured
    /// output ends here).
    start: usize,
    exit_code: i64,
};

pub const Transport = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, data: []const u8) void,
    wait_ready: *const fn (context: *anyopaque, timeout_ns: u64) bool,
};

/// A random nonce avoids collisions with script text and output from older calls.
pub fn markerText(buf: []u8, nonce: [16]u8) []const u8 {
    return std.fmt.bufPrint(buf, MARKER_PREFIX ++ "{s}_RC_", .{
        std.fmt.bytesToHex(nonce, .lower),
    }) catch unreachable;
}

/// Bound both source bytes and the encoded line for small interactive shells.
pub const COMMAND_BYTES_MAX: usize = 768;
const COMMAND_LINE_BYTES_MAX: usize = 1023;

/// The outer shell owns both output fences. Quote printable script bytes as
/// data, and encode control bytes so tty editing cannot interpret them.
pub fn commandLine(
    alloc: Allocator,
    command: []const u8,
    marker: []const u8,
) error{ CommandTooLong, InvalidCommand, OutOfMemory }![]u8 {
    if (command.len > COMMAND_BYTES_MAX) return error.CommandTooLong;
    if (std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidCommand;
    var encoded: [COMMAND_BYTES_MAX * 5]u8 = undefined;
    var length: usize = 0;
    for (command) |byte| {
        if (byte == '\\' or byte == '\'') {
            const escaped = if (byte == '\\') "\\\\" else "'\\''";
            @memcpy(encoded[length..][0..escaped.len], escaped);
            length += escaped.len;
        } else if (byte >= 0x20 and byte <= 0x7e) {
            encoded[length] = byte;
            length += 1;
        } else {
            encoded[length..][0..5].* = .{
                '\\', '0', '0' + (byte >> 6), '0' + ((byte >> 3) & 7), '0' + (byte & 7),
            };
            length += 5;
        }
    }
    const format = "printf '\\036{s}BEGIN\\037'; " ++
        "sh -c \"$(printf '%b' '{s}')\" </dev/null; echo {s}$?\n";
    const line = try std.fmt.allocPrint(alloc, format, .{ marker, encoded[0..length], marker });
    if (line.len > COMMAND_LINE_BYTES_MAX) {
        alloc.free(line);
        return error.CommandTooLong;
    }
    return line;
}

/// Find a complete marker and shell exit status terminated by CR or LF. The command echo
/// carries the marker with a literal "$?" and so does not match.
pub fn findMarker(window: []const u8, marker_text: []const u8) ?MarkerHit {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, window, search, marker_text)) |idx| {
        const tail = window[idx + marker_text.len ..];
        var digits: usize = 0;
        while (digits < tail.len and std.ascii.isDigit(tail[digits])) digits += 1;
        if (digits > 0 and digits < tail.len and
            (tail[digits] == '\r' or tail[digits] == '\n'))
        {
            const exit_code = std.fmt.parseInt(u8, tail[0..digits], 10) catch {
                search = idx + marker_text.len + digits;
                continue;
            };
            return .{ .start = idx, .exit_code = exit_code };
        }
        search = idx + 1;
    }
    return null;
}

/// Drop everything through the emitted begin fence, including wrapped tty
/// echoes and restored prompts. The injected line contains escaped controls,
/// so only the executed printf can produce this fence.
pub fn stripCommandEcho(output: []const u8, marker_text: []const u8) []const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, output, search, marker_text)) |marker| {
        const end = marker + marker_text.len;
        if (marker > 0 and output[marker - 1] == '\x1e' and
            std.mem.startsWith(u8, output[end..], "BEGIN\x1f"))
            return output[end + "BEGIN\x1f".len ..];
        search = end;
    }
    return output;
}

/// An in-process console-exec session over one Machine: buffers the
/// guest console and runs marker-delimited commands against it. The
/// Machine must already be running with its console output routed here
/// via bind().
pub const Session = struct {
    alloc: Allocator,
    transport: Transport,
    mutex: std.Io.Mutex = .init,
    output_cond: std.Io.Condition = .init,
    output: std.ArrayListUnmanaged(u8) = .empty,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(alloc: Allocator, hw: *machine.Machine) Session {
        return initTransport(alloc, .{
            .context = hw,
            .write = machineWrite,
            .wait_ready = machineWaitReady,
        });
    }

    pub fn initTransport(alloc: Allocator, transport: Transport) Session {
        return .{ .alloc = alloc, .transport = transport };
    }

    pub fn deinit(self: *Session) void {
        self.output.deinit(self.alloc);
    }

    pub fn cancel(self: *Session) void {
        self.cancelled.store(true, .release);
        const io = global.io();
        self.mutex.lockUncancelable(io);
        self.output_cond.broadcast(io);
        self.mutex.unlock(io);
    }

    /// Route a Machine's console output into this session. Pass the
    /// session pointer as the Machine's console userdata.
    pub fn sink(data: []const u8, userdata: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(userdata orelse return));
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.output.appendSlice(self.alloc, data) catch return;
        self.output_cond.signal(io);
    }

    pub const Result = struct {
        exit_code: i64,
        /// Captured output; owned by the caller.
        output: []u8,
    };

    /// Run one command and wait for completion. The returned output is
    /// allocated from `alloc` and owned by the caller.
    pub fn run(
        self: *Session,
        alloc: Allocator,
        command: []const u8,
        timeout_ms: u32,
    ) !Result {
        const io = global.io();
        var marker_buf: [48]u8 = undefined;
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const marker = markerText(&marker_buf, nonce);

        const line = try commandLine(alloc, command, marker);
        defer alloc.free(line);

        if (self.cancelled.load(.acquire)) return error.ExecCancelled;

        self.mutex.lockUncancelable(io);
        const start_pos = self.output.items.len;
        self.mutex.unlock(io);

        self.transport.write(self.transport.context, line);

        const timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
        const deadline_ns = monotonicNs() +| timeout_ns;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.cancelled.load(.acquire)) return error.ExecCancelled;
            const window = self.output.items[@min(start_pos, self.output.items.len)..];
            const hit = findMarker(window, marker);
            if (hit) |result| {
                const captured = try alloc.dupe(
                    u8,
                    stripCommandEcho(window[0..result.start], marker),
                );
                return .{ .exit_code = result.exit_code, .output = captured };
            }
            const now_ns = monotonicNs();
            if (now_ns >= deadline_ns) return error.ExecTimeout;
            thread_compat.waitTimeout(&self.output_cond, io, &self.mutex, .{
                .duration = .{
                    .raw = .{ .nanoseconds = deadline_ns - now_ns },
                    .clock = .awake,
                },
            }) catch |err| switch (err) {
                error.Timeout => return error.ExecTimeout,
                else => return err,
            };
        }
    }

    /// Wait until startup and restore are complete, then round-trip a shell
    /// command. The durable machine notification prevents the probe from
    /// being overwritten by restore. Returns false on timeout or startup
    /// failure.
    pub fn waitForPrompt(
        self: *Session,
        alloc: Allocator,
        timeout_ms: u32,
        mode: enum { boot, restored },
    ) bool {
        if (self.cancelled.load(.acquire)) return false;
        const timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
        const deadline_ns = monotonicNs() +| timeout_ns;
        if (!self.transport.wait_ready(self.transport.context, timeout_ns)) return false;
        // A restored idle shell may emit nothing until it receives input.
        if (mode == .boot and !self.waitForShellHint(deadline_ns)) return false;

        const now_ns = monotonicNs();
        if (now_ns >= deadline_ns) return false;
        const remaining_ms: u32 = @intCast(@min(
            @divTrunc(deadline_ns - now_ns, std.time.ns_per_ms) + 1,
            std.math.maxInt(u32),
        ));
        const probe = self.run(alloc, "true", remaining_ms) catch return false;
        alloc.free(probe.output);
        return true;
    }

    fn waitForShellHint(self: *Session, deadline_ns: u64) bool {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.cancelled.load(.acquire)) return false;
            if (hasShellHint(self.output.items)) return true;
            const now_ns = monotonicNs();
            if (now_ns >= deadline_ns) return false;
            thread_compat.waitTimeout(&self.output_cond, io, &self.mutex, .{
                .duration = .{
                    .raw = .{ .nanoseconds = deadline_ns - now_ns },
                    .clock = .awake,
                },
            }) catch |err| switch (err) {
                error.Timeout => return false,
                else => return false,
            };
        }
    }

    fn machineWrite(context: *anyopaque, data: []const u8) void {
        const hw: *machine.Machine = @ptrCast(@alignCast(context));
        hw.injectConsoleInput(data);
    }

    fn machineWaitReady(context: *anyopaque, timeout_ns: u64) bool {
        const hw: *machine.Machine = @ptrCast(@alignCast(context));
        return hw.waitUntilRunning(timeout_ns);
    }
};

/// Run first-boot provisioning commands in order over a console session.
pub fn provision(session: *Session, steps: []const []const u8) void {
    if (!session.waitForPrompt(session.alloc, 60_000, .boot)) {
        log.err("provisioning: guest did not reach a shell prompt", .{});
        return;
    }
    for (steps, 0..) |step, index| {
        const result = session.run(session.alloc, step, 300_000) catch |err| {
            log.err("provision step {d} ({s}) failed: {}", .{ index + 1, step, err });
            return;
        };
        defer session.alloc.free(result.output);
        if (result.exit_code != 0) {
            log.err("provision step {d}/{d} exit {d}: {s}", .{
                index + 1,
                steps.len,
                result.exit_code,
                step,
            });
            return;
        }
        log.info("provision step {d}/{d} ok: {s}", .{ index + 1, steps.len, step });
    }
    log.info("provisioning complete ({d} steps)", .{steps.len});
}

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

fn hasShellHint(output: []const u8) bool {
    const hints = [_][]const u8{ "\x1b[6n", "\n~ # ", "\n# ", "\n$ " };
    for (hints) |hint| {
        if (std.mem.indexOf(u8, output, hint) != null) return true;
    }
    return false;
}

const testing = std.testing;

test "console_exec: marker matches digits but not the command echo" {
    var buf: [48]u8 = undefined;
    const generated = markerText(&buf, @splat(7));
    try testing.expectEqualStrings("__BRVM_07070707070707070707070707070707_RC_", generated);
    const marker = "__BRVM_7_RC_";

    // The echoed command carries the marker with a literal $?.
    const echo_only = "run me ; echo __BRVM_7_RC_$?\r\n";
    try testing.expect(findMarker(echo_only, marker) == null);

    const done = "run me ; echo __BRVM_7_RC_$?\r\n" ++
        "\x1e__BRVM_7_RC_BEGIN\x1fhello\r\n__BRVM_7_RC_2\r\n";
    const hit = findMarker(done, marker).?;
    try testing.expectEqual(@as(i64, 2), hit.exit_code);
    try testing.expectEqualStrings("hello\r\n", stripCommandEcho(done[0..hit.start], marker));

    const prompted = "\r\n~ # " ++ done;
    const prompted_hit = findMarker(prompted, marker).?;
    try testing.expectEqualStrings(
        "hello\r\n",
        stripCommandEcho(prompted[0..prompted_hit.start], marker),
    );

    const duplicate_echo = "run me ; echo __BRVM_7_RC_$?\r\n~ # " ++ done;
    const duplicate_hit = findMarker(duplicate_echo, marker).?;
    try testing.expectEqualStrings(
        "hello\r\n",
        stripCommandEcho(duplicate_echo[0..duplicate_hit.start], marker),
    );
}

test "console_exec: shell hints require a prompt or cursor query" {
    try testing.expect(!hasShellHint("booting\nStarting Docker"));
    try testing.expect(hasShellHint("\r\n~ # \x1b[6n"));
    try testing.expect(hasShellHint("\n# "));
}

test "console_exec: completion waits for the entire exit status" {
    const marker = "__BRVM_7_RC_";
    const complete = marker ++ "127\r\n";
    for (0..complete.len - 1) |length| {
        try testing.expect(findMarker(complete[0..length], marker) == null);
    }
    try testing.expectEqual(@as(i64, 127), findMarker(complete, marker).?.exit_code);
    try testing.expect(findMarker(marker ++ "999999999999999999999999\n", marker) == null);
    try testing.expect(findMarker(marker ++ "2garbage\n", marker) == null);
    try testing.expectEqual(@as(i64, 0), findMarker(marker ++ "999\n" ++ marker ++ "0\n", marker).?.exit_code);
}

test "console_exec: scripts are data and console lines are bounded" {
    const script = "echo 'quoted'\nexit 7 # trailing comment\t\\";
    const line = try commandLine(testing.allocator, script, "__BRVM_1_RC_");
    defer testing.allocator.free(line);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    try testing.expect(std.mem.indexOf(u8, line, script) == null);
    try testing.expect(std.mem.endsWith(u8, line, "</dev/null; echo __BRVM_1_RC_$?\n"));
    const longest = try commandLine(
        testing.allocator,
        &(@as([COMMAND_BYTES_MAX]u8, @splat('x'))),
        "__BRVM_4294967295_RC_",
    );
    defer testing.allocator.free(longest);
    try testing.expect(longest.len <= COMMAND_LINE_BYTES_MAX);
    try testing.expectError(error.InvalidCommand, commandLine(testing.allocator, "a\x00b", "m"));
    try testing.expectError(error.CommandTooLong, commandLine(
        testing.allocator,
        &(@as([COMMAND_BYTES_MAX + 1]u8, @splat('x'))),
        "m",
    ));
}
