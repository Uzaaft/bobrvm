{
  lib,
  stdenv,
  libiconv,
  zig,
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
    zig build test
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    touch "$out"
    runHook postInstall
  '';
}
