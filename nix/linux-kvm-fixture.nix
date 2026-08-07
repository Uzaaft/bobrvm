{
  cpio,
  e2fsprogs,
  linuxPackages,
  runCommand,
  xz,
  zig,
}:
runCommand "bobrvm-linux-kvm-fixture" {
  nativeBuildInputs = [cpio e2fsprogs xz zig];
  init = ../tests/integration/linux-kvm/init.zig;
  rootInit = ../tests/integration/linux-kvm/root_init.zig;
} ''
  export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
  export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
  export E2FSPROGS_FAKE_TIME=1
  mkdir -p "$out/root/dev" "$out/root/modules" "$out/root/newroot" "$out/rootfs"
  zig build-exe "$init" \
    -target x86_64-linux-musl \
    -O ReleaseSmall \
    -fstrip \
    -femit-bin="$out/root/init"
  zig build-exe "$rootInit" \
    -target x86_64-linux-musl \
    -O ReleaseSmall \
    -fstrip \
    -femit-bin="$out/rootfs/init"
  printf 'bobrvm-root-filesystem\n' >"$out/rootfs/rootfs-marker"

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
  xz -dc "$module_root/lib/crc/crc16.ko.xz" \
    >"$out/root/modules/crc16.ko"
  xz -dc "$module_root/fs/mbcache.ko.xz" \
    >"$out/root/modules/mbcache.ko"
  xz -dc "$module_root/fs/jbd2/jbd2.ko.xz" \
    >"$out/root/modules/jbd2.ko"
  xz -dc "$module_root/fs/ext4/ext4.ko.xz" \
    >"$out/root/modules/ext4.ko"

  find "$out/root" "$out/rootfs" -exec touch -h -d @1 {} +
  (cd "$out/root" && find . -print0 | sort -z | \
    cpio --reproducible --null -o -H newc -F "$out/initrd")
  truncate -s 67108864 "$out/disk"
  mke2fs -q -t ext4 -F -L bobrvm-root \
    -U 00000000-0000-0000-0000-000000000001 \
    -E hash_seed=00000000-0000-0000-0000-000000000002,root_owner=0:0 \
    -d "$out/rootfs" \
    "$out/disk"
  ln -s ${e2fsprogs}/bin/debugfs "$out/debugfs"
  ln -s ${e2fsprogs}/bin/e2fsck "$out/e2fsck"
  ln -s ${linuxPackages.kernel}/bzImage "$out/kernel"
''
