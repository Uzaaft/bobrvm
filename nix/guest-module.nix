# NixOS module for bobrvm guests: OpenGL 4.6 / Vulkan 1.4 over Venus.
#
# What it does:
#   - overlays Mesa with the 16KiB venus blob-alignment patch (required on
#     Apple Silicon hosts; without it venus dies with OUT_OF_HOST_MEMORY),
#   - enables graphics with that Mesa (venus Vulkan ICD + zink GL),
#   - optionally makes zink the default GL driver (GL 4.6 everywhere),
#   - ships verification tools (eglinfo/glxinfo, vulkaninfo, glmark2).
#
# Usage in your NixOS configuration (aarch64-linux):
#
#   imports = [ /path/to/bobrvm/nix/guest-module.nix ];
#   virtualisation.bobrvm.guest.enable = true;
#
# NOTE: the Mesa overlay means an aarch64-linux BUILD of Mesa. A macOS host
# cannot build that itself — use a Linux builder (nix-darwin's
# `nix.linux-builder.enable`, a remote aarch64-linux machine, or a NixOS VM
# in bobrvm) or wait for it to appear in a shared binary cache.
#
# Host-side requirements (bobrvm repo): third_party/sync.sh && build.sh
# (vendored virglrenderer + KosmicKrisp), then `zig build -Dgpu-venus`.
{ config, lib, pkgs, ... }:

let
  cfg = config.virtualisation.bobrvm.guest;
in
{
  options.virtualisation.bobrvm.guest = {
    enable = lib.mkEnableOption "bobrvm guest GPU support (venus + zink)";

    zinkByDefault = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Make zink (GL-over-Vulkan) the default GL driver system-wide, giving
        OpenGL 4.6 through venus. When false, GL defaults to the virgl
        driver (bobrvm's legacy 2.x path) and zink can be selected
        per-application with MESA_LOADER_DRIVER_OVERRIDE=zink.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.versionAtLeast config.hardware.graphics.package.version "25.2";
        message = "bobrvm guest needs Mesa >= 25.2 (venus ICD loader-interface fix).";
      }
      {
        assertion = pkgs.stdenv.hostPlatform.isAarch64;
        message = "bobrvm guests are aarch64-linux.";
      }
    ];

    nixpkgs.overlays = [
      (final: prev: {
        mesa = prev.mesa.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./patches/mesa-venus-16k-blob-align.patch ];
        });
      })
    ];

    hardware.graphics = {
      enable = true;
      # venus Vulkan ICD (libvulkan_virtio) and the zink/virgl GL drivers all
      # live in the overlaid Mesa.
    };

    environment.variables = lib.mkIf cfg.zinkByDefault {
      MESA_LOADER_DRIVER_OVERRIDE = "zink";
    };

    environment.systemPackages = with pkgs; [
      mesa-demos # eglinfo/glxinfo/glxgears
      vulkan-tools # vulkaninfo/vkcube
      glmark2
    ];

    # virtio-gpu is in the standard kernel; make sure it's not filtered out
    # of the initrd so the console comes up early.
    boot.initrd.availableKernelModules = [ "virtio_gpu" ];
  };
}
