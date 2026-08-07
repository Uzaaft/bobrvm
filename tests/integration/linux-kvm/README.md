# Linux KVM direct-boot test

This hardware-only test boots a Nix-provided x86_64 Linux kernel through a tiny static Zig
initramfs. Stage 1 loads virtio-pci, virtio-blk, and ext4, then mounts the writable `/dev/vda`
root filesystem and executes its `/init`. Stage 2 persists a marker, remounts the filesystem
read-only, and emits `BOBRVM_ROOTFS_BOOT_OK` through the debug I/O port. The host requires a
clean filesystem and verifies the persisted file without repairing the image.

```bash
nix build path:.#linux-kvm-fixture
nix develop -c zig build
tests/integration/linux-kvm/run.sh \
    ./zig-out/bin/bobrvm \
    ./result/kernel \
    ./result/initrd \
    ./result/disk
```

The runner needs read/write access to `/dev/kvm`. Its ten-second timeout is only a hang guard;
the fixture reboots through the x86 triple-fault path so a successful VM exits immediately.
