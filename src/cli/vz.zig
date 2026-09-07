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
const mininat = @import("../net/mininat.zig");
const os = @import("../os/main.zig");
const checkpoint = @import("checkpoint.zig");
const console_exec = @import("console_exec.zig");
const docker_idle = @import("docker_idle.zig");
const project = @import("project.zig");
const VzConsole = @import("vz_console.zig").Console;

const log = std.log.scoped(.cli);
const interactive_pump_seconds: f64 = 0.05;
const detached_pump_seconds: f64 = 1.0;

/// Run a project on the lite engine (the `engine = "vz"` path of
/// `bobrvm up`): resume the warm state when it exists, and answer
/// SIGUSR1 (`bobrvm suspend`, also sent by the detached-runner verbs)
/// by saving it and quitting. The guest console uses stdin/stdout.
pub fn upProject(arena: Allocator, proj: *const project.Project) !void {
    const config = &proj.config;
    const console = try VzConsole.create(arena);
    defer console.destroy();
    const machine_id = try std.fmt.allocPrintSentinel(arena, "{s}/machine.id", .{
        proj.state_dir,
    }, 0);
    const warm = try arena.dupeZ(u8, proj.warm_image);
    var forwards: [@import("Config.zig").MAX_FORWARDS]mininat.Forward = undefined;
    for (config.forwards[0..config.forward_count], 0..) |forward, index| {
        forwards[index] = .{
            .host_port = forward.host_port,
            .guest_port = forward.guest_port,
        };
    }

    var machine = try linux_vz.Machine.init(&.{
        .kernel_path = try arena.dupeZ(u8, config.kernel_path.?),
        .initrd_path = if (config.initrd_path) |path| try arena.dupeZ(u8, path) else null,
        .cmdline = try arena.dupeZ(u8, config.cmdline),
        .memory_bytes = config.memory_mb * 1024 * 1024,
        .vcpu_count = config.vcpu_count,
        .console_in = console.guest_fd,
        .console_out = console.guest_fd,
        .disk_path = if (config.disk_path) |path| try arena.dupeZ(u8, path) else null,
        .disk_read_only = config.disk_read_only,
        .disk2_path = if (config.disk2_path) |path| try arena.dupeZ(u8, path) else null,
        .disk2_read_only = config.disk2_read_only,
        .enable_net = config.enable_net,
        .network_shared = config.network_shared,
        .network_mac = config.network_mac,
        .forwards = forwards[0..config.forward_count],
        .docker_socket_path = config.docker_socket_path,
        .docker_vsock = config.docker_vsock,
        .shared_dir = if (config.shared_dir) |path| try arena.dupeZ(u8, path) else null,
        .share_read_only = config.share_read_only,
        .machine_id_path = machine_id,
    });
    defer machine.deinit();

    const cold_boot = !project.fileExists(proj.warm_image);
    const start_ms = nowMs();
    if (!cold_boot) {
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
    console.markReady();

    var provision_context = ProvisionContext{
        .console = console,
        .steps = config.provision_steps,
        .done = std.atomic.Value(bool).init(!cold_boot or config.provision_steps.len == 0),
    };
    var provision_thread: ?std.Thread = if (cold_boot and config.provision_steps.len > 0) blk: {
        console.setCapture(true);
        break :blk std.Thread.spawn(.{}, provision, .{&provision_context}) catch |err| {
            console.setCapture(false);
            provision_context.done.store(true, .release);
            log.err("could not start VZ provisioning: {}", .{err});
            break :blk null;
        };
    } else null;
    defer if (provision_thread) |thread| {
        console.cancelIO();
        thread.join();
    };

    const pump_seconds = if (std.c.isatty(std.posix.STDIN_FILENO) != 0)
        interactive_pump_seconds
    else
        detached_pump_seconds;
    var idle_controller: ?docker_idle.Controller = if (config.docker_idle_sleep)
        docker_idle.Controller.init(
            &machine,
            config.docker_socket_path.?,
            &provision_context.done,
        )
    else
        null;
    defer if (idle_controller) |*controller| controller.deinit();
    os.signal.registerSuspendRequest();
    while (true) {
        console.pumpInput();
        linux_vz.pumpFor(pump_seconds);
        machine.tickPerformancePolicy();
        if (provision_thread != null and provision_context.done.load(.acquire)) {
            provision_thread.?.join();
            provision_thread = null;
        }
        switch (machine.state()) {
            .stopped, .@"error" => break,
            else => {},
        }
        if (idle_controller) |*controller| switch (try controller.tick()) {
            .none => {},
            .checkpoint => {
                const t0 = nowMs();
                try machine.pause();
                checkpoint.replace(arena, warm, &machine, saveMachineCheckpoint) catch |err| {
                    log.err("vz: automatic idle suspend failed: {}; resuming", .{err});
                    try machine.resumeVM();
                    controller.retryLater();
                    continue;
                };
                log.info("vz: automatically suspended idle Docker VM in {d} ms", .{
                    nowMs() - t0,
                });
                exitAfterSave();
            },
        };
        if (os.signal.takeSuspendRequest()) {
            const t0 = nowMs();
            try machine.pause();
            checkpoint.replace(arena, warm, &machine, saveMachineCheckpoint) catch |err| {
                log.err("vz: suspend failed: {}; resuming", .{err});
                try machine.resumeVM();
                continue;
            };
            log.info("vz: suspended to warm state in {d} ms", .{nowMs() - t0});
            exitAfterSave();
        }
    }
    log.info("vz: machine stopped", .{});
}

const ProvisionContext = struct {
    console: *VzConsole,
    steps: []const []const u8,
    done: std.atomic.Value(bool),
};

fn provision(context: *ProvisionContext) void {
    defer context.done.store(true, .release);
    defer context.console.setCapture(false);
    console_exec.provision(&context.console.session, context.steps);
}

fn nowMs() i64 {
    return @intCast(@divTrunc(
        std.Io.Clock.awake.now(global.io()).nanoseconds,
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
    const startup_benchmark = std.c.getenv("BOBRVM_BENCHMARK_STARTUP") != null;

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
    if (startup_benchmark) {
        machine.logStartupProfile();
        try machine.stop();
        return;
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
                try checkpoint.replace(
                    arena,
                    suspend_path.?,
                    &machine,
                    saveMachineCheckpoint,
                );
                log.info("vz: paused and saved in {d} ms", .{nowMs() - t0});
                exitAfterSave();
            }
        }
    }
    log.info("vz: machine stopped", .{});
}

fn saveMachineCheckpoint(machine: *linux_vz.Machine, path: [:0]const u8) !void {
    try machine.saveTo(path);
}

/// Apple's save workflow quits with the VM paused. Normal object teardown can
/// destructively stop the VM and advance its external writable disk beyond the
/// saved machine checkpoint, so successful suspend ends the runner directly.
/// https://developer.apple.com/videos/play/wwdc2023/10007/
fn exitAfterSave() noreturn {
    std.process.exit(0);
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
