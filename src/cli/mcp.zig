//! `bobrvm mcp` - Model Context Protocol server exposing disposable
//! guest sandboxes.
//!
//! Speaks MCP's stdio transport (one JSON-RPC 2.0 message per line).
//! Each sandbox is a fork of the project's warm state hosted in this
//! process: an agent starts one, runs commands in it, reads output,
//! and destroys it — the project's warm image and disks are never
//! touched.
//!
//! Scripts run in a separate shell over the guest console. Cancellation and
//! timeout discard the entire sandbox so descendants cannot outlive the call.
//! Host networking and shared-folder access are denied before restoring the VM.

const std = @import("std");
const Allocator = std.mem.Allocator;

const console_exec = @import("console_exec.zig");
const global = @import("../global.zig");
const fork = @import("fork.zig");
const project = @import("project.zig");
const thread_compat = @import("../compat/thread.zig");

const log = std.log.scoped(.mcp);

const LINE_MAX: usize = 256 * 1024;
/// Per-sandbox console history cap; the oldest bytes fall off.
const OUTPUT_CAP: usize = 1024 * 1024;
const EXEC_TIMEOUT_DEFAULT_MS: u32 = 30_000;
const EXEC_TIMEOUT_MAX_MS: u32 = 600_000;
const SANDBOX_MAX: usize = 8;
const READY_MARKER = "\x1eBOBRVM_READY\x1e";

const Sandbox = struct {
    id: u32,
    dir: []const u8 = "",
    alloc: Allocator,
    child: std.process.Child,
    reader_thread: std.Thread,
    out_mutex: std.Io.Mutex = .init,
    out_cond: std.Io.Condition = .init,
    output: std.ArrayListUnmanaged(u8) = .empty,
    output_base: u64 = 0,
    ready: bool = false,
    reader_done: bool = false,

    fn appendOutput(self: *Sandbox, data: []const u8) void {
        const io = global.io();
        self.out_mutex.lockUncancelable(io);
        defer self.out_mutex.unlock(io);
        self.output.appendSlice(self.alloc, data) catch return;
        if (!self.ready) {
            if (std.mem.indexOf(u8, self.output.items, READY_MARKER)) |index| {
                const tail = index + READY_MARKER.len;
                std.mem.copyForwards(u8, self.output.items[index..], self.output.items[tail..]);
                self.output.shrinkRetainingCapacity(
                    self.output.items.len - READY_MARKER.len,
                );
                self.ready = true;
            }
        }
        if (self.output.items.len > OUTPUT_CAP) {
            const drop = self.output.items.len - OUTPUT_CAP;
            std.mem.copyForwards(
                u8,
                self.output.items[0 .. self.output.items.len - drop],
                self.output.items[drop..],
            );
            self.output.shrinkRetainingCapacity(self.output.items.len - drop);
            self.output_base +|= @intCast(drop);
        }
        self.out_cond.signal(io);
    }

    fn finishReader(self: *Sandbox) void {
        const io = global.io();
        self.out_mutex.lockUncancelable(io);
        self.reader_done = true;
        self.out_cond.signal(io);
        self.out_mutex.unlock(io);
    }

    fn waitReady(self: *Sandbox, timeout_ns: u64, cancelled: *const std.atomic.Value(bool)) bool {
        const io = global.io();
        const deadline_ns = monotonicNs() +| timeout_ns;
        self.out_mutex.lockUncancelable(io);
        defer self.out_mutex.unlock(io);
        while (!self.ready) {
            if (cancelled.load(.acquire) or self.reader_done) return false;
            const now_ns = monotonicNs();
            if (now_ns >= deadline_ns) return false;
            thread_compat.waitTimeout(&self.out_cond, io, &self.out_mutex, .{
                .duration = .{
                    .raw = .{ .nanoseconds = @min(deadline_ns - now_ns, 20 * std.time.ns_per_ms) },
                    .clock = .awake,
                },
            }) catch |err| switch (err) {
                error.Timeout => continue,
                else => return false,
            };
        }
        return true;
    }

    fn waitReader(self: *Sandbox, timeout_ns: u64) bool {
        const io = global.io();
        const deadline_ns = monotonicNs() +| timeout_ns;
        self.out_mutex.lockUncancelable(io);
        defer self.out_mutex.unlock(io);
        while (!self.reader_done) {
            const now_ns = monotonicNs();
            if (now_ns >= deadline_ns) return false;
            thread_compat.waitTimeout(&self.out_cond, io, &self.out_mutex, .{
                .duration = .{ .raw = .{ .nanoseconds = deadline_ns - now_ns }, .clock = .awake },
            }) catch return false;
        }
        return true;
    }

    fn outputOffset(self: *const Sandbox) u64 {
        return self.output_base +| @as(u64, @intCast(self.output.items.len));
    }

    fn outputSince(self: *const Sandbox, offset: u64) []const u8 {
        if (offset <= self.output_base) return self.output.items;
        const relative = offset - self.output_base;
        if (relative >= @as(u64, @intCast(self.output.items.len))) return &.{};
        return self.output.items[@intCast(relative)..];
    }
};

