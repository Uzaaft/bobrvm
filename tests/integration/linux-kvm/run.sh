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
console_disk_copy="$test_dir/console-disk"
network_disk_copy="$test_dir/network-disk"
benchmark_disk_copy="$test_dir/benchmark-disk"
trap 'rm -rf "$test_dir"' EXIT
cp "$4" "$disk_copy"
cp "$4" "$console_disk_copy"
cp "$4" "$network_disk_copy"
cp "$4" "$benchmark_disk_copy"
chmod u+w "$disk_copy"
chmod u+w "$console_disk_copy"
chmod u+w "$network_disk_copy"
chmod u+w "$benchmark_disk_copy"
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
smp_marker="BOBRVM_SMP_OK"
if ! grep -q "^$expected_marker$" "$output_file"; then
    echo "error: $expected_marker was not observed (status $status)" >&2
    exit 1
fi
if ! grep -q "^$smp_marker$" "$output_file"; then
    echo "error: $smp_marker was not observed (status $status)" >&2
    exit 1
fi
fast_path_marker="BOBRVM_KVM_FAST_BLOCK_OK"
fast_path_pattern="^$fast_path_marker kicks=[1-9][0-9]* interrupts=[1-9][0-9]* notify_mmio_exits=0$"
if ! grep -Eq "$fast_path_pattern" "$output_file"; then
    echo "error: $fast_path_marker was not observed (status $status)" >&2
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

lifecycle_output="$test_dir/lifecycle-output"
set +e
timeout 5s "$1" kvm-lifecycle-smoke "$2" >"$lifecycle_output" 2>&1
lifecycle_status="$?"
set -e
cat "$lifecycle_output"
if [[ "$lifecycle_status" -ne 0 ]]; then
    echo "error: KVM lifecycle smoke exited with status $lifecycle_status" >&2
    exit 1
fi
lifecycle_marker="KVM lifecycle: host stop joined cleanly"
if ! grep -q "^$lifecycle_marker$" "$lifecycle_output"; then
    echo "error: $lifecycle_marker was not observed" >&2
    exit 1
fi

console_output="$test_dir/console-output"
set +e
timeout 10s \
    "$1" kvm-console-smoke "$2" "$3" "$console_disk_copy" \
    >"$console_output" 2>&1
console_status="$?"
set -e
cat "$console_output"
if [[ "$console_status" -ne 0 ]]; then
    echo "error: KVM console smoke exited with status $console_status" >&2
    exit 1
fi
console_marker="KVM console: guest accepted serial input"
if ! grep -q "^$console_marker$" "$console_output"; then
    echo "error: $console_marker was not observed" >&2
    exit 1
fi

network_output="$test_dir/network-output"
set +e
timeout 10s \
    "$1" kvm-network-smoke "$2" "$3" "$network_disk_copy" \
    >"$network_output" 2>&1
network_status="$?"
set -e
cat "$network_output"
if [[ "$network_status" -ne 0 ]]; then
    echo "error: KVM network smoke exited with status $network_status" >&2
    exit 1
fi
network_marker="KVM network: guest reached the built-in gateway"
if ! grep -q "^$network_marker$" "$network_output"; then
    echo "error: $network_marker was not observed" >&2
    exit 1
fi

benchmark_output="$test_dir/benchmark-output"
set +e
timeout 15s \
    "$1" kvm-boot-benchmark "$2" "$3" "$benchmark_disk_copy" \
    >"$benchmark_output" 2>&1
benchmark_status="$?"
set -e
cat "$benchmark_output"
if [[ "$benchmark_status" -ne 0 ]]; then
    echo "error: KVM boot benchmark exited with status $benchmark_status" >&2
    exit 1
fi
benchmark_pattern='^KVM boot benchmark: samples=3 vcpus=2 '
benchmark_pattern+='create_us_min=[0-9]+ boot_us_min=[0-9]+ '
benchmark_pattern+='boot_us_median=[0-9]+ total_us_min=[0-9]+$'
if ! grep -Eq "$benchmark_pattern" "$benchmark_output"; then
    echo "error: KVM boot benchmark result was not observed" >&2
    exit 1
fi

echo "Linux KVM E2E: smp rootfs fast-block lifecycle-stop console-input network benchmark"
