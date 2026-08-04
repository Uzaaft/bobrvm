# Alpine Linux integration test

This test boots an Alpine arm64 kernel and initramfs to exercise GICv3, the
architectural timer, PSCI, and the virtio console.

```sh
./tests/integration/alpine/download.sh
./zig-out/bin/bobrvm run \
  --kernel tests/integration/alpine/out/Image \
  --initrd tests/integration/alpine/out/initramfs-virt
```

The boot reaches Alpine init and then waits for boot media. Attach a root
filesystem through virtio-blk to continue. Expected console output includes
`Loading boot drivers: ok.` and `Mounting boot media...`.

The default kernel command line is
`console=hvc0 earlycon=pl011,0x09000000`. For verbose output, use
`console=ttyAMA0 earlycon=pl011,0x09000000 earlyprintk debug loglevel=8`.

`download.sh` extracts the raw ARM64 image from Alpine's EFI-stub
`vmlinuz-virt`.