/// Drain the child's console (stdout pipe) into the output buffer.
fn sandboxReader(sandbox: *Sandbox, stdout: std.Io.File) void {
    defer sandbox.finishReader();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(stdout.handle, &buf) catch break;
        if (n == 0) break;
        sandbox.appendOutput(buf[0..n]);
    }
}

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

pub const Server = struct {
    alloc: Allocator,
    /// Io used for child-process management. The global single-threaded
    /// Io cannot allocate, and std.process.spawn allocates the argv and
    /// environment blocks through its Io's allocator.
    proc_io: std.Io,
    child_environ: ?*const std.process.Environ.Map = null,
    sandboxes: [SANDBOX_MAX]?*Sandbox = @splat(null),
    next_id: u32 = 1,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(alloc: Allocator, proc_io: std.Io) Server {
        return .{
            .alloc = alloc,
            .proc_io = proc_io,
        };
    }

    pub fn deinit(self: *Server) void {
        for (&self.sandboxes) |*slot| {
            if (slot.*) |sandbox| self.destroySandbox(sandbox);
            slot.* = null;
        }
    }

    /// Reserve the cleanup path before spawning. Neither failed startup nor
    /// forced termination relies on child-side filesystem defers.
    fn reserveForkDir(self: *Server, name: []const u8) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var cwd_buf: [1024]u8 = undefined;
        const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
        const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
        const root = (try project.findRoot(arena.allocator(), cwd)) orelse
            return error.NoProjectFile;
        const proj = try project.load(arena.allocator(), root);
        if (proj.engine != .native) return error.UnsupportedEngine;
        if (!project.fileExists(proj.warm_image)) return error.NoWarmState;
        const forks_dir = try std.fs.path.join(arena.allocator(), &.{ proj.state_dir, "forks" });
        try std.Io.Dir.cwd().createDirPath(global.io(), forks_dir);
        const dir = try std.fs.path.join(self.alloc, &.{ forks_dir, name });
        errdefer self.alloc.free(dir);
        try std.Io.Dir.cwd().createDir(global.io(), dir, .default_dir);
        return dir;
    }

    fn startSandbox(self: *Server) !*Sandbox {
        const slot = for (&self.sandboxes) |*candidate| {
            if (candidate.* == null) break candidate;
        } else return error.TooManySandboxes;
        var random: [16]u8 = undefined;
        self.proc_io.random(&random);
        const fork_name = std.fmt.bytesToHex(random, .lower);
        const dir = try self.reserveForkDir(&fork_name);
        errdefer {
            fork.deleteTree(dir);
            self.alloc.free(dir);
        }

        var exe_buf: [1024]u8 = undefined;
        const exe_len = std.process.executablePath(global.io(), &exe_buf) catch
            return error.Unexpected;
        const exe = exe_buf[0..exe_len];

        const sandbox = try self.alloc.create(Sandbox);
        errdefer self.alloc.destroy(sandbox);
        sandbox.* = .{
            .id = self.next_id,
            .dir = dir,
            .alloc = self.alloc,
            .child = undefined,
            .reader_thread = undefined,
        };
        sandbox.child = std.process.spawn(self.proc_io, .{
            .argv = &.{
                exe,              "fork",       "--isolate-host", "--fork-name", &fork_name,
                "--ready-marker", READY_MARKER,
            },
            .environ_map = self.child_environ,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (std.c.getenv("BOBRVM_MCP_DEBUG") != null) .inherit else .ignore,
        }) catch |err| {
            log.err("sandbox spawn failed: {} ({s} fork)", .{ err, exe });
            return error.Unexpected;
        };
        var reader_started = false;
        errdefer {
            if (sandbox.child.id) |pid| std.posix.kill(pid, .KILL) catch {};
            if (reader_started) sandbox.reader_thread.join();
            _ = sandbox.child.wait(self.proc_io) catch {};
            sandbox.output.deinit(self.alloc);
        }

        sandbox.reader_thread = std.Thread.spawn(.{}, sandboxReader, .{
            sandbox, sandbox.child.stdout.?,
        }) catch return error.Unexpected;
        reader_started = true;
        if (!sandbox.waitReady(30 * std.time.ns_per_s, &self.cancelled)) return error.SandboxNotReady;
        self.next_id += 1;
        slot.* = sandbox;
        return sandbox;
    }

    fn findSandbox(self: *Server, id: u32) ?*Sandbox {
        for (self.sandboxes) |slot| {
            if (slot) |sandbox| {
                if (sandbox.id == id) return sandbox;
            }
        }
        return null;
    }

    fn destroySandbox(self: *Server, sandbox: *Sandbox) void {
        const io = self.proc_io;
        // MCP children treat stdin EOF as a graceful stop. That lets Zig
        // unwind through fork deletion; SIGTERM deliberately exits from its
        // signal handler and cannot run those filesystem defers.
        if (sandbox.child.stdin) |stdin| {
            stdin.close(io);
            sandbox.child.stdin = null;
        }
        if (!sandbox.waitReader(2 * std.time.ns_per_s)) {
            // Child.kill uses SIGTERM on POSIX, which a stopped process cannot
            // handle. SIGKILL makes this fallback independent of child progress.
            if (sandbox.child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        }
        sandbox.reader_thread.join();
        if (sandbox.child.id != null) _ = sandbox.child.wait(io) catch {};
        fork.deleteTree(sandbox.dir);
        self.alloc.free(sandbox.dir);
        sandbox.output.deinit(self.alloc);
        self.alloc.destroy(sandbox);
    }

    fn stopSandbox(self: *Server, id: u32) bool {
        for (&self.sandboxes) |*slot| {
            if (slot.*) |sandbox| {
                if (sandbox.id == id) {
                    self.destroySandbox(sandbox);
                    slot.* = null;
                    return true;
                }
            }
        }
        return false;
    }

    const ExecOutcome = struct {
        exit_code: i64,
        output: []u8,
    };

    /// The outer console shell owns the marker; the script runs with stdin
    /// disconnected. Callers destroy the sandbox if completion is uncertain.
    fn execInSandbox(
        self: *Server,
        alloc: Allocator,
        sandbox: *Sandbox,
        command: []const u8,
        timeout_ms: u32,
    ) !ExecOutcome {
        if (self.cancelled.load(.acquire)) return error.ExecCancelled;
        const io = global.io();
        var random: [16]u8 = undefined;
        self.proc_io.random(&random);
        var marker_buf: [48]u8 = undefined;
        const marker_text = console_exec.markerText(&marker_buf, random);

        const line = try console_exec.commandLine(alloc, command, marker_text);
        defer alloc.free(line);

        sandbox.out_mutex.lockUncancelable(io);
        const start_offset = sandbox.outputOffset();
        sandbox.out_mutex.unlock(io);

        const stdin = sandbox.child.stdin orelse return error.SandboxGone;
        var written: usize = 0;
        while (written < line.len) {
            const rc = std.c.write(stdin.handle, line.ptr + written, line.len - written);
            if (rc <= 0) return error.SandboxGone;
            written += @intCast(rc);
        }

        const deadline_ns = monotonicNs() +|
            @as(u64, timeout_ms) * std.time.ns_per_ms;
        sandbox.out_mutex.lockUncancelable(io);
        defer sandbox.out_mutex.unlock(io);
        while (true) {
            if (self.cancelled.load(.acquire)) return error.ExecCancelled;
            const window = sandbox.outputSince(start_offset);
            const done = console_exec.findMarker(window, marker_text);
            if (done) |result| {
                const captured = try alloc.dupe(
                    u8,
                    console_exec.stripCommandEcho(window[0..result.start], marker_text),
                );
                return .{ .exit_code = result.exit_code, .output = captured };
            }
            if (sandbox.reader_done) return error.SandboxGone;
            const now_ns = monotonicNs();
            if (now_ns >= deadline_ns) return error.ExecTimeout;
            thread_compat.waitTimeout(&sandbox.out_cond, io, &sandbox.out_mutex, .{
                .duration = .{
                    .raw = .{ .nanoseconds = @min(deadline_ns - now_ns, 20 * std.time.ns_per_ms) },
                    .clock = .awake,
                },
            }) catch |err| switch (err) {
                error.Timeout => continue,
                else => return err,
            };
        }
    }
};

