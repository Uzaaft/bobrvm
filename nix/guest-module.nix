{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.virtualisation.bobrvm.guest;
  patchedMesa = pkgs.mesa.overrideAttrs (old: {
    patches = (old.patches or []) ++ [./patches/mesa-venus-16k-blob-align.patch];
  });
  managementRpcs = [
    "guest-sync"
    "guest-sync-delimited"
    "guest-ping"
    "guest-info"
    "guest-shutdown"
    "guest-get-time"
    "guest-set-time"
    "guest-network-get-interfaces"
    "guest-get-host-name"
    "guest-get-users"
    "guest-get-osinfo"
    "guest-get-fsinfo"
    "guest-fstrim"
  ];
  snapshotRpcs = [
    "guest-fsfreeze-status"
    "guest-fsfreeze-freeze"
    "guest-fsfreeze-thaw"
  ];
  automationRpcs = [
    "guest-exec"
    "guest-exec-status"
    "guest-file-open"
    "guest-file-close"
    "guest-file-read"
    "guest-file-write"
    "guest-file-seek"
    "guest-file-flush"
  ];
  enabledRpcs =
    managementRpcs
    ++ lib.optionals cfg.quiescedSnapshots.enable snapshotRpcs
    ++ lib.optionals cfg.automation.enable automationRpcs;
  agentEnabled =
    cfg.management.enable
    || cfg.automation.enable
    || cfg.quiescedSnapshots.enable;
  nativeAgentEnabled = cfg.fileTransfer.enable;
  inboxDirectory = lib.escapeShellArg cfg.fileTransfer.directory;
  inboxArgument = lib.optionalString cfg.fileTransfer.enable " --inbox ${inboxDirectory}";
in {
  options.virtualisation.bobrvm.guest = {
    enable = lib.mkEnableOption "bobrvm guest integration";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./guest-tools.nix {};
      defaultText = lib.literalExpression "pkgs.callPackage <bobrvm/nix/guest-tools.nix> {}";
      description = "The bobrvm guest tools package.";
    };

    graphics = {
      enable = lib.mkEnableOption "bobrvm Venus and Zink guest graphics" // {default = true;};
      zinkByDefault = lib.mkEnableOption "Zink as the system-wide OpenGL driver";
    };

    management.enable = lib.mkEnableOption "host lifecycle and guest information operations";
    automation.enable = lib.mkEnableOption "host command execution and guest file access";
    clipboard.enable = lib.mkEnableOption "host and guest clipboard integration";
    fileTransfer = {
      enable = lib.mkEnableOption "explicit host-to-guest file transfer";
      directory = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bobrvm/inbox";
        description = "Directory where files sent by the host are delivered.";
      };
    };
    quiescedSnapshots.enable = lib.mkEnableOption "filesystem freeze and thaw for snapshots";

    sharedFolder = {
      enable = lib.mkEnableOption "the host 9P share";
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/bobrvm";
        description = "Mount point for the host share named 'host'.";
      };
      readOnly = lib.mkEnableOption "read-only access to the host share";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.isAarch64;
          message = "bobrvm guests are aarch64-linux.";
        }
        {
          assertion =
            !cfg.graphics.enable
            || lib.versionAtLeast config.hardware.graphics.package.version "25.2";
          message = "bobrvm guest graphics need Mesa >= 25.2.";
        }
        {
          assertion = !cfg.automation.enable || cfg.management.enable;
          message = "bobrvm guest automation requires management.enable.";
        }
        {
          assertion = !cfg.quiescedSnapshots.enable || cfg.management.enable;
          message = "bobrvm quiesced snapshots require management.enable.";
        }
        {
          assertion =
            !cfg.fileTransfer.enable
            || lib.hasPrefix "/" cfg.fileTransfer.directory;
          message = "bobrvm fileTransfer.directory must be an absolute path.";
        }
      ];

      environment.systemPackages = [cfg.package];
      boot.initrd.availableKernelModules = [
        "virtio_console"
        "virtio_gpu"
        "virtio_rng"
        "virtio_balloon"
        "9p"
        "9pnet_virtio"
      ];
    }

    (lib.mkIf cfg.graphics.enable {
      hardware.graphics = {
        enable = true;
        package = patchedMesa;
      };
      environment.systemPackages = with pkgs; [
        mesa-demos
        vulkan-tools
        glmark2
      ];
      environment.variables = lib.mkIf cfg.graphics.zinkByDefault {
        MESA_LOADER_DRIVER_OVERRIDE = "zink";
      };
    })

    (lib.mkIf agentEnabled {
      services.qemuGuest = {
        enable = true;
        package = cfg.package;
      };
      systemd.services.qemu-guest-agent.serviceConfig.ExecStart = lib.mkForce (
        "${cfg.package}/bin/qemu-ga --statedir /run/qemu-ga "
        + "--allow-rpcs=${lib.concatStringsSep "," enabledRpcs}"
      );
    })

    (lib.mkIf cfg.clipboard.enable {
      services.spice-vdagentd.enable = true;
      services.udev.extraRules = lib.concatStrings [
        ''SUBSYSTEM=="virtio-ports", ''
        ''ATTR{name}=="org.bobrvm.clipboard.0", ''
        ''TAG+="uaccess", ''
        ''ENV{ID_SEAT}="seat0"''
      ];
      systemd.user.services.bobrvm-session-agent = {
        description = "bobrvm Wayland clipboard integration";
        wantedBy = ["graphical-session.target"];
        partOf = ["graphical-session.target"];
        after = ["graphical-session.target"];
        unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
        serviceConfig = {
          ExecStart = "${cfg.package}/bin/bobrvm-session-agent";
          Restart = "on-failure";
          RestartSec = 2;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
        };
      };
    })

    (lib.mkIf nativeAgentEnabled {
      services.udev.extraRules = lib.concatStrings [
        ''SUBSYSTEM=="virtio-ports", ''
        ''ATTR{name}=="org.bobrvm.agent.0", ''
        ''TAG+="systemd", ''
        ''ENV{SYSTEMD_WANTS}="bobrvm-agentd.service"''
      ];
      systemd.services.bobrvm-agentd = {
        description = "bobrvm guest integration transport";
        serviceConfig = {
          ExecStart = "${cfg.package}/bin/bobrvm-agentd${inboxArgument}";
          Restart = "always";
          RestartSec = 1;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = lib.optional cfg.fileTransfer.enable cfg.fileTransfer.directory;
        };
      };
      systemd.tmpfiles.rules = lib.optionals cfg.fileTransfer.enable [
        "d ${cfg.fileTransfer.directory} 0755 root root -"
      ];
    })

    (lib.mkIf cfg.sharedFolder.enable {
      fileSystems.${cfg.sharedFolder.mountPoint} = {
        device = "host";
        fsType = "9p";
        options =
          [
            "trans=virtio"
            "version=9p2000.L"
            "msize=262144"
            "nofail"
            "x-systemd.automount"
            "x-systemd.device-timeout=1s"
          ]
          ++ lib.optional cfg.sharedFolder.readOnly "ro";
      };
    })
  ]);
}
