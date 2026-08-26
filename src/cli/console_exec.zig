//! Run a command in a guest over its interactive console, with no
//! guest agent required.
//!
//! The command line is injected into the shell on hvc0 followed by an
//! `echo` of a unique completion marker carrying the exit code;
//! capture ends when the marker followed by digits appears. The tty
//! echo of the injected line carries the marker with a literal "$?",
//! which is deliberately not matched. Both `bobrvm exec` (in-process)
//! and the MCP server (across a child pipe) share this matcher.

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

/// Format the completion marker for a given sequence number into `buf`.
pub fn markerText(buf: []u8, seq: u32) []const u8 {
    return std.fmt.bufPrint(buf, MARKER_PREFIX ++ "{d}_RC_", .{seq}) catch unreachable;
}

/// Find `marker_text` followed by at least one digit. The command echo
/// carries the marker with a literal "$?" and so does not match.
pub fn findMarker(window: []const u8, marker_text: []const u8) ?MarkerHit {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, window, search, marker_text)) |idx| {
        const tail = window[idx + marker_text.len ..];
        var digits: usize = 0;
        while (digits < tail.len and std.ascii.isDigit(tail[digits])) digits += 1;
        if (digits > 0) {
            const exit_code = std.fmt.parseInt(i64, tail[0..digits], 10) catch 0;
            return .{ .start = idx, .exit_code = exit_code };
        }
        search = idx + 1;
    }
    return null;
}

/// Drop the tty echo through the line carrying `marker_text$?`. A restored
/// shell may print a prompt immediately before that echo, so the marker is a
/// more reliable boundary than the first line.
pub fn stripCommandEcho(output: []const u8, marker_text: []const u8) []const u8 {
    var content_start: ?usize = null;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, output, search, marker_text)) |marker| {
        const suffix_start = marker + marker_text.len;
        const suffix = output[suffix_start..];
        if (std.mem.startsWith(u8, suffix, "$?")) {
            if (std.mem.indexOfScalar(u8, suffix[2..], '\n')) |newline| {
                content_start = suffix_start + 2 + newline + 1;
            }
        }
        search = marker + 1;
    }
    return if (content_start) |start| output[start..] else output;
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
    next_seq: u32 = 1,
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
        const marker = markerText(&marker_buf, self.next_seq);
        self.next_seq += 1;

        const line = try std.fmt.allocPrint(alloc, "{s} ; echo {s}$?\n", .{ command, marker });
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
    pub fn waitForPrompt(self: *Session, alloc: Allocator, timeout_ms: u32) bool {
        if (self.cancelled.load(.acquire)) return false;
        const timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
        const deadline_ns = monotonicNs() +| timeout_ns;
        if (!self.transport.wait_ready(self.transport.context, timeout_ns)) return false;
        if (!self.waitForShellHint(deadline_ns)) return false;

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
    if (!session.waitForPrompt(session.alloc, 60_000)) {
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
    const marker = markerText(&buf, 7);
    try testing.expectEqualStrings("__BRVM_7_RC_", marker);

    // The echoed command carries the marker with a literal $?.
    const echo_only = "run me ; echo __BRVM_7_RC_$?\r\n";
    try testing.expect(findMarker(echo_only, marker) == null);

    const done = "run me ; echo __BRVM_7_RC_$?\r\nhello\r\n__BRVM_7_RC_2\r\n";
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
