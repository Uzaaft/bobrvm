#!/bin/bash
# Build the minimal display app against libbobrvm.a.
# Runs OUTSIDE nix (uses the system Swift toolchain); build the Zig lib
# first with: nix develop -c zig build
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO/zig-out/bin/BobrvmDisplay"

# Repack the archive with Apple libtool: zig's archiver emits member
# alignment the current Apple ld refuses to read.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
(cd "$WORK" && ar -x "$REPO/zig-out/lib/libbobrvm.a" && chmod +r ./*.o &&
    libtool -static -o libbobrvm-repacked.a ./*.o 2>/dev/null)

swiftc -O \
    -import-objc-header "$REPO/include/bobrvm.h" \
    "$REPO/macos/MinimalApp/main.swift" \
    "$WORK/libbobrvm-repacked.a" \
    -framework AppKit \
    -framework Metal \
    -framework QuartzCore \
    -framework Hypervisor \
    -framework IOSurface \
    -o "$OUT"

codesign --sign - --entitlements "$REPO/cli.entitlements" --force "$OUT"
echo "built: $OUT"
