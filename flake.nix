{
  description = "bobrvm - Linux virtualization for macOS with OpenGL 4.3 and Vulkan support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    ziglint.url = "github:uzaaft/ziglint-nix";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
    ziglint,
  }:
    flake-utils.lib.eachSystem ["aarch64-darwin" "x86_64-darwin"] (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          zig-overlay.overlays.default
          ziglint.overlays.default
        ];
      };

      # Pin to Zig 0.15.2 (0.16 has too many breaking changes)
      zig = pkgs.zigpkgs."0.15.2";

      buildInputs =
        [
          zig
          pkgs.jujutsu
          pkgs.ziglint
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          pkgs.libiconv
        ];

      nativeBuildInputs = [
        pkgs.pkg-config
      ];

      # Common build args
      zigBuildArgs = target:
        [
          "-Dtarget=${target}"
          "-Doptimize=ReleaseFast"
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          "-Dcpu=baseline"
        ];
    in {
      packages = {
        default = self.packages.${system}.bobrvm;

        bobrvm = pkgs.stdenv.mkDerivation {
          pname = "bobrvm";
          version = "0.1.0";

          src = ./.;

          inherit buildInputs nativeBuildInputs;

          buildPhase = ''
            export HOME=$TMPDIR
            ${zig}/bin/zig build ${builtins.concatStringsSep " " (zigBuildArgs "native")}
          '';

          installPhase = ''
            mkdir -p $out/lib $out/include
            cp -r zig-out/lib/* $out/lib/ 2>/dev/null || true
            cp -r include/* $out/include/ 2>/dev/null || true
          '';

          meta = with pkgs.lib; {
            description = "Linux virtualization for macOS";
            license = licenses.mit;
            platforms = ["aarch64-darwin" "x86_64-darwin"];
          };
        };

        debug = self.packages.${system}.bobrvm.overrideAttrs (old: {
          buildPhase = ''
            export HOME=$TMPDIR
            ${zig}/bin/zig build -Doptimize=Debug
          '';
        });

        test = pkgs.stdenv.mkDerivation {
          pname = "bobrvm-test";
          version = "0.1.0";

          src = ./.;

          inherit buildInputs nativeBuildInputs;

          buildPhase = ''
            export HOME=$TMPDIR
            ${zig}/bin/zig build test
          '';

          installPhase = ''
            mkdir -p $out
            echo "Tests passed" > $out/result
          '';
        };

        xcframework = pkgs.stdenv.mkDerivation {
          pname = "BobrvmKit";
          version = "0.1.0";

          src = ./.;

          inherit buildInputs nativeBuildInputs;

          buildPhase = ''
            export HOME=$TMPDIR
            ${zig}/bin/zig build xcframework
          '';

          installPhase = ''
            mkdir -p $out
            cp -r zig-out/BobrvmKit.xcframework $out/
          '';
        };
      };

      devShells.default = pkgs.mkShell {
        packages =
          buildInputs
          ++ nativeBuildInputs
          ++ [
            pkgs.alejandra
          ];
      };
    })
    // {
      # Guest-side NixOS module: OpenGL 4.6 / Vulkan 1.4 over Venus
      # (16KiB-aligned Mesa overlay + zink default + verification tools).
      # Import into an aarch64-linux NixOS config and set
      # `virtualisation.bobrvm.guest.enable = true;`.
      nixosModules = {
        guest = import ./nix/guest-module.nix;
        default = import ./nix/guest-module.nix;
      };
    };
}
