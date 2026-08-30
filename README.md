# bobrvm

bobrvm runs virtual machines on macOS and Linux. Linux guests support headless
and graphical operation, accelerated graphics, persistent disks, networking,
audio, shared folders, snapshots, and a project-oriented CLI.

On Apple Silicon, bobrvm uses Hypervisor.framework for Linux guests and Apple's
Virtualization framework for macOS guests. On x86-64 Linux, it uses KVM. The
native applications stay thin; the Zig core owns virtualization, devices, and
rendering.

The project is under active development. Automated Apple Silicon builds of the
latest commit on `main` are published in the
[`tip` release](https://github.com/polymath-as/bobrvm/releases/tag/tip).

## Install

On Apple Silicon running macOS 26 or later:

```sh
brew tap polymath-as/bobrvm https://github.com/polymath-as/bobrvm
brew trust --cask polymath-as/bobrvm/bobrvm
brew install --cask bobrvm
```

Linux builds currently run from source; see [HACKING.md](HACKING.md).

## Project VMs

Put a `bobrvm.toml` in a project:

```toml
memory = 2048
cpus = 2
kernel = "boot/Image"
initrd = "boot/initrd"
forwards = ["2222:22"]
```

Then run `bobrvm up`. Quit with <kbd>Ctrl</kbd>+<kbd>B</kbd> <kbd>z</kbd> to
suspend the VM; the next `bobrvm up` restores its memory, processes, and disks.

See [Project VMs](docs/project-vms.md) for provisioning, disposable forks, SSH,
and agent sandboxes.

## Documentation

- [Running guests](docs/running-guests.md)
- [Project VMs](docs/project-vms.md)
- [Docker and Compose](docs/docker.md)
- [Guest tools and NixOS module](docs/guest-tools.md)
- [Linux host](docs/linux-host.md)
- [macOS application](macos/README.md)
- [GPU direction and design](docs/gpu-direction-decision.md)

For source builds and technical details, read [HACKING.md](HACKING.md). Before
sending a change, read [CONTRIBUTING.md](CONTRIBUTING.md).

## License

bobrvm is licensed under the [MIT License](LICENSE).
