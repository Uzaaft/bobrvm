#!/usr/bin/env bash
# E2E GL validation: boot NixOS with the GL closure squashfs attached,
# overlay it onto /nix/store, and run mesa's eglinfo against the virgl
# device.
#
# Event-driven: every command is sent only after the previous step's
# marker appears in the console log (a sleep-based feeder races the boot
# — on a cold cache the shell may not exist yet and the commands get
# eaten by the boot console, leaving the VM idle forever).
# Clean shutdown: the feeder finishing closes stdin, and
# BOBRVM_EXIT_ON_EOF=1 turns that EOF into a VM stop (Ctrl-] only works
# on a tty).
#
# Assets (kernel/initrd/ISO/squashfs) are parameterized:
#   GL_ASSETS=<dir> ./tests/integration/gl/gltest.sh
set -u

GL_ASSETS="${GL_ASSETS:?set GL_ASSETS to the dir holding nixos-Image, nixos-initrd, nixos-aarch64.iso, gl.squashfs}"
LOG="${GL_LOG:-/tmp/bobrvm-gltest.log}"
NIXINIT="${NIXINIT:-/nix/store/d1y3g9ckrcm8c04sd239ik4czxmvi5sc-nixos-system-nixos-25.05.813814.ac62194c3917/init}"
MESA="${MESA:-/nix/store/q4cwbg2r6jrl35lmgidmh72zvj4kb8rw-mesa-25.0.7}"
DEMOS="${DEMOS:-/nix/store/fa82b83chczlgk3pvd6dlrvrwb4ni8qq-mesa-demos-9.0.0}"
BOBRVM="${BOBRVM:-./zig-out/bin/bobrvm}"

: > "$LOG"

# Wait until a marker shows up in the console log (fail after a timeout
# so the harness can never hang).
wait_for() {
  local pat="$1" limit="${2:-240}" t=0
  until grep -aq "$pat" "$LOG"; do
    sleep 1
    t=$((t + 1))
    if [ "$t" -gt "$limit" ]; then
      echo "TIMEOUT waiting for: $pat" >&2
      return 1
    fi
  done
}

feed() {
  wait_for "automatic login" 300 || return 1
  sleep 2 # let the shell take the tty after getty's banner
  # Markers are emitted via string concatenation ('X""Y') so the ECHOED
  # COMMAND LINE never contains the joined marker — otherwise wait_for
  # matches the echo of the command itself, not its output.
  printf 'sudo mkdir -p /mnt/gl /tmp/lower /tmp/up /tmp/work && sudo mount -t squashfs /dev/vdb /mnt/gl && sudo mount --bind /nix/store /tmp/lower && sudo mount -t overlay overlay -o lowerdir=/mnt/gl:/tmp/lower,upperdir=/tmp/up,workdir=/tmp/work /nix/store && echo OVERLAY_""OK || echo OVERLAY_""FAIL\n'
  wait_for "OVERLAY_OK" || return 1
  printf 'sudo mkdir -p /run/opengl-driver && sudo ln -sfn %s/lib /run/opengl-driver/lib && echo OGL_LINK_""OK\n' "$MESA"
  wait_for "OGL_LINK_OK" || return 1
  printf 'export __EGL_VENDOR_LIBRARY_DIRS=%s/share/glvnd/egl_vendor.d; export MESA_LOADER_DRIVER_OVERRIDE=virtio_gpu; export EGL_PLATFORM=surfaceless; echo ENV_""SET\n' "$MESA"
  wait_for "ENV_SET" || return 1
  printf 'echo EGLINFO_""START; %s/bin/eglinfo 2>&1 | head -80; echo EGLINFO_""END\n' "$DEMOS"
  wait_for "EGLINFO_END" 120 || return 1
  # Feeder returns -> stdin EOF -> BOBRVM_EXIT_ON_EOF stops the VM.
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
grep -aE "OVERLAY_OK|OVERLAY_FAIL|OpenGL.*(renderer|version)" "$LOG" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | head -8
grep -aq "OpenGL compatibility profile renderer: virgl" "$LOG" && echo "GLTEST: PASS" || { echo "GLTEST: FAIL"; exit 1; }
