{
  mkShell,
  lib,
  stdenv,
  gtk4,
  alejandra,
  jujutsu,
  nushell,
  pandoc,
  pkg-config,
  zig,
  ziglint,
  zon2nix,
}:
mkShell {
  name = "bobrvm";

  packages =
    [
      alejandra
      jujutsu
      nushell
      pandoc
      pkg-config
      zig
      ziglint
      zon2nix.packages.${stdenv.hostPlatform.system}.zon2nix
    ]
    ++ lib.optional stdenv.hostPlatform.isLinux gtk4;

  shellHook = lib.optionalString stdenv.hostPlatform.isDarwin ''
    # Framework builds need the system Xcode macOS and iOS SDKs. Nix's
    # compiler environment only exposes its packaged macOS SDK.
    unset SDKROOT
    unset DEVELOPER_DIR
    unset NIX_CC
    unset NIX_CFLAGS_COMPILE
    unset NIX_LDFLAGS
    unset LD
    unset CC
    unset CXX
    unset CFLAGS
    unset CPPFLAGS
    unset LDFLAGS
    PATH="$(echo "$PATH" |
      awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' |
      sed 's/:$//')"
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
  '';
}
