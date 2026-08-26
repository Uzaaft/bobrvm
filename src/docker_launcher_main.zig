//! Standalone entry point for the app-bundled Docker launcher.

const launcher = @import("cli/docker_launcher.zig");

pub fn main(minimal: @import("std").process.Init.Minimal) !void {
    return launcher.main(minimal);
}
