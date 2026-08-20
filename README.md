# bobrvm

bobrvm runs virtual machines on macOS and Linux. On Apple Silicon, the Linux VM
uses Hypervisor.framework and macOS guests use Apple's Virtualization framework.
On x86-64 Linux, the direct-boot VM uses KVM with a GTK host application. The
platform applications stay thin while Zig owns virtualization and devices.

The project is under active development. Linux guests can boot to a GUI or
headless console with SMP, persistent virtio disks, input, built-in NAT, audio,
and accelerated virtio-GPU display output. Linux uses virglrenderer with a
surfaceless EGL context and falls back to the 2D scanout when the host renderer
is unavailable. On Apple Silicon, the optional Venus stack supports Vulkan 1.4
and OpenGL 4.6 through Zink using the vendored GPU dependencies in `third_party/`.

macOS guests support IPSW installation, persistent hardware identity, and
native display, input, networking, and audio devices.

Automated Apple Silicon builds of the latest commit on `main` are published to
the prerelease tagged [`tip`](https://github.com/polymath-as/bobrvm/releases/tag/tip).

Install the latest successful `main` build with Homebrew:

```sh
brew tap polymath-as/bobrvm https://github.com/polymath-as/bobrvm
brew trust --cask polymath-as/bobrvm/bobrvm
brew install --cask bobrvm
```

## Requirements

- Apple Silicon Mac running macOS 13 or later (the Bobrvm app requires macOS 26 or later)
- Or x86-64 Linux with KVM, GTK 4, and Libadwaita 1.5 or later
- Nix for the Zig core
- Xcode 26 or later and its Swift toolchain for the macOS app

## Build

```sh
nix develop
nix build              # release library
nix build .#debug       # debug library
nix build .#test        # Zig tests

zig build              # library in the development shell
zig build run          # build and run the native app with terminal logging
zig build macos-app    # build the native app without running it
zig build cli -- help  # run the headless CLI
zig build test         # run all Zig tests
zig build test -Dtest-filter=<name>
```

See [macos/README.md](macos/README.md) for Xcode and framework builds.

### Linux host preview

The Linux package installs a dependency-light headless binary and a separate
Libadwaita application, including desktop metadata and an application icon. Both
use the same cancellable Zig VM lifecycle and KVM device model.
The GTK application manages a persistent VM library, installer media, sparse raw
disks, shared folders, port forwards, memory, CPUs, networking, pause/resume,
guest management, clipboard sharing, host-to-guest file delivery, and quiesced snapshots.
Its Libadwaita interface provides separate Library, Display, Console, and Preferences
destinations, persistent defaults for new VMs, and lifecycle controls in the window header:

```sh
bobrvm run-kernel bzImage initrd writable-root.raw
bobrvm-gtk
```

For automation, the GTK executable also accepts `--iso`, `--disk`, `--kernel`,
`--initrd`, `--share`, `--restore`, repeatable `--forward host:guest`, `--memory`,
`--cpus`, `--display WxH`, and `--gpu-memory MiB`. Stereo virtio-snd playback and
accelerated virgl graphics are enabled by default; use `--no-audio` or `--no-3d`
to disable them.
The Nix development shell and package provide OVMF automatically;
`BOBRVM_OVMF_FD` and `BOBRVM_OVMF_VARS_FD` can override its images. Saving a VM
creates a private writable variable store so UEFI boot entries survive restarts.

The x86 host supports direct kernel boot and an OVMF firmware path with primary and
secondary virtio-pci block devices, including read-only ISO installation media,
plus virtio GPU, keyboard, tablet, entropy, networking, 9p shared-folder, and
multiport console devices. Guest PCM output is buffered away from the vCPU hot
path and played through the desktop's default ALSA route. Guest virgl commands
execute through the host's surfaceless EGL renderer, while GTK remains a thin
presenter for the resulting scanout.
Queue kicks and level interrupts use KVM `ioeventfd`/`irqfd`, keeping block I/O off
the vCPU thread. A virtio-net adapter uses the shared Zig user-mode NAT, with no TAP
device or host privileges required. The GTK application presents the guest's
virtio-GPU scanout with live guest modesetting and aspect-correct scaling, injects
keyboard and absolute pointer events, and retains a bounded serial-console history.
Stock qemu-guest-agent and spice-vdagent channels provide graceful lifecycle actions
and text clipboard sharing when their guest services are installed. Closing the window
requests an immediate vCPU exit and joins the VM before releasing resources.
The Snapshot action freezes guest filesystems through qemu-guest-agent, captures KVM,
device, RAM, firmware, and writable disk state, then resumes the guest. Select the
snapshot directory in Restore Snapshot before starting an identically configured VM.

Direct boot uses two KVM vCPUs by default and exposes their topology through an Intel
MP table. Use `bobrvm kvm-boot-benchmark <bzImage> <initrd> <disk>` for three comparable
host-monotonic samples of VM creation and start-to-root-readiness latency.

## Project workflow: `bobrvm up`

A `bobrvm.toml` checked into a repository describes the VM for that project.
`bobrvm up` finds it (searching from the current directory upward) and boots:

```toml
# bobrvm.toml
memory = 2048
cpus = 2
kernel = "boot/Image"
initrd = "boot/initrd"
forwards = ["2222:22"]
```

Quit with <kbd>Ctrl</kbd>+<kbd>B</kbd> <kbd>z</kbd> to suspend the machine to a
per-project warm image; the next `bobrvm up` resumes it — RAM, processes, and
shell state intact — in tens of milliseconds instead of booting. `bobrvm up
--fresh` discards the warm state. The project directory is shared with the
guest over virtio-9p by default (`share = false` opts out), relative paths
resolve against the project root, and warm state lives under
`~/.config/bobrvm/projects/`, never in the repository. `bobrvm up --help`
lists the full key set.

A `provision = ["cmd", ...]` list in `bobrvm.toml` runs shell commands once
on the first cold boot; save the result with <kbd>Ctrl</kbd>+<kbd>B</kbd>
<kbd>z</kbd> and every later `up` and `fork` starts from the provisioned
state. `bobrvm up --detach` runs the project in the background; `bobrvm
status`, `bobrvm suspend`, and `bobrvm halt` manage it. `engine = "vz"` runs
the project on Apple's Virtualization.framework instead of the custom VMM — a
lighter device set with the same verbs.

`bobrvm exec -- <command>` runs a command in a disposable clone of the warm
state and prints its output, without touching the project. `bobrvm ssh` opens
a session to the guest through the host port forwarded to guest port 22
(`forwards = ["2222:22"]`, `ssh-user = "root"`); the guest must run sshd.
`bobrvm bench-warm` reports warm-restore latency over several trials. A `share-readonly = true`
key makes the project share read-only on the host, not just in the guest
mount — a sandbox cannot write host files through it.

### Disposable sandboxes

`bobrvm fork` runs a throwaway clone of the warm state: copy-on-write copies
of the warm image and writable disks, deleted on exit, with the originals
never touched — any number of forks resume from exactly the same moment.
`bobrvm mcp` serves those sandboxes to AI agents over the Model Context
Protocol: add `{"mcpServers": {"bobrvm": {"command": "bobrvm", "args":
["mcp"]}}}` to an agent's MCP config and it gets `sandbox_start`,
`sandbox_exec` (console-based, no guest agent needed), `sandbox_output`,
`sandbox_list`, and `sandbox_stop`.

## Run a Linux guest

`bobrvm run` starts a headless VM attached to the guest console. Press
<kbd>Ctrl</kbd>+<kbd>]</kbd> to quit. Press <kbd>Ctrl</kbd>+<kbd>B</kbd>, then
<kbd>?</kbd>, for guest-tools status and lifecycle commands.

