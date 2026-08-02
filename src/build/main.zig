//! Build system modules for bobrvm.

const std = @import("std");

pub const XCFrameworkStep = @import("XCFrameworkStep.zig");
pub const XcodebuildStep = @import("XcodebuildStep.zig");

/// Build configuration options.
pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    pub fn isMacOS(self: Config) bool {
        return self.target.result.os.tag == .macos;
    }

    pub fn isAppleSilicon(self: Config) bool {
        return self.isMacOS() and self.target.result.cpu.arch == .aarch64;
    }
};
