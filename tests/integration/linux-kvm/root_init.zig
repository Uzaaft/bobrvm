//! Stage-2 init executed from the writable virtio root filesystem.

const std = @import("std");

const linux = std.os.linux;
const rootfs_contents = "bobrvm-root-filesystem\n";
const persisted_contents = "bobrvm-root-write-ok\n";
const console_input = "bobrvm-input-ok";

pub fn main() noreturn {
    const debug_port_available = linux.syscall3(.ioperm, 0xe9, 1, 1) == 0;
    if (!readExact("/rootfs-marker", rootfs_contents)) {
        if (debug_port_available) emit("BOBRVM_ROOTFS_CONTENT_FAILED\n");
        restart();
    }
    if (!writeExact("/bobrvm-write-marker", persisted_contents)) {
        if (debug_port_available) emit("BOBRVM_ROOTFS_WRITE_FAILED\n");
        restart();
    }
    const remount_flags = linux.MS.RDONLY | linux.MS.REMOUNT;
    if (linux.errno(linux.mount(null, "/", null, remount_flags, 0)) != .SUCCESS) {
        if (debug_port_available) emit("BOBRVM_ROOTFS_REMOUNT_FAILED\n");
        restart();
    }
    if (debug_port_available) emit("BOBRVM_ROOTFS_BOOT_OK\n");
    if (commandLineContains("bobrvm.console_test=1")) {
        if (debug_port_available) emit("BOBRVM_CONSOLE_INPUT_READY\n");
        if (!readConsoleLine(console_input)) {
            if (debug_port_available) emit("BOBRVM_CONSOLE_INPUT_FAILED\n");
            restart();
        }
        if (debug_port_available) emit("BOBRVM_CONSOLE_INPUT_OK\n");
    }
    restart();
}

fn commandLineContains(parameter: []const u8) bool {
    const result = linux.open("/proc/cmdline", .{}, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var buffer: [4096]u8 = undefined;
    const count = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS) return false;
    return std.mem.indexOf(u8, buffer[0..count], parameter) != null;
}

fn readConsoleLine(expected: []const u8) bool {
    const result = linux.open("/dev/ttyS0", .{}, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var buffer: [64]u8 = undefined;
    var len: usize = 0;
    while (len < buffer.len) {
        const count = linux.read(fd, buffer[len..].ptr, buffer.len - len);
        if (linux.errno(count) != .SUCCESS or count == 0) return false;
        len += count;
        if (std.mem.indexOfScalar(u8, buffer[0..len], '\n')) |newline| {
            return std.mem.eql(u8, buffer[0..newline], expected);
        }
    }
    return false;
}

fn readExact(path: [:0]const u8, expected: []const u8) bool {
    const result = linux.open(path, .{}, 0);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    var buffer: [rootfs_contents.len]u8 = undefined;
    const count = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(count) != .SUCCESS or count != expected.len) return false;
    return std.mem.eql(u8, buffer[0..expected.len], expected);
}

fn writeExact(path: [:0]const u8, bytes: []const u8) bool {
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .SYNC = true,
    };
    const result = linux.open(path, flags, 0o644);
    if (linux.errno(result) != .SUCCESS) return false;
    const fd: i32 = @intCast(result);
    defer _ = linux.close(fd);

    const count = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(count) != .SUCCESS or count != bytes.len) return false;
    return linux.errno(linux.fsync(fd)) == .SUCCESS;
}

fn restart() noreturn {
    std.posix.reboot(.{ .RESTART = {} }) catch {};
    linux.exit_group(1);
}

fn emit(bytes: []const u8) void {
    for (bytes) |byte| out(0xe9, byte);
}

fn out(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}
