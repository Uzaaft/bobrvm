# Bobrvm for macOS

The native SwiftUI/AppKit app owns the application, windows, and Metal layer.
The Zig libraries own virtualization and rendering.

## Build

Enter the Nix development environment and build the Zig frameworks without
asking Zig to invoke Xcode:

```sh
nix develop -c zig build xcframework ghostty-lib -Demit-macos-app=false
nix develop -c macos/build.nu
```

This follows Ghostty's macOS build boundary: Nix provides Zig and its
dependencies, while the native app is built by Xcode in a clean environment.
The app is written to `macos/build/Debug/Bobrvm.app` by default.

For Swift-only iteration, generate the frameworks once, then reuse the helper:

```sh
nix develop -c macos/build.nu
nix develop -c macos/build.nu --configuration Release
nix develop -c macos/build.nu --action clean
nix develop -c macos/build.nu --action test
```

The helper avoids Nix compiler and linker overrides. It requires Nushell,
which is included in `nix develop`. `zig build macos-app` and `zig build run`
remain convenience commands inside the development shell and use the same
helper. All build paths require Zig 0.16.

Configure an Apple Development or Developer ID team in Xcode before
distribution.

## Permissions

The app is not sandboxed because disks and removable images may live outside
its container and must remain accessible across launches. It requests the
Hypervisor.framework entitlement and uses Hardened Runtime. Local builds are
ad-hoc signed; distribution builds require Developer ID signing and
notarization.
