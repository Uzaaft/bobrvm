{
  cpio,
  linuxPackages,
  runCommand,
  zig,
}:
runCommand "bobrvm-linux-kvm-fixture" {
  nativeBuildInputs = [cpio zig];
  init = ../tests/integration/linux-kvm/init.zig;
} ''
  export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
  export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
  mkdir -p "$out/root"
  zig build-exe "$init" \
    -target x86_64-linux-musl \
    -O ReleaseSmall \
    -fstrip \
    -femit-bin="$out/root/init"
  (cd "$out/root" && find . -print0 | cpio --null -o -H newc -F "$out/initrd")
  ln -s ${linuxPackages.kernel}/bzImage "$out/kernel"
''
