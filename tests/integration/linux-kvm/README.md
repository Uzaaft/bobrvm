# Linux KVM direct-boot test

This hardware-only test boots a Nix-provided x86_64 Linux kernel with a tiny static Zig
initramfs. PID 1 emits `BOBRVM_LINUX_INIT_OK` through the debug I/O port, avoiding any
dependency on userspace, a root disk, or an initialized serial console.

```bash
nix build path:.#linux-kvm-fixture
nix develop -c zig build
tests/integration/linux-kvm/run.sh \
    ./zig-out/bin/bobrvm \
    ./result/kernel \
    ./result/initrd
```

The runner needs read/write access to `/dev/kvm`. It applies a ten-second host timeout because
the minimal PC platform does not yet expose an ACPI power-off device.
