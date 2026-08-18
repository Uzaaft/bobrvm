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

const log = std.log.scoped(.cli);

pub const MARKER_PREFIX = "__BRVM_";

pub const MarkerHit = struct {
    /// Offset in the window where the marker line begins (captured
    /// output ends here).
    start: usize,
    exit_code: i64,
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

/// Drop the leading tty echo of the injected command (the first line,
/// which carries the marker prefix with a literal "$?").
pub fn stripCommandEcho(output: []const u8) []const u8 {
    const newline = std.mem.indexOfScalar(u8, output, '\n') orelse return output;
    if (std.mem.indexOf(u8, output[0..newline], MARKER_PREFIX) != null) {
        return output[newline + 1 ..];
    }
    return output;
}

/// An in-process console-exec session over one Machine: buffers the
/// guest console and runs marker-delimited commands against it. The
/// Machine must already be running with its console output routed here
/// via bind().
pub const Session = struct {
    alloc: Allocator,
    hw: *machine.Machine,
    mutex: std.Io.Mutex = .init,
    output: std.ArrayListUnmanaged(u8) = .empty,
    next_seq: u32 = 1,

    pub fn init(alloc: Allocator, hw: *machine.Machine) Session {
        return .{ .alloc = alloc, .hw = hw };
    }

    pub fn deinit(self: *Session) void {
        self.output.deinit(self.alloc);
    }

    /// Route a Machine's console output into this session. Pass the
    /// session pointer as the Machine's console userdata.
    pub fn sink(data: []const u8, userdata: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(userdata orelse return));
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.output.appendSlice(self.alloc, data) catch return;
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

        self.mutex.lockUncancelable(io);
        const start_pos = self.output.items.len;
        self.mutex.unlock(io);

        self.hw.injectConsoleInput(line);

        var waited_ms: u32 = 0;
        while (true) {
            self.mutex.lockUncancelable(io);
            const window = self.output.items[@min(start_pos, self.output.items.len)..];
            const hit = findMarker(window, marker);
            if (hit) |result| {
                const captured = try alloc.dupe(u8, stripCommandEcho(window[0..result.start]));
                self.mutex.unlock(io);
                return .{ .exit_code = result.exit_code, .output = captured };
            }
            self.mutex.unlock(io);
            if (waited_ms >= timeout_ms) return error.ExecTimeout;
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
                .clock = .awake,
            }, io) catch {};
            waited_ms += 10;
        }
    }

    /// Wait until the guest shell round-trips a command, so exec and
    /// provisioning do not race the boot. Re-probes on a short cadence:
    /// a single injection can be lost if it lands mid-restore (restore
    /// overwrites the console's receive queue), so one long wait would
    /// hang forever. Returns false on timeout.
    pub fn waitForPrompt(self: *Session, alloc: Allocator, timeout_ms: u32) bool {
        var waited_ms: u32 = 0;
        while (waited_ms < timeout_ms) : (waited_ms += 500) {
            if (self.run(alloc, "true", 500)) |probe| {
                alloc.free(probe.output);
                return true;
            } else |_| {}
        }
        return false;
    }
};

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
    try testing.expectEqualStrings("hello\r\n", stripCommandEcho(done[0..hit.start]));
}
