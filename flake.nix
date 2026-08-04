{
  description = "🦫vm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ziglint.url = "github:uzaaft/ziglint-nix";
  };

  outputs = {
    self,
    nixpkgs,
    zig-overlay,
    ziglint,
  }: let
    inherit (nixpkgs) lib;

    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    forAllPlatforms = function:
      lib.genAttrs platforms (system:
        function (import nixpkgs {
          inherit system;
          overlays = [ziglint.overlays.default];
        }));
  in {
    packages = forAllPlatforms (pkgs: let
      zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
      package = optimize:
        pkgs.callPackage ./nix/package.nix {
          inherit optimize zig;
        };
    in rec {
      bobrvm-debug = package "Debug";
      bobrvm-releasefast = package "ReleaseFast";
      bobrvm = bobrvm-releasefast;
      debug = bobrvm-debug;
      default = bobrvm;

      test = pkgs.callPackage ./nix/test.nix {inherit zig;};
      xcframework = pkgs.callPackage ./nix/xcframework.nix {inherit zig;};
    });

    devShells = forAllPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
      };
    });

    formatter = forAllPlatforms (pkgs: pkgs.alejandra);

    checks = forAllPlatforms (pkgs: {
      inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) test;
    });

    nixosModules = rec {
      guest = import ./nix/guest-module.nix;
      default = guest;
    };
  };
}