const SERVER_INFO =
    \\{"name":"bobrvm","version":"0.1.0"}
;

// One line: MCP's stdio transport is newline-delimited, so no JSON
// emitted by this server may contain a literal newline.
const TOOLS_JSON = "[" ++
    "{\"name\":\"sandbox_start\",\"description\":\"Start a disposable VM sandbox forked from" ++
    " this project's warm state. The sandbox resumes an already-booted guest in well " ++
    "under a second; its writable disks and memory are private copies. Host networkin" ++
    "g and shared-folder access are disabled. Returns the sandbox id.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_exec\",\"description\":\"Run a shell command inside a sandbox and w" ++
    "ait for it to finish. Returns the command's console output and exit code. Runs a" ++
    " separate shell with stdin closed. Scripts may contain newlines," ++
    " up to 768 bytes. Shell state does not persist. Timeout or cancellation destroys" ++
    " the sandbox.\",\"inputSchema\":{\"type\":\"object\"," ++
    "\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"sandbox id\"}," ++
    "\"command\":{\"type\":\"string\",\"description\":\"shell script (max 768 bytes," ++
    " no NUL)\"},\"timeout_ms\":{\"type\":\"integer\"," ++
    "\"description\":\"max wait in milliseconds (default 30000)\"}},\"required\":[\"id\"," ++
    "\"command\"],\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_output\",\"description\":\"Read the most recent console output of a" ++
    " sandbox (up to 64 KiB).\",\"inputSchema\":{\"type\":\"object\"," ++
    "\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"sandbox id\"}}," ++
    "\"required\":[\"id\"],\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_list\",\"description\":\"List running sandboxes.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_stop\",\"description\":\"Stop a sandbox," ++
    " including any active command, and delete its private state.\"," ++
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"," ++
    "\"description\":\"sandbox id\"}},\"required\":[\"id\"]," ++
    "\"additionalProperties\":false}}" ++
    "]";

