# niri + ghostty guest — a Wayland desktop on bobrvm

A NixOS guest running the niri compositor with foot and ghostty, rendering
through bobrvm's virtio-gpu (legacy virgl→Metal translator for the
compositor; clients pick their GL path per app). This is the configuration
the GPU translator was debugged against.

## Build the image (entirely inside a VM — no cross-compiling, no builder)

The install runs in the stock NixOS ISO under bobrvm, with this directory
shared over 9p and the target disk attached writable:

    mkdir -p ~/.local/share/bobrvm-niri/share/out
    cp flake.nix configuration.nix install.sh export.sh \
       ../../nix/patches/mesa-venus-16k-blob-align.patch \
       ~/.local/share/bobrvm-niri/share/
    truncate -s 40G ~/.local/share/bobrvm-niri/nixos-niri.raw
    ./build-niri-guest.sh      # ~25 min; patched Mesa builds from source in-VM

`install.sh` partitions the disk, runs `nixos-install --flake`, and exports
the kernel/initrd plus the system's init path to `share/out/`. Boot with:

    zig build -Dgpu-venus
    BOBRVM_GUI_VENUS=1 macos/MinimalApp/build.sh
    zig-out/bin/BobrvmDisplay \
      --kernel share/out/niri-Image --initrd share/out/niri-initrd \
      --disk nixos-niri.raw --gpu3d --net --memory-mb 8192 --cpus 6 \
      --cmdline "console=tty0 console=hvc0 init=/nix/var/nix/profiles/system/init root=/dev/vda2 rw"

Use `init=/nix/var/nix/profiles/system/init` (the profile symlink), not a
store path — it tracks the current generation across rebuilds. Config
changes: edit configuration.nix, then `niri-rebuild-and-test.sh` (boots the
installed system, copies the config in over 9p, `nixos-rebuild switch`).

## GL paths in the guest (state of the world)

| Path | Windowed? | Version | Used by |
|---|---|---|---|
| virgl (bobrvm translator) | yes | GLES2-class | the compositor |
| llvmpipe (software) | yes | GL 4.6 | ghostty (LIBGL_ALWAYS_SOFTWARE=1) |
| zink over venus (hardware) | headless only | GL 4.6 | `zink-run <app>` offscreen |

zink cannot create a *windowed* screen yet: presentation needs dma-buf
export, which venus→KosmicKrisp cannot provide on macOS ("DRI2: failed to
create screen", then Mesa falls back to llvmpipe). Keybinds in the niri
config keep the canaries handy: Mod+T ghostty (software GL), Mod+Y ghostty
on virgl, Mod+U ghostty on zink.

## Gotchas encoded in these scripts

- bobrvm exposes no RTC: the guest boots at the epoch and all TLS fails
  ("certificate is not yet valid"). The harness writes `share/host-date`
  and install.sh sets the clock before touching the network.
- `/dev/disk/by-label/*` is not reliably present in the live ISO right
  after mkfs — mount partition nodes directly.
- In the live installer, absolute `/nix/store/...` symlink targets resolve
  against the ISO's root: read the link text and re-root under `/mnt`.
