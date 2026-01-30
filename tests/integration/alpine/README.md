# Alpine Linux Integration Test

Uses Alpine Linux arm64 kernel and initramfs to test full Linux boot.

## Setup

```bash
./download.sh
```

This downloads and extracts:
- `out/Image` - Raw ARM64 Linux kernel (extracted from vmlinuz-virt)
- `out/initramfs-virt` - Alpine initramfs

## Running

```bash
./zig-out/bin/bobrvm \
    --kernel tests/integration/alpine/out/Image \
    --initrd tests/integration/alpine/out/initramfs-virt
```

## Expected Output

The kernel boots fully and Alpine Init starts:
- Early boot messages via UART (earlycon)
- PSCI v1.0 detection
- GICv3 initialization (128 SPIs, 16 PPIs)
- Timer working (arch_sys_counter at 24MHz)
- Memory layout and device initialization
- Alpine Init 3.x starting
- "Loading boot drivers: ok."
- "Mounting boot media..."
- Console switches from earlycon to hvc0

After "Mounting boot media...", Alpine init waits for boot media (CD/disk).
To go further, provide a root filesystem via virtio-blk.

## What Works

- **GICv3**: Full interrupt controller emulation (GICD, GICR, ICC system registers)
- **Timer**: arch_timer working with proper interrupt delivery
- **virtio-console**: TX/RX via hvc0 working
- **PSCI**: v1.0 for system off/reset

## Known Limitations

- **SMP**: Secondary CPU boot (PSCI CPU_ON) not implemented - returns INVALID_PARAMETERS
- **virtio-blk**: Not yet fully tested with disk images

## Kernel Command Line

Default: `console=hvc0 earlycon=pl011,0x09000000`

For debug: `console=ttyAMA0 earlycon=pl011,0x09000000 earlyprintk debug loglevel=8`

## Notes

The downloaded `vmlinuz-virt` is an EFI stub PE image. The download script extracts the raw ARM64 Image from the gzip payload inside it (at offset 0xc970).
