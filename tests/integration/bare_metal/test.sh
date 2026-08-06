#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
log="$(mktemp)"
pid=""

cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$log"
}
trap cleanup EXIT

cd "$repo"
zig-out/bin/bobrvm run \
    --kernel zig-out/test/bare_metal_test.bin \
    --memory 512 \
    --cpus 2 \
    >"$log" 2>&1 &
pid=$!

deadline=$((SECONDS + 15))
while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
        echo "bare-metal SMP test timed out" >&2
        tail -n 40 "$log" >&2
        exit 1
    fi
    sleep 1
done

if ! wait "$pid"; then
    pid=""
    cat "$log" >&2
    exit 1
fi
pid=""

if ! grep -Fq "PSCI CPU_ON + GICV3: OK" "$log"; then
    echo "bare-metal SMP success marker missing" >&2
    cat "$log" >&2
    exit 1
fi

grep -Fq "ALL TESTS PASSED" "$log"
echo "bare-metal SMP test passed"
