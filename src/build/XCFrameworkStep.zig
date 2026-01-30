//! XCFramework generation step.
//!
//! Creates BobrvmKit.xcframework from the static library and headers.
//! Pattern follows Ghostty's src/build/XCFrameworkStep.zig.

const XCFrameworkStep = @This();

const std = @import("std");
const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;

step: Step,
lib: *std.Build.Step.Compile,
output_path: LazyPath,

pub fn create(b: *std.Build, lib: *std.Build.Step.Compile) *XCFrameworkStep {
    const self = b.allocator.create(XCFrameworkStep) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "xcframework",
            .owner = b,
            .makeFn = make,
        }),
        .lib = lib,
        .output_path = .{ .cwd_relative = "macos/BobrvmKit.xcframework" },
    };

    self.step.dependOn(&lib.step);

    return self;
}

fn make(step: *Step, opts: Step.MakeOptions) !void {
    _ = opts;
    const self: *XCFrameworkStep = @fieldParentPtr("step", step);
    const b = step.owner;

    const lib_path = self.lib.getEmittedBin().getPath2(b, step);
    const header_path = b.pathFromRoot("include");
    const output_path = b.pathFromRoot("macos/BobrvmKit.xcframework");

    // Remove existing xcframework using rm -rf
    var rm_code: u8 = 0;
    _ = b.runAllowFail(&.{ "rm", "-rf", output_path }, &rm_code, .Inherit) catch {};

    // Run xcodebuild -create-xcframework
    var xcode_code: u8 = 0;
    const result = b.runAllowFail(&.{
        "xcodebuild",
        "-create-xcframework",
        "-library",
        lib_path,
        "-headers",
        header_path,
        "-output",
        output_path,
    }, &xcode_code, .Inherit) catch |err| {
        std.log.err("xcodebuild failed: {}", .{err});
        return error.XcodebuildFailed;
    };
    _ = result;
}

pub fn getPath(self: *XCFrameworkStep) LazyPath {
    return self.output_path;
}
