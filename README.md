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
| Boot (Apple Hypervisor.framework, arm64) |  NixOS to login, ~15s (1 vCPU) |
| Serial console (virtio-console + PL011) |  interactive shell |
| SMP (PSCI CPU_ON) |  4 vCPUs online |
| virtio-blk |  read/write, durable across restarts |
| virtio-gpu 2D → Metal |  fbcon renders in the app window |
| virtio-input (keyboard/mouse) |  evdev in guest |
| virtio-net + built-in NAT |  DHCP, DNS, TCP/UDP internet (no root) |
| Vulkan 1.4 in guests (Venus → KosmicKrisp → Metal) | ✅ guest enumerates the host GPU |
| **OpenGL 4.6 + ES 3.2 in guests** (Zink over Venus) | ✅ `VENUS-GLTEST: PASS`; in-guest GS render probe pixel-verified; **glmark2 full suite passes, Score 1221** (~1500–1600 FPS on most scenes, M3 Max). Needs the vendored KosmicKrisp fork (`third_party/`): geometry shaders, transform feedback, depth-clip-enable, RGB32 texel buffers, split memory types |
| OpenGL (legacy virgl→Metal translator) | 🗄️ fallback path (GL 2.x honest) |

### Upstream MRs of interest (GPU stack)

The guest GL/Vulkan stack is `zink → venus → bobrvm virtio-gpu → virglrenderer
→ KosmicKrisp → Metal`. What we track/carry:

- **virglrenderer macOS support** (merged upstream 2026): build
  ([!1600](https://gitlab.freedesktop.org/virgl/virglrenderer/-/merge_requests/1600)),
  posix_spawn render workers
  ([!1601](https://gitlab.freedesktop.org/virgl/virglrenderer/-/merge_requests/1601)),
  Metal shared memory / `KHR_external_memory_fd` emulation toward the guest
  ([!1602](https://gitlab.freedesktop.org/virgl/virglrenderer/-/merge_requests/1602)),
  Metal device export at instance creation
  ([!1635](https://gitlab.freedesktop.org/virgl/virglrenderer/-/merge_requests/1635)).
- **Our virglrenderer patch (to upstream):** host-pointer shm import via
  `VK_EXT_external_memory_host` for drivers without `VK_EXT_metal_objects`
  (i.e. KosmicKrisp) — `third_party/patches/virglrenderer/`.
- **KosmicKrisp geometry pipeline (Mesa, in flight at LunarG)** — gates zink
  GL ≥ 3.0/3.2 and therefore 4.3:
  poly geometry-unroll sharing
  ([mesa!41568](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/41568), merged 2026-05),
  hardware-stage vertex lowerings
  ([mesa!42020](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42020), merged 2026-06),
  adjacency-topology CTS workaround
  ([mesa!43091](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/43091), 2026-07);
  `VK_EXT_transform_feedback` properties are staged in `kk_physical_device.c`
  on Mesa main. Until TF + `geometryShader` land, our vendored fork
  (`third_party/`) carries the gap — see `docs/gpu-direction-decision.md`.

### Guest setup (NixOS module)

The flake exports a guest-side NixOS module that sets up everything a
bobrvm guest needs for OpenGL 4.6 / Vulkan 1.4: a Mesa overlay with the
16KiB venus blob-alignment patch (`nix/patches/`), graphics enablement,
zink as the default GL driver, and verification tools
(eglinfo/vulkaninfo/glmark2).

```nix
# in your aarch64-linux NixOS configuration
{
  imports = [ bobrvm.nixosModules.guest ];   # or nix/guest-module.nix by path
  virtualisation.bobrvm.guest.enable = true;
}
```

The overlaid Mesa must be *built* for aarch64-linux — a macOS host can't do
that alone. Two ways:

- **Inside the guest** (zero host setup): boot your existing NixOS guest in
  bobrvm with `--net`, add the module, `nixos-rebuild switch`. The VM
  builds Mesa itself (~30–60 min at 4 vCPUs, once).
- **Linux builder on the Mac**: nix-darwin's `nix.linux-builder.enable`, or
  any remote aarch64-linux builder; then build a full disk image with
  nixos-generators and boot it with `bobrvm run --disk`.

Host side: `third_party/sync.sh && third_party/build.sh` (vendored
virglrenderer + KosmicKrisp), then `zig build -Dgpu-venus`. Verify in the
guest with `vulkaninfo --summary` (expect "Virtio-GPU Venus (Apple M3
Max)") and `eglinfo` (expect `OpenGL core profile version: 4.6`).

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
