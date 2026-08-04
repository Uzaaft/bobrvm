{
  mkShell,
  alejandra,
  jujutsu,
  pkg-config,
  zig,
  ziglint,
}:
mkShell {
  name = "bobrvm";

  packages = [
    alejandra
    jujutsu
    pkg-config
    zig
    ziglint
  ];
}
