//! Shared VM execution logic for run and start commands.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const console_exec = @import("console_exec.zig");
const global = @import("../global.zig");
const KittyDisplay = @import("kitty_display.zig");
const KittyInput = @import("kitty_input.zig");
const machine = @import("../machine/main.zig");
const mininat = @import("../net/mininat.zig");
const os = @import("../os/main.zig");

const log = std.log.scoped(.cli);
const input_stack_size_bytes: usize = 1024 * 1024;
const kitty_sequence_timeout_ms: i32 = 25;

/// zig 0.16 removed std.Thread.sleep in favor of the Io.Clock
/// abstraction; thin wrapper for these debug-hook sleeps.
fn sleepNs(ns: u64) void {
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = @intCast(ns) },
        .clock = .awake,
    }, global.io()) catch {};
}

pub fn run(alloc: Allocator, config: *const Config) !void {
    return runWithReadyMarker(alloc, config, null);
}

/// Run a VM and optionally publish a host-only marker after restore. MCP uses
/// the marker to keep commands out of the guest console until restore is done.
pub fn runWithReadyMarker(
    alloc: Allocator,
    config: *const Config,
    ready_marker: ?[]const u8,
) !void {
    global.state.init();
    defer global.state.deinit();

    const allocation_benchmark = std.c.getenv("BOBRVM_BENCHMARK_ALLOCATIONS") != null;
    const startup_benchmark = allocation_benchmark or
        std.c.getenv("BOBRVM_BENCHMARK_STARTUP") != null;
    var allocation_counter = AllocationCounter.init(alloc);
    const machine_alloc = if (allocation_benchmark) allocation_counter.allocator() else alloc;

    // --restore <snapshot dir>: revert disks (clonefile the snapshot's
    // copies back over the originals) and point the machine at the
    // directory's state.img. A plain file path is used as-is.
    var restore_buf: [1024]u8 = undefined;
    var restore_path = config.restore_path;
    if (config.restore_path) |rp| {
        if (isDirectory(rp)) {
            try revertSnapshotDisks(alloc, rp);
            restore_path = try std.fmt.bufPrint(&restore_buf, "{s}/state.img", .{rp});
        }
    }

    // Must outlive the machine: MachineConfig.forwards borrows this array.
    var forwards_buf: [Config.MAX_FORWARDS]mininat.Forward = undefined;
    for (config.forwards[0..config.forward_count], 0..) |f, i| {
        forwards_buf[i] = .{ .host_port = f.host_port, .guest_port = f.guest_port };
    }

    const machine_config = machine.MachineConfig{
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
        .enable_gpu = config.enable_gpu,
        .enable_virgl = config.enable_virgl,
        .enable_net = config.enable_net,
        .enable_snd = config.enable_snd,
        .forwards = forwards_buf[0..config.forward_count],
        .docker_socket_path = config.docker_socket_path,
        .shared_dir = config.shared_dir,
        .share_read_only = config.share_read_only,
        .restore_path = restore_path,
        .display_width = config.display_width,
        .display_height = config.display_height,
        .gpu_memory_bytes = config.gpu_memory_mb * 1024 * 1024,
    };

    log.info("creating VM: {}MB RAM, {} vCPUs", .{
        config.memory_mb,
        config.vcpu_count,
    });

    if (config.firmware_path) |p| log.info("firmware: {s}", .{p});
    if (config.disk_path) |p| {
        log.info("disk: {s}{s}", .{ p, if (config.disk_read_only) " (read-only)" else "" });
    }
    if (config.disk2_path) |p| {
        log.info("disk2: {s}{s}", .{ p, if (config.disk2_read_only) " (read-only)" else "" });
    }
    if (config.kernel_path) |p| log.info("kernel: {s}", .{p});

    const hw = machine.Machine.init(machine_alloc, machine_config) catch |err| {
        log.err("failed to create machine: {}", .{err});
        return err;
    };
    defer hw.deinit();

    const stderr_logging_saved = global.state.logging.stderr;
    defer global.state.logging.stderr = stderr_logging_saved;
    if (config.kitty_display) global.state.logging.stderr = false;

    registerMachineForCleanup(hw);
    defer unregisterMachineForCleanup();
    suspend_target = config.suspend_path;
    defer suspend_target = null;

    // Detached runners have no console for Ctrl-B z; SIGUSR1 requests
    // the same suspend-and-quit. The handler only sets a flag — this
    // watcher does the heavy lifting and is joined before hw dies.
    var suspend_watcher_stop = std.atomic.Value(bool).init(false);
    var suspend_watcher: ?std.Thread = null;
    defer if (suspend_watcher) |thread| {
        suspend_watcher_stop.store(true, .release);
        thread.join();
    };
    if (config.suspend_path) |path| {
        os.signal.registerSuspendRequest();
        suspend_watcher = std.Thread.spawn(
            .{},
            suspendWatcher,
            .{ hw, path, &suspend_watcher_stop },
        ) catch null;
    }

    var show_console_output = !config.kitty_display;
    hw.setConsoleOutput(consoleOutput, &show_console_output);

    var kitty_display: ?KittyDisplay = null;
    var kitty_signal_cleanup = false;
    defer if (kitty_signal_cleanup) kitty_terminal_active.store(false, .release);
    defer if (kitty_display) |*display| display.deinit();
    if (config.kitty_display) {
        kitty_display = KittyDisplay.init(alloc, hw);
        hw.setFrameReadbackRequired(true);
        try kitty_display.?.start();
        kitty_terminal_active.store(true, .release);
        kitty_signal_cleanup = true;
        hw.setFrameCallback(KittyDisplay.frameReady, &kitty_display.?);
        log.info("Ghostty display attached (Ctrl-] to quit)", .{});
    }

    // Debug: dump scanout frames when BOBRVM_DUMP_FRAMES=<dir> is set.
    if (config.enable_gpu and !config.kitty_display) {
        if (std.c.getenv("BOBRVM_DUMP_FRAMES")) |dir| {
            frame_dump_dir = std.mem.span(dir);
            frame_machine = hw;
            hw.setFrameReadbackRequired(true);
            hw.setFrameCallback(frameDump, null);
        }

        // Debug: periodically inject synthetic key presses so guest-side
        // virtio-input delivery can be verified headlessly.
        if (std.c.getenv("BOBRVM_TEST_KEYS") != null) {
            const t = std.Thread.spawn(.{}, testKeyLoop, .{hw}) catch null;
            if (t) |thread| thread.detach();
        }

        // Debug: request a live guest display resize after a delay
        // (BOBRVM_TEST_RESIZE=WxH:delay_s), for verifying the resolution
        // hotplug path headlessly (combine with BOBRVM_DUMP_FRAMES — the
        // dumped frame filenames carry the scanout dimensions).
        if (std.c.getenv("BOBRVM_TEST_RESIZE")) |spec_ptr| {
            if (parseResizeSpec(std.mem.span(spec_ptr))) |spec| {
                const t = std.Thread.spawn(.{}, testResizeLoop, .{ hw, spec }) catch null;
                if (t) |thread| thread.detach();
            } else {
                log.warn("BOBRVM_TEST_RESIZE: expected WxH:delay_s, got '{s}'", .{std.mem.span(spec_ptr)});
            }
        }

        // Debug: type BOBRVM_TEST_TYPE on the virtio keyboard after
        // BOBRVM_TEST_TYPE_DELAY seconds (default 120), for verifying
        // the GUI shell path (VT keyboard -> tty1 getty) headlessly.
        if (std.c.getenv("BOBRVM_TEST_TYPE")) |text_ptr| {
            const text = std.mem.span(text_ptr);
            const delay_s: u64 = if (std.c.getenv("BOBRVM_TEST_TYPE_DELAY")) |d|
                std.fmt.parseInt(u64, std.mem.span(d), 10) catch 120
            else
                120;
            const t = std.Thread.spawn(.{}, testTypeLoop, .{ hw, text, delay_s }) catch null;
            if (t) |thread| thread.detach();
        }
    }

    if (startup_benchmark) {
        log.info("benchmarking VM startup through vCPU setup", .{});
        try hw.benchmarkStartupSync();
        if (allocation_benchmark) {
            log.info("startup allocations: {} calls, {} bytes", .{
                allocation_counter.allocations,
                allocation_counter.allocated_bytes,
            });
        }
        return;
    }

    // Debug: exercise the qemu-guest-agent channel after a delay
    // (BOBRVM_TEST_QGA=delay_s): sync + ping + interface query; parsed
    // responses appear in the qga log scope.
    if (std.c.getenv("BOBRVM_TEST_QGA")) |delay_ptr| {
        if (std.fmt.parseInt(u64, std.mem.span(delay_ptr), 10)) |delay_s| {
            const t = std.Thread.spawn(.{}, testQgaLoop, .{ hw, delay_s }) catch null;
            if (t) |thread| thread.detach();
        } else |_| {}
    }

    // Debug: take a live snapshot after a delay, VM keeps running
    // (BOBRVM_TEST_SNAPSHOT=delay_s:dir). Revert with --restore <dir>.
    if (std.c.getenv("BOBRVM_TEST_SNAPSHOT")) |spec_ptr| {
        const spec = std.mem.span(spec_ptr);
        if (std.mem.indexOfScalar(u8, spec, ':')) |colon| blk: {
            const delay_s = std.fmt.parseInt(u64, spec[0..colon], 10) catch break :blk;
            const t = std.Thread.spawn(.{}, testSnapshotLoop, .{ hw, delay_s, spec[colon + 1 ..] }) catch null;
            if (t) |thread| thread.detach();
        }
    }

    // Debug: suspend to disk after a delay and shut down
    // (BOBRVM_TEST_SUSPEND=delay_s:path). Restore with --restore <path>.
    if (std.c.getenv("BOBRVM_TEST_SUSPEND")) |spec_ptr| {
        const spec = std.mem.span(spec_ptr);
        if (std.mem.indexOfScalar(u8, spec, ':')) |colon| blk: {
            const delay_s = std.fmt.parseInt(u64, spec[0..colon], 10) catch break :blk;
            const t = std.Thread.spawn(.{}, testSuspendLoop, .{ hw, delay_s, spec[colon + 1 ..] }) catch null;
            if (t) |thread| thread.detach();
        }
    }

    // Debug: pause the machine after a delay, resume after a duration
    // (BOBRVM_TEST_PAUSE=delay_s:duration_s) — verifies real pause/resume
    // headlessly (guest execution provably freezes, then continues).
    if (std.c.getenv("BOBRVM_TEST_PAUSE")) |spec_ptr| {
        const spec = std.mem.span(spec_ptr);
        if (std.mem.indexOfScalar(u8, spec, ':')) |colon| blk: {
            const delay_s = std.fmt.parseInt(u64, spec[0..colon], 10) catch break :blk;
            const duration_s = std.fmt.parseInt(u64, spec[colon + 1 ..], 10) catch break :blk;
            const t = std.Thread.spawn(.{}, testPauseLoop, .{ hw, delay_s, duration_s }) catch null;
            if (t) |thread| thread.detach();
        }
    }

    // Interactive console: raw mode so keystrokes (including Ctrl-C) go to
    // the guest. Ctrl-] detaches; Ctrl-B prefixes host management commands.
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdin_is_tty = std.c.isatty(stdin_fd) != 0;
    if (stdin_is_tty) {
        if (std.posix.tcgetattr(stdin_fd)) |t| {
            saved_termios = t;
            var raw = t;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;
            std.posix.tcsetattr(stdin_fd, .NOW, raw) catch {};
            log.info("console attached (Ctrl-] to quit, Ctrl-B ? for host commands)", .{});
        } else |_| {}
    }
    defer restoreTermios();

    const input_thread = std.Thread.spawn(
        .{ .stack_size = input_stack_size_bytes },
        inputLoop,
        .{ hw, stdin_is_tty, config.kitty_display },
    ) catch |err| blk: {
        log.warn("failed to start console input thread: {}", .{err});
        break :blk null;
    };
    if (input_thread) |t| t.detach();

    const ready_thread: ?std.Thread = if (ready_marker) |marker|
        try std.Thread.spawn(.{}, readyNotifier, .{ hw, marker })
    else
        null;
    defer if (ready_thread) |thread| thread.join();

    // First-boot provisioning: run the project's provision steps over
    // the console once, on a cold boot only (a warm restore already
    // carries the provisioned state). Runs on a side thread because
    // startSync blocks; consoleOutput tees the guest console into the
    // session so marker detection works alongside the live console.
    var provision_session: console_exec.Session = undefined;
    var provision_thread: ?std.Thread = null;
    defer if (provision_thread) |thread| {
        thread.join();
        provision_active.store(false, .release);
        provision_session.deinit();
    };
    if (config.restore_path == null and config.provision_steps.len > 0) {
        provision_session = console_exec.Session.init(alloc, hw);
        active_provision_session = &provision_session;
        provision_active.store(true, .release);
        provision_thread = std.Thread.spawn(
            .{ .stack_size = input_stack_size_bytes },
            console_exec.provision,
            .{ &provision_session, config.provision_steps },
        ) catch null;
    }

    log.info("starting VM...", .{});
    hw.startSync() catch |err| {
        log.err("failed to start VM: {}", .{err});
        return err;
    };

    log.info("VM stopped", .{});
}

