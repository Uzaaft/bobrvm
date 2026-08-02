//! Optimization quirks and workarounds.
//!
//! Central location for platform-specific optimizations.

const std = @import("std");
const builtin = @import("builtin");

/// Custom inline assert that avoids function call overhead in release builds.
/// In debug mode, uses std.debug.assert.
/// In release modes, compiles to unreachable for better optimization.
pub const inlineAssert = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => (struct {
        pub inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};

/// Compiler fence to prevent reordering.
pub inline fn compilerFence() void {
    asm volatile ("" ::: .memory);
}

/// Check if running on Apple Silicon.
pub fn isAppleSilicon() bool {
    return builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;
}

test "inlineAssert" {
    inlineAssert(true);
    inlineAssert(1 + 1 == 2);
}
