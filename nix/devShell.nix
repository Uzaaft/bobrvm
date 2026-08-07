{
  mkShell,
  lib,
  stdenv,
  OVMF,
  adwaita-icon-theme,
  glib,
  gobject-introspection,
  gsettings-desktop-schemas,
  gtk4,
  hicolor-icon-theme,
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

  BOBRVM_OVMF_FD = lib.optionalString stdenv.hostPlatform.isLinux "${OVMF.fd}/FV/OVMF.fd";
  BOBRVM_OVMF_VARS_FD =
    lib.optionalString stdenv.hostPlatform.isLinux "${OVMF.fd}/FV/OVMF_VARS.fd";

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
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      adwaita-icon-theme
      glib
      gobject-introspection
      gsettings-desktop-schemas
      gtk4
      hicolor-icon-theme
      OVMF.fd
    ];

  shellHook =
    (lib.optionalString stdenv.hostPlatform.isLinux ''
      # Keep GTK's icons and settings available when running an unwrapped
      # development build. Packaged binaries receive these via wrapGAppsHook4.
      export XDG_DATA_DIRS="''${XDG_DATA_DIRS:-}:${hicolor-icon-theme}/share"
      export XDG_DATA_DIRS="$XDG_DATA_DIRS:${adwaita-icon-theme}/share"
      export XDG_DATA_DIRS="$XDG_DATA_DIRS:$GSETTINGS_SCHEMAS_PATH"
    '')
    + (lib.optionalString stdenv.hostPlatform.isDarwin ''
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
    '');
}
