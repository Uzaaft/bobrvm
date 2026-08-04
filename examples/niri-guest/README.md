# niri guest

This example builds a NixOS guest with niri, foot, and Ghostty. The compositor
uses the legacy virgl-to-Metal path; applications can use software rendering or
the experimental Zink/Venus path.

## Build

The build runs inside a stock NixOS guest and takes about 25 minutes because it
builds patched Mesa from source.

```sh
mkdir -p ~/.local/share/bobrvm-niri/share/out
cp flake.nix configuration.nix install.sh export.sh \
  ../../nix/patches/mesa-venus-16k-blob-align.patch \
  ~/.local/share/bobrvm-niri/share/
truncate -s 40G ~/.local/share/bobrvm-niri/nixos-niri.raw
./build-niri-guest.sh
```

Then boot the installed system:

```sh
zig build -Dgpu-venus
BOBRVM_GUI_VENUS=1 macos/MinimalApp/build.sh
zig-out/bin/BobrvmDisplay \
  --kernel share/out/niri-Image --initrd share/out/niri-initrd \
  --disk nixos-niri.raw --gpu3d --net --memory-mb 8192 --cpus 6 \
  --cmdline 'console=tty0 console=hvc0 init=/nix/var/nix/profiles/system/init root=/dev/vda2 rw'
```

Keep the profile-based `init` path: it follows the current NixOS generation.
After changing `configuration.nix`, run `niri-rebuild-and-test.sh`.

Windowed Zink is not yet supported because the macOS Venus path cannot export
the dma-buf required for presentation. The scripts also work around the VM's
missing RTC by setting the guest clock before network access.
