#!/usr/bin/env bash
# In-guest installer: partitions /dev/vdb, installs the niri+ghostty NixOS
# system from the flake beside this script, then copies the kernel/initrd
# back out to the 9p share so the host can direct-kernel-boot the result.
#
# Runs inside the nixos-minimal ISO guest. Markers (INSTALL_*) are matched
# by the host-side harness.
set -uo pipefail

HOST=/host          # 9p share (this script's directory)
OUT=$HOST/out
DISK=/dev/vdb       # --disk2 target (vda is the read-only ISO)

step() { echo "INSTALL_STEP: $*"; }
fail() { echo "INSTALL_FAIL: $*"; echo "INSTALL_END"; exit 1; }

# bobrvm exposes no RTC, so the guest boots at the epoch and every TLS
# handshake fails with "certificate is not yet valid". The harness drops the
# host's UTC time in the share; adopt it before touching the network.
if [ -r "$HOST/host-date" ]; then
  date -u -s "$(cat "$HOST/host-date")" >/dev/null 2>&1 && \
    echo "INSTALL_STEP: clock set from host: $(date -u)" || \
    echo "INSTALL_STEP: WARNING could not set clock"
fi

step "start $(date -u +%H:%M:%S)"

# ---------------------------------------------------------------- network
step "waiting for network"
for i in $(seq 1 60); do
  if ip route 2>/dev/null | grep -q default; then break; fi
  sleep 1
done
ip route | grep -q default || fail "no default route (DHCP failed)"
step "network up: $(ip -4 -o addr show dev eth0 | awk '{print $4}')"

# ------------------------------------------------------------- partition
step "partitioning $DISK"
wipefs -a "$DISK" >/dev/null 2>&1
parted -s "$DISK" mklabel gpt || fail "mklabel"
parted -s "$DISK" mkpart ESP fat32 1MiB 512MiB || fail "mkpart esp"
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart root ext4 512MiB 100% || fail "mkpart root"
sleep 3
udevadm settle 2>/dev/null || true

mkfs.fat -F32 -n BOOT "${DISK}1" >/dev/null || fail "mkfs esp"
mkfs.ext4 -F -L nixos-niri "${DISK}2" >/dev/null || fail "mkfs root"
step "filesystems created"

# Mount the partition nodes directly: /dev/disk/by-label/* is a udev
# artifact that isn't reliably present in the live ISO right after mkfs
# (the labels themselves are set, and the installed system's initrd udev
# resolves by-label fine at boot).
udevadm trigger --subsystem-match=block 2>/dev/null || true
udevadm settle 2>/dev/null || true
mount "${DISK}2" /mnt || fail "mount root (${DISK}2)"
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot || fail "mount esp (${DISK}1)"
step "mounted: $(findmnt -no SOURCE,TARGET /mnt) + $(findmnt -no SOURCE,TARGET /mnt/boot)"

# ------------------------------------------------------------------ conf
mkdir -p /mnt/etc/nixos
cp "$HOST/flake.nix" "$HOST/configuration.nix" \
   "$HOST/mesa-venus-16k-blob-align.patch" /mnt/etc/nixos/ || fail "copy config"
step "config staged in /mnt/etc/nixos"

# ------------------------------------------------------------- install
# The patched Mesa builds from source (no cache hit); everything else
# substitutes. Keep the log so a failure is diagnosable after the fact.
step "nixos-install starting (patched mesa builds from source; this is the long part)"
nixos-install \
  --flake /mnt/etc/nixos#niri \
  --no-root-passwd \
  --option experimental-features "nix-command flakes" \
  --option max-jobs 4 \
  --option cores 2 \
  2>&1 | tee "$OUT/install.log" | grep -viE "^copying path|^ *$" | tail -400

rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || fail "nixos-install rc=$rc (see out/install.log)"
step "nixos-install done"

# --------------------------------------------------- export boot artifacts
# readlink -f resolves against the LIVE root, so it yields /nix/store/... —
# a path that only exists under /mnt from here. Prefix it back on.
STORE_PATH=$(readlink -f /mnt/nix/var/nix/profiles/system)
[ -n "$STORE_PATH" ] || fail "no system profile"
SYS="/mnt${STORE_PATH}"
echo "${STORE_PATH}/init" > "$OUT/init-path"
mkdir -p "$OUT"
cp -L "$SYS/kernel" "$OUT/niri-Image" || fail "copy kernel"
cp -L "$SYS/initrd" "$OUT/niri-initrd" || fail "copy initrd"
cat "$SYS/kernel-params" > "$OUT/kernel-params" 2>/dev/null || true

sync
step "exported kernel/initrd to share: $(ls -la $OUT | tail -4 | tr '\n' ' ')"
step "init: $(cat $OUT/init-path)"
echo "INSTALL_OK"
echo "INSTALL_END"
