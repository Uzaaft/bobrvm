#!/bin/bash
# Rebuild virglrenderer 1.3.0 from source with the tap's macOS patch stack PLUS
# the missing fix: render-server proxy socket SOCK_SEQPACKET -> SOCK_STREAM on
# macOS (framing is already implemented in the macos-unified patch; the type was
# just left as the unsupported SEQPACKET). Installs to $SP/virgl-fixed.
set -o pipefail
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1
SP=/private/tmp/claude-501/-Users-uzaaft-repositories-github-com-polymath-as-bobrvm/7a8873cd-cedc-455e-83d2-8ae4d6e619d3/scratchpad
TAP="$(brew --repository)/Library/Taps/startergo/homebrew-virglrenderer"
SRC="$SP/virgl-src"
PREFIX="$SP/virgl-fixed"
export PATH="$SP/mesa-venv/bin:/opt/homebrew/bin:$PATH"

echo "=== STAGE 1: fetch virglrenderer 1.3.0 ==="
rm -rf "$SRC"; mkdir -p "$SRC"
curl -sL "https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.3.0/virglrenderer-1.3.0.tar.gz?ref_type=tags" -o "$SP/virgl.tar.gz"
tar xzf "$SP/virgl.tar.gz" -C "$SRC" --strip-components=1
echo "extracted: $(ls "$SRC" | head -3)"

echo "=== STAGE 2: apply tap patches ==="
cd "$SRC" || exit 9
PATCHES=(
  virglrenderer-debug-init-logging.patch virglrenderer-default-debug-log.patch
  virglrenderer-macos-unified.patch virglrenderer-venus-metal-func-ptrs.patch
  virglrenderer-gallium-endian.patch virglrenderer-macos-a8-swizzle.patch
  virglrenderer-corefoundation-link.patch virglrenderer-a8-shader-swizzle.patch
  virglrenderer-a8-shader-swizzle-texture.patch virglrenderer-a8-unpack-alignment.patch
  virglrenderer-bgra-upload-swizzle-core.patch virglrenderer-msaa-assertion-fix.patch
  virglrenderer-ignore-surface0-clear.patch virglrenderer-venus-errno-debug.patch
  virglrenderer-macos-profile-forcing.patch virglrenderer-macos-egl-profile.patch
  virglrenderer-texture-swizzle-core.patch virglrenderer-bgra-unified.patch
  virglrenderer-core-profile-frag-datalocation.patch virglrenderer-macos-core-profile-fixes.patch
)
for p in "${PATCHES[@]}"; do
  if [ -f "$TAP/patches/$p" ]; then
    patch -p1 --batch --forward -i "$TAP/patches/$p" >/dev/null 2>&1 && echo "  ok  $p" || echo "  SKIP/fail $p"
  else echo "  MISSING $p"; fi
done

echo "=== STAGE 3: THE FIX — macOS proxy socket SOCK_SEQPACKET -> SOCK_STREAM ==="
# BOTH socketpair sites need the fix: the server side AND the proxy (client)
# side. The proxy is the one that actually creates the pair in-process.
for SOCKF in "$SRC/server/render_socket.c" "$SRC/src/proxy/proxy_socket.c"; do
  perl -0777 -pi -e 's/(#ifdef __APPLE__\s*\n\s*int type = )SOCK_SEQPACKET;/${1}SOCK_STREAM;/' "$SOCKF"
  echo "--- $SOCKF ---"; grep -n "int type = SOCK_" "$SOCKF"
done

echo "=== STAGE 4: meson setup (venus + angle/epoxy) ==="
ANGLE_INC="$(brew --prefix angle)/include"
export PKG_CONFIG_PATH="$(brew --prefix angle)/lib/pkgconfig:$(brew --prefix libepoxy)/lib/pkgconfig:$PKG_CONFIG_PATH"
rm -rf build
meson setup build \
  --prefix="$PREFIX" --buildtype=release \
  -Dc_args="-I$ANGLE_INC" -Dcpp_args="-I$ANGLE_INC" \
  -Ddrm-renderers=[] -Dvenus=true -Dtests=false -Dvideo=false -Dtracing=none 2>&1 | tail -15
echo "meson exit: $?"

echo "=== STAGE 5: compile + install ==="
meson compile -C build 2>&1 | tail -12
echo "compile exit: $?"
meson install -C build 2>&1 | tail -4
echo "=== RESULT ==="
ls -l "$PREFIX/lib/"libvirglrenderer*.dylib 2>/dev/null
ls "$PREFIX/libexec/"virgl_render_server 2>/dev/null
echo "=== DONE ==="
