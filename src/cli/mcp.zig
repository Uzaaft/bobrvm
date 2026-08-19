//! `bobrvm mcp` - Model Context Protocol server exposing disposable
//! guest sandboxes.
//!
//! Speaks MCP's stdio transport (one JSON-RPC 2.0 message per line).
//! Each sandbox is a fork of the project's warm state hosted in this
//! process: an agent starts one, runs commands in it, reads output,
//! and destroys it — the project's warm image and disks are never
//! touched.
//!
//! Command execution rides the guest console: the command line is
//! injected into the shell on hvc0 followed by an `echo` of a unique
//! completion marker carrying the exit code, and output is captured
//! until the marker appears. That works against any guest with an
//! interactive shell — no guest agent required.

const std = @import("std");
const Allocator = std.mem.Allocator;

const console_exec = @import("console_exec.zig");
const global = @import("../global.zig");
const project = @import("project.zig");

const log = std.log.scoped(.mcp);

// Hypervisor.framework allows one VM per process, so each sandbox is a
// `bobrvm fork` child process (the same signed binary, so the
// hypervisor entitlement carries): its stdin/stdout pipes ARE the
// guest console.
extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

const LINE_MAX: usize = 256 * 1024;
/// Per-sandbox console history cap; the oldest bytes fall off.
const OUTPUT_CAP: usize = 1024 * 1024;
const EXEC_TIMEOUT_DEFAULT_MS: u32 = 30_000;
const EXEC_TIMEOUT_MAX_MS: u32 = 600_000;
const SANDBOX_MAX: usize = 8;

const Sandbox = struct {
    id: u32,
    alloc: Allocator,
    child: std.process.Child,
    reader_thread: std.Thread,
    out_mutex: std.Io.Mutex = .init,
    output: std.ArrayListUnmanaged(u8) = .empty,

    fn appendOutput(self: *Sandbox, data: []const u8) void {
        const io = global.io();
        self.out_mutex.lockUncancelable(io);
        defer self.out_mutex.unlock(io);
        self.output.appendSlice(self.alloc, data) catch return;
        if (self.output.items.len > OUTPUT_CAP) {
            const drop = self.output.items.len - OUTPUT_CAP;
            std.mem.copyForwards(
                u8,
                self.output.items[0 .. self.output.items.len - drop],
                self.output.items[drop..],
            );
            self.output.shrinkRetainingCapacity(self.output.items.len - drop);
        }
    }
};

/// Drain the child's console (stdout pipe) into the output buffer.
fn sandboxReader(sandbox: *Sandbox) void {
    const stdout = sandbox.child.stdout orelse return;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(stdout.handle, &buf) catch break;
        if (n == 0) break;
        sandbox.appendOutput(buf[0..n]);
    }
}

