{
  lib,
  stdenv,
  OVMF,
  alsa-lib,
  glib,
  gobject-introspection,
  gsettings-desktop-schemas,
  libiconv,
  gtk4,
  libadwaita,
  patchelf,
  pkg-config,
  virglrenderer,
  wrapGAppsHook4,
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
        ../linux
        ../macos/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png
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

  nativeBuildInputs =
    [
      pkg-config
      patchelf
      zig
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      gobject-introspection
      wrapGAppsHook4
    ];
  buildInputs =
    lib.optional stdenv.hostPlatform.isDarwin libiconv
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      glib
      alsa-lib
      gsettings-desktop-schemas
      gtk4
      libadwaita
      virglrenderer
    ];

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
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} "$out/bin/bobrvm"
      patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} "$out/bin/bobrvm-gtk"
      mkdir -p "$out/share/bobrvm"
      cp ${OVMF.fd}/FV/OVMF.fd "$out/share/bobrvm/OVMF.fd"
      cp ${OVMF.fd}/FV/OVMF_VARS.fd "$out/share/bobrvm/OVMF_VARS.fd"
    ''}
    runHook postInstall
  '';

  preFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    gappsWrapperArgs+=(--set BOBRVM_OVMF_FD "$out/share/bobrvm/OVMF.fd")
    gappsWrapperArgs+=(--set BOBRVM_OVMF_VARS_FD "$out/share/bobrvm/OVMF_VARS.fd")
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
