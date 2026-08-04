# Bobrvm for macOS

The native SwiftUI/AppKit app owns the application, windows, and Metal layer.
The Zig libraries own virtualization and rendering.

## Build

Generate the frameworks before opening the Xcode project:

```sh
zig build ghostty-lib xcframework
open macos/Bobrvm.xcodeproj
```

This requires Zig 0.16. `BobrvmKit.xcframework` is written to `macos/` and
`GhosttyKit.xcframework` to `zig-out/`; these macOS-only steps are not part of
the Nix development shell.

Build the frameworks and signed Debug app together with:

```sh
zig build -Demit-macos-app=true
```

Configure an Apple Development or Developer ID team in Xcode before
distribution.

## Permissions

The app is not sandboxed because disks and removable images may live outside
its container and must remain accessible across launches. It requests the
Hypervisor.framework entitlement and uses Hardened Runtime. Local builds are
ad-hoc signed; distribution builds require Developer ID signing and
notarization.
