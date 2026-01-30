#!/bin/bash
# Download Alpine Linux aarch64 kernel and initramfs for VM testing.
#
# Downloads and extracts:
#   - Image: Raw ARM64 Linux kernel (extracted from vmlinuz-virt)
#   - initramfs-virt: Initial ramdisk
#
# The vmlinuz-virt is an EFI stub, so we extract the raw Image from inside.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"

# Alpine version
ALPINE_VERSION="3.20"
ALPINE_ARCH="aarch64"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/netboot"

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

echo "Downloading Alpine Linux ${ALPINE_VERSION} netboot (virt) for ${ALPINE_ARCH}..."

if [ -f "Image" ] && [ -f "initramfs-virt" ]; then
    echo "Already downloaded. Delete $OUT_DIR to re-download."
    exit 0
fi

# Download vmlinuz (EFI stub kernel)
echo "Downloading vmlinuz-virt..."
curl -L -o "vmlinuz-virt" "${MIRROR}/vmlinuz-virt"

# Download initramfs
echo "Downloading initramfs-virt..."
curl -L -o "initramfs-virt" "${MIRROR}/initramfs-virt"

# Extract raw Image from vmlinuz (gzip compressed at offset 0xc970)
echo "Extracting raw ARM64 Image from vmlinuz-virt..."
dd if="vmlinuz-virt" bs=1 skip=$((0xc970)) 2>/dev/null | gunzip > "Image" 2>/dev/null || true

# Verify extraction
if [ ! -s "Image" ]; then
    echo "ERROR: Failed to extract Image from vmlinuz-virt"
    exit 1
fi

echo ""
echo "Downloaded and extracted:"
ls -la Image initramfs-virt

echo ""
echo "To run:"
echo "  ./zig-out/bin/bobrvm --kernel $OUT_DIR/Image --initrd $OUT_DIR/initramfs-virt"
