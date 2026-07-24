#!/bin/bash
# KosmicKrisp build attempt 4: add SPIRV-LLVM-Translator + spirv-tools/headers.
set -o pipefail
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_CURL_RETRIES=5
SP=/private/tmp/claude-501/-Users-uzaaft-repositories-github-com-polymath-as-bobrvm/7a8873cd-cedc-455e-83d2-8ae4d6e619d3/scratchpad
MESA="$SP/mesa"

echo "=== STAGE 1: spirv deps ==="
for i in 1 2 3 4 5; do
  brew install spirv-llvm-translator spirv-tools spirv-headers 2>&1 | tail -3
  if brew list spirv-llvm-translator >/dev/null 2>&1; then echo "spirv-llvm-translator installed"; break; fi
  echo "retry..."; sleep 3
done

LLVM_PREFIX=$(brew --prefix llvm)
LIBCLC_PREFIX=$(brew --prefix libclc)
SLT_PREFIX=$(brew --prefix spirv-llvm-translator)
STOOLS_PREFIX=$(brew --prefix spirv-tools)
export PATH="$SP/mesa-venv/bin:$LLVM_PREFIX/bin:/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="$LIBCLC_PREFIX/share/pkgconfig:$SLT_PREFIX/lib/pkgconfig:$STOOLS_PREFIX/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"
echo "LLVMSPIRVLib: $(pkg-config --exists LLVMSPIRVLib && pkg-config --modversion LLVMSPIRVLib || echo MISSING)"
echo "SPIRV-Tools:  $(pkg-config --exists SPIRV-Tools && echo FOUND || echo MISSING)"

echo "=== STAGE 2: meson setup ==="
cd "$MESA" || exit 9
rm -rf build-kk
meson setup build-kk \
  -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= \
  -Dopengl=false -Dzstd=disabled -Dvideo-codecs= -Dllvm=enabled \
  --prefer-static --buildtype=release 2>&1 | tail -18
echo "meson setup exit: $?"

echo "=== STAGE 3: ninja (this is the long one) ==="
ninja -C build-kk 2>&1 | tail -30
echo "ninja exit: $?"

echo "=== RESULT ==="
find "$MESA/build-kk" -iname '*icd*.json' 2>/dev/null
find "$MESA/build-kk" \( -iname '*kosmickrisp*.dylib' -o -iname '*vulkan_kosmickrisp*' -o -iname 'libvulkan_*.dylib' \) 2>/dev/null | head
echo "=== DONE ==="
