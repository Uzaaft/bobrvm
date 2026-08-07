{
  cpio,
  linuxPackages,
  runCommand,
  xz,
  zig,
}:
runCommand "bobrvm-linux-kvm-fixture" {
  nativeBuildInputs = [cpio xz zig];
  init = ../tests/integration/linux-kvm/init.zig;
} ''
  export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
  export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
  mkdir -p "$out/root/dev" "$out/root/modules"
  zig build-exe "$init" \
    -target x86_64-linux-musl \
    -O ReleaseSmall \
    -fstrip \
    -femit-bin="$out/root/init"

  module_root=${linuxPackages.kernel.modules}/lib/modules
  module_root+="/${linuxPackages.kernel.modDirVersion}/kernel"
  xz -dc "$module_root/drivers/virtio/virtio.ko.xz" \
    >"$out/root/modules/virtio.ko"
  xz -dc "$module_root/drivers/virtio/virtio_ring.ko.xz" \
    >"$out/root/modules/virtio_ring.ko"
  xz -dc "$module_root/drivers/virtio/virtio_pci_modern_dev.ko.xz" \
    >"$out/root/modules/virtio_pci_modern_dev.ko"
  xz -dc "$module_root/drivers/virtio/virtio_pci_legacy_dev.ko.xz" \
    >"$out/root/modules/virtio_pci_legacy_dev.ko"
  xz -dc "$module_root/drivers/virtio/virtio_pci.ko.xz" \
    >"$out/root/modules/virtio_pci.ko"
  xz -dc "$module_root/drivers/block/virtio_blk.ko.xz" \
    >"$out/root/modules/virtio_blk.ko"

  (cd "$out/root" && find . -print0 | cpio --null -o -H newc -F "$out/initrd")
  printf 'bobrvm-disk-fixture\n' >"$out/disk"
  truncate -s 1048576 "$out/disk"
  ln -s ${linuxPackages.kernel}/bzImage "$out/kernel"
''
