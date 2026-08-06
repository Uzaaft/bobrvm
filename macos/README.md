# Bobrvm for macOS

The native SwiftUI/AppKit app owns the application, windows, and Metal layer.
The Zig libraries own virtualization and rendering.

## Build

Build and run the native app from the repository root:

```sh
zig build run
```

Use `zig build macos-app` to build without launching. Both commands generate
`BobrvmKit.xcframework` in `macos/`, generate `GhosttyKit.xcframework` in
`zig-out/`, and build the signed app with Xcode. Pass application arguments
after `--` when running.

For Swift-only iteration, generate the frameworks once and use the
Ghostty-style clean-environment Xcode helper:

```sh
zig build xcframework ghostty-lib
macos/build.nu
macos/build.nu --configuration Release
macos/build.nu --action clean
```

The helper avoids Nix compiler and linker overrides. It requires Nushell,
which is included in `nix develop`. All build paths require Zig 0.16.

Configure an Apple Development or Developer ID team in Xcode before
distribution.

## Permissions

The app is not sandboxed because disks and removable images may live outside
its container and must remain accessible across launches. It requests the
Hypervisor.framework entitlement and uses Hardened Runtime. Local builds are
ad-hoc signed; distribution builds require Developer ID signing and
notarization.
