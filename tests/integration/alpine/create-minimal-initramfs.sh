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

# Copy necessary libraries (busybox is dynamically linked to musl)
if [ -d "$WORK_DIR/lib" ]; then
    cp -a "$WORK_DIR/lib/"* "$MINI_DIR/lib/" 2>/dev/null || true
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

# Copy virtio_mmio module (needed for virtio-console over MMIO)
KERN_VERSION=$(ls "$WORK_DIR/lib/modules" | head -1)
if [ -n "$KERN_VERSION" ]; then
    mkdir -p "$MINI_DIR/lib/modules/$KERN_VERSION/kernel/drivers/virtio"
    cp "$WORK_DIR/lib/modules/$KERN_VERSION/kernel/drivers/virtio/virtio_mmio.ko" \
       "$MINI_DIR/lib/modules/$KERN_VERSION/kernel/drivers/virtio/" 2>/dev/null || true
    
    # Copy modules metadata
    cp "$WORK_DIR/lib/modules/$KERN_VERSION/modules."* "$MINI_DIR/lib/modules/$KERN_VERSION/" 2>/dev/null || true
fi

# Create symlinks for basic commands
cd "$MINI_DIR/bin"
for cmd in sh ash cat echo ls mount mkdir mknod sleep insmod uname; do
    ln -sf busybox "$cmd"
done

# Create minimal init script
cat > "$MINI_DIR/init" << 'EOF'
#!/bin/ash

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
    echo "Loading virtio_mmio.ko..." >/dev/ttyAMA0 2>&1
    /bin/insmod "/lib/modules/$KVER/kernel/drivers/virtio/virtio_mmio.ko" 2>/dev/ttyAMA0
    RET=$?
    echo "insmod returned: $RET" >/dev/ttyAMA0 2>&1
    sleep 1
else
    echo "virtio_mmio.ko not found for $KVER" >/dev/ttyAMA0 2>&1
    ls -la /lib/modules/ >/dev/ttyAMA0 2>&1
fi

# Create hvc0 device if not created by devtmpfs
mknod -m 666 /dev/hvc0 c 229 0 2>/dev/null || true

# List /dev to see what we have
echo "Devices:" >/dev/ttyAMA0 2>&1
ls /dev/hvc* /dev/tty* 2>/dev/null >/dev/ttyAMA0 2>&1 || echo "no hvc/tty" >/dev/ttyAMA0 2>&1

# Check if hvc0 is available
if [ -c /dev/hvc0 ]; then
    echo "hvc0 available, switching..." >/dev/ttyAMA0 2>&1
    
    # Redirect stdio to hvc0 (virtio-console)
    exec 0</dev/hvc0 1>/dev/hvc0 2>/dev/hvc0
    
    echo "==============================================="
    echo "bobrvm minimal initramfs - shell ready"
    echo "==============================================="
    echo ""
    echo "Running test commands..."
    echo ""
    
    # Run some test commands to verify console works
    echo "uname: $(uname -a)"
    echo ""
    echo "uptime: $(cat /proc/uptime)"
    echo ""
    echo "memory:"
    cat /proc/meminfo | head -5
    echo ""
    echo "cpuinfo:"
    cat /proc/cpuinfo | head -10
    echo ""
    echo "==============================================="
    echo "Test complete! VM is running successfully."
    echo "==============================================="
    
    # Keep running - just sleep in a loop so we don't exit
    while true; do
        sleep 10
    done
else
    echo "hvc0 not available, trying ttyAMA0..." >/dev/ttyAMA0 2>&1
    
    # Fall back to ttyAMA0 (PL011 UART)
    exec 0</dev/ttyAMA0 1>/dev/ttyAMA0 2>/dev/ttyAMA0
    
    echo "==============================================="
    echo "bobrvm minimal initramfs - shell ready (UART)"
    echo "==============================================="
    echo ""
    
    while true; do
        sleep 10
    done
fi
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
