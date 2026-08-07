//! Stage-1 initramfs payload for the Linux KVM root-filesystem test.

const std = @import("std");

const linux = std.os.linux;
const module_paths = [_][:0]const u8{
    "/modules/virtio_ring.ko",
    "/modules/virtio.ko",
    "/modules/virtio_pci_modern_dev.ko",
    "/modules/virtio_pci_legacy_dev.ko",
    "/modules/virtio_pci.ko",
    "/modules/failover.ko",
    "/modules/net_failover.ko",
    "/modules/virtio_net.ko",
    "/modules/af_packet.ko",
    "/modules/virtio_blk.ko",
    "/modules/crc16.ko",
    "/modules/mbcache.ko",
    "/modules/jbd2.ko",
    "/modules/ext4.ko",
};

pub fn main() noreturn {
    const debug_port_available = linux.syscall3(.ioperm, 0xe9, 1, 1) == 0;
    _ = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    for (module_paths) |path| {
        if (!loadModule(path) and debug_port_available) {
            emit("BOBRVM_MODULE_LOAD_FAILED ");
            emit(path);
            emit("\n");
        }
    }

    if (linux.errno(linux.mount("/dev/vda", "/newroot", "ext4", 0, 0)) != .SUCCESS) {
        if (debug_port_available) emit("BOBRVM_ROOTFS_MOUNT_FAILED\n");
        restart();
    }
    if (linux.errno(linux.mount("devtmpfs", "/newroot/dev", "devtmpfs", 0, 0)) != .SUCCESS or
        linux.errno(linux.mount("proc", "/newroot/proc", "proc", 0, 0)) != .SUCCESS or
        linux.errno(linux.mount("sysfs", "/newroot/sys", "sysfs", 0, 0)) != .SUCCESS)
    {
        if (debug_port_available) emit("BOBRVM_PSEUDOFS_MOUNT_FAILED\n");
        restart();
    }
    if (linux.errno(linux.chroot("/newroot")) != .SUCCESS or
        linux.errno(linux.chdir("/")) != .SUCCESS)
    {
        if (debug_port_available) emit("BOBRVM_ROOTFS_CHROOT_FAILED\n");
        restart();
    }

    const argv = [_:null]?[*:0]const u8{"/init"};
    const envp = [_:null]?[*:0]const u8{};
    _ = linux.execve("/init", &argv, &envp);
    if (debug_port_available) emit("BOBRVM_ROOTFS_EXEC_FAILED\n");
    restart();
}

fn restart() noreturn {
    std.posix.reboot(.{ .RESTART = {} }) catch {};
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
