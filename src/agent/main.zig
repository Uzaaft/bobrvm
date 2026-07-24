//! Host-side guest-agent protocol handlers (spoken over virtio-console
//! multiport ports; the guest runs stock distro agents).

pub const qga = @import("qga.zig");
pub const Qga = qga.Qga;

test {
    @import("std").testing.refAllDecls(@This());
}
