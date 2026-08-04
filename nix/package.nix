{
  lib,
  stdenv,
  libiconv,
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

  nativeBuildInputs = [
    pkg-config
    zig
  ];
  buildInputs = [libiconv];

  dontConfigure = true;
  dontUseZigBuild = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build -Dcpu=baseline -Doptimize=${finalAttrs.optimize}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -R zig-out/. "$out"
    runHook postInstall
  '';

  meta = {
    description = "Linux virtualization for macOS";
    homepage = "https://github.com/polymath-as/bobrvm";
    license = lib.licenses.bsl11;
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    mainProgram = "bobrvm";
  };
})