fn readyNotifier(hw: *machine.Machine, marker: []const u8) void {
    if (!hw.waitUntilRunning(30 * std.time.ns_per_s)) return;
    _ = std.c.write(std.posix.STDOUT_FILENO, marker.ptr, marker.len);
}

/// Console tee target for provisioning (see provisionLoop). Guarded by
/// provision_active so consoleOutput only touches it while live.
var active_provision_session: ?*console_exec.Session = null;
var provision_active = std.atomic.Value(bool).init(false);

var saved_termios: ?std.posix.termios = null;
var frame_dump_dir: ?[]const u8 = null;
var frame_machine: ?*machine.Machine = null;
var frame_count: u32 = 0;

const AllocationCounter = struct {
    backing: Allocator,
    allocations: usize = 0,
    allocated_bytes: usize = 0,

    fn init(backing: Allocator) AllocationCounter {
        return .{ .backing = backing };
    }

    fn allocator(self: *AllocationCounter) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *AllocationCounter = @ptrCast(@alignCast(ctx));
        const memory = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.allocations += 1;
        self.allocated_bytes += len;
        return memory;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *AllocationCounter = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) return false;
        if (new_len > memory.len) self.allocated_bytes += new_len - memory.len;
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *AllocationCounter = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        if (new_len > memory.len) self.allocated_bytes += new_len - memory.len;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *AllocationCounter = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

