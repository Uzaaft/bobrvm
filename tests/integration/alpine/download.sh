#!/bin/bash
# Download a matching Alpine kernel, initramfs, and module archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.20"
mkdir -p "$OUT_DIR"

if [ -s "$OUT_DIR/Image" ] && [ -s "$OUT_DIR/initramfs-virt" ] &&
    [ -s "$OUT_DIR/modloop-virt" ]; then
    echo "Already downloaded. Delete $OUT_DIR to re-download."
    exit 0
fi

WORK_DIR=$(mktemp -d "$OUT_DIR/download.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
for asset in vmlinuz-virt initramfs-virt modloop-virt; do
    curl -fL --retry 3 -o "$WORK_DIR/$asset" \
        "$MIRROR/releases/aarch64/netboot/$asset"
done

# Discover the EFI payload instead of depending on a particular stub's size.
# Check the ARM64 header and kernel release before publishing the bundle.
python3 - "$WORK_DIR" <<'PY'
import pathlib
import re
import subprocess
import sys
import zlib

work = pathlib.Path(sys.argv[1])
listing = subprocess.check_output(["tar", "-tf", str(work / "initramfs-virt")], text=True)
versions = set(re.findall(r"(?:^|/)lib/modules/([^/\n]+)", listing, re.MULTILINE))
if len(versions) != 1:
    raise SystemExit(f"Expected one initramfs kernel release, got {versions}")
version = versions.pop()
match = re.fullmatch(r"([0-9.]+)-([0-9]+)-virt", version)
if not match:
    raise SystemExit(f"Unexpected Alpine kernel release: {version}")
data = (work / "vmlinuz-virt").read_bytes()
for offset in (m.start() for m in re.finditer(b"\x1f\x8b\x08", data)):
    try:
        kernel = zlib.decompress(data[offset:], wbits=31)
    except zlib.error:
        continue
    if kernel[56:60] == b"ARM\x64" and f"Linux version {version} ".encode() in kernel:
        (work / "Image").write_bytes(kernel)
        break
else:
    raise SystemExit("No ARM64 kernel payload matching the initramfs release")
PY

# Publish only after every download and the kernel compatibility check succeeded.
for asset in vmlinuz-virt initramfs-virt modloop-virt Image; do
    mv "$WORK_DIR/$asset" "$OUT_DIR/$asset"
done
rm -f "$OUT_DIR/initramfs-minimal"
echo "Downloaded matching kernel, initramfs, and modules to $OUT_DIR"
