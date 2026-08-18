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

Then boot the installed system. This directory ships a `bobrvm.toml`, so from
here you can just run the project workflow with a Venus-enabled build:

```sh
zig build -Dgpu-venus     # builds and signs zig-out/bin/bobrvm with Venus
bobrvm up                 # reads bobrvm.toml (virgl + net + 1920x1080 display)
```

`bobrvm up` boots headless attached to the console; quit with
<kbd>Ctrl</kbd>+<kbd>B</kbd> <kbd>z</kbd> to save the warm state so the next
`bobrvm up` resumes the running desktop instead of booting. For a native
window, build and run the macOS app (`zig build run`) against the same disk.

Or invoke the headless CLI directly without the project file:

```sh
zig-out/bin/bobrvm run \
  --kernel share/out/niri-Image --initrd share/out/niri-initrd \
  --disk nixos-niri.raw --virgl --net --memory 8192 --cpus 6 \
  --cmdline 'console=tty0 console=hvc0 init=/nix/var/nix/profiles/system/init root=/dev/vda2 rw'
```

Keep the profile-based `init` path: it follows the current NixOS generation.
After changing `configuration.nix`, run `niri-rebuild-and-test.sh`.

Windowed Zink is not yet supported because the macOS Venus path cannot export
the dma-buf required for presentation. The scripts also work around the VM's
missing RTC by setting the guest clock before network access.
