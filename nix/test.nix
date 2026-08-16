{
  lib,
  stdenv,
  libiconv,
  virglrenderer,
  zig,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "bobrvm-test";
  version = "0.1.0";

  src = lib.cleanSource ../.;

  zigDeps = zig.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-8Jxd6eCAVre82oRiAkAh0jS7AxBFTGXMEIhHxDJhupI=";
  };

  nativeBuildInputs = [zig];
  buildInputs =
    lib.optional stdenv.hostPlatform.isDarwin libiconv
    ++ lib.optional stdenv.hostPlatform.isLinux virglrenderer;

  dontConfigure = true;
  dontUseZigBuild = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    zig build test-compile
    mapfile -t test_binaries < <(find "$ZIG_LOCAL_CACHE_DIR/o" \
      -type f -name 'bobrvm-*-tests' -perm -0100)
    if [[ "''${#test_binaries[@]}" -ne 2 ]]; then
      echo "expected two Zig test binaries, found ''${#test_binaries[@]}" >&2
      exit 1
    fi
    for test_binary in "''${test_binaries[@]}"; do
      ${
      if stdenv.hostPlatform.isDarwin
      then ''
        "$test_binary"
      ''
      else ''
        ${stdenv.cc.bintools.dynamicLinker} \
          --library-path ${lib.makeLibraryPath [stdenv.cc.libc virglrenderer]} \
          "$test_binary"
      ''
    }
    done
    zig build bare-metal-test
    zig build test-fuzz-virtqueue --fuzz=100K
    zig build test-fuzz-virgl-decoder --fuzz=100K
    zig build test-fuzz-agent-protocol --fuzz=100K
    zig build test-fuzz-snapshot-container --fuzz=100K
    zig build test-fuzz-p9 --fuzz=100K
    zig build test-fuzz-virtio-mmio --fuzz=100K
    zig build test-fuzz-pci --fuzz=100K
    zig build test-fuzz-gic --fuzz=100K
    zig build test-fuzz-tgsi --fuzz=100K
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    touch "$out"
    runHook postInstall
  '';
})
