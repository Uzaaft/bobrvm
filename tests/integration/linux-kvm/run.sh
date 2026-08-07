#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$#" -gt 4 ]]; then
    echo "usage: $0 <bobrvm> <bzImage> <initrd> [read-only-disk]" >&2
    exit 2
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "error: hardware KVM test requires read/write access to /dev/kvm" >&2
    exit 2
fi

output_file="$(mktemp -p /tmp bobrvm-linux-kvm.XXXXXXXX)"
trap 'rm -f "$output_file"' EXIT
command=("$1" run-kernel "$2" "$3")
if [[ "$#" -eq 4 ]]; then
    command+=("$4")
fi

set +e
timeout 10s "${command[@]}" >"$output_file" 2>&1
status="$?"
set -e
cat "$output_file"

expected_marker="BOBRVM_LINUX_INIT_OK"
if [[ "$#" -eq 4 ]]; then
    expected_marker="BOBRVM_DISK_READ_OK"
fi
if ! grep -q "^$expected_marker$" "$output_file"; then
    echo "error: $expected_marker was not observed (status $status)" >&2
    exit 1
fi

echo "Linux KVM E2E: $expected_marker"
