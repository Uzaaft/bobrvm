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
    const derived_data_path = b.pathFromRoot("zig-out/xcode-derived-data");

    // Xcode must not inherit compiler and linker overrides from a Nix shell.
    const env_map = b.allocator.create(std.process.Environ.Map) catch @panic("OOM");
    env_map.* = .init(b.allocator);
    if (b.graph.environ_map.get("HOME")) |home| {
        env_map.put("HOME", home) catch @panic("OOM");
    }
    env_map.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin") catch @panic("OOM");

    const build_step = RunStep.create(b, "xcodebuild");
    build_step.has_side_effects = true;
    build_step.environ_map = env_map;
    build_step.addArgs(&.{
        "xcodebuild",
        "-project",
        b.pathFromRoot("macos/Bobrvm.xcodeproj"),
        "-scheme",
        "Bobrvm",
        "-configuration",
        configuration.toString(),
        "-derivedDataPath",
        derived_data_path,
        "CODE_SIGNING_ALLOWED=YES",
        "ONLY_ACTIVE_ARCH=YES",
        "-quiet",
        "build",
    });
    build_step.expectExitCode(0);
    build_step.step.dependOn(&xcframework.step);

    const self = b.allocator.create(XcodebuildStep) catch @panic("OOM");
    self.* = .{
        .build = build_step,
        .app_executable = b.fmt(
            "{s}/Build/Products/{s}/Bobrvm.app/Contents/MacOS/Bobrvm",
            .{ derived_data_path, configuration.toString() },
        ),
    };

    return self;
}
