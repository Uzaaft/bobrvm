# Running guests

The project workflow in [project-vms.md](project-vms.md) is the normal way to
run a Linux guest. The lower-level CLI is useful for bring-up and debugging.

## Native macOS VMM

```sh
./zig-out/bin/bobrvm run \
  --kernel Image --initrd initrd \
  --memory 4096 --cpus 4 \
  --disk root.raw --net \
  --cmdline 'console=hvc0 root=LABEL=... init=/nix/store/...-init'
```

Press <kbd>Ctrl</kbd>+<kbd>]</kbd> to quit. Use `--disk2 <image>` with
`--disk2-writable` for a persistent second disk. Add a display with `--gpu` or
`--virgl`, and set its size with `--display WxH`.

`--kitty-display` renders the scanout in terminals that implement the Kitty
graphics protocol. It is intended for headless development, not as a native UI.

For a headless Linux host build:

```sh
zig build cli -- run --kernel Image --initrd initrd \
  --cmdline 'console=hvc0 ...'
```

Run `bobrvm run --help` for the complete interface.

## Startup profiling

`BOBRVM_BENCHMARK_STARTUP=1` exits after VM and primary-vCPU startup. It works
with both the native VMM and Virtualization.framework paths:

```sh
BOBRVM_LOG=true BOBRVM_BENCHMARK_STARTUP=1 ./zig-out/bin/bobrvm run \
  --kernel Image --initrd initrd
BOBRVM_LOG=true BOBRVM_BENCHMARK_STARTUP=1 ./zig-out/bin/bobrvm vz-run \
  --kernel Image --initrd initrd
```

## Guest integration

The flake exports `packages.aarch64-linux.bobrvm-tools` and
`nixosModules.guest`. The module can configure graphics, lifecycle management,
clipboard integration, file delivery, shared folders, snapshots, and Docker.
See [guest-tools.md](guest-tools.md).
