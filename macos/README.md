# Bobrvm for macOS

The native SwiftUI/AppKit app owns the application, windows, and Metal layer.
The Zig libraries own virtualization and rendering.

## Build

Enter the Nix development environment and run the macOS build helper:

```sh
nix develop -c macos/build.nu
```

The helper brings the Zig XCFrameworks up to date before running Xcode in a
clean environment. This follows Ghostty's macOS build boundary: Zig owns the
generated dependencies and Xcode owns the native app. The app is written to
`macos/build/Debug/Bobrvm.app` by default.

For Swift-only iteration after a successful build, reuse the generated
frameworks:

```sh
nix develop -c macos/build.nu --skip-dependencies
```

The helper also accepts `--configuration Release`, `--action clean`, and
`--action test`. A clean action does not rebuild the Zig dependencies.

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
