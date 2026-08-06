{
  lib,
  buildEnv,
  qemu_kvm,
  spice-vdagent,
  stdenv,
  zig_0_16,
}: let
  guestBinaries = stdenv.mkDerivation {
    pname = "bobrvm-guest-binaries";
    version = "0.1.0";
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../build.zig
        ../build.zig.zon
        ../LICENSE
        ../src/build
        ../src/callback.zig
        ../src/agent/native.zig
        ../src/agent/protocol.zig
        ../src/guest_tools
      ];
    };
    nativeBuildInputs = [zig_0_16];
    dontConfigure = true;
    dontUseZigBuild = true;
    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
      zig build -Demit-guest-tools=true -Doptimize=ReleaseSafe
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -R zig-out/. "$out"
      runHook postInstall
    '';
  };
in
  buildEnv {
    pname = "bobrvm-tools";
    version = "0.1.0";
    name = "bobrvm-tools-0.1.0";
    paths = [
      guestBinaries
      qemu_kvm.ga
      spice-vdagent
    ];
    meta = {
      description = "Guest integration tools for bobrvm virtual machines";
      homepage = "https://github.com/polymath-as/bobrvm";
      license = lib.licenses.bsl11;
      platforms = ["aarch64-linux"];
    };
  }
