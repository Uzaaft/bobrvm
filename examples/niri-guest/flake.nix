{
  description = "bobrvm niri guest: wayland compositor + ghostty on venus/zink GL";

  # nixos-unstable: needs Mesa >= 25.2 for the venus ICD loader-interface fix
  # (the 25.05 channel ships 25.0.x, which fails vkCreateInstance under venus).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosConfigurations.niri = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [ ./configuration.nix ];
    };
  };
}