pub const Server = struct {
    alloc: Allocator,
    /// Io used for child-process management. The global single-threaded
    /// Io cannot allocate, and std.process.spawn allocates the argv and
    /// environment blocks through its Io's allocator.
    proc_io: std.Io,
    proj: ?project.Project = null,
    proj_arena: std.heap.ArenaAllocator,
    sandboxes: [SANDBOX_MAX]?*Sandbox = @splat(null),
    next_id: u32 = 1,
    next_marker: u32 = 1,

    pub fn init(alloc: Allocator, proc_io: std.Io) Server {
        return .{
            .alloc = alloc,
            .proc_io = proc_io,
            .proj_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Server) void {
        for (&self.sandboxes) |*slot| {
            if (slot.*) |sandbox| self.destroySandbox(sandbox);
            slot.* = null;
        }
        self.proj_arena.deinit();
    }

    /// Load the project lazily (the first sandbox tool call), so the
    /// protocol handshake works even outside a project directory.
    fn projectRef(self: *Server) !*const project.Project {
        if (self.proj == null) {
            const arena = self.proj_arena.allocator();
            var cwd_buf: [1024]u8 = undefined;
            const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
            const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
            const root = (try project.findRoot(arena, cwd)) orelse return error.NoProjectFile;
            self.proj = try project.load(arena, root);
        }
        return &self.proj.?;
    }

    fn startSandbox(self: *Server) !*Sandbox {
        // Fail early with a useful error when there is no warm state;
        // the child would discover it too, but only in its logs.
        const proj = try self.projectRef();
        if (!project.fileExists(proj.warm_image)) return error.NoWarmState;

        const slot = for (&self.sandboxes) |*candidate| {
            if (candidate.* == null) break candidate;
        } else return error.TooManySandboxes;

        var exe_buf: [1024]u8 = undefined;
        var exe_len: u32 = exe_buf.len;
        if (_NSGetExecutablePath(&exe_buf, &exe_len) != 0) return error.Unexpected;
        const exe = std.mem.sliceTo(exe_buf[0..exe_len], 0);

        const sandbox = try self.alloc.create(Sandbox);
        errdefer self.alloc.destroy(sandbox);
        sandbox.* = .{
            .id = self.next_id,
            .alloc = self.alloc,
            .child = undefined,
            .reader_thread = undefined,
        };

        sandbox.child = std.process.spawn(self.proc_io, .{
            .argv = &.{ exe, "fork" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (std.c.getenv("BOBRVM_MCP_DEBUG") != null) .inherit else .ignore,
        }) catch |err| {
            log.err("sandbox spawn failed: {} ({s} fork)", .{ err, exe });
            return error.Unexpected;
        };
        errdefer {
            sandbox.child.kill(self.proc_io);
            _ = sandbox.child.wait(self.proc_io) catch {};
        }

        sandbox.reader_thread = std.Thread.spawn(.{}, sandboxReader, .{sandbox}) catch
            return error.Unexpected;
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
        // SIGTERM takes the child through the runner's cleanup path
        // (the same one Ctrl-] raises): stop the guest, delete its
        // fork directory, exit. The reader sees EOF when it dies.
        if (sandbox.child.id) |pid| _ = std.c.kill(pid, .TERM);
        if (sandbox.child.stdin) |stdin| {
            stdin.close(io);
            sandbox.child.stdin = null;
        }
        sandbox.reader_thread.join();
        _ = sandbox.child.wait(io) catch {};
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

    /// Console-marker exec: inject the command followed by an echo of
    /// a unique completion marker, capture until the marker appears.
    /// The echoed command line contains the marker text with a literal
    /// "$?", so completion matches only marker-plus-digits.
    fn execInSandbox(
        self: *Server,
        alloc: Allocator,
        sandbox: *Sandbox,
        command: []const u8,
        timeout_ms: u32,
    ) !ExecOutcome {
        const io = global.io();
        const marker = self.next_marker;
        self.next_marker += 1;

        var marker_buf: [48]u8 = undefined;
        const marker_text = console_exec.markerText(&marker_buf, marker);

        const line = try std.fmt.allocPrint(alloc, "{s} ; echo {s}$?\n", .{
            command, marker_text,
        });
        defer alloc.free(line);

        sandbox.out_mutex.lockUncancelable(io);
        const start_pos = sandbox.output.items.len;
        sandbox.out_mutex.unlock(io);

        const stdin = sandbox.child.stdin orelse return error.SandboxGone;
        var written: usize = 0;
        while (written < line.len) {
            const rc = std.c.write(stdin.handle, line.ptr + written, line.len - written);
            if (rc <= 0) return error.SandboxGone;
            written += @intCast(rc);
        }

        var waited_ms: u32 = 0;
        while (true) {
            sandbox.out_mutex.lockUncancelable(io);
            const window = sandbox.output.items[@min(start_pos, sandbox.output.items.len)..];
            const done = console_exec.findMarker(window, marker_text);
            if (done) |result| {
                const captured = try alloc.dupe(u8, window[0..result.start]);
                sandbox.out_mutex.unlock(io);
                return .{ .exit_code = result.exit_code, .output = captured };
            }
            sandbox.out_mutex.unlock(io);
            if (waited_ms >= timeout_ms) return error.ExecTimeout;
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
                .clock = .awake,
            }, io) catch {};
            waited_ms += 10;
        }
    }
};

// =============================================================================
// JSON-RPC / MCP protocol
// =============================================================================

const SERVER_INFO =
    \\{"name":"bobrvm","version":"0.1.0"}
;

// One line: MCP's stdio transport is newline-delimited, so no JSON
// emitted by this server may contain a literal newline.
const TOOLS_JSON = "[" ++
    "{\"name\":\"sandbox_start\",\"description\":\"Start a disposable VM sandbox forked from this project's warm state. The sandbox resumes an already-booted guest in well under a second; its disks and memory are private copies. Returns the sandbox id.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_exec\",\"description\":\"Run a shell command inside a sandbox and wait for it to finish. Returns the command's console output and exit code. The command runs in the guest's interactive shell; keep it a single line.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"sandbox id\"},\"command\":{\"type\":\"string\",\"description\":\"single-line shell command\"},\"timeout_ms\":{\"type\":\"integer\",\"description\":\"max wait in milliseconds (default 30000)\"}},\"required\":[\"id\",\"command\"],\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_output\",\"description\":\"Read the most recent console output of a sandbox (up to 64 KiB).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"sandbox id\"}},\"required\":[\"id\"],\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_list\",\"description\":\"List running sandboxes.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}}," ++
    "{\"name\":\"sandbox_stop\",\"description\":\"Stop a sandbox and delete its private state.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"description\":\"sandbox id\"}},\"required\":[\"id\"],\"additionalProperties\":false}}" ++
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
            return try textResult(alloc, id_json, "missing sandbox id", true);
        const command_value = args.get("command") orelse
            return try textResult(alloc, id_json, "missing command", true);
        if (command_value != .string)
            return try textResult(alloc, id_json, "missing command", true);
        const timeout: u32 = @intCast(std.math.clamp(
            argInt(args, "timeout_ms") orelse EXEC_TIMEOUT_DEFAULT_MS,
            1,
            EXEC_TIMEOUT_MAX_MS,
        ));
        const sandbox = server.findSandbox(@intCast(id)) orelse
            return try textResult(alloc, id_json, "no such sandbox", true);

        const outcome = server.execInSandbox(
            alloc,
            sandbox,
            command_value.string,
            timeout,
        ) catch |err| {
            const text = try std.fmt.allocPrint(alloc, "exec failed: {s}", .{@errorName(err)});
            defer alloc.free(text);
            return try textResult(alloc, id_json, text, true);
        };
        defer alloc.free(outcome.output);
        const text = try std.fmt.allocPrint(alloc, "exit code {d}\n{s}", .{
            outcome.exit_code, stripCommandEcho(outcome.output),
        });
        defer alloc.free(text);
        return try textResult(alloc, id_json, text, outcome.exit_code != 0);
    }

    if (std.mem.eql(u8, name, "sandbox_output")) {
        const args = arguments orelse
            return try textResult(alloc, id_json, "missing arguments", true);
        const id = argInt(args, "id") orelse
            return try textResult(alloc, id_json, "missing sandbox id", true);
        const sandbox = server.findSandbox(@intCast(id)) orelse
            return try textResult(alloc, id_json, "no such sandbox", true);
        const io = global.io();
        sandbox.out_mutex.lockUncancelable(io);
        const items = sandbox.output.items;
        const window = items[items.len - @min(items.len, 64 * 1024) ..];
        const copy = try alloc.dupe(u8, window);
        sandbox.out_mutex.unlock(io);
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
            return try textResult(alloc, id_json, "missing sandbox id", true);
        if (server.stopSandbox(@intCast(id))) {
            return try textResult(alloc, id_json, "sandbox stopped and deleted", false);
        }
        return try textResult(alloc, id_json, "no such sandbox", true);
    }

    return try textResult(alloc, id_json, "unknown tool", true);
}

