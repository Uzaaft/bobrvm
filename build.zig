const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const XCFrameworkStep = @import("src/build/XCFrameworkStep.zig");
const XcodebuildStep = @import("src/build/XcodebuildStep.zig");

const GhosttyXCFrameworkTarget = enum { native, universal };

const GhosttySteps = struct {
    install_root_step: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // A sandboxed `nix build` sets NIX_BUILD_TOP but not IN_NIX_SHELL;
    // `nix develop` sets both. Codesigning must run in the dev shell (the
    // CLI needs the hypervisor entitlement) but can't run in the sandbox.
    const in_nix_shell = b.graph.environ_map.get("IN_NIX_SHELL") != null;
    const is_nix_build = b.graph.environ_map.get("NIX_BUILD_TOP") != null and !in_nix_shell;
    // Swift/Xcode/Ghostty steps never run under nix (nix builds the Zig core
    // only); resolving the ghostty dependency inside a nix shell also fails
    // because ghostty's apple-sdk detection can't see the real Darwin SDK.
    const in_nix = is_nix_build or in_nix_shell;

    // Build options
    const emit_xcframework = b.option(bool, "emit-xcframework", "Build XCFramework") orelse false;
    const emit_macos_app = b.option(bool, "emit-macos-app", "Build macOS app via xcodebuild") orelse false;

    // Venus (KosmicKrisp) GPU backend — opt-in. When set, the GPU device routes
    // 3D contexts to virglrenderer(venus); the default build never links it.
    // Needs the macOS-patched virglrenderer (tools/build-virglrenderer-macos.sh).
    const gpu_venus = b.option(bool, "gpu-venus", "Enable the Venus/KosmicKrisp GPU backend") orelse false;
    const home = b.graph.environ_map.get("HOME") orelse "/tmp";
    const default_virgl_prefix = b.fmt("{s}/.local/opt/virgl-upstream", .{home});
    const virgl_prefix = b.option([]const u8, "virgl-prefix", "virglrenderer(venus) install prefix") orelse default_virgl_prefix;
    const virgl_lib = b.fmt("{s}/lib", .{virgl_prefix});

    const build_options = b.addOptions();
    build_options.addOption(bool, "gpu_venus", gpu_venus);
    // Carried into venus.zig so it can self-configure the render-server binary +
    // KosmicKrisp ICD paths from this install prefix (no manual env needed).
    build_options.addOption([]const u8, "virgl_prefix", virgl_prefix);

    // Applies the build_options import and, when venus is enabled, the
    // virglrenderer link, to a module that compiles the GPU device.
    const wireVenus = struct {
        fn apply(m: *std.Build.Module, opts: *std.Build.Step.Options, enabled: bool, libdir: []const u8) void {
            m.addOptions("build_options", opts);
            if (enabled) {
                m.addLibraryPath(.{ .cwd_relative = libdir });
                m.linkSystemLibrary("virglrenderer", .{});
                m.addRPath(.{ .cwd_relative = libdir });
            }
        }
    }.apply;

    // Create the root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main_c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link system frameworks on macOS
    if (target.result.os.tag == .macos) {
        // Add framework search path from SDKROOT if available
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            const framework_path = b.fmt("{s}/System/Library/Frameworks", .{sdk});
            const include_path = b.fmt("{s}/usr/include", .{sdk});
            const library_path = b.fmt("{s}/usr/lib", .{sdk});
            root_module.addFrameworkPath(.{ .cwd_relative = framework_path });
            root_module.addSystemIncludePath(.{ .cwd_relative = include_path });
            root_module.addLibraryPath(.{ .cwd_relative = library_path });
        }

        root_module.linkFramework("Hypervisor", .{});
        root_module.linkFramework("Metal", .{});
        root_module.linkFramework("MetalKit", .{});
        root_module.linkFramework("QuartzCore", .{});
        root_module.linkFramework("IOSurface", .{});
        root_module.linkFramework("CoreFoundation", .{});
        root_module.linkSystemLibrary("objc", .{});

        // Add C source for os_log wrapper
        root_module.addCSourceFile(.{
            .file = b.path("src/os/log.c"),
            .flags = &.{"-std=c11"},
        });
    }

    wireVenus(root_module, build_options, gpu_venus, virgl_lib);

    // Create the main library
    const lib = b.addLibrary(.{
        .name = "bobrvm",
        .root_module = root_module,
        .linkage = .static,
    });

    b.installArtifact(lib);

    // Install headers
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });

    // CLI executable module
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link system frameworks for CLI on macOS
    if (target.result.os.tag == .macos) {
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            const framework_path = b.fmt("{s}/System/Library/Frameworks", .{sdk});
            const include_path = b.fmt("{s}/usr/include", .{sdk});
            const library_path = b.fmt("{s}/usr/lib", .{sdk});
            cli_module.addFrameworkPath(.{ .cwd_relative = framework_path });
            cli_module.addSystemIncludePath(.{ .cwd_relative = include_path });
            cli_module.addLibraryPath(.{ .cwd_relative = library_path });
        }

        cli_module.linkFramework("Hypervisor", .{});
        cli_module.linkFramework("Metal", .{});
        cli_module.linkFramework("QuartzCore", .{});
        cli_module.linkFramework("IOSurface", .{});
        cli_module.linkFramework("CoreFoundation", .{});
        cli_module.linkSystemLibrary("objc", .{});

        cli_module.addCSourceFile(.{
            .file = b.path("src/os/log.c"),
            .flags = &.{"-std=c11"},
        });
    }

    wireVenus(cli_module, build_options, gpu_venus, virgl_lib);

    // CLI executable
    const cli_exe = b.addExecutable(.{
        .name = "bobrvm",
        .root_module = cli_module,
    });

    const install_cli = b.addInstallArtifact(cli_exe, .{});
    b.getInstallStep().dependOn(&install_cli.step);

    // Code-sign the installed CLI with hypervisor entitlement (macOS only)
    if (target.result.os.tag == .macos and !is_nix_build) {
        // Venus loads ad-hoc-signed third-party dylibs (virglrenderer/KosmicKrisp),
        // so that build needs library validation disabled in addition to the
        // hypervisor entitlement.
        const cli_entitlements = if (gpu_venus) "cli-venus.entitlements" else "cli.entitlements";
        const codesign = b.addSystemCommand(&.{
            "codesign",
            "--sign",
            "-",
            "--entitlements",
            cli_entitlements,
            "--force",
            "zig-out/bin/bobrvm",
        });
        codesign.step.dependOn(&install_cli.step);
        b.getInstallStep().dependOn(&codesign.step);
    }

    // CLI run step
    const cli_run = b.addRunArtifact(cli_exe);
    cli_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        cli_run.addArgs(args);
    }

    const cli_step = b.step("cli", "Run the headless CLI");
    cli_step.dependOn(&cli_run.step);

    // GUI run step - build the minimal Swift display app (macos/MinimalApp)
    // and run it. Doesn't touch ghostty/xcodebuild, so unlike the full
    // Xcode "run" step below it works fine inside a nix dev shell too.
    if (target.result.os.tag == .macos) {
        // swiftc must use the real system Xcode/SDK, not the nix-provided
        // SDKROOT/DEVELOPER_DIR (a mismatched Swift toolchain + SDK pair
        // fails to compile the Swift standard library module).
        const gui_build = b.addSystemCommand(&.{"macos/MinimalApp/build.sh"});
        gui_build.step.dependOn(b.getInstallStep());
        gui_build.removeEnvironmentVariable("SDKROOT");
        gui_build.removeEnvironmentVariable("DEVELOPER_DIR");
        // nix's xcrun/xcodebuild shims sit ahead of /usr/bin on PATH and
        // resolve the SDK to a mismatched nix-provided one; put the real
        // system toolchain first so swiftc finds Xcode's actual SDK.
        if (b.graph.environ_map.get("PATH")) |path| {
            gui_build.setEnvironmentVariable("PATH", b.fmt("/usr/bin:/bin:{s}", .{path}));
        }

        const gui_run = b.addSystemCommand(&.{"zig-out/bin/BobrvmDisplay"});
        gui_run.step.dependOn(&gui_build.step);
        if (b.args) |args| {
            gui_run.addArgs(args);
        }

        const gui_step = b.step("gui", "Build and run the minimal Swift GUI display app");
        gui_step.dependOn(&gui_run.step);
    }

    // ==========================================================================
    // Venus GPU backend smoke test (macOS): prove the Zig↔virglrenderer(venus)
    // FFI creates a Venus context through the render server. Opt-in via
    // `zig build venus-smoke`; needs the macOS-patched virglrenderer
    // (tools/build-virglrenderer-macos.sh → ~/.local/opt/virgl-macos) + the
    // KosmicKrisp ICD + vulkan-loader/spirv-tools/angle. See docs/gpu-venus-moltenvk.md.
    // ==========================================================================
    if (target.result.os.tag == .macos) {
        // virgl_prefix / virgl_lib come from the top-level options block. The
        // Venus path needs the macOS-patched virglrenderer built by
        // tools/build-virglrenderer-macos.sh (installs to ~/.local/opt/virgl-macos).
        const venus_mod = b.createModule(.{
            .root_source_file = b.path("src/gpu/venus.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        venus_mod.addOptions("build_options", build_options);

        const venus_smoke_mod = b.createModule(.{
            .root_source_file = b.path("tools/venus_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        venus_smoke_mod.addImport("venus", venus_mod);
        venus_smoke_mod.addLibraryPath(.{ .cwd_relative = virgl_lib });
        venus_smoke_mod.linkSystemLibrary("virglrenderer", .{});
        // virglrenderer's own dylib is resolved via this rpath.
        venus_smoke_mod.addRPath(.{ .cwd_relative = virgl_lib });

        const venus_smoke_exe = b.addExecutable(.{
            .name = "venus_smoke",
            .root_module = venus_smoke_mod,
        });

        const install_venus_smoke = b.addInstallArtifact(venus_smoke_exe, .{});

        // Codesign with the Venus entitlements (library validation must be off
        // to load the ad-hoc-signed third-party GPU dylibs).
        const sign_venus_smoke = b.addSystemCommand(&.{
            "codesign", "--sign", "-", "--entitlements", "venus.entitlements",
            "--force",  "zig-out/bin/venus_smoke",
        });
        sign_venus_smoke.step.dependOn(&install_venus_smoke.step);

        // Run it. Wire the KosmicKrisp ICD, the render-server binary, and the
        // runtime library path (fixed virglrenderer + loader + spirv + angle).
        const run_venus_smoke = b.addSystemCommand(&.{"zig-out/bin/venus_smoke"});
        run_venus_smoke.setEnvironmentVariable(
            "VK_ICD_FILENAMES",
            b.fmt("{s}/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json", .{virgl_prefix}),
        );
        run_venus_smoke.setEnvironmentVariable(
            "RENDER_SERVER_EXEC_PATH",
            b.fmt("{s}/libexec/virgl_render_server", .{virgl_prefix}),
        );
        run_venus_smoke.setEnvironmentVariable(
            "DYLD_LIBRARY_PATH",
            b.fmt("{s}:/opt/homebrew/opt/vulkan-loader/lib:/opt/homebrew/opt/spirv-tools/lib:" ++
                "/opt/homebrew/opt/angle/lib:/opt/homebrew/lib", .{virgl_lib}),
        );
        run_venus_smoke.step.dependOn(&sign_venus_smoke.step);

        const venus_smoke_step = b.step("venus-smoke", "Build+run the Venus host backend smoke test");
        venus_smoke_step.dependOn(&run_venus_smoke.step);

        // Build-and-sign only (no run) — useful where the sandbox blocks the run.
        const venus_smoke_build_step = b.step("venus-smoke-build", "Build+sign the Venus smoke test (no run)");
        venus_smoke_build_step.dependOn(&sign_venus_smoke.step);
    }

    // Test module
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Link frameworks for tests on macOS. Mirror the lib/cli modules so
    // Metal-backed tests (virgl renderer) can create a real device: the
    // SDK library path is what lets -lobjc resolve.
    if (target.result.os.tag == .macos) {
        if (b.graph.environ_map.get("SDKROOT")) |sdk| {
            const framework_path = b.fmt("{s}/System/Library/Frameworks", .{sdk});
            const include_path = b.fmt("{s}/usr/include", .{sdk});
            const library_path = b.fmt("{s}/usr/lib", .{sdk});
            test_module.addFrameworkPath(.{ .cwd_relative = framework_path });
            test_module.addSystemIncludePath(.{ .cwd_relative = include_path });
            test_module.addLibraryPath(.{ .cwd_relative = library_path });
        }
        test_module.linkFramework("Hypervisor", .{});
        test_module.linkFramework("Metal", .{});
        test_module.linkFramework("QuartzCore", .{});
        test_module.linkFramework("IOSurface", .{});
        test_module.linkFramework("CoreFoundation", .{});
        test_module.linkSystemLibrary("objc", .{});
    }

    wireVenus(test_module, build_options, gpu_venus, virgl_lib);

    // Test step
    const main_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ==========================================================================
    // Integration test: bare-metal ARM64 test binary (pure assembly)
    // ==========================================================================
    const bare_metal_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const bare_metal_module = b.createModule(.{
        .target = bare_metal_target,
        .optimize = .ReleaseSmall,
    });

    // Pure assembly test
    bare_metal_module.addAssemblyFile(b.path("tests/integration/bare_metal/test.S"));

    const bare_metal_test = b.addExecutable(.{
        .name = "bare_metal_test",
        .root_module = bare_metal_module,
    });
    bare_metal_test.setLinkerScript(b.path("tests/integration/bare_metal/link.ld"));

    // Extract raw binary from ELF
    const bare_metal_bin = bare_metal_test.addObjCopy(.{
        .format = .bin,
    });

    // Install the binary
    const install_bare_metal = b.addInstallFile(bare_metal_bin.getOutput(), "test/bare_metal_test.bin");

    const bare_metal_step = b.step("bare-metal-test", "Build bare-metal ARM64 test binary");
    bare_metal_step.dependOn(&install_bare_metal.step);

    // XCFramework + app steps (macOS only, never under nix). The vendored
    // ghostty dependency pins its own build.zig to zig 0.15.2 exactly
    // (build.zig.zon requireZig) and hasn't been updated for 0.16+; skip
    // this whole block on other compilers rather than hard error, so the
    // core lib/cli/gui/test targets keep working on newer system zig.
    const zig_version = @import("builtin").zig_version;
    const ghostty_zig_compatible = zig_version.major == 0 and zig_version.minor == 15;
    if (target.result.os.tag == .macos and !in_nix and !ghostty_zig_compatible) {
        std.debug.print(
            "note: skipping ghostty-lib/xcframework/run steps — the vendored " ++
                "ghostty dependency requires zig 0.15.2, this is {}. Use `nix develop` " ++
                "for those steps; gui/cli/test/install are unaffected.\n",
            .{zig_version},
        );
    }
    if (target.result.os.tag == .macos and !in_nix and ghostty_zig_compatible) {
        const ghostty_steps = addGhosttySteps(b, optimize);
        const ghostty_step = b.step("ghostty-lib", "Build GhosttyKit.xcframework");
        ghostty_step.dependOn(ghostty_steps.install_root_step);

        const xcframework = XCFrameworkStep.create(b, lib);
        const xcframework_step = b.step("xcframework", "Build BobrvmKit.xcframework");
        xcframework_step.dependOn(&xcframework.step);

        if (emit_xcframework) {
            b.default_step.dependOn(&xcframework.step);
        }

        // macOS app step
        if (emit_macos_app) {
            const xcodebuild = XcodebuildStep.create(b, xcframework, optimize);
            xcodebuild.step.dependOn(ghostty_steps.install_root_step);
            b.default_step.dependOn(&xcodebuild.step);
        }

        // Run step - build and run app with logging to terminal
        const run_step = b.step("run", "Build and run the macOS app (with terminal logging)");
        const xcodebuild_for_run = XcodebuildStep.create(b, xcframework, optimize);
        xcodebuild_for_run.step.dependOn(ghostty_steps.install_root_step);
        run_step.dependOn(&xcodebuild_for_run.step);

        // Run app directly (not via open) so stderr shows in terminal
        // Set BOBRVM_LOG=true for dev mode logging
        const xcodeproj_path = b.pathFromRoot("macos/Bobrvm.xcodeproj");
        const run_script = b.fmt(
            \\BUILT_PRODUCTS_DIR=$(xcodebuild -project "{s}" -scheme Bobrvm -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | head -1 | awk '{{print $3}}')
            \\BOBRVM_LOG=true exec "$BUILT_PRODUCTS_DIR/Bobrvm.app/Contents/MacOS/Bobrvm"
        , .{xcodeproj_path});
        var run_cmd = b.addSystemCommand(&.{"sh"});
        run_cmd.addArgs(&.{ "-c", run_script });
        run_cmd.step.dependOn(&xcodebuild_for_run.step);
        run_step.dependOn(&run_cmd.step);
    }
}

fn addGhosttySteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) GhosttySteps {
    const ghostty_xcframework_target = b.option(
        GhosttyXCFrameworkTarget,
        "ghostty-xcframework-target",
        "Ghostty xcframework target (native or universal).",
    ) orelse .native;

    const ghostty_dep = b.dependency("ghostty", .{ .@"version-string" = "0.0.0" });
    const ghostty_target_arg = @tagName(ghostty_xcframework_target);

    const ghostty_cmd = b.addSystemCommand(&.{
        "zig",
        "build",
        "-Dapp-runtime=none",
        "-Dversion-string=0.0.0",
        "-Demit-macos-app=false",
        "-Demit-xcframework=true",
        "-Di18n=false",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Dxcframework-target={s}", .{ghostty_target_arg}),
    });
    ghostty_cmd.setCwd(ghostty_dep.path("."));
    ghostty_cmd.expectExitCode(0);
    ghostty_cmd.addFileInput(ghostty_dep.path("build.zig"));
    ghostty_cmd.addFileInput(ghostty_dep.path("build.zig.zon"));
    ghostty_cmd.addFileInput(ghostty_dep.path("include/ghostty.h"));
    addRunFileInputsForDir(b, ghostty_cmd, ghostty_dep.path("src").getPath(b), &.{});
    addRunFileInputsForDir(b, ghostty_cmd, ghostty_dep.path("include").getPath(b), &.{});

    const ghostty_install = b.addInstallDirectory(.{
        .source_dir = ghostty_dep.path("macos/GhosttyKit.xcframework"),
        .install_dir = .prefix,
        .install_subdir = "GhosttyKit.xcframework",
    });
    ghostty_install.step.dependOn(&ghostty_cmd.step);

    const install_prefix = b.getInstallPath(.prefix, "");
    const install_prefix_abs = if (fs.path.isAbsolute(install_prefix))
        install_prefix
    else
        b.pathFromRoot(install_prefix);
    const zig_out_abs = b.pathFromRoot("zig-out");
    const ghostty_xcframework_src = b.fmt("{s}/GhosttyKit.xcframework", .{install_prefix_abs});
    const ghostty_xcframework_dest = b.pathFromRoot("zig-out/GhosttyKit.xcframework");

    const ghostty_install_root_step: *std.Build.Step = if (mem.eql(u8, install_prefix_abs, zig_out_abs))
        &ghostty_install.step
    else blk: {
        const copy_step = CopyDirStep.create(
            b,
            .{ .cwd_relative = ghostty_xcframework_src },
            .{ .cwd_relative = ghostty_xcframework_dest },
        );
        copy_step.step.dependOn(&ghostty_install.step);
        break :blk &copy_step.step;
    };

    return .{ .install_root_step = ghostty_install_root_step };
}

fn addRunFileInputsForDir(
    b: *std.Build,
    run: *std.Build.Step.Run,
    root_path: []const u8,
    extensions: []const []const u8,
) void {
    const dir = if (fs.path.isAbsolute(root_path))
        fs.openDirAbsolute(root_path, .{ .iterate = true })
    else
        fs.cwd().openDir(root_path, .{ .iterate = true });
    var handle = dir catch @panic("unable to open directory");
    defer handle.close();

    var walker = handle.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    while (true) {
        const entry = walker.next() catch @panic("unable to walk directory") orelse break;
        if (entry.kind != .file) continue;
        if (extensions.len != 0 and !hasExtension(entry.path, extensions)) continue;

        const full_path = b.pathJoin(&.{ root_path, entry.path });
        run.addFileInput(.{ .cwd_relative = full_path });
    }
}

fn hasExtension(path: []const u8, extensions: []const []const u8) bool {
    for (extensions) |ext| {
        if (mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

const CopyDirStep = struct {
    step: std.Build.Step,
    source_dir: std.Build.LazyPath,
    dest_dir: std.Build.LazyPath,

    pub fn create(
        b: *std.Build,
        source_dir: std.Build.LazyPath,
        dest_dir: std.Build.LazyPath,
    ) *CopyDirStep {
        const step = b.allocator.create(CopyDirStep) catch @panic("OOM");
        step.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "copy GhosttyKit.xcframework",
                .owner = b,
                .makeFn = make,
            }),
            .source_dir = source_dir.dupe(b),
            .dest_dir = dest_dir.dupe(b),
        };
        source_dir.addStepDependencies(&step.step);
        return step;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const b = step.owner;
        const self: *CopyDirStep = @fieldParentPtr("step", step);
        step.clearWatchInputs();

        const src_path = self.source_dir.getPath3(b, step);
        const dest_path = self.dest_dir.getPath3(b, step);

        const src = try src_path.toString(b.allocator);
        defer b.allocator.free(src);
        const dest = try dest_path.toString(b.allocator);
        defer b.allocator.free(dest);

        try copyDirTree(b.allocator, src, dest);
    }
};

fn copyDirTree(allocator: Allocator, source_path: []const u8, dest_path: []const u8) !void {
    try deleteTreePath(dest_path);
    if (fs.path.isAbsolute(dest_path)) {
        try ensureDirAbsolute(dest_path);
    } else {
        try fs.cwd().makePath(dest_path);
    }

    var source_dir = try openDirPath(source_path, true);
    defer source_dir.close();
    var dest_dir = try openDirPath(dest_path, false);
    defer dest_dir.close();

    try copyDirContents(allocator, source_dir, dest_dir);
}

fn copyDirContents(allocator: Allocator, source_dir: fs.Dir, dest_dir: fs.Dir) !void {
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                try dest_dir.makePath(entry.path);
            },
            .file => {
                try ensureParentDir(dest_dir, entry.path);
                try source_dir.copyFile(entry.path, dest_dir, entry.path, .{});
            },
            .sym_link => {
                try ensureParentDir(dest_dir, entry.path);
                var buf: [fs.max_path_bytes]u8 = undefined;
                const target = try source_dir.readLink(entry.path, &buf);
                dest_dir.symLink(target, entry.path, .{}) catch |err| {
                    if (err != error.PathAlreadyExists) return err;
                };
            },
            else => {},
        }
    }
}

fn ensureParentDir(dir: fs.Dir, path: []const u8) !void {
    const parent = fs.path.dirname(path) orelse return;
    try dir.makePath(parent);
}

fn ensureDirAbsolute(path: []const u8) !void {
    if (!fs.path.isAbsolute(path)) return error.BadPathName;
    fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = fs.path.dirname(path) orelse return err;
            try ensureDirAbsolute(parent);
            try fs.makeDirAbsolute(path);
        },
        else => return err,
    };
}

fn openDirPath(path: []const u8, iterate: bool) !fs.Dir {
    const opts: fs.Dir.OpenOptions = .{ .iterate = iterate };
    return if (fs.path.isAbsolute(path))
        fs.openDirAbsolute(path, opts)
    else
        fs.cwd().openDir(path, opts);
}

fn deleteTreePath(path: []const u8) !void {
    if (fs.path.isAbsolute(path)) {
        fs.deleteTreeAbsolute(path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        return;
    }

    fs.cwd().deleteTree(path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}