const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

const CallResult = struct {
    content: []const TextContent,
    isError: bool = false,
};

fn envelope(alloc: Allocator, id_json: []const u8, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{
        id_json, result_json,
    });
}

fn errorEnvelope(alloc: Allocator, id_json: []const u8, code: i32, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n",
        .{ id_json, code, message },
    );
}

fn textResult(alloc: Allocator, id_json: []const u8, text: []const u8, is_error: bool) ![]u8 {
    const result = try std.json.Stringify.valueAlloc(alloc, CallResult{
        .content = &.{.{ .text = text }},
        .isError = is_error,
    }, .{});
    defer alloc.free(result);
    return envelope(alloc, id_json, result);
}

/// Handle one JSON-RPC message; returns the response line (owned by
/// the caller) or null for notifications. Never throws on malformed
/// input — protocol errors become JSON-RPC errors.
pub fn handleMessage(server: *Server, alloc: Allocator, line: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
        return try errorEnvelope(alloc, "null", -32700, "parse error");
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return try errorEnvelope(alloc, "null", -32600, "invalid request");

    const method_value = root.object.get("method") orelse
        return try errorEnvelope(alloc, "null", -32600, "invalid request");
    if (method_value != .string) return try errorEnvelope(alloc, "null", -32600, "invalid request");
    const method = method_value.string;

    const id_value = root.object.get("id");
    // Notifications get no response.
    if (id_value == null or id_value.? == .null) return null;
    if (id_value.? != .integer and id_value.? != .string)
        return try errorEnvelope(alloc, "null", -32600, "invalid request id");
    const id_json = try std.json.Stringify.valueAlloc(alloc, id_value.?, .{});
    defer alloc.free(id_json);

    if (std.mem.eql(u8, method, "initialize")) {
        const result = try std.fmt.allocPrint(
            alloc,
            "{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{s}}}",
            .{SERVER_INFO},
        );
        defer alloc.free(result);
        return try envelope(alloc, id_json, result);
    }
    if (std.mem.eql(u8, method, "ping")) {
        return try envelope(alloc, id_json, "{}");
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        const result = try std.fmt.allocPrint(alloc, "{{\"tools\":{s}}}", .{TOOLS_JSON});
        defer alloc.free(result);
        return try envelope(alloc, id_json, result);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return try handleToolCall(server, alloc, root, id_json);
    }
    return try errorEnvelope(alloc, id_json, -32601, "method not found");
}

