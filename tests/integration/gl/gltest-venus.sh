#!/usr/bin/env bash
# E2E Venus/Zink GL validation — the real GL 4.3 proof.
#
# Boots NixOS with a `-Dgpu-venus` bobrvm, overlays the GL closure squashfs onto
# /nix/store, then drives Mesa's ZINK gallium driver over the VENUS (virtio)
# Vulkan driver and reads the reported OpenGL version. Target: >= 4.3.
#
# Chain: guest zink (GL->Vulkan) -> guest venus (virtio_icd) -> virtio-gpu ->
#        host bobrvm(-Dgpu-venus) -> virglrenderer(venus) -> virgl_render_server
#        -> KosmicKrisp -> Metal.
#
# Prereqs:
#   - zig build -Dgpu-venus                       (advertises the venus capset)
#   - tools/build-virglrenderer-macos.sh          (~/.local/opt/virgl-macos, patched)
#   - tools/build-kosmickrisp.sh                  (KosmicKrisp dylib in /opt/homebrew/lib)
#   - GL_ASSETS=<dir with nixos-Image, nixos-initrd, nixos-aarch64.iso, gl.squashfs>
#
# Event-driven (markers) + BOBRVM_EXIT_ON_EOF for a clean, hang-proof shutdown,
# mirroring gltest.sh.
set -u

GL_ASSETS="${GL_ASSETS:?set GL_ASSETS to the dir holding nixos-Image, nixos-initrd, nixos-aarch64.iso, gl.squashfs}"
LOG="${GL_LOG:-/tmp/bobrvm-venus-gltest.log}"
NIXINIT="${NIXINIT:-/nix/store/d1y3g9ckrcm8c04sd239ik4czxmvi5sc-nixos-system-nixos-25.05.813814.ac62194c3917/init}"
MESA="${MESA:-/nix/store/q4cwbg2r6jrl35lmgidmh72zvj4kb8rw-mesa-25.0.7}"
DEMOS="${DEMOS:-/nix/store/fa82b83chczlgk3pvd6dlrvrwb4ni8qq-mesa-demos-9.0.0}"
BOBRVM="${BOBRVM:-./zig-out/bin/bobrvm}"

# Host venus stack: dyld reads DYLD_LIBRARY_PATH at exec, so the vulkan-loader +
# friends must be on it before launch. venus.zig self-configures the ICD +
# render-server paths from its build prefix, so those two need no export here.
VIRGL_PREFIX="${VIRGL_PREFIX:-$HOME/.local/opt/virgl-macos}"
export DYLD_LIBRARY_PATH="$VIRGL_PREFIX/lib:/opt/homebrew/opt/vulkan-loader/lib:/opt/homebrew/opt/spirv-tools/lib:/opt/homebrew/opt/angle/lib:/opt/homebrew/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
# Debug env inherited by the forked virgl_render_server (host venus renderer).
export ${VENUS_DEBUG_ENV:-VKR_DEBUG=result VN_DEBUG=init MESA_DEBUG=1}

: > "$LOG"

wait_for() {
  local pat="$1" limit="${2:-240}" t=0
  until grep -aq "$pat" "$LOG"; do
    sleep 1; t=$((t + 1))
    if [ "$t" -gt "$limit" ]; then echo "TIMEOUT waiting for: $pat" >&2; return 1; fi
  done
}

