#!/usr/bin/env nu

# Build the macOS app with a clean environment so Nix compiler and linker
# overrides cannot interfere with Xcode's toolchain.

def main [
    --scheme: string = "Bobrvm"       # Xcode scheme
    --configuration: string = "Debug" # Build configuration (Debug or Release)
    --action: string = "build"        # xcodebuild action (build, test, clean, etc.)
] {
    let repository = ($env.FILE_PWD | path dirname)
    let project = ($env.FILE_PWD | path join "Bobrvm.xcodeproj")
    let derived_data = ($repository | path join "zig-out" "xcode-derived-data")

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        -derivedDataPath $derived_data
        CODE_SIGNING_ALLOWED=YES
        ONLY_ACTIVE_ARCH=YES
        -quiet
        $action)
}
