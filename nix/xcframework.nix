{
  lib,
  stdenv,
  libiconv,
  zig,
}:
stdenv.mkDerivation {
  pname = "BobrvmKit";
  version = "0.1.0";

  src = lib.cleanSource ../.;

  nativeBuildInputs = [zig];
  buildInputs = [libiconv];

  dontConfigure = true;
  dontUseZigBuild = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build xcframework
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -R macos/BobrvmKit.xcframework "$out"
    runHook postInstall
  '';
}
