# bobrvm

bobrvm runs Linux and macOS virtual machines on Apple Silicon. The Linux VM is
implemented in Zig on Hypervisor.framework; macOS guests use Apple's
Virtualization framework. A native Swift app provides the window and Metal
context while Zig owns Linux guest rendering.

The project is under active development. Linux guests can boot NixOS to a GUI
or headless console with SMP, persistent virtio disks, input, built-in NAT, and
2D Metal display output. The optional Venus stack supports Vulkan 1.4 and
OpenGL 4.6 through Zink using the vendored GPU dependencies in `third_party/`.
The legacy virgl translator is a GL 2.x fallback.

macOS guests support IPSW installation, persistent hardware identity, and
native display, input, networking, and audio devices.

## Requirements

- Apple Silicon Mac running macOS 13 or later
- Nix for the Zig core
- Xcode and the Swift toolchain for the macOS app

## Build

```sh
nix develop
nix build              # release library
nix build .#debug       # debug library
nix build .#test        # Zig tests

zig build              # library in the development shell
zig build run          # build and run with terminal logging
zig build -Demit-macos-app
```

See [macos/README.md](macos/README.md) for Xcode and framework builds.

## Run a Linux guest

`bobrvm run` starts a headless VM attached to the guest console. Press
<kbd>Ctrl</kbd>+<kbd>]</kbd> to quit.

```sh
./zig-out/bin/bobrvm run \
  --kernel Image --initrd initrd \
  --memory 4096 --cpus 4 \
  --disk root.raw --net \
  --cmdline 'console=hvc0 root=LABEL=... init=/nix/store/...-init'
```

Use `--disk2 <image> --disk2-writable` for a persistent second disk. Add a
display device with `--gpu` or `--virgl`; use `--display WxH` to set its size.
The build signs the CLI with the Hypervisor.framework entitlement.

For the lightweight Swift display app:

```sh
nix develop -c zig build
./macos/MinimalApp/build.sh
./zig-out/bin/BobrvmDisplay --kernel Image --initrd initrd \
  --cmdline 'console=tty0 console=hvc0 ...'
```

## Guest graphics

The flake exports `nixosModules.guest`, which configures a NixOS guest for
Zink and Venus:

```nix
{
  imports = [ bobrvm.nixosModules.guest ];
  virtualisation.bobrvm.guest.enable = true;
}
```

The guest Mesa package must be built on aarch64 Linux, either inside the guest
or with a remote Linux builder. Build the host GPU stack with:

```sh
third_party/sync.sh
third_party/build.sh
zig build -Dgpu-venus
```

See [third_party/README.md](third_party/README.md) for the pinned GPU forks and
[docs/gpu-direction-decision.md](docs/gpu-direction-decision.md) for design
details.

## Logging

`zig build run` logs to the terminal. Packaged apps also use macOS unified
logging. `BOBRVM_LOG` accepts `true`, `false`, or backend settings such as
`stderr=true,macos=false`.

```sh
log stream --level debug --predicate 'subsystem=="com.bobrvm.lib"'
```

## License

MIT
