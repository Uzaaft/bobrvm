//! Platform and optimization workarounds.

const std = @import("std");
const builtin = @import("builtin");

/// Uses `std.debug.assert` in Debug and an optimization assumption in releases.
pub const inlineAssert = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => (struct {
        pub inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};

pub inline fn compilerFence() void {
    asm volatile ("" ::: .memory);
}

pub fn isAppleSilicon() bool {
    return builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;
}

test "inlineAssert" {
    inlineAssert(true);
    inlineAssert(1 + 1 == 2);
}
