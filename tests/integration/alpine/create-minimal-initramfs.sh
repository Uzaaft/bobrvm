#!/bin/bash
# Create a minimal initramfs that just runs busybox shell.
# This allows testing the virtio-console without needing boot media.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
WORK_DIR="$OUT_DIR/minimal-initramfs-work"

# Clean up any previous work
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Extract busybox from Alpine initramfs
echo "Extracting busybox from Alpine initramfs..."
cd "$WORK_DIR"
gunzip -c "$OUT_DIR/initramfs-virt" | cpio -idm 2>/dev/null || true

# Create minimal initramfs structure
MINI_DIR="$OUT_DIR/mini-root"
rm -rf "$MINI_DIR"
mkdir -p "$MINI_DIR"/{bin,dev,proc,sys,etc,lib}

# Copy busybox
cp "$WORK_DIR/bin/busybox" "$MINI_DIR/bin/"

# Copy necessary libraries (busybox is dynamically linked to musl;
# kmod's modprobe needs libzstd/liblzma from usr/lib)
if [ -d "$WORK_DIR/lib" ]; then
    cp -a "$WORK_DIR/lib/"* "$MINI_DIR/lib/" 2>/dev/null || true
fi
if [ -d "$WORK_DIR/usr/lib" ]; then
    mkdir -p "$MINI_DIR/usr/lib"
    cp -a "$WORK_DIR/usr/lib/"* "$MINI_DIR/usr/lib/" 2>/dev/null || true
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

# Copy the full module tree so modprobe can resolve dependencies
# (virtio_mmio/virtio_blk plus virtio_gpu with its DRM stack).
KERN_VERSION=$(ls "$WORK_DIR/lib/modules" | head -1)
if [ -n "$KERN_VERSION" ]; then
    mkdir -p "$MINI_DIR/lib/modules"
    cp -a "$WORK_DIR/lib/modules/$KERN_VERSION" "$MINI_DIR/lib/modules/" 2>/dev/null || true
fi

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
if [ -f "/lib/modules/$KVER/kernel/drivers/virtio/virtio_mmio.ko" ]; then
    echo "Loading virtio modules..." >/dev/ttyAMA0 2>&1
    modprobe virtio_mmio 2>/dev/ttyAMA0
    echo "virtio_mmio: $?" >/dev/ttyAMA0 2>&1
    modprobe virtio_blk 2>/dev/ttyAMA0
    echo "virtio_blk: $?" >/dev/ttyAMA0 2>&1
    modprobe virtio-gpu 2>/dev/ttyAMA0
    echo "virtio_gpu: $?" >/dev/ttyAMA0 2>&1
    sleep 1
else
    echo "virtio_mmio.ko not found for $KVER" >/dev/ttyAMA0 2>&1
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
find . | cpio -o -H newc 2>/dev/null | gzip > "$OUT_DIR/initramfs-minimal"

echo ""
echo "Created: $OUT_DIR/initramfs-minimal"
echo ""
echo "Test with:"
echo "  ./zig-out/bin/bobrvm --kernel $OUT_DIR/Image --initrd $OUT_DIR/initramfs-minimal"

# Clean up
rm -rf "$WORK_DIR" "$MINI_DIR"
