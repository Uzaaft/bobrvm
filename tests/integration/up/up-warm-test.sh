#!/bin/bash
# E2E: `bobrvm up` cold-boots a project, a suspend writes the warm
# image, and a second `up` resumes the same guest.
#
# Continuity proof: the guest runs a 1 Hz tick loop; the first tick
# after the warm `up` must continue the pre-suspend numbering.
#
# Requires the alpine assets (tests/integration/alpine/out) and a host
# where Hypervisor.framework is available. Run from anywhere:
#
#   bash tests/integration/up/up-warm-test.sh
#
# UP_WARM_WORKDIR overrides the scratch location (default: mktemp).
# UP_WARM_CPUS sets the guest vCPU count (default: 2 — proves SMP
# suspend/restore; set 1 for the single-CPU path).
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
BIN=$REPO/zig-out/bin/bobrvm
KERNEL=$REPO/tests/integration/alpine/out/Image
INITRD=$REPO/tests/integration/alpine/out/initramfs-minimal
WORK=${UP_WARM_WORKDIR:-$(mktemp -d /tmp/bobrvm-up-warm.XXXXXX)}
PROJ=$WORK/proj
LOG_A=$WORK/up-a.log
LOG_B=$WORK/up-b.log

[ -x "$BIN" ] || { echo "SKIP: build bobrvm first (zig build)"; exit 1; }
[ -f "$KERNEL" ] || { echo "SKIP: alpine assets missing (create-minimal-initramfs.sh)"; exit 1; }

rm -rf "$PROJ"
mkdir -p "$PROJ"
cat > "$PROJ/bobrvm.toml" <<EOF
name = "up-warm-test"
memory = 512
cpus = ${UP_WARM_CPUS:-2}
kernel = "$KERNEL"
initrd = "$INITRD"
share = false
EOF

# The state dir is keyed by the project path; wipe leftovers so run A
# is genuinely cold.
rm -rf "$HOME"/.config/bobrvm/projects/proj-*

echo "=== RUN A: cold boot, tick loop, suspend at t+25s ==="
cd "$PROJ"
( sleep 8; printf 'i=0; while true; do i=$((i+1)); set -- $(cat /proc/uptime); echo TICK $i UP ${1%%.*}; sleep 1; done\n'; sleep 37 ) \
  | BOBRVM_LOG=stderr=true BOBRVM_TEST_SUSPEND=25:"$PROJ/suspend.img" "$BIN" up \
  > "$LOG_A" 2>&1
echo "run A exit: $?"

WARM_DIR=$(grep -o 'state in [^ ]*' "$LOG_A" | head -1 | sed 's/state in //')
A_LAST=$(grep -o 'TICK [0-9]*' "$LOG_A" | tail -1 | awk '{print $2}')
echo "state dir: $WARM_DIR; last tick before suspend: ${A_LAST:-none}"
if [ -z "$WARM_DIR" ] || [ -z "${A_LAST:-}" ] || [ ! -f "$PROJ/suspend.img" ]; then
  echo "FAIL: run A produced no ticks or no suspend image (see $LOG_A)"
  exit 1
fi
mkdir -p "$WARM_DIR"
mv "$PROJ/suspend.img" "$WARM_DIR/warm.img"

# Deliberate gap: without the restored vtimer offset the guest's
# monotonic clock (and /proc/uptime) would jump forward by this much.
sleep 10

echo "=== RUN B: warm up (must resume the tick loop) ==="
( sleep 12 ) | BOBRVM_LOG=stderr=true BOBRVM_EXIT_ON_EOF=1 "$BIN" up \
  > "$LOG_B" 2>&1
echo "run B exit: $?"

grep -q "resuming warm state" "$LOG_B" || { echo "FAIL: run B did not restore"; exit 1; }
B_FIRST=$(grep -o 'TICK [0-9]*' "$LOG_B" | head -1 | awk '{print $2}')
echo "run A last tick: $A_LAST, run B first tick: ${B_FIRST:-none}"
if [ -z "${B_FIRST:-}" ] || [ "$B_FIRST" -le "$A_LAST" ] || [ "$B_FIRST" -gt $((A_LAST + 3)) ]; then
  echo "FAIL: tick continuity not proven (see $LOG_B)"
  exit 1
fi

# Guest clock continuity: /proc/uptime rides the virtual counter, so
# it must continue from the capture point rather than absorbing the
# 10 s suspend gap.
A_UP=$(grep -o 'UP [0-9]*' "$LOG_A" | tail -1 | awk '{print $2}')
B_UP=$(grep -o 'UP [0-9]*' "$LOG_B" | head -1 | awk '{print $2}')
echo "run A last uptime: ${A_UP:-none}s, run B first uptime: ${B_UP:-none}s"
if [ -z "${A_UP:-}" ] || [ -z "${B_UP:-}" ] || [ $((B_UP - A_UP)) -gt 5 ]; then
  echo "FAIL: guest clock jumped across restore (see $LOG_B)"
  exit 1
fi

echo "UP-WARM: PASS (tick continuity + guest clock continuity)"
rm -rf "$WORK"
