//! `bobrvm exec -- <command>` - Run a command in a disposable clone of
//! the project's warm state and print its output and exit code.
//!
//! Like `fork`, but non-interactive: boot a copy-on-write clone of the
//! warm image in-process, run the command over the guest console, then
//! discard everything. The project's warm state and disks are never
//! touched.

const std = @import("std");
const Allocator = std.mem.Allocator;

const console_exec = @import("console_exec.zig");
const fork = @import("fork.zig");
const global = @import("../global.zig");
const machine = @import("../machine/main.zig");
const project = @import("project.zig");

const log = std.log.scoped(.cli);

const EXEC_TIMEOUT_MS: u32 = 120_000;

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Collect the command after an optional `--` separator.
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var saw_separator = false;
    while (args.next()) |arg| {
        if (!saw_separator and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            printHelp();
            return;
        }
        if (!saw_separator and std.mem.eql(u8, arg, "--")) {
            saw_separator = true;
            continue;
        }
        try parts.append(arena, try arena.dupe(u8, arg));
    }
    if (parts.items.len == 0) {
        log.err("exec requires a command (bobrvm exec -- <command>)", .{});
        return error.InvalidArgument;
    }
    // Shell-quote each argv element so multi-word arguments survive as
    // one word in the injected command line — otherwise
    // `exec -- sh -c 'a b'` would flatten to `sh -c a b`.
    const command = try shellJoin(arena, parts.items);

    var cwd_buf: [1024]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));
    const root = (try project.findRoot(arena, cwd)) orelse {
        log.err("no {s} found in {s} or any parent directory", .{ project.FILE_NAME, cwd });
        return error.NoProjectFile;
    };
    const proj = try project.load(arena, root);

    global.state.init();
    defer global.state.deinit();

    const clone = try fork.prepare(arena, &proj);
    defer fork.deleteTree(clone.dir);

    var hw = try machine.Machine.init(alloc, machineConfig(&clone.config));
    defer hw.deinit();

    var session = console_exec.Session.init(alloc, hw);
    defer session.deinit();
    hw.setConsoleOutput(console_exec.Session.sink, &session);

    const vm_thread = std.Thread.spawn(.{}, machineMain, .{hw}) catch return error.Unexpected;
    defer {
        hw.requestStop();
        vm_thread.join();
    }

    if (!session.waitForPrompt(alloc, 30_000)) {
        log.err("guest did not reach a shell prompt", .{});
        return error.ExecTimeout;
    }

    const result = try session.run(alloc, command, EXEC_TIMEOUT_MS);
    defer alloc.free(result.output);
    _ = std.c.write(std.posix.STDOUT_FILENO, result.output.ptr, result.output.len);
    if (result.exit_code != 0) {
        log.info("exit code {d}", .{result.exit_code});
        std.process.exit(@intCast(@as(u8, @truncate(@as(u64, @bitCast(result.exit_code))))));
    }
}

fn machineMain(hw: *machine.Machine) void {
    hw.startSync() catch |err| log.err("machine failed: {}", .{err});
}

/// Join argv into a single POSIX-shell command line, single-quoting
/// each word (embedded single quotes become '\'').
fn shellJoin(arena: Allocator, parts: []const []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.append(arena, '\'');
        for (part) |byte| {
            if (byte == '\'') {
                try out.appendSlice(arena, "'\\''");
            } else {
                try out.append(arena, byte);
            }
        }
        try out.append(arena, '\'');
    }
    return out.items;
}

test "shellJoin quotes each argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "'sh' '-c' 'exit 7'",
        try shellJoin(arena, &.{ "sh", "-c", "exit 7" }),
    );
    try std.testing.expectEqualStrings(
        "'echo' 'it'\\''s'",
        try shellJoin(arena, &.{ "echo", "it's" }),
    );
}

fn machineConfig(config: *const @import("Config.zig")) machine.MachineConfig {
    return .{
        .ram_size = config.memory_mb * 1024 * 1024,
        .vcpu_count = config.vcpu_count,
        .firmware_path = config.firmware_path,
        .vars_path = config.vars_path,
        .kernel_path = config.kernel_path,
        .initrd_path = config.initrd_path,
        .cmdline = config.cmdline,
        .disk_path = config.disk_path,
        .disk_read_only = config.disk_read_only,
        .disk2_path = config.disk2_path,
        .disk2_read_only = config.disk2_read_only,
        .enable_net = config.enable_net,
        .shared_dir = config.shared_dir,
        .restore_path = config.restore_path,
    };
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm exec -- <command>
        \\
        \\Run a command in a disposable clone of the project's warm state
        \\and print its output. The clone is discarded afterwards, so the
        \\command cannot affect the project. Requires warm state (bobrvm
        \\up, then quit with Ctrl-B z).
        \\
        \\  bobrvm exec -- ls -la /workspace
        \\  bobrvm exec -- sh -c 'make && ./run-tests'
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}
