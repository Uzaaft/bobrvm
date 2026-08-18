//! `bobrvm up` - Boot the project described by the nearest bobrvm.toml.
//!
//! The first `up` cold-boots the VM. Quitting with the console's
//! suspend command (Ctrl-B z) writes the machine state to the
//! project's warm image, so every later `up` resumes it in place of
//! booting. `up --fresh` discards the warm image and boots cold.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const project = @import("project.zig");
const runner = @import("runner.zig");

const log = std.log.scoped(.cli);

extern "c" fn _NSGetExecutablePath(buf: [*]u8, bufsize: *u32) c_int;

pub fn execute(
    alloc: Allocator,
    args: *std.process.Args.Iterator,
    environ: std.process.Environ,
) !void {
    var fresh = false;
    var detach = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--fresh")) {
            fresh = true;
        } else if (std.mem.eql(u8, arg, "--detach") or std.mem.eql(u8, arg, "-d")) {
            detach = true;
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    // Everything project-related (paths, config strings) lives in one
    // arena that outlives the whole run; runner.run only borrows.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cwd_buf: [1024]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.span(@as([*:0]u8, @ptrCast(cwd_ptr)));

    const root = (try project.findRoot(arena, cwd)) orelse {
        log.err("no {s} found in {s} or any parent directory", .{ project.FILE_NAME, cwd });
        printHelp();
        return error.NoProjectFile;
    };

    var proj = try project.load(arena, root);
    try project.ensureStateDir(&proj);
    log.info("project {s} ({s}); state in {s}", .{
        proj.config.name, proj.file_path, proj.state_dir,
    });

    if (fresh) {
        var path_buf: [1024:0]u8 = undefined;
        if (proj.warm_image.len < path_buf.len) {
            @memcpy(path_buf[0..proj.warm_image.len], proj.warm_image);
            path_buf[proj.warm_image.len] = 0;
            _ = std.c.unlink(path_buf[0..proj.warm_image.len :0].ptr);
        }
    }

    if (detach) return detachedUp(alloc, arena, &proj, environ);

    if (project.fileExists(proj.warm_image)) {
        proj.config.restore_path = proj.warm_image;
        log.info("up: {s} — resuming warm state (Ctrl-B z saves it again on quit)", .{
            proj.config.name,
        });
    } else {
        log.info("up: {s} — cold boot (Ctrl-B z suspends to the warm image and quits)", .{
            proj.config.name,
        });
    }

    try runner.run(alloc, &proj.config);
}

/// Start a detached runner: a copy of this binary running plain `up`
/// with the console captured in the state directory, its pid recorded
/// for `bobrvm status` / `halt` / `suspend`.
fn detachedUp(
    alloc: Allocator,
    arena: Allocator,
    proj: *const project.Project,
    environ: std.process.Environ,
) !void {
    const io_alloc = alloc;
    var io_impl = std.Io.Threaded.init(io_alloc, .{ .environ = environ });
    defer io_impl.deinit();
    const io = io_impl.io();

    var exe_buf: [1024]u8 = undefined;
    var exe_len: u32 = exe_buf.len;
    if (_NSGetExecutablePath(&exe_buf, &exe_len) != 0) return error.Unexpected;
    const exe = std.mem.sliceTo(exe_buf[0..exe_len], 0);

    const log_path = try std.fs.path.join(arena, &.{ proj.state_dir, "console.log" });
    const console_log = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    defer console_log.close(io);

    const child = std.process.spawn(io, .{
        .argv = &.{ exe, "up" },
        .stdin = .ignore,
        .stdout = .{ .file = console_log },
        .stderr = .{ .file = console_log },
    }) catch |err| {
        log.err("cannot start detached runner: {}", .{err});
        return error.Unexpected;
    };
    // Deliberately not waited or reaped: the runner outlives this
    // command and is reparented to init when we exit.

    const pid_path = try std.fs.path.join(arena, &.{ proj.state_dir, "runner.pid" });
    const pid_file = try std.Io.Dir.cwd().createFile(io, pid_path, .{});
    defer pid_file.close(io);
    const pid_text = try std.fmt.allocPrint(arena, "{d}\n", .{child.id.?});
    try pid_file.writePositionalAll(io, pid_text, 0);

    log.info("up: {s} — detached (pid {d}); console in {s}", .{
        proj.config.name, child.id.?, log_path,
    });
    log.info("manage it with: bobrvm status | bobrvm suspend | bobrvm halt", .{});
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm up [--fresh] [--detach]
        \\
        \\Boot the project described by the nearest bobrvm.toml (searched
        \\from the current directory upward). Quit with Ctrl-B z to save
        \\the machine state; the next `up` resumes it instead of booting.
        \\
        \\Options:
        \\  --fresh        Discard the saved warm state and boot cold
        \\  -d, --detach   Run in the background; manage with bobrvm
        \\                 status / suspend / halt
        \\
        \\bobrvm.toml keys:
        \\  name = "webapp"            memory = 2048         cpus = 1
        \\  kernel = "boot/Image"      initrd = "initrd"     cmdline = "..."
        \\  firmware = "..."           vars = "..."
        \\  disk = "root.raw"          disk-readonly = false
        \\  disk2 = "extra.iso"        disk2-writable = false
        \\  gpu = true                 virgl = true          sound = true
        \\  net = true                 forwards = ["2222:22"]
        \\  share = "dir" | false      (default: the project directory)
        \\  display = "1280x800"       gpu-memory = 512
        \\
        \\Relative paths resolve against the project root. Warm state is
        \\kept under ~/.config/bobrvm/projects/, not in the repository.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}