```sh
./zig-out/bin/bobrvm run \
  --kernel Image --initrd initrd \
  --memory 4096 --cpus 4 \
  --disk root.raw --net \
  --cmdline 'console=hvc0 root=LABEL=... init=/nix/store/...-init'
```

Use `--disk2 <image> --disk2-writable` for a persistent second disk. Add a
display device with `--gpu` or `--virgl`; use `--display WxH` to set its size.
The build signs the CLI with the Hypervisor.framework entitlement.

For a headless Linux guest:

```sh
zig build cli -- run --kernel Image --initrd initrd \
  --cmdline 'console=hvc0 ...'
```

Set `BOBRVM_BENCHMARK_STARTUP=1` to stop after host-side VM and primary-vCPU
setup and emit phase timings. The same variable makes `vz-run` stop after
Virtualization.framework completes its asynchronous start, so the two engines
can be profiled without waiting for a guest shutdown:

```sh
BOBRVM_LOG=true BOBRVM_BENCHMARK_STARTUP=1 ./zig-out/bin/bobrvm run \
  --kernel Image --initrd initrd
BOBRVM_LOG=true BOBRVM_BENCHMARK_STARTUP=1 ./zig-out/bin/bobrvm vz-run \
  --kernel Image --initrd initrd
```

## Guest tools

The flake exports `packages.aarch64-linux.bobrvm-tools` and
`nixosModules.guest`. The module configures Venus/Zink graphics and can opt in
to clipboard integration, guest lifecycle management, quiesced snapshots,
file delivery, and a shared folder:

```nix
{
  imports = [ bobrvm.nixosModules.guest ];
  virtualisation.bobrvm.guest = {
    enable = true;
    management.enable = true;
    clipboard.enable = true;
    fileTransfer.enable = true;
    sharedFolder.enable = true;
  };
}
```

The guest Mesa package must be built on aarch64 Linux, either inside the guest
or with a remote Linux builder. Build the host GPU stack with:

```sh
third_party/sync.sh
third_party/build.sh
zig build -Dgpu-venus
```

See [docs/guest-tools.md](docs/guest-tools.md) for the feature matrix, security
defaults, diagnostics, and complete NixOS configuration.

See [third_party/README.md](third_party/README.md) for the pinned GPU forks and
[docs/gpu-direction-decision.md](docs/gpu-direction-decision.md) for design
details.

## Logging

`zig build run` logs to the terminal. The Zig core and Swift app use the same
subsystem for macOS unified logging. For Zig logs, `BOBRVM_LOG` accepts `true`,
`false`, or a comma-separated destination list using `stderr`, `macos`,
`no-stderr`, and `no-macos`. Swift logs use macOS unified logging directly.

```sh
BOBRVM_LOG=stderr,macos zig build run
log stream --level debug --predicate 'subsystem=="com.bobrvm.app"'
```

The compile-time minimum defaults to `debug` for Debug builds and `info` for
release builds. Override it for Zig, the C API, and Swift logging with
`-Dlog-level=debug|info|warn|err`:

```sh
zig build macos-app -Doptimize=ReleaseFast -Dlog-level=debug
```
