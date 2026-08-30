#!/usr/bin/env nu

# Build the Zig frameworks before running Xcode with a clean environment so
# Nix compiler and linker overrides cannot interfere with Xcode's toolchain.

def prepare-frameworks [
    repo_root: path
    optimize: string
] {
    cd $repo_root
    ^zig build xcframework ghostty-lib -Demit-macos-app=false $"-Doptimize=($optimize)"
    if $env.LAST_EXIT_CODE != 0 {
        exit $env.LAST_EXIT_CODE
    }
}

def main [
    --scheme: string = "Bobrvm"        # Xcode scheme
    --configuration: string = "Debug"  # Build configuration (Debug or Release)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --skip-dependencies                 # Zig already prepared the XCFrameworks
] {
    let repo_root = ($env.FILE_PWD | path dirname)
    let project = ($env.FILE_PWD | path join "Bobrvm.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")
    let xcode_cache = ($env.HOME |
        path join "Library/Developer/Xcode/DerivedData/CompilationCache.noindex")
    let optimize = match $configuration {
        "Debug" => "Debug"
        "Release" => "ReleaseFast"
        _ => {
            error make {
                msg: $"unsupported build configuration: ($configuration)"
                help: "expected Debug or Release"
            }
        }
    }

    if ($action != "clean") and (not $skip_dependencies) {
        prepare-frameworks $repo_root $optimize
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        CODE_SIGNING_ALLOWED=YES
        ONLY_ACTIVE_ARCH=YES
        $"COMPILATION_CACHE_CAS_PATH=($xcode_cache)"
        COMPILATION_CACHE_KEEP_CAS_DIRECTORY=YES
        $action)
}