/// Inject 'a' key presses every second (BOBRVM_TEST_KEYS debug hook).
fn testKeyLoop(hw: *machine.Machine) void {
    sleepNs(15 * std.time.ns_per_s);
    var i: u32 = 0;
    while (i < 600) : (i += 1) {
        hw.injectKey(30, true); // KEY_A
        sleepNs(50 * std.time.ns_per_ms);
        hw.injectKey(30, false);
        sleepNs(1 * std.time.ns_per_s);
    }
}

/// Map an ASCII character to an evdev keycode (unshifted keys only).
fn asciiToEvdev(char: u8) u16 {
    return KittyInput.evdevForCodepoint(char);
}

/// Exercise the guest-agent channel (BOBRVM_TEST_QGA debug hook).
fn testQgaLoop(hw: *machine.Machine, delay_s: u64) void {
    sleepNs(delay_s * std.time.ns_per_s);
    log.info("probing guest agent (sync+ping+interfaces)", .{});
    hw.pingGuestAgent();
    hw.queryGuestIps();
}

fn isDirectory(path: []const u8) bool {
    const directory = std.Io.Dir.cwd().openDir(global.io(), path, .{}) catch return false;
    directory.close(global.io());
    return true;
}

/// Revert every disk recorded in a snapshot's meta.json: clonefile the
/// snapshot copy back over the original path (destructive by design —
/// that's what reverting to a snapshot means).
fn revertSnapshotDisks(alloc: Allocator, dir: []const u8) !void {
    const file_compat = @import("../compat/file.zig");
    var path_buf: [1024]u8 = undefined;
    const meta_path = try std.fmt.bufPrint(&path_buf, "{s}/meta.json", .{dir});
    const meta_file = try std.Io.Dir.cwd().openFile(global.io(), meta_path, .{ .mode = .read_only });
    defer meta_file.close(global.io());
    const meta_bytes = try file_compat.readToEndAlloc(meta_file, alloc, 1024 * 1024);
    defer alloc.free(meta_bytes);

    const Meta = struct {
        disks: []struct { orig: []const u8, copy: []const u8 },
    };
    var parsed = try std.json.parseFromSlice(Meta, alloc, meta_bytes, .{});
    defer parsed.deinit();

    for (parsed.value.disks) |disk| {
        var copy_buf: [1024]u8 = undefined;
        const copy_path = try std.fmt.bufPrint(&copy_buf, "{s}/{s}", .{ dir, disk.copy });
        log.info("reverting disk {s} from snapshot", .{disk.orig});
        try machine.Machine.cloneFile(alloc, copy_path, disk.orig);
    }
}

