#!/bin/bash
# Create a minimal initramfs that just runs busybox shell.
# This allows testing the virtio-console without needing boot media.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"

command -v unsquashfs >/dev/null || {
    echo "unsquashfs is required; run this script in nix shell nixpkgs#squashfsTools." >&2
    exit 1
}

WORK_DIR=$(mktemp -d "$OUT_DIR/minimal-initramfs.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract busybox from Alpine initramfs
echo "Extracting busybox from Alpine initramfs..."
cd "$WORK_DIR"
tar -xf "$OUT_DIR/initramfs-virt"

# Create minimal initramfs structure
MINI_DIR="$WORK_DIR/mini-root"
mkdir -p "$MINI_DIR"/{bin,dev,proc,sys,etc,lib}

# Copy busybox
cp "$WORK_DIR/bin/busybox" "$MINI_DIR/bin/"

# Copy necessary libraries (busybox is dynamically linked to musl;
# kmod's modprobe needs libzstd/liblzma from usr/lib)
if [ -d "$WORK_DIR/lib" ]; then
    cp -a "$WORK_DIR/lib/." "$MINI_DIR/lib/"
fi
if [ -d "$WORK_DIR/usr/lib" ]; then
    mkdir -p "$MINI_DIR/usr/lib"
    cp -a "$WORK_DIR/usr/lib/." "$MINI_DIR/usr/lib/"
fi

# Copy sbin/modprobe if available
if [ -f "$WORK_DIR/sbin/modprobe" ]; then
    mkdir -p "$MINI_DIR/sbin"
    cp "$WORK_DIR/sbin/modprobe" "$MINI_DIR/sbin/"
fi

# Create modprobe symlink to busybox if modprobe not available
if [ ! -f "$MINI_DIR/sbin/modprobe" ]; then
    mkdir -p "$MINI_DIR/sbin"
    ln -sf ../bin/busybox "$MINI_DIR/sbin/modprobe"
fi

# The boot initramfs omits 9p. Use modules from the matching netboot module archive,
# retaining the boot module set and adding only 9p and its dependency closure.
[ -f "$OUT_DIR/modloop-virt" ] || {
    echo "Run $SCRIPT_DIR/download.sh first to fetch matching kernel modules." >&2
    exit 1
}
python3 - "$WORK_DIR" "$MINI_DIR" "$OUT_DIR/modloop-virt" <<'PY'
import pathlib
import shutil
import subprocess
import sys

work, root, archive = map(pathlib.Path, sys.argv[1:])
versions = list((work / "lib/modules").iterdir())
if len(versions) != 1:
    raise SystemExit("Expected exactly one initramfs kernel release")
original = versions[0]
source = work / "modloop/modules" / original.name
metadata = f"modules/{original.name}"
dep_text = subprocess.check_output(
    ["unsquashfs", "-cat", str(archive), f"{metadata}/modules.dep"], text=True,
)
deps = {}
for line in dep_text.splitlines():
    module, dependencies = line.split(":", 1)
    deps[module] = dependencies.split()
by_name = {pathlib.Path(module).name.removesuffix(".gz"): module for module in deps}
required = {p.name.removesuffix(".gz") for p in original.rglob("*.ko*")}
required.update(("9p.ko", "9pnet_virtio.ko"))
pending = [by_name[name] for name in required]
selected = set()
while pending:
    module = pending.pop()
    if module not in selected:
        selected.add(module)
        pending.extend(deps[module])
# Select before extraction: the full archive contains case-distinct netfilter
# filenames that collide on the default macOS filesystem.
subprocess.run([
    "unsquashfs", "-no-progress", "-d", str(work / "modloop"), str(archive),
    f"{metadata}/modules.*", *(f"{metadata}/{module}" for module in sorted(selected)),
], check=True)
destination = root / "lib/modules" / original.name
shutil.rmtree(destination)
destination.mkdir()
for metadata in source.glob("modules.*"):
    shutil.copy2(metadata, destination / metadata.name)
for module in selected:
    target = destination / module
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / module, target)
print(f"Included {len(selected)} modules for {original.name}, including 9p")
PY

# Create symlinks for basic commands
cd "$MINI_DIR/bin"
for cmd in sh ash cat echo ls mount mkdir mknod sleep insmod uname setsid cttyhack poweroff; do
    ln -sf busybox "$cmd"
done

# Create minimal init script
cat > "$MINI_DIR/init" << 'EOF'
#!/bin/ash

# Install all busybox applet symlinks (dd, head, mount, ...)
/bin/busybox --install -s /bin

# Mount virtual filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create console devices
mknod -m 622 /dev/console c 5 1 2>/dev/null || true
mknod -m 666 /dev/null c 1 3 2>/dev/null || true
mknod -m 666 /dev/tty c 5 0 2>/dev/null || true
mknod -m 666 /dev/ttyAMA0 c 204 64 2>/dev/null || true

# Load virtio-mmio module (enables virtio-console)
echo "Loading virtio modules..." >/dev/ttyAMA0 2>&1
KVER=$(uname -r)
echo "Kernel: $KVER" >/dev/ttyAMA0 2>&1
if modprobe virtio_mmio 2>/dev/ttyAMA0; then
    modprobe virtio_blk 2>/dev/ttyAMA0
    echo "virtio_blk: $?" >/dev/ttyAMA0 2>&1
    modprobe virtio-gpu 2>/dev/ttyAMA0
    echo "virtio_gpu: $?" >/dev/ttyAMA0 2>&1
    sleep 1
else
    echo "Could not load virtio_mmio for $KVER" >/dev/ttyAMA0 2>&1
    ls -la /lib/modules/ >/dev/ttyAMA0 2>&1
fi

# Create hvc0 device if not created by devtmpfs
mknod -m 666 /dev/hvc0 c 229 0 2>/dev/null || true

# Attach stdio to whatever console= selected (hvc0, ttyAMA0, ...).
exec 0</dev/console 1>/dev/console 2>/dev/console

echo "==============================================="
echo "bobrvm minimal initramfs - shell ready"
echo "uname: $(uname -a)"
echo "==============================================="

# Interactive shell on the console. cttyhack (when available) makes it
# the controlling tty so job control works; respawn if the shell exits.
if /bin/busybox cttyhack true 2>/dev/null; then
    SHELL_CMD="setsid cttyhack /bin/sh"
else
    SHELL_CMD="/bin/sh"
fi
while true; do
    $SHELL_CMD
    echo "(shell exited, respawning)"
    sleep 1
done
EOF
chmod +x "$MINI_DIR/init"

# Create initramfs
echo "Creating minimal initramfs..."
cd "$MINI_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip > "$WORK_DIR/initramfs-minimal"
mv "$WORK_DIR/initramfs-minimal" "$OUT_DIR/initramfs-minimal"

echo ""
echo "Created: $OUT_DIR/initramfs-minimal"
echo ""
echo "Test with:"
echo "  ./zig-out/bin/bobrvm --kernel $OUT_DIR/Image --initrd $OUT_DIR/initramfs-minimal"
