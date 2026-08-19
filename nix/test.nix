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

  src = lib.fileset.toSource {
    root = ../.;
    fileset =
      lib.fileset.intersection
      (lib.fileset.fromSource (lib.sources.cleanSource ../.))
      (lib.fileset.unions [
        ../build.zig
        ../build.zig.zon
        ../include
        ../LICENSE
        ../linux
        ../macos/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png
        ../src
        ../tests
        ../third_party
        ../tools
        ../cli.entitlements
        ../cli-venus.entitlements
        ../venus.entitlements
      ]);
  };

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
    run_fuzz() {
      local step="$1"
      local log="$TMPDIR/$step.log"

      zig build "$step" --fuzz=100K 2>&1 | tee "$log"
      local status="''${PIPESTATUS[0]}"
      if [[ "$status" -ne 0 ]] ||
        grep -Fq "run test failure" "$log" ||
        grep -Fq "input saved to" "$log"
      then
        echo "$step found a failing input" >&2
        return 1
      fi
    }
    run_fuzz test-fuzz-virtqueue
    run_fuzz test-fuzz-virgl-decoder
    run_fuzz test-fuzz-agent-protocol
    run_fuzz test-fuzz-snapshot-container
    run_fuzz test-fuzz-p9
    run_fuzz test-fuzz-virtio-mmio
    run_fuzz test-fuzz-pci
    run_fuzz test-fuzz-gic
    run_fuzz test-fuzz-tgsi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    touch "$out"
    runHook postInstall
  '';
})