/// Take a live snapshot; VM keeps running (BOBRVM_TEST_SNAPSHOT hook).
fn testSnapshotLoop(hw: *machine.Machine, delay_s: u64, dir: []const u8) void {
    sleepNs(delay_s * std.time.ns_per_s);
    log.info("taking snapshot into {s}", .{dir});
    hw.snapshotTo(dir) catch |err| {
        log.err("snapshot failed: {}", .{err});
    };
}

/// Suspend to disk then shut down (BOBRVM_TEST_SUSPEND debug hook).
fn testSuspendLoop(hw: *machine.Machine, delay_s: u64, path: []const u8) void {
    sleepNs(delay_s * std.time.ns_per_s);
    log.info("suspending machine to {s}", .{path});
    hw.suspendToDisk(path) catch |err| {
        log.err("suspend failed: {}", .{err});
        return;
    };
    hw.requestStop();
}

/// Pause then resume the machine (BOBRVM_TEST_PAUSE debug hook).
fn testPauseLoop(hw: *machine.Machine, delay_s: u64, duration_s: u64) void {
    sleepNs(delay_s * std.time.ns_per_s);
    log.info("pausing machine for {}s", .{duration_s});
    hw.pause();
    sleepNs(duration_s * std.time.ns_per_s);
    log.info("resuming machine", .{});
    hw.unpause();
}

const ResizeSpec = struct {
    width: u32,
    height: u32,
    delay_s: u64,
};

