# Bobrvm for macOS

The native SwiftUI/AppKit app owns the application, windows, and Metal layer.
The Zig libraries own virtualization and rendering.

## Build

Enter the Nix development environment and run the macOS build helper:

```sh
nix develop -c macos/build.nu
```

The helper brings the Zig XCFrameworks up to date before running Xcode in a
clean environment. This follows Ghostty's macOS build boundary: Zig owns the
generated dependencies and Xcode owns the native app. The app is written to
`macos/build/Debug/Bobrvm.app` by default.

For Swift-only iteration after a successful build, reuse the generated
frameworks:

```sh
nix develop -c macos/build.nu --skip-dependencies
```

The helper also accepts `--configuration Release`, `--action clean`, and
`--action test`. A clean action does not rebuild the Zig dependencies.

The helper avoids Nix compiler and linker overrides. It requires Nushell,
which is included in `nix develop`. `zig build macos-app` and `zig build run`
remain convenience commands inside the development shell and use the same
helper. All build paths require Zig 0.16.

Configure an Apple Development or Developer ID team in Xcode before
distribution.

## Direct Linux boot

Choose **Boot a Linux kernel** in the creation wizard to select an ARM64
kernel, an optional initrd, kernel arguments, and an optional existing disk.
Direct boot uses Bobrvm Hypervisor. A diskless initrd guest is supported.

For a stopped Linux VM, **Settings > Boot** switches between direct kernel
boot and UEFI and edits the corresponding paths. Switching methods clears
the other method's inputs; disk contents are preserved.

## Snapshots

For a running Hypervisor VM, **Guest Tools > Create Snapshot…** captures
memory and disks without requiring a guest agent. **Create Quiesced
Snapshot…** also freezes guest filesystems through the guest agent.

For a stopped VM, choose **Restore Snapshot…** in its details toolbar or
context menu. Select the snapshot directory and confirm replacement of the
VM's writable disks. Use the same VM configuration: restore checks memory,
captured CPUs, device presence, and recorded disk destinations before writes.
Disk copies use APFS cloning; replacement is atomic per disk, not across
multiple disks. Runtime startup errors are currently reported in the log.

## SSH and TCP forwarding

For a VM using Bobrvm Hypervisor, enable **SSH access from this Mac** during creation or in
**Virtual Machine Settings > SSH and Port Forwarding**. Enter an existing guest username. The
guest must have an SSH server enabled and a password or authorized public key configured.
For NixOS, enable `services.openssh.enable = true` and configure the chosen user's credentials.
The host option only supplies connectivity; it does not provision the guest.

After boot, the VM details show **SSH** and **Copy command**. Automatic mode asks the OS for a
free localhost port, remembers it, and reuses it on later boots when available. A busy remembered
port triggers allocation of another free port. Manual ports fail startup if unavailable.

The SSH button opens Terminal with the same command shown in the VM details. Copy that command
for another terminal or IDE. `HostKeyAlias` uses the VM UUID so port changes do not change the
guest's SSH identity; normal host-key verification remains enabled. A cloned VM receives its
own identity.

The settings also support up to seven additional TCP forwarding rules. Each defaults to
`127.0.0.1`; **Allow LAN access** binds that rule to all IPv4 interfaces. SSH's preset remains
localhost-only. Stop the VM before changing rules. Bridged networking and these forwarding
controls for Apple Virtualization are not implemented.

The CLI's existing `--forward` and `forwards` rules now also bind localhost by default.

## VM discovery

The **Command Line VMs** sidebar lists configurations from `~/.config/bobrvm/vms`, including
records whose disk is missing. It provides a quoted start command and reveals the original file.
`bobrvm list` also lists native-app configurations, with `cli:` and `app:` IDs to distinguish
identical names. Start CLI VMs by their original name; start app VMs in Bobrvm.
Discovery reads both stores without importing or rewriting them. Cross-frontend lifecycle
control is not implemented.

## Permissions

The app is not sandboxed because disks and removable images may live outside
its container and must remain accessible across launches. It requests the
Hypervisor.framework entitlement and uses Hardened Runtime. Local builds are
ad-hoc signed; distribution builds require Developer ID signing and
notarization.
