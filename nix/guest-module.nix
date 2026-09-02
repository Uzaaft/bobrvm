{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.virtualisation.bobrvm.guest;
  virtualImageDriver =
    "    'virtual_image': { 'virtual': true, 'helper': ['virtual'], "
    + "'optional': true },";
  patchedMesa = pkgs.mesa.overrideAttrs (old: {
    patches = (old.patches or []) ++ [./patches/mesa-venus-16k-blob-align.patch];
  });
  bobrvmLibfprint = pkgs.libfprint.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
            cp ${../pkg/libfprint-bobrvm/bobrvm.c} libfprint/drivers/bobrvm.c
            cp ${../pkg/libfprint-bobrvm/bobrvm_transport.h} \
              libfprint/drivers/bobrvm_transport.h
            substituteInPlace meson.build \
              --replace-fail \
                "${virtualImageDriver}" \
                "    'bobrvm': { 'virtual': true, 'optional': true },
        'virtual_image': { 'virtual': true, 'helper': ['virtual'], 'optional': true },"
            substituteInPlace libfprint/meson.build \
              --replace-fail \
                "    'virtual_image' : files('drivers/virtual-image.c')," \
                "    'bobrvm' : files('drivers/bobrvm.c'),
        'virtual_image' : files('drivers/virtual-image.c'),"
            substituteInPlace libfprint/meson.build \
              --replace-fail \
                "    mathlib_dep," \
                "    mathlib_dep,
        cc.find_library('bobrvm-fprint-transport', dirs: '${cfg.package}/lib', static: true),"
      '';
  });
  bobrvmFprintd = pkgs.fprintd.override {libfprint = bobrvmLibfprint;};
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
  nativeAgentEnabled = cfg.fileTransfer.enable || cfg.touchID.enable;
  inboxDirectory = lib.escapeShellArg cfg.fileTransfer.directory;
  inboxArgument = lib.optionalString cfg.fileTransfer.enable " --inbox ${inboxDirectory}";
  touchIDArgument = lib.optionalString cfg.touchID.enable " --touch-id";
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
    touchID.enable = lib.mkEnableOption "macOS Touch ID as a Linux fingerprint device";
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

    docker = {
      enable = lib.mkEnableOption "the private bobrvm Docker API endpoint";
      vsock.enable = lib.mkEnableOption "the Virtualization.framework Docker vsock transport";
      runtime = lib.mkOption {
        type = lib.types.enum ["crun" "runc"];
        default = "crun";
        description = "OCI runtime used for bobrvm Docker containers.";
      };
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
          assertion = !cfg.docker.vsock.enable || cfg.docker.enable;
          message = "bobrvm Docker vsock requires docker.enable.";
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
      boot.kernelModules =
        ["virtio_rng"]
        ++ lib.optional cfg.docker.vsock.enable "vmw_vsock_virtio_transport";
      boot.kernelPatches = lib.mkIf cfg.docker.enable (lib.mkAfter [
        {
          name = "bobrvm-sched-wake-affine-current";
          patch = ./patches/linux-sched-wake-affine-current.patch;
          extraStructuredConfig = {
            HZ = lib.kernel.freeform "300";
            HZ_300 = lib.kernel.yes;
            HZ_1000 = lib.kernel.no;
          };
        }
        {
          name = "bobrvm-fuse-coherent-directory-cache";
          patch = ./patches/linux-fuse-coherent-directory-cache.patch;
        }
      ]);
      boot.kernelParams = lib.mkIf cfg.docker.enable (lib.mkAfter [
        "preempt=full"
        "transparent_hugepage=never"
        "rootflags=noatime,lazytime,commit=30"
        "fuse.force_cache_dir=1"
        "fuse.dir_cache_timeout_ms=1000"
      ]);
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
          ExecStart = "${cfg.package}/bin/bobrvm-agentd${inboxArgument}${touchIDArgument}";
          Restart = "always";
          RestartSec = 1;
          RuntimeDirectory = "bobrvm";
          RuntimeDirectoryMode = "0755";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths =
            lib.optional cfg.fileTransfer.enable cfg.fileTransfer.directory
            ++ lib.optional cfg.touchID.enable "/run/bobrvm";
        };
      };
      systemd.tmpfiles.rules = lib.optionals cfg.fileTransfer.enable [
        "d ${cfg.fileTransfer.directory} 0755 root root -"
      ];
    })

    (lib.mkIf cfg.touchID.enable {
      services.fprintd = {
        enable = true;
        package = bobrvmFprintd;
      };
      systemd.services.fprintd.environment.FP_BOBRVM_TOUCH_ID = "/run/bobrvm/touch-id.sock";
      systemd.services.fprintd = {
        after = ["bobrvm-agentd.service"];
        requires = ["bobrvm-agentd.service"];
      };
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

    (lib.mkIf cfg.docker.enable {
      # The shared Docker guest has no VGA console. Keeping an idle tty1
      # getty only consumes guest memory; hvc0 remains the management console.
      systemd.services."getty@tty1".enable = false;
      systemd.services."autovt@tty1".enable = false;
      boot.kernel.sysctl = {
        # Published container ports traverse Docker's conntrack rules. The
        # kernel default of 65,536 entries can fill in seconds under local
        # HTTP load, while reset connections need no long NAT grace period.
        "net.netfilter.nf_conntrack_max" = 262144;
        "net.netfilter.nf_conntrack_tcp_timeout_close" = 1;
      };
      virtualisation.docker = {
        enable = true;
        extraPackages = lib.optional (cfg.docker.runtime == "crun") pkgs.crun;
        daemon.settings = lib.mkIf (cfg.docker.runtime == "crun") {
          default-runtime = "crun";
          runtimes.crun.path = "${pkgs.crun}/bin/crun";
        };
        listenOptions =
          ["/run/docker.sock"]
          ++ lib.optional (!cfg.docker.vsock.enable) "10.0.2.15:2375";
        # Make the intentional plaintext listener explicit. Dockerd otherwise
        # delays startup to warn about a listener that MiniNat keeps private.
        extraOptions = lib.optionalString (!cfg.docker.vsock.enable) "--tls=false";
      };
      systemd.sockets.docker.socketConfig.FreeBind = lib.mkIf (!cfg.docker.vsock.enable) true;
      networking.firewall.allowedTCPPorts = lib.optional (!cfg.docker.vsock.enable) 2375;
    })

    (lib.mkIf cfg.docker.vsock.enable {
      systemd.services.bobrvm-docker-proxy = {
        description = "bobrvm Docker virtio-vsock proxy";
        wantedBy = ["multi-user.target"];
        requires = ["docker.socket"];
        after = ["docker.socket"];
        serviceConfig = {
          ExecStart = "${cfg.package}/bin/bobrvm-docker-proxy";
          Restart = "always";
          RestartSec = 1;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_VSOCK"
          ];
        };
      };
    })
  ]);
}
