//! Deterministic initramfs payload for the Linux KVM boot test.

const std = @import("std");

const marker = "BOBRVM_LINUX_INIT_OK\n";

pub fn main() noreturn {
    if (std.os.linux.syscall3(.ioperm, 0xe9, 1, 1) == 0) {
        for (marker) |byte| out(0xe9, byte);
    }
    std.posix.reboot(.{ .POWER_OFF = {} }) catch {};
    std.os.linux.exit_group(1);
}

fn out(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}
