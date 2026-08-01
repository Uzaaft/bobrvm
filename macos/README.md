# Bobrvm for macOS

The macOS application is a native SwiftUI/AppKit frontend. Swift owns the application and
window lifecycle plus the `CAMetalLayer`; the Zig libraries own virtualization and rendering.

## Build

Generate the native frameworks before opening the Xcode project:

```bash
zig build ghostty-lib xcframework
open macos/Bobrvm.xcodeproj
```

The framework build uses Zig 0.16 for both Bobrvm and the pinned Ghostty revision. The Nix
development shell intentionally omits these macOS-only steps. `BobrvmKit.xcframework` is
generated in `macos/`, while `GhosttyKit.xcframework` is generated in `zig-out/`.

To build the frameworks and signed Debug application in one command:

```bash
zig build -Demit-macos-app=true
```

The shared `Bobrvm` scheme supports Run, Test, Profile, Analyze, and Archive. Release archives
use the same target settings as local builds; configure an Apple Development or Developer ID
team in Xcode before distributing the app.

## Permissions

Bobrvm is intentionally not App Sandbox-enabled. Persistent virtual disks and removable ISO
images may live outside the app container, and the VM must retain access across launches. The
target requests only `com.apple.security.hypervisor`, which is required by
`Hypervisor.framework`. Add privacy entitlements only when a feature actually needs them.

The Hardened Runtime remains enabled for Debug and Release. Local builds use ad-hoc signing;
distribution builds should use Developer ID signing and notarization.
