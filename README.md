# bobrvm

Native Linux virtualization for macOS. The entire VM core — hypervisor,
virtio devices, interrupt controller, GPU translation, networking — is
Zig; only the window/Metal-context host is Swift (the ghostty split).

Boots NixOS to a shell in two modes: a **GUI** window (VMware-Fusion
style) and a **headless** drop-into-a-shell console.

## Status

Working and verified against a NixOS 25.05 aarch64 guest:

| Area | State |
|------|-------|
| Boot (Apple Hypervisor.framework, arm64) | ✅ NixOS to login, ~15s (1 vCPU) |
| Serial console (virtio-console + PL011) | ✅ interactive shell |
| SMP (PSCI CPU_ON) | ✅ 4 vCPUs online |
| virtio-blk | ✅ read/write, durable across restarts |
| virtio-gpu 2D → Metal | ✅ fbcon renders in the app window |
| virtio-input (keyboard/mouse) | ✅ evdev in guest |
| virtio-net + built-in NAT | ✅ DHCP, DNS, TCP/UDP internet (no root) |
| OpenGL 4.3 (virgl) | ⚠️ capset advertised (glsl 430); Metal execution WIP |
| Vulkan (Venus) | ⏳ planned |

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- Nix (for the Zig core); Xcode/Swift toolchain (for the app)

## Building

```bash
# Enter development shell
nix develop

# Build release
nix build

# Build debug
nix build .#debug

# Run tests
nix build .#test
```

### Development with Zig

```bash
# Build library only
zig build

# Build macOS app
zig build -Demit-macos-app

# Build and run with terminal logging (dev mode)
zig build run
```

## Usage

Two ways to run a guest, sharing the same Zig VM core.

### Headless (drop into a shell)

`bobrvm run` boots directly into the guest's console — no window:

```bash
# Sign the CLI once per build (Hypervisor.framework entitlement).
# `nix develop -c zig build` does this automatically.

# Direct kernel boot, interactive serial console (Ctrl-] to quit):
./zig-out/bin/bobrvm run \
    --kernel Image --initrd initrd \
    --memory 4096 --cpus 4 \
    --disk root.raw --disk2 scratch.raw --disk2-writable \
    --net \
    --cmdline 'console=hvc0 root=LABEL=... init=/nix/store/...-init'
```

Key flags: `--net` (built-in NAT: DHCP + real internet, no root),
`--gpu`/`--virgl` (add a display device), `--display WxH`,
`--disk2 <img> --disk2-writable` (a persistent second disk, `/dev/vdb`).

### GUI (window)

The Swift app (`macos/MinimalApp`) owns the window and Metal context;
the Zig renderer thread blits the guest scanout into a `CAMetalLayer`
and routes keyboard/mouse back to virtio-input.

```bash
nix develop -c zig build            # build libbobrvm.a
./macos/MinimalApp/build.sh         # link + codesign the app
./zig-out/bin/BobrvmDisplay --kernel Image --initrd initrd \
    --cmdline 'console=tty0 console=hvc0 ...'
```

## Logging

bobrvm has dual logging: stderr (terminal) and macOS unified logging.

### Dev Mode

When running via `zig build run`, logs automatically appear in the terminal:

```
info: (main) bobrvm initialized (version 0.1.0)
debug: (apprt) creating app instance
info: (apprt) app created successfully
info: (renderer) starting renderer thread (target 60fps)
```

### Environment Variable

Control logging with `BOBRVM_LOG`:

```bash
# Enable all logging (stderr + macOS unified log)
BOBRVM_LOG=true ./Bobrvm.app/Contents/MacOS/Bobrvm

# Disable all logging
BOBRVM_LOG=false ./Bobrvm.app/Contents/MacOS/Bobrvm

# Fine-grained control
BOBRVM_LOG=stderr=true,macos=false ./Bobrvm.app/Contents/MacOS/Bobrvm
```

### macOS Unified Logging

View logs from deployed apps:

```bash
log stream --level debug --predicate 'subsystem=="com.bobrvm.lib"'
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Swift (UI only)                                    │
│  - NSWindow, CAMetalLayer                           │
│  - Routes input events to Zig                       │
└──────────────────┬──────────────────────────────────┘
                   │ C FFI (bobrvm.h)
                   ▼
┌─────────────────────────────────────────────────────┐
│  Zig Core (libbobrvm)                               │
│  - Hypervisor.framework bindings                    │
│  - virtio device emulation                          │
│  - virgl/Venus → Metal translation                  │
│  - Renderer thread (60fps)                          │
└─────────────────────────────────────────────────────┘
```

## Project Structure

```
bobrvm/
├── flake.nix           # Nix build (Zig core only)
├── build.zig           # Zig build
├── include/bobrvm.h    # C API (Swift FFI)
├── src/
│   ├── cli/            # `bobrvm run` headless entry
│   ├── apprt/          # C API + embedded runtime (keymap, surfaces)
│   ├── hypervisor/     # Hypervisor.framework bindings, vCPU
│   ├── machine/        # Machine model, MMIO dispatch, PSCI/SMP, DTB
│   ├── gic/            # GICv3 interrupt controller
│   ├── virtio/         # console, blk, gpu, input, net, mmio, ring
│   ├── net/            # built-in NAT (ARP/DHCP/ICMP/UDP/TCP)
│   ├── gpu/            # virgl decode + Metal backend
│   └── renderer/       # Metal render thread
├── macos/
│   ├── MinimalApp/     # Swift display app (swiftc, outside nix)
│   └── Bobrvm.xcodeproj/
└── tests/integration/  # alpine, persistence, bare-metal harnesses
```

## License

MIT
