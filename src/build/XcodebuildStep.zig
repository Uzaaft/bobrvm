//! Builds the native macOS app after its Zig XCFramework is ready.

const XcodebuildStep = @This();

const std = @import("std");
const RunStep = std.Build.Step.Run;
const XCFrameworkStep = @import("XCFrameworkStep.zig");

build: *RunStep,
app_executable: []const u8,

pub const Configuration = enum {
    Debug,
    Release,

    pub fn toString(self: Configuration) []const u8 {
        return switch (self) {
            .Debug => "Debug",
            .Release => "Release",
        };
    }
};

pub fn create(
    b: *std.Build,
    xcframework: *XCFrameworkStep,
    optimize: std.builtin.OptimizeMode,
) *XcodebuildStep {
    const configuration: Configuration = switch (optimize) {
        .Debug => .Debug,
        else => .Release,
    };
    const build_step = RunStep.create(b, "macos/build.nu");
    build_step.has_side_effects = true;
    build_step.addArgs(&.{
        b.pathFromRoot("macos/build.nu"),
        "--configuration",
        configuration.toString(),
    });
    build_step.expectExitCode(0);
    build_step.step.dependOn(&xcframework.step);

    const self = b.allocator.create(XcodebuildStep) catch @panic("OOM");
    self.* = .{
        .build = build_step,
        .app_executable = b.pathFromRoot(b.fmt(
            "macos/build/{s}/Bobrvm.app/Contents/MacOS/Bobrvm",
            .{configuration.toString()},
        )),
    };

    return self;
}
