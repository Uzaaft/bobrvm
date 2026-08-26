# bobrvm guest tools

The flake exposes an AArch64 Linux package and a NixOS module:

- `packages.aarch64-linux.bobrvm-tools` contains `qemu-ga`, `spice-vdagent`,
  `bobrvm-agentd`, `bobrvm-docker-proxy`, `bobrvm-session-agent`, and
  `bobrvm-toolbox`.
- `nixosModules.guest` installs the package, configures the selected services,
  and applies the Mesa Venus alignment patch without overriding Mesa globally.

Import the module from the same pinned bobrvm flake input used to build the host:

```nix
{
  inputs.bobrvm.url = "github:polymath-as/bobrvm";

  outputs = {nixpkgs, bobrvm, ...}: {
    nixosConfigurations.guest = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        bobrvm.nixosModules.guest
        {
          virtualisation.bobrvm.guest = {
            enable = true;
            management.enable = true;
            clipboard.enable = true;
            fileTransfer.enable = true;
            quiescedSnapshots.enable = true;
            sharedFolder.enable = true;
            docker.enable = true;
            docker.vsock.enable = true;
          };
        }
      ];
    };
  };
}
```

All integrations except the graphics driver are opt-in. This keeps the guest's
privileged control surface explicit. `automation.enable` additionally enables
QGA command execution and file RPCs and therefore requires
`management.enable`.

## Features

| Feature | Guest option | Transport |
| --- | --- | --- |
| Vulkan and Zink | `graphics.enable` | virtio-gpu Venus |
| Graceful shutdown, reboot, time sync, trim, guest information | `management.enable` | QGA |
| Guest exec and QGA file RPCs | `automation.enable` | QGA |
| Text copy and paste in X11 sessions | `clipboard.enable` | SPICE vdagent |
| Text copy and paste in Wayland sessions | `clipboard.enable` | bobrvm session agent |
| Host-to-guest file delivery | `fileTransfer.enable` | bobrvm native agent |
| Filesystem-consistent snapshots | `quiescedSnapshots.enable` | QGA fsfreeze |
| Persistent host folder | `sharedFolder.enable` | virtio-9p |
| Host Docker CLI and Compose | `docker.enable` | private host Unix socket |
| Fast VZ Docker streams | `docker.vsock.enable` | virtio-vsock to guest Unix socket |

The native file channel accepts one regular file at a time, uses acknowledged
48 KiB chunks, and rejects traversal names and files larger than 16 GiB. Files
arrive atomically in `/var/lib/bobrvm/inbox` by default; set
`fileTransfer.directory` to another absolute path if required. Existing files
are never overwritten.

The host folder has mount tag `host` and defaults to `/mnt/bobrvm`. Select the
host directory in the macOS VM settings or pass `--share /absolute/path` to the
CLI. Set `sharedFolder.readOnly = true` when the guest should not modify it.

`docker.enable` installs and starts the guest Docker daemon. Enabling
`docker.vsock.enable` also loads the virtio-vsock transport and starts the
bounded `bobrvm-docker-proxy`; dockerd then listens only on `/run/docker.sock`.
The module selects crun by default because the matched lifecycle experiment
improved full container runs by 7.6–15.5%. Set `docker.runtime = "runc"` to
retain Docker's conventional runtime.

Configure one global guest under `~/.config/bobrvm/docker` with
`engine = "vz"`, `docker = true`, and `docker-vsock = true`. Its private host
Unix socket is available to Docker and Compose from every directory. Share a
common host ancestor at the same absolute guest path so Compose bind mounts
remain valid. Per-project Docker sockets and MiniNat port 2375 remain a
compatibility path only when no global runtime is configured.

Container bridge creation and teardown are sensitive to the guest kernel timer frequency. The
guest module selects `CONFIG_HZ=300` together with the scheduler patch used by the measured Docker
runtime. This preserved active container latency while reducing measured timer-driven background
work; Linux still uses tickless idle. Keep the kernel, initramfs, and root modules on the exact same
release.

The user-session agent prefers the standardized `ext-data-control-v1` Wayland
protocol and falls back to `wlr-data-control-unstable-v1`. It opens a dedicated
user-accessible virtio port and advertises clipboard support only after the
compositor data-control protocol is live. X11 sessions continue to use the
SPICE agent. Text is validated as UTF-8 and bounded to 48 KiB by the
virtio-console port capacity.

Compositors must expose one of those data-control protocols. If neither is
available, the session agent exits without advertising clipboard support and
the macOS UI reports the capability as unavailable.

## Diagnostics

Inside the guest:

```sh
bobrvm-toolbox status
bobrvm-toolbox doctor
systemctl status qemu-guest-agent spice-vdagentd bobrvm-agentd
systemctl --user status bobrvm-session-agent
```

The macOS Guest Tools menu reports the aggregate negotiated status. Management
actions stay disabled until QGA answers its liveness probe, and file delivery
stays disabled until the native agent advertises the inbox capability.

The headless CLI uses <kbd>Ctrl</kbd>+<kbd>B</kbd> as a host-command prefix: `p`
reports status, `s` shuts down, `r` reboots, `t` synchronizes time, and `f`
trims filesystems. Press the prefix twice to send a literal
<kbd>Ctrl</kbd>+<kbd>B</kbd> to the guest.
