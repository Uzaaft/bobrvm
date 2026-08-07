#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 <bobrvm> <bzImage> <initrd> <writable-root-disk>" >&2
    exit 2
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "error: hardware KVM test requires read/write access to /dev/kvm" >&2
    exit 2
fi

test_dir="$(mktemp -d -p /tmp bobrvm-linux-kvm.XXXXXXXX)"
output_file="$test_dir/output"
disk_copy="$test_dir/disk"
trap 'rm -rf "$test_dir"' EXIT
cp "$4" "$disk_copy"
chmod u+w "$disk_copy"
command=("$1" run-kernel "$2" "$3" "$disk_copy")

set +e
timeout 10s "${command[@]}" >"$output_file" 2>&1
status="$?"
set -e
cat "$output_file"

if [[ "$status" -ne 0 ]]; then
    echo "error: bobrvm exited with status $status" >&2
    exit 1
fi
expected_marker="BOBRVM_ROOTFS_BOOT_OK"
if ! grep -q "^$expected_marker$" "$output_file"; then
    echo "error: $expected_marker was not observed (status $status)" >&2
    exit 1
fi
fixture_dir="$(dirname "$4")"
debugfs="$fixture_dir/debugfs"
e2fsck="$fixture_dir/e2fsck"
if [[ ! -x "$debugfs" || ! -x "$e2fsck" ]]; then
    echo "error: fixture filesystem tools not found beside disk" >&2
    exit 1
fi
if ! "$e2fsck" -fn "$disk_copy" >/dev/null 2>&1; then
    echo "error: root filesystem is not clean" >&2
    exit 1
fi
persisted="$($debugfs -R 'cat /bobrvm-write-marker' "$disk_copy" 2>/dev/null)"
if [[ "$persisted" != "bobrvm-root-write-ok" ]]; then
    echo "error: root filesystem write was not persisted" >&2
    exit 1
fi

echo "Linux KVM E2E: $expected_marker"
