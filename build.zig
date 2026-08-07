const std = @import("std");
const builtin = @import("builtin");
const XCFrameworkStep = @import("src/build/XCFrameworkStep.zig");
const XcodebuildStep = @import("src/build/XcodebuildStep.zig");

const GhosttyXCFrameworkTarget = enum { native, universal };

const GhosttySteps = struct {
    install_root_step: *std.Build.Step,
};

const dynamic_link_options: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};

fn environmentVariable(b: *std.Build, key: []const u8) ?[]const u8 {
    if (@hasField(std.Build.Graph, "environ_map")) {
        return b.graph.environ_map.get(key);
    }
    return b.graph.env_map.get(key);
}

fn macosCFlags(b: *std.Build) []const []const u8 {
    const sdk = environmentVariable(b, "SDKROOT") orelse std.mem.trim(
        u8,
        b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }),
        &std.ascii.whitespace,
    );
    return b.dupeStrings(&.{
        "-std=c11",
        b.fmt("-isysroot{s}", .{sdk}),
        b.fmt("-I{s}/usr/include", .{sdk}),
    });
}

pub fn build(b: *std.Build) !void {
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and builtin.target.os.tag.isDarwin()) {
        target = b.resolveTargetQuery(.{
            .cpu_arch = target.query.cpu_arch orelse builtin.target.cpu.arch,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{
                .major = 13,
                .minor = 0,
                .patch = 0,
            } },
        });
    }
    const optimize = b.standardOptimizeOption(.{});
    const emit_guest_tools = b.option(
        bool,
        "emit-guest-tools",
        "Build Linux guest integration tools",
    ) orelse false;
    if (emit_guest_tools) {
        addGuestTools(b, target, optimize);
        return;
    }
    // A sandboxed `nix build` sets NIX_BUILD_TOP but not IN_NIX_SHELL;
    // `nix develop` sets both. The sandbox cannot use Apple's Xcode tools,
    // while the development shell can build frameworks for the native app.
    const in_nix_shell = environmentVariable(b, "IN_NIX_SHELL") != null;
    const is_nix_build = environmentVariable(b, "NIX_BUILD_TOP") != null and !in_nix_shell;
    const objc_dependency = if (target.result.os.tag == .macos)
        b.dependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        })
    else
        null;

    const emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build XCFramework",
    ) orelse false;
    const emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build macOS app via xcodebuild",
    ) orelse false;
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter Zig tests by name",
    ) orelse &[0][]const u8{};

    // Keep the primary workflows visible in `zig build --help` regardless of
    // which artifacts the default install emits.
    const run_step = b.step("run", "Build and run the native app");
    const macos_app_step = b.step("macos-app", "Build the macOS app");
    const xcframework_step = b.step("xcframework", "Build BobrvmKit.xcframework");
    const ghostty_step = b.step("ghostty-lib", "Build GhosttyKit.xcframework");

    // Venus (KosmicKrisp) GPU backend — opt-in. When set, the GPU device routes
    // 3D contexts to virglrenderer(venus); the default build never links it.
    // Needs the macOS-patched virglrenderer (tools/build-virglrenderer-macos.sh).
    const gpu_venus = b.option(
        bool,
        "gpu-venus",
        "Enable the Venus/KosmicKrisp GPU backend",
    ) orelse false;
    const home = environmentVariable(b, "HOME") orelse "/tmp";
    const default_virgl_prefix = b.fmt("{s}/.local/opt/virgl-upstream", .{home});
    const virgl_prefix = b.option(
        []const u8,
        "virgl-prefix",
        "virglrenderer(venus) install prefix",
    ) orelse default_virgl_prefix;
    const virgl_lib = b.fmt("{s}/lib", .{virgl_prefix});

    const build_options = b.addOptions();
    build_options.addOption(bool, "gpu_venus", gpu_venus);
    // Carried into venus.zig so it can self-configure the render-server binary +
    // KosmicKrisp ICD paths from this install prefix (no manual env needed).
    build_options.addOption([]const u8, "virgl_prefix", virgl_prefix);

    // Applies the build_options import and, when venus is enabled, the
    // virglrenderer link, to a module that compiles the GPU device.
    const wireVenus = struct {
        fn apply(
            m: *std.Build.Module,
            opts: *std.Build.Step.Options,
            enabled: bool,
            libdir: []const u8,
        ) void {
            m.addOptions("build_options", opts);
            if (enabled) {
                m.addLibraryPath(.{ .cwd_relative = libdir });
                m.linkSystemLibrary("virglrenderer", .{});
                m.addRPath(.{ .cwd_relative = libdir });
            }
        }
    }.apply;

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main_c.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (target.result.os.tag == .macos) {
        root_module.addImport("objc", objc_dependency.?.module("objc"));
        if (environmentVariable(b, "SDKROOT")) |sdk| {
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
        root_module.linkFramework("Foundation", .{});
        root_module.linkFramework("AppKit", .{});
        root_module.linkFramework("Virtualization", .{});
        root_module.linkSystemLibrary("objc", .{});

        root_module.addCSourceFile(.{
            .file = b.path("src/os/log.c"),
            .flags = macosCFlags(b),
        });
    }

    wireVenus(root_module, build_options, gpu_venus, virgl_lib);

    const lib = if (target.result.os.tag == .macos)
        b.addLibrary(.{
            .name = "bobrvm",
            .root_module = root_module,
            .linkage = .static,
        })
    else
        null;

    if (lib) |artifact| b.installArtifact(artifact);

    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });

    const cli_module = b.createModule(.{
        .root_source_file = b.path(if (target.result.os.tag == .linux)
            "src/main_linux.zig"
        else
            "src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (target.result.os.tag == .macos) {
        cli_module.addImport("objc", objc_dependency.?.module("objc"));
        if (environmentVariable(b, "SDKROOT")) |sdk| {
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
        cli_module.linkFramework("Foundation", .{});
        cli_module.linkFramework("AppKit", .{});
        cli_module.linkFramework("Virtualization", .{});
        cli_module.linkSystemLibrary("objc", .{});

        cli_module.addCSourceFile(.{
            .file = b.path("src/os/log.c"),
            .flags = macosCFlags(b),
        });
    }

    wireVenus(cli_module, build_options, gpu_venus, virgl_lib);

    const cli_exe = b.addExecutable(.{
        .name = "bobrvm",
        .root_module = cli_module,
    });

    const install_cli = b.addInstallArtifact(cli_exe, .{});
    b.getInstallStep().dependOn(&install_cli.step);

    if (target.result.os.tag == .linux) {
        const gtk_module = b.createModule(.{
            .root_source_file = b.path("src/main_gtk.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        wireVenus(gtk_module, build_options, gpu_venus, virgl_lib);
        gtk_module.linkSystemLibrary("gtk4", dynamic_link_options);
        const gtk_exe = b.addExecutable(.{
            .name = "bobrvm-gtk",
            .root_module = gtk_module,
        });
        const install_gtk = b.addInstallArtifact(gtk_exe, .{});
        b.getInstallStep().dependOn(&install_gtk.step);

        const gtk_run = b.addRunArtifact(gtk_exe);
        gtk_run.step.dependOn(&install_gtk.step);
        if (b.args) |args| gtk_run.addArgs(args);
        run_step.dependOn(&gtk_run.step);
    }

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

    const cli_run = b.addRunArtifact(cli_exe);
    cli_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        cli_run.addArgs(args);
    }

    const cli_step = b.step("cli", "Run the headless CLI");
    cli_step.dependOn(&cli_run.step);

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
            "codesign", "--sign",                  "-", "--entitlements", "venus.entitlements",
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

        const venus_smoke_step = b.step(
            "venus-smoke",
            "Build+run the Venus host backend smoke test",
        );
        venus_smoke_step.dependOn(&run_venus_smoke.step);

        // Build-and-sign only (no run) — useful where the sandbox blocks the run.
        const venus_smoke_build_step = b.step(
            "venus-smoke-build",
            "Build+sign the Venus smoke test (no run)",
        );
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
        test_module.addImport("objc", objc_dependency.?.module("objc"));
        if (environmentVariable(b, "SDKROOT")) |sdk| {
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
        test_module.linkFramework("Foundation", .{});
        test_module.linkFramework("AppKit", .{});
        test_module.linkFramework("Virtualization", .{});
        test_module.linkSystemLibrary("objc", .{});
    }

    wireVenus(test_module, build_options, gpu_venus, virgl_lib);

    // Test step
    const main_tests = b.addTest(.{
        .name = "bobrvm-core-tests",
        .root_module = test_module,
        .filters = test_filters,
    });

    const run_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    const test_compile_step = b.step("test-compile", "Compile unit tests without running them");
    test_compile_step.dependOn(&main_tests.step);
    const wayland_test_module = b.createModule(.{
        .root_source_file = b.path("src/guest_tools/wayland.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wayland_tests = b.addTest(.{
        .name = "bobrvm-wayland-tests",
        .root_module = wayland_test_module,
        .filters = test_filters,
    });
    const run_wayland_tests = b.addRunArtifact(wayland_tests);
    test_step.dependOn(&run_wayland_tests.step);
    test_compile_step.dependOn(&wayland_tests.step);

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
    const install_bare_metal = b.addInstallFile(
        bare_metal_bin.getOutput(),
        "test/bare_metal_test.bin",
    );

    const bare_metal_step = b.step("bare-metal-test", "Build bare-metal ARM64 test binary");
    bare_metal_step.dependOn(&install_bare_metal.step);

    // Register native Apple workflows only when their SDK discovery and Xcode
    // processes can run. The steps remain visible in sandboxed Nix builds, but
    // their Ghostty dependency must not be instantiated while building the
    // portable Zig artifacts.
    if (target.result.os.tag == .macos and !is_nix_build) {
        const xcframework = XCFrameworkStep.create(b, lib.?);
        xcframework_step.dependOn(&xcframework.step);

        const ghostty_steps = addGhosttySteps(b, optimize);
        ghostty_step.dependOn(ghostty_steps.install_root_step);

        if (emit_xcframework) {
            b.default_step.dependOn(&xcframework.step);
            b.default_step.dependOn(ghostty_steps.install_root_step);
        }

        const xcodebuild = XcodebuildStep.create(b, xcframework, optimize);
        xcodebuild.build.step.dependOn(ghostty_steps.install_root_step);
        macos_app_step.dependOn(&xcodebuild.build.step);
        if (emit_macos_app) b.default_step.dependOn(macos_app_step);

        // Run the signed Xcode product directly so stderr remains visible.
        const run_cmd = b.addSystemCommand(&.{xcodebuild.app_executable});
        run_cmd.setEnvironmentVariable("BOBRVM_LOG", "true");
        run_cmd.step.dependOn(&xcodebuild.build.step);
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    } else if (target.result.os.tag == .macos) {
        const message = "native Apple workflows require nix develop or Xcode";
        try run_step.addError(message, .{});
        try macos_app_step.addError(message, .{});
        try xcframework_step.addError(message, .{});
        try ghostty_step.addError(message, .{});
        if (emit_xcframework) b.default_step.dependOn(xcframework_step);
        if (emit_macos_app) b.default_step.dependOn(macos_app_step);
    } else if (target.result.os.tag == .linux) {
        try macos_app_step.addError("the macOS app can only build on macOS", .{});
        try xcframework_step.addError("BobrvmKit.xcframework requires macOS", .{});
        try ghostty_step.addError("GhosttyKit.xcframework requires macOS", .{});
    } else {
        try run_step.addError("the macOS app can only run on macOS", .{});
        try macos_app_step.addError("the macOS app can only build on macOS", .{});
        try xcframework_step.addError("BobrvmKit.xcframework requires macOS", .{});
        try ghostty_step.addError("GhosttyKit.xcframework requires macOS", .{});
    }
}

fn addGuestTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (target.result.os.tag != .linux) {
        std.debug.panic("guest tools require a Linux target", .{});
    }
    const tools = .{
        .{ "bobrvm-agentd", "src/guest_tools/agentd.zig" },
        .{ "bobrvm-session-agent", "src/guest_tools/session_agent.zig" },
        .{ "bobrvm-toolbox", "src/guest_tools/toolbox.zig" },
    };
    const protocol_module = b.createModule(.{
        .root_source_file = b.path("src/agent/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wayland_module = b.createModule(.{
        .root_source_file = b.path("src/guest_tools/wayland.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    inline for (tools) |tool| {
        const module = b.createModule(.{
            .root_source_file = b.path(tool[1]),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        if (std.mem.eql(u8, tool[0], "bobrvm-agentd") or
            std.mem.eql(u8, tool[0], "bobrvm-session-agent"))
        {
            module.addImport("guest_protocol", protocol_module);
        }
        if (std.mem.eql(u8, tool[0], "bobrvm-session-agent")) {
            module.addImport("wayland_client", wayland_module);
        }
        const executable = b.addExecutable(.{
            .name = tool[0],
            .root_module = module,
        });
        b.installArtifact(executable);
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
    if (environmentVariable(b, "BOBRVM_ZIG_SYSTEM_PACKAGE_DIR")) |dir| {
        ghostty_cmd.addArgs(&.{ "--system", dir });
    }
    ghostty_cmd.setCwd(ghostty_dep.path("."));
    // This is a nested Zig build. Sharing the parent's local cache can reuse
    // successful step metadata without materializing Ghostty's output.
    ghostty_cmd.setEnvironmentVariable(
        "ZIG_LOCAL_CACHE_DIR",
        b.pathFromRoot(".zig-cache/ghostty"),
    );
    ghostty_cmd.expectExitCode(0);
    ghostty_cmd.addFileInput(ghostty_dep.path("build.zig"));
    ghostty_cmd.addFileInput(ghostty_dep.path("build.zig.zon"));
    ghostty_cmd.addFileInput(ghostty_dep.path("include/ghostty.h"));

    const ghostty_install = b.addInstallDirectory(.{
        .source_dir = ghostty_dep.path("macos/GhosttyKit.xcframework"),
        .install_dir = .prefix,
        .install_subdir = "GhosttyKit.xcframework",
    });
    ghostty_install.step.dependOn(&ghostty_cmd.step);

    return .{ .install_root_step = &ghostty_install.step };
}
