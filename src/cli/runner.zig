//! Shared VM execution logic for run and start commands.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const global = @import("../global.zig");
const machine = @import("../machine/main.zig");
const os = @import("../os/main.zig");

const log = std.log.scoped(.cli);

/// zig 0.16 removed std.Thread.sleep in favor of the Io.Clock
/// abstraction; thin wrapper for these debug-hook sleeps.
fn sleepNs(ns: u64) void {
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = @intCast(ns) },
        .clock = .awake,
    }, global.io()) catch {};
}

pub fn run(alloc: Allocator, config: *const Config) !void {
    global.state.init();
    defer global.state.deinit();

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
        .display_width = config.display_width,
        .display_height = config.display_height,
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

    const hw = machine.Machine.init(alloc, machine_config) catch |err| {
        log.err("failed to create machine: {}", .{err});
        return err;
    };
    defer hw.deinit();

    registerMachineForCleanup(hw);
    defer unregisterMachineForCleanup();

    hw.setConsoleOutput(consoleOutput, null);

    // Debug: dump scanout frames when BOBRVM_DUMP_FRAMES=<dir> is set.
    if (config.enable_gpu) {
        if (std.c.getenv("BOBRVM_DUMP_FRAMES")) |dir| {
            frame_dump_dir = std.mem.span(dir);
            frame_machine = hw;
            hw.setFrameCallback(frameDump, null);
        }

        // Debug: periodically inject synthetic key presses so guest-side
        // virtio-input delivery can be verified headlessly.
        if (std.c.getenv("BOBRVM_TEST_KEYS") != null) {
            const t = std.Thread.spawn(.{}, testKeyLoop, .{hw}) catch null;
            if (t) |thread| thread.detach();
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

    // Interactive console: raw mode so keystrokes (including Ctrl-C) go to
    // the guest. Ctrl-] detaches and shuts down, like telnet.
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
            log.info("console attached (Ctrl-] to quit)", .{});
        } else |_| {}
    }
    defer restoreTermios();

    const input_thread = std.Thread.spawn(.{}, inputLoop, .{ hw, stdin_is_tty }) catch |err| blk: {
        log.warn("failed to start console input thread: {}", .{err});
        break :blk null;
    };
    if (input_thread) |t| t.detach();

    log.info("starting VM...", .{});
    hw.startSync() catch |err| {
        log.err("failed to start VM: {}", .{err});
        return err;
    };

    log.info("VM stopped", .{});
}

var saved_termios: ?std.posix.termios = null;
var frame_dump_dir: ?[]const u8 = null;
var frame_machine: ?*machine.Machine = null;
var frame_count: u32 = 0;

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
    return switch (char) {
        'a' => 30,
        'b' => 48,
        'c' => 46,
        'd' => 32,
        'e' => 18,
        'f' => 33,
        'g' => 34,
        'h' => 35,
        'i' => 23,
        'j' => 36,
        'k' => 37,
        'l' => 38,
        'm' => 50,
        'n' => 49,
        'o' => 24,
        'p' => 25,
        'q' => 16,
        'r' => 19,
        's' => 31,
        't' => 20,
        'u' => 22,
        'v' => 47,
        'w' => 17,
        'x' => 45,
        'y' => 21,
        'z' => 44,
        '1' => 2,
        '2' => 3,
        '3' => 4,
        '4' => 5,
        '5' => 6,
        '6' => 7,
        '7' => 8,
        '8' => 9,
        '9' => 10,
        '0' => 11,
        ' ' => 57,
        '\n' => 28,
        '-' => 12,
        '=' => 13,
        '/' => 53,
        '.' => 52,
        ',' => 51,
        ';' => 39,
        else => 0,
    };
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
    file.writePositionalAll(global.io(), scan.data, 0) catch {};
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
fn inputLoop(hw: *machine.Machine, is_tty: bool) void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch break;
        if (n == 0) break; // EOF: keep VM running, stop forwarding

        if (is_tty) {
            // Ctrl-] detaches: forward everything before it, then shut down.
            if (std.mem.indexOfScalar(u8, buf[0..n], 0x1d)) |esc| {
                if (esc > 0) hw.injectConsoleInput(buf[0..esc]);
                restoreTermios();
                std.posix.raise(std.posix.SIG.TERM) catch {};
                return;
            }
        }

        hw.injectConsoleInput(buf[0..n]);
    }
}

fn consoleOutput(data: []const u8, _: ?*anyopaque) void {
    const stdout = std.posix.STDOUT_FILENO;
    _ = std.c.write(stdout, data.ptr, data.len);
}

var cleanup_machine: ?*machine.Machine = null;

fn registerMachineForCleanup(hw: *machine.Machine) void {
    cleanup_machine = hw;
    os.signal.registerCleanup(machineCleanup);
}

fn unregisterMachineForCleanup() void {
    cleanup_machine = null;
}

/// Signal-handler cleanup. Runs in async-signal context while the vCPU
/// and NAT threads are still live, so it must NOT free anything or take
/// locks (the old hw.deinit() here use-after-freed device state out from
/// under running threads → segfault under load). The process exits right
/// after; the kernel reclaims memory and releases the HVF VM. We only
/// request the vCPUs to stop and restore the terminal.
fn machineCleanup() void {
    restoreTermios();
    if (cleanup_machine) |hw| {
        hw.requestStop();
    }
}