/// Parse "WxH:delay_s" (BOBRVM_TEST_RESIZE debug hook).
fn parseResizeSpec(spec: []const u8) ?ResizeSpec {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    const x = std.mem.indexOfScalar(u8, spec[0..colon], 'x') orelse return null;
    return .{
        .width = std.fmt.parseInt(u32, spec[0..x], 10) catch return null,
        .height = std.fmt.parseInt(u32, spec[x + 1 .. colon], 10) catch return null,
        .delay_s = std.fmt.parseInt(u64, spec[colon + 1 ..], 10) catch return null,
    };
}

/// Request a guest display resize after a delay (BOBRVM_TEST_RESIZE hook).
fn testResizeLoop(hw: *machine.Machine, spec: ResizeSpec) void {
    sleepNs(spec.delay_s * std.time.ns_per_s);
    log.info("requesting guest display resize to {}x{}", .{ spec.width, spec.height });
    hw.requestDisplayResize(spec.width, spec.height);
    // Storm mode (BOBRVM_TEST_RESIZE_STORM=n:ms): follow with n rapid
    // alternating resizes, mimicking a live window drag, to chase modeset
    // races that a single hotplug never hits.
    const storm = std.c.getenv("BOBRVM_TEST_RESIZE_STORM") orelse return;
    const s = std.mem.span(storm);
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return;
    const n = std.fmt.parseInt(u32, s[0..colon], 10) catch return;
    const gap_ms = std.fmt.parseInt(u64, s[colon + 1 ..], 10) catch return;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        sleepNs(gap_ms * std.time.ns_per_ms);
        // Sweep through varied sizes (grow and shrink, odd heights).
        const w = spec.width -| (i % 5) * 137;
        const h = spec.height -| (i % 7) * 61;
        log.info("storm resize {}/{}: {}x{}", .{ i + 1, n, w, h });
        hw.requestDisplayResize(@max(w, 320), @max(h, 240));
    }
}

/// Type a string on the virtio keyboard (BOBRVM_TEST_TYPE debug hook).
fn testTypeLoop(hw: *machine.Machine, text: []const u8, delay_s: u64) void {
    sleepNs(delay_s * std.time.ns_per_s);
    log.info("typing test string on virtio keyboard", .{});
    for (text) |char| {
        const code = asciiToEvdev(char);
        if (code == 0) continue;
        hw.injectKey(code, true);
        sleepNs(40 * std.time.ns_per_ms);
        hw.injectKey(code, false);
        sleepNs(80 * std.time.ns_per_ms);
    }
}

/// Dump selected scanout frames as raw BGRA for debugging.
fn frameDump(_: ?*anyopaque) void {
    const dir = frame_dump_dir orelse return;
    const hw = frame_machine orelse return;
    const gpu = hw.gpu orelse return;
    const scan = gpu.scanout() orelse return;

    frame_count += 1;
    // First frames and every 120th thereafter.
    if (frame_count > 3 and frame_count % 120 != 0) return;

    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/frame-{d}-{d}x{d}.bgra", .{
        dir, frame_count, scan.width, scan.height,
    }) catch return;
    const file = std.Io.Dir.cwd().createFile(global.io(), path, .{}) catch return;
    defer file.close(global.io());
    if (scan.width == scan.full_width and scan.height == scan.full_height) {
        file.writePositionalAll(global.io(), scan.data, 0) catch {};
    } else {
        // Sub-rect scanout: extract the visible rows from the full-stride
        // resource so the dump matches the WxH in the filename.
        const stride: usize = @as(usize, scan.full_width) * 4;
        const row_bytes: usize = @as(usize, scan.width) * 4;
        var row: usize = 0;
        while (row < scan.height) : (row += 1) {
            const src_off = (@as(usize, scan.src_y) + row) * stride + @as(usize, scan.src_x) * 4;
            if (src_off + row_bytes > scan.data.len) break;
            file.writePositionalAll(global.io(), scan.data[src_off..][0..row_bytes], row * row_bytes) catch break;
        }
    }
    log.info("dumped frame {} ({}x{})", .{ frame_count, scan.width, scan.height });
}

fn restoreTermios() void {
    if (saved_termios) |t| {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, t) catch {};
        saved_termios = null;
    }
}

