{
  lib,
  stdenv,
  libiconv,
  zig,
  zigDeps,
}:
stdenv.mkDerivation {
  pname = "bobrvm-test";
  version = "0.1.0";

  src = lib.cleanSource ../.;

  nativeBuildInputs = [zig];
  buildInputs = [libiconv];

  dontConfigure = true;
  dontUseZigBuild = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    zig build test
    zig build bare-metal-test
    zig build test-fuzz-virtqueue --fuzz=100K
    zig build test-fuzz-virgl-decoder --fuzz=100K
    zig build test-fuzz-agent-protocol --fuzz=100K
    zig build test-fuzz-snapshot-container --fuzz=100K
    zig build test-fuzz-p9 --fuzz=100K
    zig build test-fuzz-virtio-mmio --fuzz=100K
    zig build test-fuzz-pci --fuzz=100K
    zig build test-fuzz-tgsi --fuzz=100K
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    touch "$out"
    runHook postInstall
  '';
}
