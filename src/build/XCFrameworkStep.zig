//! XCFramework generation step.
//!
//! Creates BobrvmKit.xcframework from the static library and headers.

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

    const emitted_lib_path = self.lib.getEmittedBin().getPath2(b, step);
    const lib_path = if (std.fs.path.isAbsolute(emitted_lib_path))
        emitted_lib_path
    else
        b.pathFromRoot(emitted_lib_path);
    const header_path = b.pathFromRoot("include");
    const output_path = b.pathFromRoot("macos/BobrvmKit.xcframework");
    const repacked_lib_path = b.pathFromRoot("zig-out/lib/libbobrvm-xcode.a");

    // Zig 0.16 archives Mach-O members at four-byte boundaries, while Apple's
    // linker requires eight-byte alignment. Repack the emitted objects with
    // Apple's libtool before placing the library in the XCFramework.
    var repack_code: u8 = 0;
    _ = b.runAllowFail(&.{
        b.pathFromRoot("tools/repack-static-library.sh"),
        lib_path,
        repacked_lib_path,
    }, &repack_code, .inherit) catch |err| {
        std.log.err("static library repack failed: {}", .{err});
        return error.ArchiveRepackFailed;
    };
    if (repack_code != 0) return error.ArchiveRepackFailed;

    // Remove existing xcframework using rm -rf
    var rm_code: u8 = 0;
    _ = b.runAllowFail(&.{ "rm", "-rf", output_path }, &rm_code, .inherit) catch {};

    // Run xcodebuild -create-xcframework
    var xcode_code: u8 = 0;
    const result = b.runAllowFail(&.{
        "xcodebuild",
        "-create-xcframework",
        "-library",
        repacked_lib_path,
        "-headers",
        header_path,
        "-output",
        output_path,
    }, &xcode_code, .inherit) catch |err| {
        std.log.err("xcodebuild failed: {}", .{err});
        return error.XcodebuildFailed;
    };
    _ = result;
}

pub fn getPath(self: *XCFrameworkStep) LazyPath {
    return self.output_path;
}