/// Reads host stdin and forwards it to the guest console. Runs detached;
/// the process exits (and reaps it) when the VM stops.
fn inputLoop(hw: *machine.Machine, is_tty: bool, kitty_mouse: bool) void {
    var buf: [1024]u8 = undefined;
    var decoder: KittyInput = .{};
    var host_input: HostInputState = .{};
    while (true) {
        // Bound incomplete CSI input so a truncated mouse or key report does
        // not remain buffered until another event happens to arrive.
        if (kitty_mouse and decoder.hasPending() and
            !stdinReady(kitty_sequence_timeout_ms))
        {
            if (decoder.flushPending()) |bytes| {
                if (!routeHostInput(hw, bytes, &host_input)) return;
            }
            continue;
        }

        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch break;
        if (n == 0) {
            if (kitty_mouse) {
                if (decoder.flushPending()) |bytes| {
                    _ = routeHostInput(hw, bytes, &host_input);
                }
            }
            // EOF. Interactive runs keep the VM alive (stdin may just be
            // closed); scripted harnesses set BOBRVM_EXIT_ON_EOF=1 to shut
            // the VM down when the feeder finishes — Ctrl-] can't serve
            // that role on a pipe (it needs the raw-mode tty path), which
            // is exactly how sleep-based feeders used to leave VMs running
            // forever.
            if (std.c.getenv("BOBRVM_EXIT_ON_EOF") != null) {
                log.info("stdin EOF: shutting down (BOBRVM_EXIT_ON_EOF)", .{});
                hw.requestStop();
            }
            break;
        }

        if (!is_tty) {
            hw.injectConsoleInput(buf[0..n]);
            continue;
        }

        if (kitty_mouse) {
            if (!routeKittyInput(hw, &decoder, buf[0..n], &host_input)) return;
            continue;
        }

        if (!routeHostInput(hw, buf[0..n], &host_input)) return;
    }
}

fn stdinReady(timeout_ms: i32) bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    return (std.posix.poll(&poll_fds, timeout_ms) catch return true) != 0;
}

fn routeKittyInput(
    hw: *machine.Machine,
    decoder: *KittyInput,
    bytes: []const u8,
    host_input: *HostInputState,
) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (!decoder.hasPending()) {
            const relative = std.mem.indexOfScalar(u8, bytes[offset..], '\x1b') orelse {
                return routeHostInput(hw, bytes[offset..], host_input);
            };
            if (relative > 0) {
                if (!routeHostInput(
                    hw,
                    bytes[offset..][0..relative],
                    host_input,
                )) return false;
                offset += relative;
                continue;
            }
        }

        switch (decoder.feed(bytes[offset])) {
            .pending => {},
            .forward => |forwarded| {
                if (!routeHostInput(hw, forwarded, host_input)) return false;
            },
            .key => |event| if (!routeKittyKey(hw, event, host_input)) return false,
            .mouse => |event| injectKittyMouse(hw, event),
        }
        offset += 1;
    }
    return true;
}

const HostInputState = struct {
    command_pending: bool = false,
    suppressed_release: u16 = 0,
};

fn routeKittyKey(
    hw: *machine.Machine,
    event: KittyInput.KeyEvent,
    host_input: *HostInputState,
) bool {
    if (event.evdev_code == host_input.suppressed_release) {
        if (event.action == .release) {
            host_input.suppressed_release = 0;
            return true;
        }
        if (event.action == .repeat) return true;
    }

    if (event.action == .press and isKittyControlKey(event, 'b')) {
        host_input.suppressed_release = event.evdev_code;
        if (host_input.command_pending) {
            host_input.command_pending = false;
            hw.injectKeyAction(event.evdev_code, .press);
            hw.injectKeyAction(event.evdev_code, .release);
        } else {
            host_input.command_pending = true;
        }
        return true;
    }

    if (host_input.command_pending and event.action == .press and !isKittyModifier(event)) {
        host_input.command_pending = false;
        host_input.suppressed_release = event.evdev_code;
        if (classifyKittyHostCommand(event)) |command| {
            executeHostCommand(hw, command);
        } else {
            log.warn("unknown host command key U+{x}; Ctrl-B ? lists commands", .{
                event.codepoint,
            });
        }
        return true;
    }

    if (event.action == .press and isKittyControlKey(event, ']')) {
        restoreTermios();
        std.posix.raise(std.posix.SIG.TERM) catch {};
        return false;
    }

    injectKittyKey(hw, event);
    return true;
}

fn injectKittyKey(hw: *machine.Machine, event: KittyInput.KeyEvent) void {
    if (event.evdev_code == 0) return;
    const action: machine.KeyAction = switch (event.action) {
        .press => .press,
        .repeat => .repeat,
        .release => .release,
    };
    hw.injectKeyAction(event.evdev_code, action);
}

fn isKittyControlKey(event: KittyInput.KeyEvent, key: u8) bool {
    if (event.modifiers & KittyInput.KeyEvent.Modifier.control == 0) return false;
    if (event.codepoint > std.math.maxInt(u8)) return false;
    return std.ascii.toLower(@as(u8, @intCast(event.codepoint))) == std.ascii.toLower(key);
}

fn isKittyModifier(event: KittyInput.KeyEvent) bool {
    return switch (event.evdev_code) {
        29, 42, 54, 56, 97, 100, 125, 126 => true,
        else => event.codepoint >= 57441 and event.codepoint <= 57454,
    };
}