fn handleToolCall(
    server: *Server,
    alloc: Allocator,
    root: std.json.Value,
    id_json: []const u8,
) ![]u8 {
    const params = root.object.get("params") orelse
        return try errorEnvelope(alloc, id_json, -32602, "missing params");
    if (params != .object) return try errorEnvelope(alloc, id_json, -32602, "missing params");
    const name_value = params.object.get("name") orelse
        return try errorEnvelope(alloc, id_json, -32602, "missing tool name");
    if (name_value != .string) return try errorEnvelope(alloc, id_json, -32602, "missing tool name");
    const name = name_value.string;
    const arguments: ?std.json.ObjectMap = blk: {
        const args = params.object.get("arguments") orelse break :blk null;
        if (args != .object) break :blk null;
        break :blk args.object;
    };

    if (std.mem.eql(u8, name, "sandbox_start")) {
        const sandbox = server.startSandbox() catch |err| {
            const text = try std.fmt.allocPrint(alloc, "cannot start sandbox: {s}", .{
                @errorName(err),
            });
            defer alloc.free(text);
            return try textResult(alloc, id_json, text, true);
        };
        const text = try std.fmt.allocPrint(
            alloc,
            "sandbox {d} started (resumed from warm state)",
            .{sandbox.id},
        );
        defer alloc.free(text);
        return try textResult(alloc, id_json, text, false);
    }

    if (std.mem.eql(u8, name, "sandbox_exec")) {
        const args = arguments orelse
            return try textResult(alloc, id_json, "missing arguments", true);
        const id = argInt(args, "id") orelse
            return try textResult(alloc, id_json, "invalid sandbox id", true);
        const command_value = args.get("command") orelse
            return try textResult(alloc, id_json, "missing command", true);
        if (command_value != .string)
            return try textResult(alloc, id_json, "missing command", true);
        if (command_value.string.len > console_exec.COMMAND_BYTES_MAX)
            return try textResult(alloc, id_json, "command exceeds 768 bytes", true);
        if (std.mem.indexOfScalar(u8, command_value.string, 0) != null)
            return try textResult(alloc, id_json, "command contains NUL", true);
        const timeout = if (args.contains("timeout_ms"))
            argInt(args, "timeout_ms") orelse
                return try textResult(alloc, id_json, "invalid timeout_ms", true)
        else
            EXEC_TIMEOUT_DEFAULT_MS;
        const sandbox = server.findSandbox(id) orelse
            return try textResult(alloc, id_json, "no such sandbox", true);

        const outcome = server.execInSandbox(
            alloc,
            sandbox,
            command_value.string,
            std.math.clamp(timeout, 1, EXEC_TIMEOUT_MAX_MS),
        ) catch |err| {
            if (err == error.CommandTooLong or err == error.InvalidCommand)
                return try textResult(alloc, id_json, "encoded command exceeds console limits", true);
            _ = server.stopSandbox(id);
            const text = try std.fmt.allocPrint(alloc, "exec failed: {s}; sandbox stopped and deleted", .{@errorName(err)});
            defer alloc.free(text);
            return try textResult(alloc, id_json, text, true);
        };
        defer alloc.free(outcome.output);
        const text = try std.fmt.allocPrint(alloc, "exit code {d}\n{s}", .{
            outcome.exit_code, outcome.output,
        });
        defer alloc.free(text);
        return try textResult(alloc, id_json, text, outcome.exit_code != 0);
    }

    if (std.mem.eql(u8, name, "sandbox_output")) {
        const args = arguments orelse
            return try textResult(alloc, id_json, "missing arguments", true);
        const id = argInt(args, "id") orelse
            return try textResult(alloc, id_json, "invalid sandbox id", true);
        const sandbox = server.findSandbox(id) orelse
            return try textResult(alloc, id_json, "no such sandbox", true);
        const io = global.io();
        sandbox.out_mutex.lockUncancelable(io);
        const copy = blk: {
            defer sandbox.out_mutex.unlock(io);
            const items = sandbox.output.items;
            break :blk try alloc.dupe(u8, items[items.len - @min(items.len, 64 * 1024) ..]);
        };
        defer alloc.free(copy);
        return try textResult(alloc, id_json, copy, false);
    }

    if (std.mem.eql(u8, name, "sandbox_list")) {
        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(alloc);
        for (server.sandboxes) |slot| {
            if (slot) |sandbox| {
                const entry = try std.fmt.allocPrint(alloc, "sandbox {d}\n", .{sandbox.id});
                defer alloc.free(entry);
                try text.appendSlice(alloc, entry);
            }
        }
        const body = if (text.items.len == 0) "no sandboxes running" else text.items;
        return try textResult(alloc, id_json, body, false);
    }

    if (std.mem.eql(u8, name, "sandbox_stop")) {
        const args = arguments orelse
            return try textResult(alloc, id_json, "missing arguments", true);
        const id = argInt(args, "id") orelse
            return try textResult(alloc, id_json, "invalid sandbox id", true);
        if (server.stopSandbox(id)) {
            return try textResult(alloc, id_json, "sandbox stopped and deleted", false);
        }
        return try textResult(alloc, id_json, "no such sandbox", true);
    }

    return try textResult(alloc, id_json, "unknown tool", true);
}

