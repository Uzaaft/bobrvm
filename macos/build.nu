#!/usr/bin/env nu

# Build the macOS app with a clean environment so Nix compiler and linker
# overrides cannot interfere with Xcode's toolchain.

def main [
    --scheme: string = "Bobrvm"       # Xcode scheme
    --configuration: string = "Debug" # Build configuration (Debug or Release)
    --action: string = "build"        # xcodebuild action (build, test, clean, etc.)
] {
    let project = ($env.FILE_PWD | path join "Bobrvm.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")
    let xcode_cache = ($env.HOME |
        path join "Library/Developer/Xcode/DerivedData/CompilationCache.noindex")

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