fn classifyKittyHostCommand(event: KittyInput.KeyEvent) ?HostCommand {
    return classifyHostCommand(event.commandByte() orelse return null);
}

fn routeHostInput(
    hw: *machine.Machine,
    bytes: []const u8,
    host_input: *HostInputState,
) bool {
    var guest_start: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (host_input.command_pending) {
            if (guest_start < i) hw.injectConsoleInput(bytes[guest_start..i]);
            host_input.command_pending = false;
            if (classifyHostCommand(byte)) |command| {
                executeHostCommand(hw, command);
            } else {
                log.warn("unknown host command 0x{x}; Ctrl-B ? lists commands", .{byte});
            }
            guest_start = i + 1;
            continue;
        }

        if (byte == host_command_prefix) {
            if (guest_start < i) hw.injectConsoleInput(bytes[guest_start..i]);
            host_input.command_pending = true;
            guest_start = i + 1;
            continue;
        }

        // Ctrl-] detaches: forward everything before it, then shut down.
        if (byte == 0x1d) {
            if (guest_start < i) hw.injectConsoleInput(bytes[guest_start..i]);
            restoreTermios();
            std.posix.raise(std.posix.SIG.TERM) catch {};
            return false;
        }
    }
    if (guest_start < bytes.len) hw.injectConsoleInput(bytes[guest_start..]);
    return true;
}

fn injectKittyMouse(hw: *machine.Machine, event: KittyInput.MouseEvent) void {
    const size = KittyInput.terminalPixelSize(std.posix.STDOUT_FILENO) orelse return;
    const guest = KittyInput.translate(event, size);
    hw.injectMousePosition(guest.x, guest.y);
    switch (guest.action) {
        .none => {},
        .button => |button| hw.injectMouseButton(button.code, button.pressed),
        .scroll => |scroll| hw.injectScroll(scroll.dx, scroll.dy),
    }
}

/// Service SIGUSR1 suspend requests (the flag is all the handler may
/// touch); ends after a successful suspend or when the run finishes.
fn suspendWatcher(
    hw: *machine.Machine,
    path: []const u8,
    stop: *std.atomic.Value(bool),
) void {
    while (!stop.load(.acquire)) {
        if (os.signal.takeSuspendRequest()) {
            log.info("suspending machine to {s} (SIGUSR1)", .{path});
            hw.suspendToDisk(path) catch |err| {
                log.err("suspend failed: {}; resuming", .{err});
                hw.unpause();
                continue;
            };
            hw.requestStop();
            return;
        }
        sleepNs(100 * std.time.ns_per_ms);
    }
}

const host_command_prefix: u8 = 0x02;

/// Target for the suspend-and-quit console command; set from the
/// config before the input thread starts (same lifetime pattern as
/// cleanup_machine).
var suspend_target: ?[]const u8 = null;

const HostCommand = enum {
    literal_prefix,
    help,
    ctrl_alt_delete,
    status,
    shutdown,
    reboot,
    sync_time,
    trim,
    suspend_quit,
};

fn classifyHostCommand(byte: u8) ?HostCommand {
    return switch (byte) {
        host_command_prefix => .literal_prefix,
        '?' => .help,
        'd' => .ctrl_alt_delete,
        'p' => .status,
        's' => .shutdown,
        'r' => .reboot,
        't' => .sync_time,
        'f' => .trim,
        'z' => .suspend_quit,
        else => null,
    };
}

fn executeHostCommand(hw: *machine.Machine, command: HostCommand) void {
    switch (command) {
        .literal_prefix => hw.injectConsoleInput(&.{host_command_prefix}),
        .help => log.info(
            "host commands: d=ctrl-alt-delete p=status s=shutdown r=reboot " ++
                "t=sync-time f=trim z=suspend+quit Ctrl-B=literal",
            .{},
        ),
        .ctrl_alt_delete => injectCtrlAltDelete(hw),
        .status => log.info("guest tools: {s}, capabilities=0x{x}", .{
            @tagName(hw.guestToolsStatus()),
            hw.guestToolsCapabilities(),
        }),
        .shutdown => hw.requestGuestShutdown(),
        .reboot => hw.requestGuestReboot(),
        .sync_time => hw.syncGuestTime(),
        .trim => hw.trimGuestFilesystems(),
        .suspend_quit => {
            const path = suspend_target orelse {
                log.warn("no suspend target configured (--suspend-to <path>)", .{});
                return;
            };
            log.info("suspending machine to {s}", .{path});
            hw.suspendToDisk(path) catch |err| {
                log.err("suspend failed: {}; resuming", .{err});
                hw.unpause();
                return;
            };
            hw.requestStop();
        },
    }
}

