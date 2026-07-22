//! Shared VM execution logic for run and start commands.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const global = @import("../global.zig");
const machine = @import("../machine/main.zig");
const os = @import("../os/main.zig");

const log = std.log.scoped(.cli);

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

    // Interactive console: raw mode so keystrokes (including Ctrl-C) go to
    // the guest. Ctrl-] detaches and shuts down, like telnet.
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdin_is_tty = std.posix.isatty(stdin_fd);
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
    _ = std.posix.write(stdout, data) catch {};
}

var cleanup_machine: ?*machine.Machine = null;

fn registerMachineForCleanup(hw: *machine.Machine) void {
    cleanup_machine = hw;
    os.signal.registerCleanup(machineCleanup);
}

fn unregisterMachineForCleanup() void {
    cleanup_machine = null;
}

fn machineCleanup() void {
    if (cleanup_machine) |hw| {
        hw.deinit();
        cleanup_machine = null;
    }
}
