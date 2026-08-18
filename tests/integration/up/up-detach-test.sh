#!/bin/bash
# E2E: the detached-runner lifecycle. `bobrvm up --detach` records the
# runner pid; `suspend` (SIGUSR1) saves the warm image and stops it;
# a second detached `up` resumes the warm state; `halt` stops it.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
BIN=$REPO/zig-out/bin/bobrvm
KERNEL=$REPO/tests/integration/alpine/out/Image
INITRD=$REPO/tests/integration/alpine/out/initramfs-minimal
WORK=${UP_DETACH_WORKDIR:-$(mktemp -d /tmp/bobrvm-up-detach.XXXXXX)}
PROJ=$WORK/proj

[ -x "$BIN" ] || { echo "SKIP: build bobrvm first (zig build)"; exit 1; }
[ -f "$KERNEL" ] || { echo "SKIP: alpine assets missing"; exit 1; }

mkdir -p "$PROJ"
cat > "$PROJ/bobrvm.toml" <<EOF
name = "up-detach-test"
memory = 512
cpus = 2
kernel = "$KERNEL"
initrd = "$INITRD"
share = false
EOF
rm -rf "$HOME"/.config/bobrvm/projects/proj-*

fail() { echo "FAIL: $1"; exit 1; }
cd "$PROJ"

"$BIN" up --detach --fresh >/dev/null 2>&1 || fail "detach start"
sleep 10
"$BIN" status | grep -q "running" || fail "status after detach"

"$BIN" suspend >/dev/null 2>&1 || fail "suspend verb"
"$BIN" status | grep -q "not running" || fail "status after suspend"
"$BIN" status | grep -q "warm state present" || fail "warm image after suspend"

"$BIN" up --detach >/dev/null 2>&1 || fail "warm detached resume"
sleep 3
"$BIN" status | grep -q "running" || fail "status after resume"
STATE_DIR=$(ls -d "$HOME"/.config/bobrvm/projects/proj-*)
grep -q "resuming warm state" "$STATE_DIR/console.log" || fail "resume was not warm"

"$BIN" halt >/dev/null 2>&1 || fail "halt verb"
"$BIN" status | grep -q "not running" || fail "status after halt"

rm -rf "$WORK" "$STATE_DIR"
echo "UP-DETACH: PASS"
