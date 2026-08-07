# bobrvm

bobrvm runs virtual machines on macOS and Linux. On Apple Silicon, the Linux VM
uses Hypervisor.framework and macOS guests use Apple's Virtualization framework.
On x86-64 Linux, the direct-boot VM uses KVM with a GTK host application. The
platform applications stay thin while Zig owns virtualization and devices.

The project is under active development. Linux guests can boot NixOS to a GUI
or headless console with SMP, persistent virtio disks, input, built-in NAT, and
2D Metal display output. The optional Venus stack supports Vulkan 1.4 and
OpenGL 4.6 through Zink using the vendored GPU dependencies in `third_party/`.
The legacy virgl translator is a GL 2.x fallback.

macOS guests support IPSW installation, persistent hardware identity, and
native display, input, networking, and audio devices.

Automated Apple Silicon builds of the latest commit on `main` are published to
the prerelease tagged [`tip`](https://github.com/polymath-as/bobrvm/releases/tag/tip).

## Requirements

- Apple Silicon Mac running macOS 13 or later
- Or x86-64 Linux with KVM and GTK 4
- Nix for the Zig core
- Xcode and the Swift toolchain for the macOS app

## Build

```sh
nix develop
nix build              # release library
nix build .#debug       # debug library
nix build .#test        # Zig tests

zig build              # library in the development shell
zig build run          # build and run the native app with terminal logging
zig build macos-app    # build the native app without running it
zig build cli -- help  # run the headless CLI
zig build test         # run all Zig tests
zig build test -Dtest-filter=<name>
```

See [macos/README.md](macos/README.md) for Xcode and framework builds.

### Linux host preview

The Linux package installs a dependency-light headless binary and a separate GTK
application. Both use the same cancellable Zig VM lifecycle and KVM device model:

```sh
bobrvm run-kernel bzImage initrd writable-root.raw
bobrvm-gtk bzImage initrd writable-root.raw
```

The current x86 direct-boot path provides writable virtio-pci block storage.
Queue kicks and level interrupts use KVM `ioeventfd`/`irqfd`, keeping block I/O off
the vCPU thread. A virtio-net adapter uses the shared Zig user-mode NAT, with no TAP
device or host privileges required. The GTK application displays a bounded
serial-console history and forwards text and navigation keys through the shared Zig
16550 UART. Closing its window requests an immediate vCPU exit and joins the VM before
releasing resources.

Direct boot uses two KVM vCPUs by default and exposes their topology through an Intel
MP table. Use `bobrvm kvm-boot-benchmark <bzImage> <initrd> <disk>` for three comparable
host-monotonic samples of VM creation and start-to-root-readiness latency.

## Run a Linux guest

`bobrvm run` starts a headless VM attached to the guest console. Press
<kbd>Ctrl</kbd>+<kbd>]</kbd> to quit. Press <kbd>Ctrl</kbd>+<kbd>B</kbd>, then
<kbd>?</kbd>, for guest-tools status and lifecycle commands.

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

For a headless Linux guest:

```sh
zig build cli -- run --kernel Image --initrd initrd \
  --cmdline 'console=hvc0 ...'
```

## Guest tools

The flake exports `packages.aarch64-linux.bobrvm-tools` and
`nixosModules.guest`. The module configures Venus/Zink graphics and can opt in
to clipboard integration, guest lifecycle management, quiesced snapshots,
file delivery, and a shared folder:

```nix
{
  imports = [ bobrvm.nixosModules.guest ];
  virtualisation.bobrvm.guest = {
    enable = true;
    management.enable = true;
    clipboard.enable = true;
    fileTransfer.enable = true;
    sharedFolder.enable = true;
  };
}
```

The guest Mesa package must be built on aarch64 Linux, either inside the guest
or with a remote Linux builder. Build the host GPU stack with:

```sh
third_party/sync.sh
third_party/build.sh
zig build -Dgpu-venus
```

See [docs/guest-tools.md](docs/guest-tools.md) for the feature matrix, security
defaults, diagnostics, and complete NixOS configuration.

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
