{ config, lib, pkgs, ... }:

let
  # The 16KiB venus blob-alignment patch (Apple Silicon host pages). Same
  # patch the repo's nix/guest-module.nix applies; copied in beside this
  # file by install.sh so the path is store-relative.
  #
  # NOTE: applied via hardware.graphics.package rather than a global mesa
  # overlay (what guest-module.nix does). The overlay would rebuild every
  # mesa dependent — gtk4, ghostty, the whole desktop closure — from source
  # inside the VM. Overriding only the graphics package rebuilds mesa alone;
  # everything else substitutes from cache, and runtime GL/Vulkan still
  # resolves through /run/opengl-driver, which is what venus needs.
  patchedMesa = pkgs.mesa.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./mesa-venus-16k-blob-align.patch ];
  });
in
{
  # ---------------------------------------------------------------------
  # Boot: bobrvm direct-kernel-boots this system (kernel+initrd are copied
  # out to the host after install), so no bootloader is installed.
  # ---------------------------------------------------------------------
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  boot.loader.initScript.enable = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos-niri";
    fsType = "ext4";
  };

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_mmio"
    "virtio_blk"
    "virtio_gpu"
    "virtio_net"
    "virtio_input"
  ];
  boot.kernelParams = [ "console=hvc0" ];

  # ---------------------------------------------------------------------
  # GPU: venus (Vulkan) + zink (GL 4.6) through bobrvm's virtio-gpu.
  # ---------------------------------------------------------------------
  hardware.graphics = {
    enable = true;
    package = patchedMesa;
  };
  # NOTE: deliberately NO global MESA_LOADER_DRIVER_OVERRIDE=zink. Forcing
  # zink system-wide also forces it for the compositor's GBM/KMS device,
  # where it cannot allocate scanout buffers — niri then rejects the EGL
  # renderer ("software EGL renderers are skipped") and finds no allocator.
  # kmscube shows the GBM path resolves to virgl either way. zink stays
  # available per-application (see the zink-run wrapper below) for GL 4.6
  # over venus.
  environment.variables = {
    LIBGL_ALWAYS_SOFTWARE = "0";
  };

  # Opt-in zink launcher: `zink-run glxinfo`, `zink-run glmark2`, …
  environment.shellAliases.zink-run = "MESA_LOADER_DRIVER_OVERRIDE=zink";

  # Why is the EGL renderer being judged "software"? Make Mesa and EGL say
  # so out loud in the session that actually runs the compositor.
  systemd.services.greetd.environment = {
    EGL_LOG_LEVEL = "debug";
    MESA_DEBUG = "1";
    RUST_BACKTRACE = "1";
  };

  # ---------------------------------------------------------------------
  # niri + ghostty, autologin straight into a session.
  # ---------------------------------------------------------------------
  programs.niri.enable = true;

  # A minimal niri config that actually starts something visible: ghostty on
  # login, plus Mod+T for another. Symlinked over whatever niri auto-created
  # (L+ replaces), since the user config takes precedence over /etc/niri.
  systemd.tmpfiles.rules =
    let
      niriConfig = pkgs.writeText "niri-config.kdl" ''
        // ghostty needs GL >= 3.3 (GTK4 ngl). The legacy virgl driver tops
        // out at GLES2-class, and zink-over-venus cannot create a WINDOWED
        // screen (no dma-buf export from the macOS host driver), but Mesa's
        // llvmpipe gives a full GL 4.6 context in software — plenty for a
        // terminal. So ghostty launches with LIBGL_ALWAYS_SOFTWARE=1 until
        // venus WSI lands.
        spawn-at-startup "foot"
        spawn-at-startup "sh" "-c" "LIBGL_ALWAYS_SOFTWARE=1 ghostty"

        binds {
            // T: ghostty (software GL 4.6 — the working default for now)
            Mod+T { spawn "sh" "-c" "LIBGL_ALWAYS_SOFTWARE=1 ghostty"; }
            // Y: ghostty on the hardware virgl path (currently fails: GTK4
            // wants GL 3.3+, virgl exposes GLES2-class)
            Mod+Y { spawn "ghostty"; }
            // U: ghostty on zink/venus (currently fails: no windowed WSI)
            Mod+U { spawn "sh" "-c" "MESA_LOADER_DRIVER_OVERRIDE=zink ghostty"; }
            // F: another foot
            Mod+F { spawn "foot"; }
            Mod+Q { close-window; }
            Mod+Shift+E { quit skip-confirmation=true; }
        }
      '';
    in
    [
      "d /home/nixos/.config 0755 nixos users -"
      "d /home/nixos/.config/niri 0755 nixos users -"
      "L+ /home/nixos/.config/niri/config.kdl - - - - ${niriConfig}"
    ];



  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.niri}/bin/niri-session";
        user = "nixos";
      };
    };
  };

  users.users.nixos = {
    isNormalUser = true;
    password = "nixos";
    extraGroups = [ "wheel" "video" "input" "render" "seat" ];
  };
  users.users.root.password = "nixos";
  security.sudo.wheelNeedsPassword = false;
  security.polkit.enable = true;

  environment.systemPackages = with pkgs; [
    ghostty
    adwaita-icon-theme # cursor theme: niri warns "no default icon" without one
    # GL/Vulkan verification, plus kmscube: the smallest real GBM+KMS
    # page-flip client, which is what exercises the scanout path.
    mesa-demos
    vulkan-tools
    glmark2
    kmscube
    foot # fallback terminal if ghostty misbehaves under zink
    kitty
    wayland-utils
    libinput
    drm_info
    strace
  ];

  networking.hostName = "niri-guest";
  networking.useDHCP = true;
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";

  # Serial console getty so the harness can drive the guest over hvc0
  # even when the compositor owns the framebuffer.
  systemd.services."serial-getty@hvc0".enable = true;
  systemd.services."serial-getty@hvc0".wantedBy = [ "multi-user.target" ];
  services.getty.autologinUser = lib.mkDefault "nixos";

  system.stateVersion = "25.05";
}
