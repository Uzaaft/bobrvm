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

For CLI and MCP tests, build the shell fixture:

```sh
./tests/integration/alpine/download.sh
nix shell nixpkgs#squashfsTools -c bash tests/integration/alpine/create-minimal-initramfs.sh
python3 tests/integration/mcp/mcp-sandbox-test.py
```

The builder needs Python 3.9+ and `unsquashfs` on the host. It retains the boot
initramfs's module set and adds 9p with its dependencies from Alpine's matching
`modloop-virt` archive. It rejects mismatched kernel releases. The archive is a
build input; only selected modules enter `initramfs-minimal`.

The MCP test requires a mounted host folder before taking its warm snapshot.
It verifies ordinary forks can read the share, while isolated forks deny host
reads and writes after restoring the mount. Missing drivers fail the test.
Rebuild existing fixtures with the commands above; downloading a new bundle
invalidates `initramfs-minimal`. Regenerate warm snapshots after changing images.