fn argInt(args: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = args.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return std.math.cast(u32, value.integer);
}

pub fn execute(
    alloc: Allocator,
    args: *std.process.Args.Iterator,
    environ: std.process.Environ,
) !void {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        }
        log.err("unknown argument: {s}", .{arg});
        return error.InvalidArgument;
    }

    global.state.init();
    defer global.state.deinit();

    // Sandbox children inherit the real environment, plus a private EOF
    // contract that stops their VM and lets fork cleanup unwind normally.
    var child_environ = try std.process.Environ.createMap(environ, alloc);
    defer child_environ.deinit();
    try child_environ.put("BOBRVM_EXIT_ON_EOF", "1");
    var io_impl = std.Io.Threaded.init(alloc, .{ .environ = environ });
    defer io_impl.deinit();
    var server = Server.init(alloc, io_impl.io());
    server.child_environ = &child_environ;
    defer server.deinit();

    const read_buf = try alloc.alloc(u8, LINE_MAX + 1);
    defer alloc.free(read_buf);
    var reader = std.Io.File.stdin().readerStreaming(io_impl.io(), read_buf);
    var write_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io_impl.io(), &write_buf);
    try serve(&server, alloc, &reader.interface, &writer.interface);
}

/// Both the control loop and the active tool may reply, but a JSON line is
/// always written under one lock. Tool execution never holds this lock.
const Output = struct {
    writer: *std.Io.Writer,
    mutex: std.Io.Mutex = .init,

    fn send(self: *Output, line: []const u8) !void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.writer.writeAll(line);
        try self.writer.flush();
    }
};