const ctrl_alt_delete = [_]struct {
    keycode: u16,
    action: machine.KeyAction,
}{
    .{ .keycode = 29, .action = .press }, // KEY_LEFTCTRL
    .{ .keycode = 56, .action = .press }, // KEY_LEFTALT
    .{ .keycode = 111, .action = .press }, // KEY_DELETE
    .{ .keycode = 111, .action = .release },
    .{ .keycode = 56, .action = .release },
    .{ .keycode = 29, .action = .release },
};

fn injectCtrlAltDelete(hw: *machine.Machine) void {
    for (ctrl_alt_delete) |event| {
        hw.injectKeyAction(event.keycode, event.action);
    }
}

test "host console command decoder" {
    try std.testing.expectEqual(HostCommand.help, classifyHostCommand('?').?);
    try std.testing.expectEqual(HostCommand.ctrl_alt_delete, classifyHostCommand('d').?);
    try std.testing.expectEqual(HostCommand.status, classifyHostCommand('p').?);
    try std.testing.expectEqual(HostCommand.shutdown, classifyHostCommand('s').?);
    try std.testing.expectEqual(HostCommand.reboot, classifyHostCommand('r').?);
    try std.testing.expectEqual(HostCommand.sync_time, classifyHostCommand('t').?);
    try std.testing.expectEqual(HostCommand.trim, classifyHostCommand('f').?);
    try std.testing.expectEqual(HostCommand.suspend_quit, classifyHostCommand('z').?);
    try std.testing.expectEqual(HostCommand.literal_prefix, classifyHostCommand(0x02).?);
    try std.testing.expect(classifyHostCommand('x') == null);
}

test "Ctrl-Alt-Delete presses modifiers before releasing them" {
    const keycodes = [_]u16{ 29, 56, 111, 111, 56, 29 };
    const actions = [_]machine.KeyAction{
        .press,
        .press,
        .press,
        .release,
        .release,
        .release,
    };
    for (ctrl_alt_delete, keycodes, actions) |event, keycode, action| {
        try std.testing.expectEqual(keycode, event.keycode);
        try std.testing.expectEqual(action, event.action);
    }
}

test "Kitty host shortcuts use physical and shifted key codes" {
    const prefix: KittyInput.KeyEvent = .{
        .evdev_code = 48,
        .codepoint = 'b',
        .shifted_codepoint = null,
        .modifiers = KittyInput.KeyEvent.Modifier.control,
        .action = .press,
    };
    try std.testing.expect(isKittyControlKey(prefix, 'b'));

    const help: KittyInput.KeyEvent = .{
        .evdev_code = 53,
        .codepoint = '/',
        .shifted_codepoint = '?',
        .modifiers = KittyInput.KeyEvent.Modifier.shift,
        .action = .press,
    };
    try std.testing.expectEqual(HostCommand.help, classifyKittyHostCommand(help).?);

    const modifier: KittyInput.KeyEvent = .{
        .evdev_code = 42,
        .codepoint = 57441,
        .shifted_codepoint = null,
        .modifiers = KittyInput.KeyEvent.Modifier.shift,
        .action = .press,
    };
    try std.testing.expect(isKittyModifier(modifier));
}

fn consoleOutput(data: []const u8, userdata: ?*anyopaque) void {
    const show: *const bool = @ptrCast(@alignCast(userdata orelse return));
    if (show.*) {
        const stdout = std.posix.STDOUT_FILENO;
        _ = std.c.write(stdout, data.ptr, data.len);
    }
    // Tee to the provisioning session while it is running, so its
    // marker detection sees the same console stream the user does.
    if (provision_active.load(.acquire)) {
        if (active_provision_session) |session| {
            console_exec.Session.sink(data, session);
        }
    }
}

var cleanup_machine: ?*machine.Machine = null;
var kitty_terminal_active = std.atomic.Value(bool).init(false);

fn registerMachineForCleanup(hw: *machine.Machine) void {
    cleanup_machine = hw;
    os.signal.registerCleanup(machineCleanup);
}

fn unregisterMachineForCleanup() void {
    cleanup_machine = null;
    os.signal.unregisterCleanup();
}

/// Signal-handler cleanup. Runs in async-signal context while the vCPU
/// and NAT threads are still live, so it must NOT free anything or take
/// locks (the old hw.deinit() here use-after-freed device state out from
/// under running threads → segfault under load). The process exits right
/// after; the kernel reclaims memory and releases the HVF VM. We only
/// request the vCPUs to stop and restore the terminal.
fn machineCleanup() void {
    restoreTermios();
    if (kitty_terminal_active.load(.acquire)) {
        KittyDisplay.restoreTerminalSignalSafe();
    }
    if (cleanup_machine) |hw| {
        hw.requestStop();
    }
}
