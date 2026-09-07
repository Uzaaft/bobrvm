# Docker and Compose

Release app bundles include the Docker CLI, Docker Compose, Buildx, and the
macOS keychain credential helper. Install their entry points with:

```sh
sudo /Applications/Bobrvm.app/Contents/MacOS/bin/bobrvm install-cli
```

The installer creates symlinks under `/usr/local/bin` and does not replace a
valid existing path. Use `--prefix <directory>` to install elsewhere.

## Runtime

Containers run in one shared Virtualization.framework Linux VM, not one VM per
container or Compose project. Docker streams travel over virtio-vsock to the
guest's Unix socket.

Enable Docker and vsock in the guest NixOS configuration:

```nix
virtualisation.bobrvm.guest.docker = {
  enable = true;
  vsock.enable = true;
};
```

The module uses crun by default. Set `runtime = "runc"` when compatibility
requires it. See [guest tools](guest-tools.md) for the complete module.

Place the guest kernel, initramfs, and writable root disk under
`~/.config/bobrvm/docker/`, alongside this configuration:

```toml
name = "docker"
engine = "vz"
memory = 4096
cpus = 4
kernel = "Image"
initrd = "initramfs"
disk = "root.raw"
docker = true
docker-vsock = true
share = "/Users/example/Developer"
forwards = ["5433:5433"]
```

The shared directory must contain every project used for container bind mounts
at the same absolute path. Prefer the narrowest common ancestor.

```sh
bobrvm docker-host start
docker info
docker compose up --wait
bobrvm docker-host status
bobrvm docker-host suspend
bobrvm docker-host stop
```

The first server-side Docker command starts the runtime when necessary. Suspend
atomically replaces its checkpoint and preserves running containers.

### Startup readiness

The guest `bobrvm-docker-proxy` announces its listening vsock transport to the
host on port 62376. The host holds early Docker requests until that notification,
then confirms daemon readiness with one `/_ping` request. Socket publication,
HTTP response, and runner exit use kernel notifications with a shared 30-second
deadline; startup does not periodically poll Docker.

Build the host and guest tools together when updating this protocol. Existing
guests need the updated `bobrvm-docker-proxy` for cold boot. Warm restore first
tries the restored listener; if the snapshot predates proxy startup, the request
waits for its startup notification.