/// A single owned tool call keeps the server's sandbox table single-threaded.
/// The input loop only touches cancellation while this worker owns the server.
const ActiveCall = struct {
    server: *Server,
    alloc: Allocator,
    output: *Output,
    thread: ?std.Thread = null,
    request: []u8 = &.{},
    id_json: []u8 = &.{},
    sandbox_id: ?u32 = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    suppress_response: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(self: *ActiveCall, line: []const u8, id: []const u8, sandbox_id: ?u32) !void {
        self.request = try self.alloc.dupe(u8, line);
        errdefer self.alloc.free(self.request);
        self.id_json = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(self.id_json);
        self.sandbox_id = sandbox_id;
        self.done.store(false, .release);
        self.suppress_response.store(false, .release);
        self.server.cancelled.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn join(self: *ActiveCall) void {
        const thread = self.thread orelse return;
        thread.join();
        self.alloc.free(self.request);
        self.alloc.free(self.id_json);
        self.thread = null;
    }

    fn cancel(self: *ActiveCall, suppress_response: bool) void {
        if (suppress_response) self.suppress_response.store(true, .release);
        self.server.cancelled.store(true, .release);
        self.join();
    }

    fn run(self: *ActiveCall) void {
        const response = handleMessage(self.server, self.alloc, self.request) catch |err| {
            log.err("MCP tool failed: {}", .{err});
            self.done.store(true, .release);
            const failure = errorEnvelope(self.alloc, self.id_json, -32603, "internal error") catch
                return;
            defer self.alloc.free(failure);
            if (!self.suppress_response.load(.acquire)) self.output.send(failure) catch {};
            return;
        };
        // Publish completion before replying so an immediate subsequent request
        // joins this worker instead of receiving a spurious busy response.
        self.done.store(true, .release);
        if (response) |line| {
            defer self.alloc.free(line);
            if (!self.suppress_response.load(.acquire)) self.output.send(line) catch {};
        }
    }
};

/// Only integer and string IDs participate in request cancellation.
fn requestId(alloc: Allocator, value: ?std.json.Value) !?[]u8 {
    const id = value orelse return null;
    if (id != .integer and id != .string) return null;
    return try std.json.Stringify.valueAlloc(alloc, id, .{});
}

fn toolSandbox(root: std.json.ObjectMap, name: []const u8) ?u32 {
    const params = root.get("params") orelse return null;
    if (params != .object) return null;
    const tool = params.object.get("name") orelse return null;
    if (tool != .string or !std.mem.eql(u8, tool.string, name)) return null;
    const args = params.object.get("arguments") orelse return null;
    if (args != .object) return null;
    return argInt(args.object, "id");
}

/// Oversized messages terminate the stream: no suffix may become a new request.
fn serve(server: *Server, alloc: Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    var output = Output{ .writer = writer };
    var active = ActiveCall{ .server = server, .alloc = alloc, .output = &output };
    defer active.cancel(true);
    while (try reader.takeDelimiter('\n')) |line| {
        if (line.len > LINE_MAX) return error.StreamTooLong;
        if (active.thread != null and active.done.load(.acquire)) active.join();
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
            try output.send("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error\"}}\n");
            continue;
        };
        defer parsed.deinit();
        if (parsed.value == .object and
            try controlMessage(&active, parsed.value.object, line)) continue;
        if (try handleMessage(server, alloc, line)) |response| {
            defer alloc.free(response);
            try output.send(response);
        }
    }
}

/// Handle tool ownership and MCP cancellation without entering the busy server.
fn controlMessage(active: *ActiveCall, root: std.json.ObjectMap, line: []const u8) !bool {
    const method = root.get("method") orelse return false;
    if (method != .string) return false;
    if (std.mem.eql(u8, method.string, "notifications/cancelled")) {
        if (root.contains("id") or active.thread == null) return true;
        const params = root.get("params") orelse return true;
        if (params != .object) return true;
        const id = (try requestId(active.alloc, params.object.get("requestId"))) orelse return true;
        defer active.alloc.free(id);
        if (std.mem.eql(u8, id, active.id_json)) active.cancel(true);
        return true;
    }
    if (!std.mem.eql(u8, method.string, "tools/call")) return false;
    const id = (try requestId(active.alloc, root.get("id"))) orelse return false;
    defer active.alloc.free(id);
    if (active.thread == null) {
        try active.start(line, id, toolSandbox(root, "sandbox_exec"));
        return true;
    }
    const stop_id = toolSandbox(root, "sandbox_stop");
    const stopping = stop_id != null and stop_id == active.sandbox_id;
    if (stopping) {
        active.cancel(false);
        _ = active.server.stopSandbox(stop_id.?);
    }
    const response = try textResult(active.alloc, id, if (stopping)
        "sandbox stopped and deleted"
    else
        "another tool call is running; cancel it or wait for its response", !stopping);
    defer active.alloc.free(response);
    try active.output.send(response);
    return true;
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm mcp
        \\
        \\Serve the Model Context Protocol over stdio, exposing disposable
        \\VM sandboxes forked from this project's warm state. Add to an
        \\agent's MCP config, e.g. .mcp.json:
        \\
        \\  {"mcpServers": {"bobrvm": {"command": "bobrvm", "args": ["mcp"]}}}
        \\
        \\Tools: sandbox_start, sandbox_exec, sandbox_output,
        \\sandbox_list, sandbox_stop. Requires warm state (bobrvm up,
        \\then Ctrl-B z) in the project the server is started in.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}

