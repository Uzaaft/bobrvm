{
  description = "🦫vm";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    systems = {
      url = "github:nix-systems/default";
      flake = false;
    };

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        systems.follows = "systems";
      };
    };

    ziglint = {
      url = "github:uzaaft/ziglint-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zon2nix = {
      url = "github:jcollie/zon2nix?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    ziglint,
    zon2nix,
    ...
  }: let
    inherit (nixpkgs) lib;

    supportedHostPlatforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
    zigPlatforms = lib.attrNames zig.packages;
    hostPlatforms =
      lib.filter
      (system: builtins.elem system supportedHostPlatforms)
      zigPlatforms;
    linuxHostPlatforms =
      lib.filter
      (system: (lib.systems.elaborate system).isLinux)
      hostPlatforms;
    guestPlatforms = ["aarch64-linux"];

    allowBobrvm = package:
      builtins.elem (lib.getName package) [
        "bobrvm"
        "bobrvm-tools"
      ];
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [ziglint.overlays.default];
        config.allowUnfreePredicate = allowBobrvm;
      };
    forPlatforms = platforms: function:
      lib.genAttrs platforms (system: function (pkgsFor system));

    revision = self.shortRev or self.dirtyShortRev or "dirty";
    mkPackage = pkgs: optimize:
      pkgs.callPackage ./nix/package.nix {
        inherit optimize revision;
      };
    mkOverlay = optimize: final: _: {
      bobrvm = mkPackage final optimize;
    };
  in {
    devShells = forPlatforms hostPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = zig.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
        inherit zon2nix;
      };
    });

    packages = builtins.foldl' lib.recursiveUpdate {} [
      (forPlatforms hostPlatforms (pkgs: let
        zigCompiler = pkgs.zig_0_16;
        zigDeps = pkgs.callPackage ./build.zig.zon.nix {
          name = "bobrvm-zig-deps";
        };
      in
        rec {
          bobrvm-debug = mkPackage pkgs "Debug";
          bobrvm-releasesafe = mkPackage pkgs "ReleaseSafe";
          bobrvm-releasefast = mkPackage pkgs "ReleaseFast";

          bobrvm = bobrvm-releasefast;
          default = bobrvm;

          debug = bobrvm-debug;
          releasesafe = bobrvm-releasesafe;
          releasefast = bobrvm-releasefast;
          deps = zigDeps;
          framework-deps = bobrvm.zigDeps;
          test = pkgs.callPackage ./nix/test.nix {zig = zigCompiler;};
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          linux-kvm-fixture = pkgs.callPackage ./nix/linux-kvm-fixture.nix {
            zig = zigCompiler;
          };
        }))
      (forPlatforms guestPlatforms (pkgs: {
        bobrvm-tools = pkgs.callPackage ./nix/guest-tools.nix {};
      }))
    ];

    apps = forPlatforms linuxHostPlatforms (pkgs: let
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      mkApp = program: description: {
        type = "app";
        program = "${package}/bin/${program}";
        meta.description = description;
      };
    in rec {
      default = gui;
      gui = mkApp "bobrvm-gtk" "start the bobrvm virtual machine manager";
      cli = mkApp "bobrvm" "run the headless bobrvm command-line interface";
    });

    formatter = forPlatforms hostPlatforms (pkgs: pkgs.alejandra);

    checks = builtins.foldl' lib.recursiveUpdate {} [
      (forPlatforms hostPlatforms (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) test;
      }))
      (forPlatforms guestPlatforms (pkgs: let
        guestSystem = lib.nixosSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            self.nixosModules.guest
            {
              nixpkgs.config.allowUnfreePredicate = allowBobrvm;
              virtualisation.bobrvm.guest = {
                enable = true;
                management.enable = true;
                clipboard.enable = true;
                fileTransfer.enable = true;
                quiescedSnapshots.enable = true;
                sharedFolder.enable = true;
                docker.enable = true;
              };
            }
          ];
        };
        guestConfig = guestSystem.config;
        guestVsockSystem = lib.nixosSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            self.nixosModules.guest
            {
              nixpkgs.config.allowUnfreePredicate = allowBobrvm;
              virtualisation.bobrvm.guest = {
                enable = true;
                docker.enable = true;
                docker.vsock.enable = true;
              };
            }
          ];
        };
        guestVsockConfig = guestVsockSystem.config;
      in {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) bobrvm-tools;
        guest-module = assert guestConfig.services.qemuGuest.enable;
        assert guestConfig.services.spice-vdagentd.enable;
        assert lib.hasSuffix "/bin/bobrvm-session-agent"
        guestConfig.systemd.user.services.bobrvm-session-agent.serviceConfig.ExecStart;
        assert guestConfig.fileSystems."/mnt/bobrvm".fsType == "9p";
        assert lib.hasInfix "--inbox /var/lib/bobrvm/inbox"
        guestConfig.systemd.services.bobrvm-agentd.serviceConfig.ExecStart;
        assert guestConfig.virtualisation.docker.enable;
        assert lib.elem "10.0.2.15:2375"
        guestConfig.virtualisation.docker.listenOptions;
        assert lib.hasInfix "--tls=false"
        guestConfig.virtualisation.docker.extraOptions;
        assert guestConfig.virtualisation.docker.daemon.settings."default-runtime" == "crun";
        assert guestConfig.virtualisation.docker.daemon.settings.runtimes.crun.path
        == "${pkgs.crun}/bin/crun";
        assert lib.elem pkgs.crun guestConfig.virtualisation.docker.extraPackages;
        assert guestConfig.systemd.sockets.docker.socketConfig.FreeBind;
        assert lib.elem "preempt=full" guestConfig.boot.kernelParams;
        assert lib.elem "transparent_hugepage=never" guestConfig.boot.kernelParams;
        assert lib.elem "rootflags=noatime,lazytime,commit=30"
        guestConfig.boot.kernelParams;
        assert lib.elem "fuse.force_cache_dir=1" guestConfig.boot.kernelParams;
        assert lib.elem "fuse.dir_cache_timeout_ms=1000" guestConfig.boot.kernelParams;
          pkgs.runCommand "bobrvm-guest-module-check" {} ''
            touch "$out"
          '';
        guest-module-vsock = assert guestVsockConfig.virtualisation.docker.enable;
        assert guestVsockConfig.systemd.services.bobrvm-docker-proxy.enable;
        assert lib.elem "vmw_vsock_virtio_transport" guestVsockConfig.boot.kernelModules;
        assert !(lib.elem "10.0.2.15:2375"
          guestVsockConfig.virtualisation.docker.listenOptions);
        assert guestVsockConfig.virtualisation.docker.extraOptions == "";
          pkgs.runCommand "bobrvm-guest-module-vsock-check" {} ''
            touch "$out"
          '';
      }))
    ];

    overlays = {
      default = self.overlays.releasefast;
      releasefast = mkOverlay "ReleaseFast";
      releasesafe = mkOverlay "ReleaseSafe";
      debug = mkOverlay "Debug";
    };

    nixosModules = rec {
      guest = import ./nix/guest-module.nix;
      default = guest;
    };
  };
}
