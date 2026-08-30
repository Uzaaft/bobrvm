# Linux host

On x86-64 Linux, bobrvm provides a headless CLI and a Libadwaita application.
Both use the same cancellable Zig VM lifecycle and KVM device model.

```sh
nix run .#cli -- help
nix run .#
```

The GTK application manages VM definitions, installer media, disks, shared
folders, port forwards, CPU and memory allocation, networking, snapshots, and
guest lifecycle. OVMF is provided by the Nix package. Override its images with
`BOBRVM_OVMF_FD` and `BOBRVM_OVMF_VARS_FD`.

The KVM backend supports direct kernel boot and UEFI boot with virtio-pci block,
GPU, input, entropy, network, 9p, sound, and multiport console devices. Virgl
uses a surfaceless EGL renderer and falls back to the 2D scanout when 3D is not
available. User-mode NAT requires neither TAP nor host privileges.

For direct boot outside the project workflow:

```sh
bobrvm run-kernel bzImage initrd writable-root.raw
```

The GTK executable accepts automation flags including `--iso`, `--disk`,
`--kernel`, `--initrd`, `--share`, `--restore`, `--forward`, `--memory`,
`--cpus`, `--display`, and `--gpu-memory`. Run `bobrvm-gtk --help` for the
current interface.

Snapshots include vCPU, device, RAM, firmware-variable, and writable-disk state.
When qemu-guest-agent is available, the application freezes guest filesystems
around capture. Restore into an identically configured VM.

Use `bobrvm kvm-boot-benchmark <bzImage> <initrd> <disk>` for three
host-monotonic direct-boot measurements.