fn argInt(args: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = args.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return value.integer;
}

const stripCommandEcho = console_exec.stripCommandEcho;

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

    // Sandbox children must inherit the real environment (HOME etc.),
    // which spawn takes from this Io instance.
    var io_impl = std.Io.Threaded.init(alloc, .{ .environ = environ });
    defer io_impl.deinit();
    var server = Server.init(alloc, io_impl.io());
    defer server.deinit();

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(alloc);
    var read_buf: [4096]u8 = undefined;

    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &read_buf) catch break;
        if (n == 0) break; // client closed: shut everything down
        var remaining: []const u8 = read_buf[0..n];
        while (std.mem.indexOfScalar(u8, remaining, '\n')) |newline| {
            if (line_buf.items.len + newline <= LINE_MAX) {
                try line_buf.appendSlice(alloc, remaining[0..newline]);
                if (try handleMessage(&server, alloc, line_buf.items)) |response| {
                    defer alloc.free(response);
                    _ = std.c.write(std.posix.STDOUT_FILENO, response.ptr, response.len);
                }
            }
            line_buf.clearRetainingCapacity();
            remaining = remaining[newline + 1 ..];
        }
        if (line_buf.items.len + remaining.len <= LINE_MAX) {
            try line_buf.appendSlice(alloc, remaining);
        }
    }
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
