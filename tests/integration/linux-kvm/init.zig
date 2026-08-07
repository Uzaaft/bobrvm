//! Deterministic initramfs payload for the Linux KVM boot test.

const std = @import("std");

const linux = std.os.linux;
const init_marker = "BOBRVM_LINUX_INIT_OK\n";
const disk_marker = "BOBRVM_DISK_READ_OK\n";
const disk_contents = "bobrvm-disk-fixture\n";
const module_paths = [_][:0]const u8{
    "/modules/virtio_ring.ko",
    "/modules/virtio.ko",
    "/modules/virtio_pci_modern_dev.ko",
    "/modules/virtio_pci_legacy_dev.ko",
    "/modules/virtio_pci.ko",
    "/modules/virtio_blk.ko",
};

pub fn main() noreturn {
    const debug_port_available = linux.syscall3(.ioperm, 0xe9, 1, 1) == 0;
    _ = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    for (module_paths) |path| {
        if (!loadModule(path) and debug_port_available) {
            emit("BOBRVM_MODULE_LOAD_FAILED\n");
        }
    }

    if (readDiskMarker() and debug_port_available) emit(disk_marker);
    if (debug_port_available) emit(init_marker);
    std.posix.reboot(.{ .POWER_OFF = {} }) catch {};
    linux.exit_group(1);
}

fn loadModule(path: [:0]const u8) bool {
    const fd = openRead(path) orelse return false;
    defer _ = linux.close(fd);
    const parameters: [:0]const u8 = "";
    const result = linux.syscall3(
        .finit_module,
        @intCast(fd),
        @intFromPtr(parameters.ptr),
        0,
    );
    return linux.errno(result) == .SUCCESS;
}

fn readDiskMarker() bool {
    const fd = openRead("/dev/vda") orelse return false;
    defer _ = linux.close(fd);
    var buffer: [disk_contents.len]u8 = undefined;
    const result = linux.read(fd, &buffer, buffer.len);
    if (linux.errno(result) != .SUCCESS or result != buffer.len) return false;
    return std.mem.eql(u8, &buffer, disk_contents);
}

fn openRead(path: [:0]const u8) ?i32 {
    const result = linux.open(path, .{}, 0);
    if (linux.errno(result) != .SUCCESS) return null;
    return @intCast(result);
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
