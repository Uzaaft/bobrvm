//! Host-side guest-agent protocol handlers (spoken over virtio-console
//! multiport ports; the guest runs stock distro agents).

pub const qga = @import("qga.zig");
pub const Qga = qga.Qga;
pub const native = @import("native.zig");
pub const Native = native.Native;
pub const vdagent = @import("vdagent.zig");
pub const Vdagent = vdagent.Vdagent;

test {
    @import("std").testing.refAllDecls(@This());
}
