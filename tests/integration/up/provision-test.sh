#!/bin/bash
# E2E: first-boot provisioning. `provision = [...]` in bobrvm.toml runs
# once on a cold boot; the warm image saved afterwards carries the
# provisioned state, so a later `exec` sees the artifacts.
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
BIN=$REPO/zig-out/bin/bobrvm
KERNEL=$REPO/tests/integration/alpine/out/Image
INITRD=$REPO/tests/integration/alpine/out/initramfs-minimal
WORK=${PROVISION_WORKDIR:-$(mktemp -d /tmp/bobrvm-provision.XXXXXX)}
PROJ=$WORK/proj

[ -x "$BIN" ] || { echo "SKIP: build bobrvm first (zig build)"; exit 1; }
[ -f "$KERNEL" ] || { echo "SKIP: alpine assets missing"; exit 1; }

mkdir -p "$PROJ"
cat > "$PROJ/bobrvm.toml" <<EOF
name = "provision-test"
memory = 512
cpus = 1
kernel = "$KERNEL"
initrd = "$INITRD"
share = false
provision = ["echo provisioned-ok > /provisioned-marker", "mkdir -p /opt/app"]
EOF
rm -rf "$HOME"/.config/bobrvm/projects/proj-*
cd "$PROJ"

fail() { echo "FAIL: $1"; exit 1; }

# Cold boot runs provisioning; suspend captures it into the warm image.
( sleep 20 ) | BOBRVM_TEST_SUSPEND=13:"$PROJ/suspend.img" \
  BOBRVM_LOG=stderr=true "$BIN" up > "$WORK/up.log" 2>&1
grep -q "provisioning complete (2 steps)" "$WORK/up.log" || fail "provisioning did not complete"

STATE_DIR=$(ls -d "$HOME"/.config/bobrvm/projects/proj-*)
[ -n "$STATE_DIR" ] && [ -f "$PROJ/suspend.img" ] || fail "warm boot"
mv "$PROJ/suspend.img" "$STATE_DIR/warm.img"

OUT=$("$BIN" exec -- cat /provisioned-marker 2>/dev/null)
echo "$OUT" | grep -q "provisioned-ok" || fail "provisioned file missing in warm state ($OUT)"
"$BIN" exec -- sh -c 'test -d /opt/app' >/dev/null 2>&1 || fail "provisioned directory missing"

rm -rf "$WORK" "$STATE_DIR"
echo "PROVISION: PASS"
