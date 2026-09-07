# bobrvm Agent Guide

bobrvm is Linux virtualization software for macOS with OpenGL 4.3 and Vulkan support.

## Workflow

- Finish authorized work and make routine decisions independently. Ask only when ambiguity changes
  the outcome or new authority is needed. Finish authorized preparation before requesting approval.
- Preserve unrelated work and existing commits. Commit or publish only when requested.
- Update callers and remove obsolete code; add compatibility paths only when explicitly requested.
- User instructions take precedence over skill guidelines. Explain any instruction that blocks work.
- Run relevant checks and report the result and validation gaps concisely. Broaden testing only when
  changes, failures, or concerns justify it. For documentation, review the diff and formatting.

## Commands

Choose commands relevant to the change; this is a reference, not a required checklist.

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
- `macos`: SwiftUI/AppKit application. The guest console owns its own terminal: guest UART
  bytes go into libghostty-vt for VT parsing and grid state, and `TerminalView` draws the
  resulting cell grid with CoreText.

## Code Style

Follow surrounding code and the rules below; use TIGER_STYLE and Ghostty as references where these
rules leave room for judgment. Prioritize safety, then performance, then developer experience.
Use four-space indentation and keep lines within 100 columns.

For Zig:

- Put the `@This()` declaration first, then standard-library imports, then local imports.
- Use explicit error sets and `errdefer` for partial initialization.
- Pair `init`/`deinit` and `create`/`destroy`; make ownership apparent at call sites.
- Avoid allocation in hot paths; preallocate at initialization when practical.
- Keep functions under 70 lines, avoid recursion, and push conditional checks before loops.
- Put units last in names, such as `latency_max_ns`.
- Order struct fields before nested types and methods.
- Use assertions for invariants, not guest input validation.

For Swift, wrap C handles in type-safe objects and make actor, lifetime, and ownership boundaries
explicit.

### Comments

Document public contracts, ownership, invariants, and non-obvious protocol or platform constraints.
Link primary sources for workarounds when useful. Avoid restating code or recording history.

## Constraints

- Validate guest-controlled data before use; bound lengths, loops, queues, and memory accesses.
- Keep host/guest transitions batched and use zero-copy paths where practical.
- Do not add external runtime dependencies. Vendor required C libraries under `pkg`; prefer Zig
  implementations when feasible.
- Preserve renderer-thread isolation and GPU synchronization invariants.
- Do not put secrets in code or changes.

## Boot Paths

Direct Linux boot loads the kernel at `0x40200000`, passes the DTB in `x0`, and uses virtio-mmio.
UEFI boot requires a PCIe ECAM host bridge and virtio-pci devices; QEMU EDK2 firmware does not use
the DTB's virtio-mmio nodes.

The guest-visible memory map follows QEMU `virt`. See `MemoryLayout` in
[src/machine/main.zig](src/machine/main.zig) for addresses and sizes, and
[src/machine/dtb.zig](src/machine/dtb.zig) for the device-tree configuration.

## References

- [TigerBeetle
  TIGER_STYLE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md)
- [Ghostty](https://github.com/ghostty-org/ghostty)
- [Hypervisor.framework](https://developer.apple.com/documentation/hypervisor)
- [Virtio 1.2](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
