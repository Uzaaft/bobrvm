//! `bobrvm vz-run` - Boot a Linux guest on the Virtualization.framework
//! "lite" engine (experimental).
//!
//! The OS provides the devices; bobrvm provides the workflow. The
//! guest console is wired to this process's stdin/stdout. State
//! save/restore comes from the framework (macOS 14+, SMP included):
//! restore with --restore, and either quit-and-save on a timer with
//! the BOBRVM_VZ_SUSPEND=delay_s:path hook or leave the guest to halt
//! on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const linux_vz = @import("../runtime/linux_vz.zig");
const os = @import("../os/main.zig");
const project = @import("project.zig");

const log = std.log.scoped(.cli);

/// Run a project on the lite engine (the `engine = "vz"` path of
/// `bobrvm up`): resume the warm state when it exists, and answer
/// SIGUSR1 (`bobrvm suspend`, also sent by the detached-runner verbs)
/// by saving it and quitting. The guest console uses stdin/stdout.
pub fn upProject(arena: Allocator, proj: *const project.Project) !void {
    const config = &proj.config;
    const machine_id = try std.fmt.allocPrintSentinel(arena, "{s}/machine.id", .{
        proj.state_dir,
    }, 0);
    const warm = try arena.dupeZ(u8, proj.warm_image);

    var machine = try linux_vz.Machine.init(&.{
        .kernel_path = try arena.dupeZ(u8, config.kernel_path.?),
        .initrd_path = if (config.initrd_path) |path| try arena.dupeZ(u8, path) else null,
        .cmdline = try arena.dupeZ(u8, config.cmdline),
        .memory_bytes = config.memory_mb * 1024 * 1024,
        .vcpu_count = config.vcpu_count,
        .console_in = std.posix.STDIN_FILENO,
        .console_out = std.posix.STDOUT_FILENO,
        .machine_id_path = machine_id,
    });
    defer machine.deinit();

    const start_ms = nowMs();
    if (project.fileExists(proj.warm_image)) {
        try machine.restoreFrom(warm);
        try machine.resumeVM();
        log.info("up: {s} — resuming warm state (vz engine, {d} ms)", .{
            config.name, nowMs() - start_ms,
        });
    } else {
        try machine.start();
        log.info("up: {s} — cold boot (vz engine, {d} ms)", .{
            config.name, nowMs() - start_ms,
        });
    }

    os.signal.registerSuspendRequest();
    while (true) {
        linux_vz.pump();
        switch (machine.state()) {
            .stopped, .@"error" => break,
            else => {},
        }
        if (os.signal.takeSuspendRequest()) {
            const t0 = nowMs();
            try machine.pause();
            try machine.saveTo(warm);
            log.info("vz: suspended to warm state in {d} ms", .{nowMs() - t0});
            try machine.stop();
            break;
        }
    }
    log.info("vz: machine stopped", .{});
}

fn nowMs() i64 {
    return @intCast(@divTrunc(
        std.Io.Clock.real.now(global.io()).nanoseconds,
        std.time.ns_per_ms,
    ));
}

