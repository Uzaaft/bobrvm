# VM networking on macOS

New VMs created in the app default to **Shared with this Mac**. Install networking
from the VM creation screen or a stopped VM's network settings. macOS requests
administrator authorization once. The app bundles its helper; no Homebrew package
or Apple networking entitlement is required. Existing saved VMs keep their previous
network mode until you change it in settings.

Shared networking gives the guest an address on Apple's vmnet shared network.
The Mac and other VMs on that shared network can reach guest services directly;
external LAN machines do not receive direct access. Guest DHCP, DNS, and outbound
NAT are handled by vmnet. The app displays an observed IPv4 address after the guest
configures its network and sends IPv4 or ARP traffic. It does not discover IPv6
addresses. Set the guest username to use the displayed SSH command.

bobrvm does not supply images or configure guest services. The guest owner must
install and enable SSH, configure credentials, and allow SSH through any guest
firewall. An IP address in the app indicates network activity, not SSH readiness.

## Installation and removal

The app's **Install networking…**, **Update networking…**, and **Remove networking…**
buttons invoke the bundled management script through macOS administrator authorization.
Updating or removing the helper disconnects every VM using shared networking.
The helper is authorized for the installing user's UID. Installing from another
account replaces that authorization; this initial implementation supports one host
user at a time.

The app queries the **running** helper over its authenticated control socket and
warns when its source version differs from the app's expected version. CLI shared
network startup logs the same warning. The version is a SHA-256 fingerprint of the
helper sources, so local edits are detected without a release-version bump. A
mismatch means a different version, not necessarily an older one; networking is
still allowed when the existing protocol works. Helpers predating the version
query show an unverified-version warning. An unreachable helper is reported
separately. Updating restarts the daemon; the app then checks its running version
again. The fingerprint inputs live in `src/network_helper_version.zig` and must be
extended when adding helper dependencies. It is a source identity, not a hash of
the final executable or its toolchain.

For CLI-only installations, build and install from this checkout:

```sh
zig build network-helper -Demit-macos-app=false
sudo /bin/sh macos/network-helper/manage-network-helper.sh install \
    "$PWD/zig-out/bin/bobrvm-network-helper" "$(id -u)"
```

To remove it:

```sh
sudo /bin/sh macos/network-helper/manage-network-helper.sh remove
```

The root-owned executable is installed at
`/Library/PrivilegedHelperTools/as.polymath.bobrvm.network`, with a launch daemon at
`/Library/LaunchDaemons/as.polymath.bobrvm.network.plist`. The daemon recreates its
root-owned runtime directory on reboot and logs failures to `/var/log/bobrvm-network.log`. It restarts after a crash; affected VMs
must be restarted to reconnect. A missing or incompatible helper fails shared
network startup rather than silently switching network modes.

## CLI and projects

Use `--network shared` for a direct CLI boot, or add this to `bobrvm.toml`:

```toml
network = "shared"
ssh-user = "alice" # An existing account in the guest.
```

Start the project, then run `bobrvm ssh`. The command queries the helper for that
project's observed address and connects to guest port 22. Project identities derive
from the absolute project directory; direct CLI identities derive from the disk,
variables, or kernel path. GUI identities are random persistent MAC addresses and
are regenerated when duplicating a VM. Concurrent interfaces with the same MAC
are rejected. A warm snapshot retains the guest network state; cold boot after changing
network modes or moving a project to a different identity.

**User networking (port forwards)** remains available without administrator access.
For CLI use `--network user` (or `--net`); projects can use `network = "user"`.
This mode uses MiniNat and requires explicit host-port forwarding for incoming
connections. Shared mode rejects MiniNat forwarding rules and Docker socket
configuration. Docker-oriented projects continue using their existing networking.
Linux hosts continue using MiniNat. GUI Virtualization.framework VMs keep Apple NAT;
the native GUI and both macOS CLI engines support the helper. Isolated native
sandboxes never connect to the helper.

## Privilege boundary

Only the helper runs as root. Its Unix control socket authenticates clients with
kernel-provided peer UIDs before processing requests. Clients authenticate the
helper as root. Each connection creates one fixed shared-mode vmnet interface and
receives a private datagram descriptor for Ethernet frames. Closing the control
connection destroys the interface. Requests cannot select host paths, execute
commands, alter routes, or choose a physical bridge interface.

The daemon admits at most 32 concurrent interfaces, rejects duplicate or invalid
MACs, bounds packet sizes and receive batches, and checks outgoing source MACs.
A stalled framework lifecycle callback terminates the daemon instead of releasing
memory still referenced by asynchronous callbacks. Helper updates require a new
administrator authorization.