feed() {
  wait_for "automatic login" 300 || return 1
  sleep 2 # let the shell take the tty after getty's banner
  # Overlay the GL closure onto /nix/store (markers split as 'X""Y' so the
  # echoed command line never matches wait_for — only its output does).
  printf 'sudo mkdir -p /mnt/gl /tmp/lower /tmp/up /tmp/work && sudo mount -t squashfs /dev/vdb /mnt/gl && sudo mount --bind /nix/store /tmp/lower && sudo mount -t overlay overlay -o lowerdir=/mnt/gl:/tmp/lower,upperdir=/tmp/up,workdir=/tmp/work /nix/store && echo OVERLAY_""OK || echo OVERLAY_""FAIL\n'
  wait_for "OVERLAY_OK" || return 1
  printf 'sudo mkdir -p /run/opengl-driver && sudo ln -sfn %s/lib /run/opengl-driver/lib && echo OGL_LINK_""OK\n' "$MESA"
  wait_for "OGL_LINK_OK" || return 1
  # Confirm the guest sees a virtio-gpu DRM device and the venus capset.
  printf 'ls /dev/dri 2>&1; dmesg | grep -iE "virtio_gpu|drm" | tail -4; echo DRI_""DONE\n'
  wait_for "DRI_DONE" || return 1
  # ZINK over VENUS: zink as the GL gallium driver, virtio_icd (venus) as Vulkan.
  printf 'export VK_ICD_FILENAMES=%s/share/vulkan/icd.d/virtio_icd.aarch64.json; export MESA_LOADER_DRIVER_OVERRIDE=zink; export GALLIUM_DRIVER=zink; export __EGL_VENDOR_LIBRARY_DIRS=%s/share/glvnd/egl_vendor.d; export EGL_PLATFORM=surfaceless; echo ENV_""SET\n' "$MESA" "$MESA"
  wait_for "ENV_SET" || return 1
  # Sanity: are the zink/venus drivers actually reachable in the guest?
  printf 'echo SANITY_""START; ls /run/opengl-driver/lib/dri/ | grep -iE "zink|virtio"; echo "--icd--"; cat $VK_ICD_FILENAMES; echo; ls -l /run/opengl-driver/lib/libvulkan_virtio.so; echo SANITY_""END\n'
  wait_for "SANITY_END" || return 1
  # Does VENUS create a Vulkan device on its own (before involving zink)? vkgears
  # exercises the venus path directly; --help/-info still initializes Vulkan.
  printf 'echo VK_""START; VK_LOADER_DEBUG=error VN_DEBUG=init timeout 8 %s/bin/vkgears -info 2>&1 | head -25; echo VK_""END\n' "$DEMOS"
  wait_for "VK_END" 120 || return 1
  # The proof: RAW eglinfo (no grep) with full zink/venus/mesa debug so any
  # failure reason is captured in the host log.
  printf 'echo EGLINFO_""START; EGL_LOG_LEVEL=debug LIBGL_DEBUG=verbose MESA_DEBUG=1 VN_DEBUG=init VK_LOADER_DEBUG=error %s/bin/eglinfo 2>&1 | head -140; echo EGLINFO_""END\n' "$DEMOS"
  wait_for "EGLINFO_END" 180 || return 1
}

feed | BOBRVM_EXIT_ON_EOF=1 "$BOBRVM" run \
  --kernel "$GL_ASSETS"/nixos-Image --initrd "$GL_ASSETS"/nixos-initrd \
  --memory 8192 --cpus 4 \
  --disk "$GL_ASSETS"/nixos-aarch64.iso --disk-readonly \
  --disk2 "$GL_ASSETS"/gl.squashfs --disk2-readonly \
  --virgl --net \
  --cmdline "console=hvc0 init=$NIXINIT root=LABEL=nixos-minimal-25.05-aarch64 nohibernate loglevel=4" \
  > "$LOG" 2>&1
rc=$?

echo "== guest exited rc=$rc =="
sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$LOG" | grep -aiE "OpenGL.*(renderer|version)|zink|/dev/dri|virtio_gpu|venus|MESA-LOADER|vulkan|error|fail" | tail -20

ver=$(sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$LOG" | grep -aoE "OpenGL core profile version string: [0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | head -1)
echo "detected OpenGL core version: ${ver:-none}"
if [ -n "$ver" ] && awk "BEGIN{exit !($ver >= 4.3)}"; then
  echo "VENUS-GLTEST: PASS (GL $ver >= 4.3)"
else
  echo "VENUS-GLTEST: FAIL (need >= 4.3, got ${ver:-none})"; exit 1
fi
