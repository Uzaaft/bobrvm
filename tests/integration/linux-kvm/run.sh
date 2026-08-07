#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "usage: $0 <bobrvm> <bzImage> <initrd>" >&2
    exit 2
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "error: hardware KVM test requires read/write access to /dev/kvm" >&2
    exit 2
fi

output_file="$(mktemp -p /tmp bobrvm-linux-kvm.XXXXXXXX)"
trap 'rm -f "$output_file"' EXIT

set +e
timeout 10s "$1" run-kernel "$2" "$3" >"$output_file" 2>&1
status="$?"
set -e
cat "$output_file"

if ! grep -q '^BOBRVM_LINUX_INIT_OK$' "$output_file"; then
    echo "error: Linux init success marker was not observed (status $status)" >&2
    exit 1
fi

echo "Linux KVM E2E: direct kernel boot reached initramfs userspace"
