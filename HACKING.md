# Developing bobrvm

This document is the technical entry point for working on bobrvm. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before sending changes.

## Requirements

- Nix
- Zig 0.16, supplied by the development shell
- Apple Silicon with macOS 13 or later for Hypervisor.framework development
- Xcode 26 or later for the macOS application
- x86-64 Linux with KVM, GTK 4, and Libadwaita 1.5 or later for the Linux app

## Build and run

```sh
nix develop
zig build
zig build run
zig build cli -- help
zig build macos-app
```

The flake exposes reproducible build targets:

```sh
nix build
nix build .#debug
nix build .#releasesafe
nix build .#test
nix run .#
nix run .#cli -- help
```

For the native macOS build boundary and Swift-only iteration, see
[macos/README.md](macos/README.md).

## Test and format

Prefer a targeted test while iterating:

```sh
zig build test -Dtest-filter=<name>
zig build test
zig fmt --check .
alejandra --check .
swift-format lint -r macos/Sources
```

`zig build --help` lists the integration and fuzz-test steps.

## Architecture

The Zig core owns virtualization and rendering. Swift owns the native
application and window:

- `src/hypervisor` implements Hypervisor.framework and KVM support.
- `src/virtio`, `src/pci`, and `src/gic` implement guest devices and interrupts.
- `src/gpu` and `src/renderer` implement virgl/Venus translation and rendering.
- `src/runtime` and `src/apprt` define embedding and application boundaries.
- `include/bobrvm.h` is the Swift/Zig contract.
- `macos` contains the SwiftUI/AppKit application.

Swift creates the window, view, Metal layer, device, and command queue. Zig owns
Metal command encoding, synchronization, and presentation. Guest UART bytes are
parsed by libghostty-vt; the Swift terminal view draws the resulting cell grid.

Direct Linux boot loads the kernel at `0x40200000`, passes the DTB in `x0`, and
uses virtio-mmio. UEFI boot uses PCI ECAM and virtio-pci because QEMU EDK2 does
not consume the DTB's virtio-mmio nodes.

## GPU development

The Apple Silicon Venus stack uses vendored dependencies under `third_party`:

```sh
third_party/sync.sh
third_party/build.sh
zig build -Dgpu-venus
```

The guest Mesa package must be built on AArch64 Linux, locally or with a remote
builder. See [guest requirements](docs/gpu-venus-guest-requirements.md),
[host implementation notes](docs/gpu-venus-moltenvk.md), and
[third_party/README.md](third_party/README.md).

## Logging

`zig build run` logs to the terminal. `BOBRVM_LOG` accepts `true`, `false`, or a
comma-separated list containing `stderr`, `macos`, `no-stderr`, and `no-macos`.

```sh
BOBRVM_LOG=stderr,macos zig build run
log stream --level debug --predicate 'subsystem=="com.bobrvm.app"'
```

The compile-time minimum is `debug` in Debug builds and `info` in release
builds. Override it with `-Dlog-level=debug|info|warn|err`.
