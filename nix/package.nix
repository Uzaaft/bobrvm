{
  lib,
  stdenv,
  libiconv,
  gtk4,
  pkg-config,
  zig,
  optimize ? "ReleaseFast",
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "bobrvm";
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
        ../src
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

  passthru = {
    inherit (finalAttrs) zigDeps;
  };

  nativeBuildInputs = [
    pkg-config
    zig
  ];
  buildInputs =
    lib.optional stdenv.hostPlatform.isDarwin libiconv
    ++ lib.optional stdenv.hostPlatform.isLinux gtk4;

  dontConfigure = true;
  dontUseZigBuild = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    zig build \
      -Dcpu=baseline \
      -Doptimize=${optimize}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -R zig-out/. "$out"
    runHook postInstall
  '';

  meta = {
    description = "Fast Linux virtualization for macOS and Linux";
    homepage = "https://github.com/polymath-as/bobrvm";
    license = lib.licenses.bsl11;
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    mainProgram = "bobrvm";
  };
})
