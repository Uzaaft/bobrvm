{
  description = "🦫vm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    ziglint.url = "github:uzaaft/ziglint-nix";

    zon2nix = {
      url = "github:jcollie/zon2nix?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig-overlay,
    ziglint,
    zon2nix,
  }: let
    inherit (nixpkgs) lib;

    hostPlatforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
    guestPlatforms = ["aarch64-linux"];
    forPlatforms = platforms: function:
      lib.genAttrs platforms (system:
        function (import nixpkgs {
          inherit system;
          overlays = [ziglint.overlays.default];
        }));
  in {
    packages =
      (forPlatforms hostPlatforms (pkgs: let
        zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
        zigDeps = pkgs.callPackage ./build.zig.zon.nix {
          name = "bobrvm-zig-deps";
          zig_0_16 = zig;
        };
        package = optimize:
          pkgs.callPackage ./nix/package.nix {
            inherit optimize zig;
          };
      in
        rec {
          bobrvm-debug = package "Debug";
          bobrvm-releasefast = package "ReleaseFast";
          bobrvm = bobrvm-releasefast;
          debug = bobrvm-debug;
          default = bobrvm;

          deps = zigDeps;

          test = pkgs.callPackage ./nix/test.nix {inherit zig;};
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          linux-kvm-fixture = pkgs.callPackage ./nix/linux-kvm-fixture.nix {inherit zig;};
        }))
      // (forPlatforms guestPlatforms (pkgs: {
        bobrvm-tools = pkgs.callPackage ./nix/guest-tools.nix {};
      }));

    devShells = forPlatforms hostPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
        inherit zon2nix;
      };
    });

    formatter = forPlatforms hostPlatforms (pkgs: pkgs.alejandra);

    checks =
      (forPlatforms hostPlatforms (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) test;
      }))
      // (forPlatforms guestPlatforms (pkgs: let
        guestSystem = nixpkgs.lib.nixosSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            self.nixosModules.guest
            {
              virtualisation.bobrvm.guest = {
                enable = true;
                management.enable = true;
                clipboard.enable = true;
                fileTransfer.enable = true;
                quiescedSnapshots.enable = true;
                sharedFolder.enable = true;
              };
            }
          ];
        };
        guestConfig = guestSystem.config;
      in {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) bobrvm-tools;
        guest-module = assert guestConfig.services.qemuGuest.enable;
        assert guestConfig.services.spice-vdagentd.enable;
        assert lib.hasSuffix "/bin/bobrvm-session-agent"
        guestConfig.systemd.user.services.bobrvm-session-agent.serviceConfig.ExecStart;
        assert guestConfig.fileSystems."/mnt/bobrvm".fsType == "9p";
        assert lib.hasInfix "--inbox /var/lib/bobrvm/inbox"
        guestConfig.systemd.services.bobrvm-agentd.serviceConfig.ExecStart;
          pkgs.runCommand "bobrvm-guest-module-check" {} ''
            touch "$out"
          '';
      }));

    nixosModules = rec {
      guest = import ./nix/guest-module.nix;
      default = guest;
    };
  };
}
