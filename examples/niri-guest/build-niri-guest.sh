#!/usr/bin/env bash
# Host-side driver: boots the nixos-minimal ISO with the target disk + a 9p
# share, mounts the share in-guest and runs install.sh. Long-running (the
# patched Mesa builds from source inside the VM).
set -u

BASE="$HOME/.local/share/bobrvm-niri"
GL="$HOME/.local/share/bobrvm-gl"
BOBRVM="${BOBRVM:-/Users/uzaaft/repositories/github.com/polymath-as/bobrvm/zig-out/bin/bobrvm}"
NIXINIT="/nix/store/d1y3g9ckrcm8c04sd239ik4czxmvi5sc-nixos-system-nixos-25.05.813814.ac62194c3917/init"
LOG="${NIRI_LOG:-/tmp/niri-install.log}"
: > "$LOG"

# The guest has no RTC (boots at the epoch); hand it our clock so TLS works.
date -u "+%Y-%m-%d %H:%M:%S" > "$BASE/share/host-date"

wait_for() {
  local pat="$1" limit="${2:-300}" t=0
  until grep -aq "$pat" "$LOG"; do
    sleep 2; t=$((t + 2))
    if [ "$t" -gt "$limit" ]; then echo "TIMEOUT waiting for: $pat" >&2; return 1; fi
  done
  return 0
}

feed() {
  wait_for "automatic login" 300 || return 1
  sleep 3
  # Mount the 9p share and hand off to the in-guest installer. Markers are
  # split ('X""Y') so wait_for matches the OUTPUT, never the echoed command.
  printf 'sudo mkdir -p /host && sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 host /host && echo SHARE_""OK || echo SHARE_""FAIL\n'
  wait_for "SHARE_OK" 60 || return 1
  printf 'sudo bash /host/install.sh 2>&1 | tee /host/out/harness.log\n'
  # The install (incl. a from-source Mesa build) can run well over an hour.
  wait_for "INSTALL_END" "${INSTALL_TIMEOUT:-7200}" || return 1
  sleep 3
}

feed | BOBRVM_EXIT_ON_EOF=1 "$BOBRVM" run \
  --kernel "$GL/nixos-Image" --initrd "$GL/nixos-initrd" \
  --memory "${MEM:-12288}" --cpus "${CPUS:-8}" \
  --disk "$GL/nixos-aarch64.iso" --disk-readonly \
  --disk2 "$BASE/nixos-niri.raw" --disk2-writable \
  --share "$BASE/share" \
  --net \
  --cmdline "console=hvc0 init=$NIXINIT root=LABEL=nixos-minimal-25.05-aarch64 nohibernate loglevel=4" \
  >> "$LOG" 2>&1

echo "== installer VM exited rc=$? ==" >> "$LOG"
