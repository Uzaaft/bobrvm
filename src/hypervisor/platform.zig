//! Host hypervisor selection.

const builtin = @import("builtin");

pub const backend = switch (builtin.os.tag) {
    .linux => @import("kvm/main.zig"),
    .macos => @import("main.zig"),
    else => @compileError("bobrvm requires a Linux or macOS host"),
};

pub const VM = backend.VM;
pub const Vcpu = backend.Vcpu;
pub const Error = backend.Error;

/// Linux callers use this handle to validate KVM before creating a VM.
pub const Kvm = if (builtin.os.tag == .linux) backend.Kvm else void;

test {
    _ = backend;
}
