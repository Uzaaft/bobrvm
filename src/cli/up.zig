//! `bobrvm up` - Boot the project described by the nearest bobrvm.toml.
//!
//! The first `up` cold-boots the VM. Quitting with the console's
//! suspend command (Ctrl-B z) writes the machine state to the
//! project's warm image, so every later `up` resumes it in place of
//! booting. `up --fresh` discards the warm image and boots cold.

const std = @import("std");
const Allocator = std.mem.Allocator;

const project = @import("project.zig");
const runner = @import("runner.zig");

const log = std.log.scoped(.cli);

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    var fresh = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--fresh")) {
            fresh = true;
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

fn printHelp() void {
    const help =
        \\Usage: bobrvm up [--fresh]
        \\
        \\Boot the project described by the nearest bobrvm.toml (searched
        \\from the current directory upward). Quit with Ctrl-B z to save
        \\the machine state; the next `up` resumes it instead of booting.
        \\
        \\Options:
        \\  --fresh    Discard the saved warm state and boot cold
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
