#!/bin/bash
# E2E: `bobrvm exec` runs a command in a disposable clone of the warm
# state — output, exit-code passthrough, multi-word arguments, and
# isolation (a write in one exec is gone in the next).
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
BIN=$REPO/zig-out/bin/bobrvm
KERNEL=$REPO/tests/integration/alpine/out/Image
INITRD=$REPO/tests/integration/alpine/out/initramfs-minimal
WORK=${EXEC_WORKDIR:-$(mktemp -d /tmp/bobrvm-exec.XXXXXX)}
PROJ=$WORK/proj

[ -x "$BIN" ] || { echo "SKIP: build bobrvm first (zig build)"; exit 1; }
[ -f "$KERNEL" ] || { echo "SKIP: alpine assets missing"; exit 1; }

mkdir -p "$PROJ"
cat > "$PROJ/bobrvm.toml" <<EOF
name = "exec-test"
memory = 512
cpus = 1
kernel = "$KERNEL"
initrd = "$INITRD"
share = false
EOF
rm -rf "$HOME"/.config/bobrvm/projects/proj-*

# Warm state parked at an idle prompt (a foreground process would
# swallow the console-exec input).
( sleep 18 ) | BOBRVM_TEST_SUSPEND=13:"$PROJ/suspend.img" \
  env -C "$PROJ" "$BIN" up >/dev/null 2>&1
STATE_DIR=$(ls -d "$HOME"/.config/bobrvm/projects/proj-*)
[ -n "$STATE_DIR" ] && [ -f "$PROJ/suspend.img" ] || { echo "FAIL: warm boot"; exit 1; }
mv "$PROJ/suspend.img" "$STATE_DIR/warm.img"
cd "$PROJ"

fail() { echo "FAIL: $1"; exit 1; }

OUT=$("$BIN" exec -- uname -m 2>/dev/null)
echo "$OUT" | grep -q "aarch64" || fail "exec output ($OUT)"

OUT=$("$BIN" exec -- sh -c 'echo hello world' 2>/dev/null)
echo "$OUT" | grep -q "hello world" || fail "multi-word args ($OUT)"

"$BIN" exec -- sh -c 'exit 7' >/dev/null 2>&1
[ $? -eq 7 ] || fail "exit code passthrough"

"$BIN" exec -- sh -c 'echo x > /mark' >/dev/null 2>&1
OUT=$("$BIN" exec -- cat /mark 2>&1)
echo "$OUT" | grep -qiE "no such|can't open" || fail "clones are isolated ($OUT)"

rm -rf "$WORK" "$STATE_DIR"
echo "EXEC: PASS"