pub fn execute(alloc: Allocator, args: *std.process.Args.Iterator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var kernel: ?[:0]const u8 = null;
    var initrd: ?[:0]const u8 = null;
    var cmdline: [:0]const u8 = "console=hvc0";
    var memory_mb: u64 = 512;
    var cpus: u8 = 2;
    var restore: ?[:0]const u8 = null;
    var machine_id: ?[:0]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--kernel") or std.mem.eql(u8, arg, "-k")) {
            kernel = try arena.dupeZ(u8, args.next() orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, arg, "--initrd") or std.mem.eql(u8, arg, "-i")) {
            initrd = try arena.dupeZ(u8, args.next() orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, arg, "--cmdline")) {
            cmdline = try arena.dupeZ(u8, args.next() orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, arg, "--memory") or std.mem.eql(u8, arg, "-m")) {
            const value = args.next() orelse return error.InvalidArgument;
            memory_mb = std.fmt.parseInt(u64, value, 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--cpus") or std.mem.eql(u8, arg, "-c")) {
            const value = args.next() orelse return error.InvalidArgument;
            cpus = std.fmt.parseInt(u8, value, 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--restore")) {
            restore = try arena.dupeZ(u8, args.next() orelse return error.InvalidArgument);
        } else if (std.mem.eql(u8, arg, "--machine-id")) {
            machine_id = try arena.dupeZ(u8, args.next() orelse return error.InvalidArgument);
        } else {
            log.err("unknown argument: {s}", .{arg});
            return error.InvalidArgument;
        }
    }

    const kernel_path = kernel orelse {
        log.err("vz-run requires --kernel", .{});
        return error.InvalidArgument;
    };

    global.state.init();
    defer global.state.deinit();

    var machine = try linux_vz.Machine.init(&.{
        .kernel_path = kernel_path,
        .initrd_path = initrd,
        .cmdline = cmdline,
        .memory_bytes = memory_mb * 1024 * 1024,
        .vcpu_count = cpus,
        .console_in = std.posix.STDIN_FILENO,
        .console_out = std.posix.STDOUT_FILENO,
        .machine_id_path = machine_id,
    });
    defer machine.deinit();

    const start_ms = nowMs();
    if (restore) |path| {
        try machine.restoreFrom(path);
        try machine.resumeVM();
        log.info("vz: restored and resumed in {d} ms", .{nowMs() - start_ms});
    } else {
        try machine.start();
        log.info("vz: started in {d} ms", .{nowMs() - start_ms});
    }

    // Scripted suspend hook, mirroring BOBRVM_TEST_SUSPEND on the
    // native engine: pause, save, and quit after a delay.
    var suspend_deadline_ms: ?i64 = null;
    var suspend_path: ?[:0]const u8 = null;
    if (std.c.getenv("BOBRVM_VZ_SUSPEND")) |spec_ptr| {
        const spec = std.mem.span(spec_ptr);
        if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
            if (std.fmt.parseInt(u32, spec[0..colon], 10)) |delay_s| {
                suspend_deadline_ms = nowMs() + @as(i64, delay_s) * 1000;
                suspend_path = try arena.dupeZ(u8, spec[colon + 1 ..]);
            } else |_| {}
        }
    }

    while (true) {
        linux_vz.pump();
        switch (machine.state()) {
            .stopped, .@"error" => break,
            else => {},
        }
        if (suspend_deadline_ms) |deadline| {
            if (nowMs() >= deadline) {
                const t0 = nowMs();
                try machine.pause();
                try machine.saveTo(suspend_path.?);
                log.info("vz: paused and saved in {d} ms", .{nowMs() - t0});
                try machine.stop();
                break;
            }
        }
    }
    log.info("vz: machine stopped", .{});
}

fn printHelp() void {
    const help =
        \\Usage: bobrvm vz-run --kernel <Image> [options]
        \\
        \\Boot a Linux guest on Apple's Virtualization.framework (the
        \\lite engine, experimental). The guest console uses this
        \\process's stdin/stdout.
        \\
        \\Options:
        \\  -k, --kernel <path>   Kernel image (required)
        \\  -i, --initrd <path>   Initial ramdisk
        \\  --cmdline <str>       Kernel command line (default: console=hvc0)
        \\  -m, --memory <MB>     RAM size in MB (default: 512)
        \\  -c, --cpus <N>        Number of vCPUs (default: 2)
        \\  --restore <path>      Resume from a saved machine state
        \\  --machine-id <path>   Persisted machine identifier (required for
        \\                        restore to work across processes)
        \\
        \\BOBRVM_VZ_SUSPEND=delay_s:path pauses, saves the machine state
        \\to <path>, and quits after the delay.
        \\
    ;
    _ = std.c.write(std.posix.STDOUT_FILENO, help.ptr, help.len);
}
