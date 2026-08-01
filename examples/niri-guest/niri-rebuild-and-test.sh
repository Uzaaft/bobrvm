#!/usr/bin/env bash
# Two phases in one job:
#   1. boot the installed system, copy in the updated configuration.nix,
#      nixos-rebuild switch
#   2. boot the NEW generation (init= via the system profile symlink, so it
#      always tracks the current generation) and capture what niri decides
#      about its renderer.
# Writes a one-line-per-event status file so progress survives a session exit.
set -u

B="$HOME/.local/share/bobrvm-niri"
REPO=/Users/uzaaft/repositories/github.com/polymath-as/bobrvm
BOBRVM="$REPO/zig-out/bin/bobrvm"
OLD_INIT=$(cat "$B/share/out/init-path")
PROFILE_INIT=/nix/var/nix/profiles/system/init
STATUS="$B/status.txt"
: > "$STATUS"
say() { echo "[$(date -u +%H:%M:%S)] $*" >> "$STATUS"; }

export DYLD_LIBRARY_PATH="$HOME/.local/opt/virgl-upstream/lib:/opt/homebrew/opt/vulkan-loader/lib:/opt/homebrew/opt/spirv-tools/lib:/opt/homebrew/lib"
date -u "+%Y-%m-%d %H:%M:%S" > "$B/share/host-date"

wait_for() { # pattern logfile limit
  local pat="$1" log="$2" limit="${3:-300}" t=0
  until grep -aq "$pat" "$log" 2>/dev/null; do
    sleep 3; t=$((t + 3))
    if [ "$t" -gt "$limit" ]; then return 1; fi
  done
  return 0
}

# ---------------------------------------------------------------- phase 1
P1=/tmp/niri-p1-rebuild.log; : > "$P1"
say "phase1: booting to rebuild (init=$OLD_INIT)"
feed1() {
  wait_for "nixos@niri-guest" "$P1" 300 || { say "phase1: TIMEOUT waiting for shell"; return 1; }
  sleep 12
  # Set the clock first: no RTC, so nix/TLS and file timestamps are otherwise at the epoch.
  printf 'sudo date -u -s "%s" >/dev/null; sudo mkdir -p /host && sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 host /host && sudo cp /host/configuration.nix /etc/nixos/ && echo CFG_""COPIED\n' "$(cat "$B/share/host-date")"
  wait_for "CFG_COPIED" "$P1" 90 || { say "phase1: config copy FAILED"; return 1; }
  say "phase1: config copied, running nixos-rebuild switch"
  printf 'sudo nixos-rebuild switch --flake /etc/nixos#niri --option experimental-features "nix-command flakes" 2>&1 | tail -15; echo RB_""RC=$?; echo RB_""END\n'
  wait_for "RB_END" "$P1" 1200 || { say "phase1: rebuild TIMEOUT"; return 1; }
  say "phase1: rebuild finished"
  # Record the new generation's init path for reference.
  printf 'readlink -f /nix/var/nix/profiles/system; echo GEN_""END\n'
  wait_for "GEN_END" "$P1" 60
  sleep 3
}
feed1 | BOBRVM_EXIT_ON_EOF=1 "$BOBRVM" run \
  --kernel "$B/share/out/niri-Image" --initrd "$B/share/out/niri-initrd" \
  --disk "$B/nixos-niri.raw" --share "$B/share" --gpu --virgl --net \
  --memory 8192 --cpus 6 \
  --cmdline "console=hvc0 init=$OLD_INIT root=/dev/vda2 rw loglevel=4" >> "$P1" 2>&1
say "phase1: VM exited rc=$?"
grep -aq "RB_END" "$P1" || { say "phase1: NO RB_END — aborting before phase 2"; exit 1; }
grep -a "RB_RC=" "$P1" | tail -1 >> "$STATUS"

# ---------------------------------------------------------------- phase 2
P2=/tmp/niri-p2-test.log; : > "$P2"
say "phase2: booting NEW generation via $PROFILE_INIT"
feed2() {
  wait_for "nixos@niri-guest" "$P2" 300 || { say "phase2: TIMEOUT waiting for shell"; return 1; }
  sleep 25   # let greetd start niri
  printf 'echo NIRI_""ENV; systemctl show greetd -p Environment --no-pager; env | grep -i mesa; echo E_""END\n'
  wait_for "E_END" "$P2" 60
  printf 'sudo journalctl -b --no-pager _COMM=niri 2>&1 | grep -viE "config|watcher|xwayland|LockedHint|power key" | tail -30; echo NJ_""END\n'
  wait_for "NJ_END" "$P2" 90
  printf 'echo FLIPS_""CHECK; sudo journalctl -b --no-pager 2>&1 | grep -icE "niri.*(output|mode set|connector)"; niri msg outputs 2>&1 | head -12; echo F_""END\n'
  wait_for "F_END" "$P2" 60
  sleep 3
}
feed2 | BOBRVM_EXIT_ON_EOF=1 "$BOBRVM" run \
  --kernel "$B/share/out/niri-Image" --initrd "$B/share/out/niri-initrd" \
  --disk "$B/nixos-niri.raw" --share "$B/share" --gpu --virgl --net \
  --memory 8192 --cpus 6 \
  --cmdline "console=hvc0 init=$PROFILE_INIT root=/dev/vda2 rw loglevel=4" >> "$P2" 2>&1
say "phase2: VM exited rc=$?"
say "phase2: set_scanout events = $(grep -ac 'set_scanout' "$P2")"
say "DONE"
