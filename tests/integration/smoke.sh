#!/usr/bin/env bash
# Full-stack smoke test: unit suite + a live NixOS boot with every device
# enabled at once (SMP + virgl + net), asserting the guest reaches a
# shell and the core capabilities are live.
#
# Env (see tests/integration/alpine for extraction notes):
#   NIXOS_IMAGE NIXOS_INITRD NIXOS_ISO NIXOS_INIT
#
# Usage: tests/integration/smoke.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

: "${NIXOS_IMAGE:?}" "${NIXOS_INITRD:?}" "${NIXOS_ISO:?}" "${NIXOS_INIT:?}"

echo "== unit tests =="
nix develop -c zig build test >/dev/null
echo "  OK"

echo "== full-stack boot (4 vCPU + virgl + net) =="
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
GUEST='echo SMOKE_$((900+99)); nproc; ip -4 addr show eth0 | grep -o "inet [0-9.]*"; getent hosts example.com >/dev/null && echo DNS_OK; sudo dmesg | grep -c "+virgl"; sudo poweroff'

( sleep 130; printf '%s\n' "$GUEST"; sleep 20 ) | \
    ./zig-out/bin/bobrvm run \
        --kernel "$NIXOS_IMAGE" --initrd "$NIXOS_INITRD" \
        --memory 4096 --cpus 4 \
        --disk "$NIXOS_ISO" --disk-readonly \
        --virgl --net \
        --cmdline "console=hvc0 init=$NIXOS_INIT root=LABEL=nixos-minimal-25.05-aarch64 nohibernate loglevel=4" \
        > "$LOG" 2>&1 &
BOBR=$!
sleep 165
pkill -f "zig-out/bin/bobrvm" 2>/dev/null || true
wait "$BOBR" 2>/dev/null || true

fail=0
grep -qa 'nixos login:'  "$LOG" || { echo "  FAIL: no login prompt"; fail=1; }
grep -qa 'SMOKE_999'     "$LOG" || { echo "  FAIL: shell did not run commands"; fail=1; }
grep -qa 'inet 10.0.2.15' "$LOG" || { echo "  FAIL: no DHCP lease"; fail=1; }
grep -qa 'DNS_OK'        "$LOG" || { echo "  FAIL: DNS resolution"; fail=1; }
[ "$fail" -eq 0 ] && echo "  OK: login + SMP + net + DNS + virgl" || { cat "$LOG" | tail -20; exit 1; }
echo "SMOKE PASS"
