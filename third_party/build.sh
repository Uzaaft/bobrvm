#!/bin/bash
# Build the vendored GPU stack from third_party/src (run sync.sh first):
#   - virglrenderer (venus, macOS) -> ~/.local/opt/virgl-upstream
#     (bobrvm's default -Dvirgl-prefix)
#   - KosmicKrisp (Mesa Vulkan-on-Metal) -> /opt/homebrew/lib/
#     libvulkan_kosmickrisp.dylib (the ICD json's library_path)
#
# Host deps (brew): meson ninja pkgconf libepoxy angle vulkan-loader
# spirv-tools llvm libclc spirv-llvm-translator spirv-headers molten-vk
# python: pip install mako pyyaml packaging (--break-system-packages)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PREFIX="${VIRGL_PREFIX:-$HOME/.local/opt/virgl-upstream}"
export PKG_CONFIG_PATH="/opt/homebrew/opt/angle/lib/pkgconfig:/opt/homebrew/opt/libepoxy/lib/pkgconfig:/opt/homebrew/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

echo "=== virglrenderer ==="
(cd src/virglrenderer &&
  meson setup build-macos --prefix "$PREFIX" \
    -Dplatforms= -Dvenus=true -Dvulkan-dload=true \
    -Drender-server-worker=process -Dtests=false \
    ${MESON_RECONFIGURE:+--reconfigure} >/dev/null &&
  ninja -C build-macos install | tail -1)

echo "=== KosmicKrisp ==="
LLVM_PREFIX=$(brew --prefix llvm)
LIBCLC_PREFIX=$(brew --prefix libclc)
SLT_PREFIX=$(brew --prefix spirv-llvm-translator)
STOOLS_PREFIX=$(brew --prefix spirv-tools)
export PATH="$LLVM_PREFIX/bin:/opt/homebrew/opt/python@3.14/libexec/bin:/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="$LIBCLC_PREFIX/share/pkgconfig:$SLT_PREFIX/lib/pkgconfig:$STOOLS_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
(cd src/mesa &&
  { [ -d build-kk ] || meson setup build-kk \
      -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= \
      -Dopengl=false -Dzstd=disabled -Dvideo-codecs= -Dllvm=enabled \
      --prefer-static --buildtype=release >/dev/null; } &&
  ninja -C build-kk src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib | tail -1)

DYLIB=src/mesa/build-kk/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib
cp "$DYLIB" /opt/homebrew/lib/libvulkan_kosmickrisp.dylib
codesign --verify --strict /opt/homebrew/lib/libvulkan_kosmickrisp.dylib 2>/dev/null ||
  codesign --force --sign - /opt/homebrew/lib/libvulkan_kosmickrisp.dylib

mkdir -p "$PREFIX/share/vulkan/icd.d"
[ -f "$PREFIX/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json" ] || cat > "$PREFIX/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json" <<'EOF'
{
    "ICD": {
        "api_version": "1.4.354",
        "library_path": "/opt/homebrew/lib/libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF
echo "installed: $PREFIX (virgl) + /opt/homebrew/lib/libvulkan_kosmickrisp.dylib (KK)"
