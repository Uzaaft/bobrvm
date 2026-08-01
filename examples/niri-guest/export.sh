#!/usr/bin/env bash
# Copy the installed system's kernel/initrd out to the 9p share so the host
# can direct-kernel-boot it. Split out of install.sh (the install itself is
# already done and takes ~25 minutes to repeat).
set -uo pipefail

HOST=/host
OUT=$HOST/out
DISK=/dev/vdb

step() { echo "EXPORT_STEP: $*"; }
fail() { echo "EXPORT_FAIL: $*"; echo "EXPORT_END"; exit 1; }

mkdir -p /mnt
mountpoint -q /mnt || mount "${DISK}2" /mnt || fail "mount ${DISK}2"
step "mounted $(findmnt -no SOURCE,TARGET /mnt)"

# readlink -f resolves against the LIVE root, so it yields /nix/store/... —
# a path that only exists under /mnt here. Prefix it back on.
STORE_PATH=$(readlink -f /mnt/nix/var/nix/profiles/system)
[ -n "$STORE_PATH" ] || fail "no system profile"
SYS="/mnt${STORE_PATH}"
[ -d "$SYS" ] || fail "system dir missing: $SYS"
step "system: $STORE_PATH"

mkdir -p "$OUT"
step "system dir: $(ls "$SYS" | tr '\n' ' ')"

# $SYS/kernel is a symlink whose target is an ABSOLUTE /nix/store path. Any
# dereference (cp -L, readlink -f) resolves it against the LIVE root, where
# that store path doesn't exist. Read the link text and re-root it under /mnt.
copy_from_installed() {
  local link="$1" dest="$2" target
  [ -e "$link" ] || [ -L "$link" ] || { echo "missing: $link"; return 1; }
  target=$(readlink "$link" || true)
  if [ -z "$target" ]; then
    cp "$link" "$dest"                      # a real file, not a link
  elif [ "${target#/}" != "$target" ]; then
    cp "/mnt${target}" "$dest"              # absolute → re-root
  else
    cp "$(dirname "$link")/${target}" "$dest" # relative → resolve in place
  fi
}

copy_from_installed "$SYS/kernel" "$OUT/niri-Image" || fail "copy kernel from $SYS"
copy_from_installed "$SYS/initrd" "$OUT/niri-initrd" || fail "copy initrd from $SYS"
cat "$SYS/kernel-params" > "$OUT/kernel-params" 2>/dev/null || true
# The init the host must pass on the kernel cmdline (init=...).
echo "${STORE_PATH}/init" > "$OUT/init-path"
sync

step "kernel:  $(stat -c %s "$OUT/niri-Image") bytes"
step "initrd:  $(stat -c %s "$OUT/niri-initrd") bytes"
step "init:    $(cat "$OUT/init-path")"
step "params:  $(cat "$OUT/kernel-params" 2>/dev/null)"
echo "EXPORT_OK"
echo "EXPORT_END"
