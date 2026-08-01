//! Xcodebuild invocation step.
//!
//! Builds the macOS app using xcodebuild after the XCFramework is ready.
//! Pattern follows Ghostty's src/build/GhosttyXcodebuild.zig.

const XcodebuildStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const XCFrameworkStep = @import("XCFrameworkStep.zig");

step: Step,
xcframework: *XCFrameworkStep,
configuration: Configuration,

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
    const self = b.allocator.create(XcodebuildStep) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "xcodebuild",
            .owner = b,
            .makeFn = make,
        }),
        .xcframework = xcframework,
        .configuration = switch (optimize) {
            .Debug => .Debug,
            else => .Release,
        },
    };

    self.step.dependOn(&xcframework.step);

    return self;
}

fn make(step: *Step, opts: Step.MakeOptions) !void {
    _ = opts;
    const self: *XcodebuildStep = @fieldParentPtr("step", step);
    const b = step.owner;
    const xcodeproj_path = b.pathFromRoot("macos/Bobrvm.xcodeproj");
    const derived_data_path = b.pathFromRoot("zig-out/xcode-derived-data");

    // Run xcodebuild
    var exit_code: u8 = 0;
    _ = b.runAllowFail(&.{
        "xcodebuild",
        "-project",
        xcodeproj_path,
        "-scheme",
        "Bobrvm",
        "-configuration",
        self.configuration.toString(),
        "-derivedDataPath",
        derived_data_path,
        "CODE_SIGNING_ALLOWED=YES",
        "-quiet",
        "build",
    }, &exit_code, .inherit) catch {
        return error.XcodebuildFailed;
    };
}

pub fn getAppPath(self: *XcodebuildStep) []const u8 {
    _ = self;
    return "macos/build/Build/Products/Debug/Bobrvm.app";
}
