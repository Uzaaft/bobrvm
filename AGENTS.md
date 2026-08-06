# bobrvm Agent Guide

bobrvm is Linux virtualization software for macOS with OpenGL 4.3 and Vulkan support.

## Commands

```bash
# Zig/Nix
nix build
nix build .#debug
nix build .#test
nix develop -c zig build xcframework ghostty-lib
zig build run
zig build macos-app
zig build test -Dtest-filter=<name>
macos/build.nu

# Swift/Xcode (not managed by Nix)
xcodebuild -project macos/Bobrvm.xcodeproj -scheme Bobrvm

# Formatting
zig fmt --check .
alejandra --check .
swift-format lint -r macos/Sources
```

Use Jujutsu, not Git, for version-control operations. Describe focused changes with conventional
commit messages, for example `fix(hypervisor): correct memory region alignment`.

## Architecture

The Zig core owns virtualization and rendering. Swift owns only the native application and window:

- Swift creates `NSWindow`, `NSView`, `CAMetalLayer`, `MTLDevice`, and `MTLCommandQueue`.
- Swift passes Metal objects through the C API and forwards display and input events.
- Zig owns Metal command encoding, virgl/Venus translation, synchronization, and presentation.
- `include/bobrvm.h` is the Swift/Zig contract. Keep opaque handles and ownership explicit.

The main components are:

- `src/hypervisor`: Hypervisor.framework VM and vCPU support.
- `src/virtio`, `src/pci`, `src/gic`: guest devices and interrupt delivery.
- `src/gpu`, `src/renderer`: virgl/Venus translation and Metal rendering.
- `src/runtime`, `src/apprt`: embedding and application-runtime boundaries.
- `macos`: SwiftUI/AppKit application.

## Code Style

Follow TigerBeetle's TIGER_STYLE and established Ghostty patterns. Prioritize safety, then
performance, then developer experience.

For Zig:

- Put the `@This()` declaration first, then standard-library imports, then local imports.
- Use explicit error sets and `errdefer` for partial initialization.
- Pair `init`/`deinit` and `create`/`destroy`; make ownership apparent at call sites.
- Bound guest-controlled lengths, loops, queues, and memory accesses.
- Avoid allocation in hot paths; preallocate at initialization when practical.
- Keep functions under 70 lines, avoid recursion, and push conditional checks before loops.
- Put units last in names, such as `latency_ns_max`.
- Order struct fields before nested types and methods.
- Use assertions for invariants, not guest input validation.

For Swift, wrap C handles in type-safe objects and make actor, lifetime, and ownership boundaries
explicit.

### Comments

Write comments in the style of Ghostty's Zig sources:

- Document public contracts and the purpose of substantial modules.
- Explain ownership, invariants, protocol semantics, platform quirks, and non-obvious choices.
- Record why a workaround or ordering constraint exists; include a primary-source link when useful.
- Do not narrate the next statement, restate a name or type, add section banners, or preserve
  implementation history that version control already records.
- Prefer a short precise comment. Use a longer comment only when the constraint cannot be made clear
  in code.

## Constraints

- Keep lines within 100 columns and use four-space indentation.
- Validate all guest-controlled data before use.
- Keep host/guest transitions batched and use zero-copy paths where practical.
- Do not add external runtime dependencies. Vendor required C libraries under `pkg`; prefer Zig
  implementations when feasible.
- Preserve renderer-thread isolation and GPU synchronization invariants.
- Do not put secrets in code or changes.

## Boot Paths

Direct Linux boot loads the kernel at `0x40200000`, passes the DTB in `x0`, and uses virtio-mmio.
UEFI boot requires a PCIe ECAM host bridge and virtio-pci devices; QEMU EDK2 firmware does not use
the DTB's virtio-mmio nodes.

The guest-visible memory map follows QEMU `virt`:

| Region | Address | Size |
| --- | ---: | ---: |
| Flash firmware | `0x00000000` | 64 MiB |
| Flash variables | `0x04000000` | 64 MiB |
| GIC distributor | `0x08000000` | 64 KiB |
| GIC redistributor | `0x080A0000` | 128 KiB/CPU |
| PL011 UART | `0x09000000` | 4 KiB |
| Virtio MMIO | `0x0A000000` | 512 B/device |
| PCI MMIO | `0x10000000` | 768 MiB |
| PCI ECAM | `0x3C000000` | 64 MiB |
| RAM | `0x40000000` | configurable |

## References

- [TigerBeetle
  TIGER_STYLE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Ghostty](https://github.com/ghostty-org/ghostty)
- [Hypervisor.framework](https://developer.apple.com/documentation/hypervisor)
- [Virtio 1.2](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
