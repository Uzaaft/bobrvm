#!/usr/bin/env bash
# Writable-disk persistence integration test.
#
# Proves durable block storage across VM restarts (a core capability for
# competing with VMware Fusion): format an ext4 filesystem on a writable
# virtio-blk disk in one VM instance, write a marker file, then boot a
# fresh VM and read it back.
#
# Requires: a NixOS aarch64 kernel + initrd + minimal ISO. Point the env
# vars below at them (see tests/integration/alpine for extraction notes).
#
#   NIXOS_IMAGE   raw ARM64 kernel Image
#   NIXOS_INITRD  initrd
#   NIXOS_ISO     minimal ISO (read-only root)
#   NIXOS_INIT    /nix/store/...-nixos-system-.../init path from the ISO
#
# Usage: tests/integration/persistence/test-persist.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BOBR="$REPO/zig-out/bin/bobrvm"
DISK="$(mktemp -t bobrvm-persist-XXXX).raw"
MARKER="BOBRVM_PERSIST_MARKER_$RANDOM"
trap 'rm -f "$DISK"' EXIT

: "${NIXOS_IMAGE:?set NIXOS_IMAGE}"
: "${NIXOS_INITRD:?set NIXOS_INITRD}"
: "${NIXOS_ISO:?set NIXOS_ISO}"
: "${NIXOS_INIT:?set NIXOS_INIT}"

dd if=/dev/zero of="$DISK" bs=1m count=64 2>/dev/null
CMDLINE="console=hvc0 init=$NIXOS_INIT root=LABEL=nixos-minimal-25.05-aarch64 nohibernate loglevel=4"

boot() { # <guest-script> <logfile> <settle-seconds>
    ( sleep 120; printf '%s\n' "$1"; sleep 20 ) | \
        "$BOBR" run --kernel "$NIXOS_IMAGE" --initrd "$NIXOS_INITRD" \
            --memory 4096 --cpus 2 \
            --disk "$NIXOS_ISO" --disk-readonly \
            --disk2 "$DISK" --disk2-writable \
            --cmdline "$CMDLINE" > "$2" 2>&1 &
    sleep "$3"
    pkill -f "$BOBR" || true
}

W="$(mktemp)"; R="$(mktemp)"; trap 'rm -f "$DISK" "$W" "$R"' EXIT

echo "[1/2] format + write marker ($MARKER)"
boot "sudo mkfs.ext4 -q -F /dev/vdb && sudo mkdir -p /mnt/p && sudo mount /dev/vdb /mnt/p && echo $MARKER | sudo tee /mnt/p/marker.txt && sync && sudo umount /mnt/p && echo WROTE_OK" "$W" 155
grep -q WROTE_OK "$W" || { echo "FAIL: write did not complete"; exit 1; }

echo "[2/2] fresh boot, read back"
boot "sudo mkdir -p /mnt/p && sudo mount /dev/vdb /mnt/p && echo READBACK: \$(cat /mnt/p/marker.txt) && sudo umount /mnt/p" "$R" 150

if grep -q "READBACK: $MARKER" "$R"; then
    echo "PASS: marker persisted across VM restarts"
else
    echo "FAIL: marker not read back"; exit 1
fi
