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

# Venus GPU backend: the -Dgpu-venus libbobrvm.a references virgl_renderer_*;
# link the upstream virglrenderer dylib and sign with the entitlements that
# allow loading ad-hoc-signed third-party GPU dylibs.
# NOTE: macOS ships bash 3.2, where "${arr[@]}" on an EMPTY array trips
# `set -u` ("unbound variable"). Seed the array with a harmless flag so it is
# never empty, instead of expanding an empty array below.
VENUS_LINK=(-Xlinker -w)
ENTITLEMENTS="$REPO/cli.entitlements"
if [ "${BOBRVM_GUI_VENUS:-0}" = "1" ]; then
    VIRGL_PREFIX="${VIRGL_PREFIX:-$HOME/.local/opt/virgl-upstream}"
    VENUS_LINK+=(-L"$VIRGL_PREFIX/lib" -lvirglrenderer
        -Xlinker -rpath -Xlinker "$VIRGL_PREFIX/lib")
    ENTITLEMENTS="$REPO/cli-venus.entitlements"
fi

swiftc -O \
    -import-objc-header "$REPO/include/bobrvm.h" \
    "$REPO/macos/MinimalApp/main.swift" \
    "$WORK/libbobrvm-repacked.a" \
    -framework AppKit \
    -framework Metal \
    -framework QuartzCore \
    -framework Hypervisor \
    -framework IOSurface \
    "${VENUS_LINK[@]}" \
    -o "$OUT"

codesign --sign - --entitlements "$ENTITLEMENTS" --force "$OUT"
echo "built: $OUT"