const testing = std.testing;

fn expectResponse(server: *Server, line: []const u8, needle: []const u8) !void {
    const response = (try handleMessage(server, testing.allocator, line)) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, needle) != null);
}

test "mcp: protocol handshake, tool list, and errors" {
    var server = Server.init(testing.allocator, global.io());
    defer server.deinit();

    try expectResponse(&server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", "\"protocolVersion\":\"2024-11-05\"");
    try expectResponse(&server, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", "sandbox_exec");
    try expectResponse(&server, "{\"jsonrpc\":\"2.0\",\"id\":\"s1\",\"method\":\"ping\"}", "\"id\":\"s1\"");
    try expectResponse(&server, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"nope\"}", "-32601");
    try expectResponse(&server, "not json", "-32700");

    // Notifications never get responses.
    const none = try handleMessage(&server, testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try testing.expect(none == null);

    // Tool calls against unknown sandboxes fail as tool errors, not
    // protocol errors.
    try expectResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"sandbox_exec\",\"arguments\":{\"id\":9,\"command\":\"true\"}}}",
        "no such sandbox",
    );
    try expectResponse(
        &server,
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"sandbox_list\"}}",
        "no sandboxes",
    );
}

test "mcp: split readiness marker is removed from guest output" {
    var sandbox = Sandbox{
        .id = 7,
        .alloc = testing.allocator,
        .child = undefined,
        .reader_thread = undefined,
    };
    defer sandbox.output.deinit(testing.allocator);

    sandbox.appendOutput("guest prefix\x1eBOBRVM_");
    try testing.expect(!sandbox.ready);
    sandbox.appendOutput("READY\x1eguest suffix");

    try testing.expect(sandbox.ready);
    try testing.expectEqualStrings("guest prefixguest suffix", sandbox.output.items);
}

test "mcp: rejects out-of-range ids and console control input" {
    var server = Server.init(testing.allocator, global.io());
    defer server.deinit();
    for ([_][]const u8{ "sandbox_exec", "sandbox_output", "sandbox_stop" }) |tool| {
        const request = try std.fmt.allocPrint(testing.allocator,
            \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"{s}",
            \\"arguments":{{"id":4294967296,"command":"true"}}}}}}
        , .{tool});
        defer testing.allocator.free(request);
        try expectResponse(&server, request, "invalid sandbox id");
    }
    try expectResponse(&server,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sandbox_exec",
        \\"arguments":{"id":1,"command":"true\u0000exit"}}}
    , "command contains NUL");
    try expectResponse(&server,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sandbox_exec",
        \\"arguments":{"id":1,"command":"true","timeout_ms":"fast"}}}
    , "invalid timeout_ms");
}

test "mcp: stream emits complete responses and stops on oversized requests" {
    var server = Server.init(testing.allocator, global.io());
    defer server.deinit();
    const ping = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n";
    var reader = std.Io.Reader.fixed(ping ++ ping);
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();
    try serve(&server, testing.allocator, &reader, &writer.writer);
    const response = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n";
    try testing.expectEqualStrings(response ++ response, writer.written());

    const oversized = try testing.allocator.alloc(u8, LINE_MAX + 1 + ping.len);
    defer testing.allocator.free(oversized);
    @memset(oversized[0 .. LINE_MAX + 1], ' ');
    @memcpy(oversized[LINE_MAX + 1 ..], ping);
    reader = std.Io.Reader.fixed(oversized);
    try testing.expectError(
        error.StreamTooLong,
        serve(&server, testing.allocator, &reader, &writer.writer),
    );
    try testing.expectEqualStrings(response ++ response, writer.written());
}
