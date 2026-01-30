# Bare-Metal Integration Test

Minimal ARM64 assembly test that verifies basic hypervisor functionality without a full Linux kernel.

## Building

```bash
zig build bare-metal-test
```

Output: `zig-out/test/bare_metal_test.bin`

## Running

```bash
./zig-out/bin/bobrvm --kernel zig-out/test/bare_metal_test.bin
```

## What It Tests

1. **UART output** - PL011 at 0x09000000
2. **PSCI VERSION** - HVC call, expects v1.0 (0x00010000)
3. **PSCI FEATURES** - Query supported features
4. **PSCI SYSTEM_OFF** - Clean shutdown

## Expected Output

```
BOBRVM TEST START
UART: OK
PSCI VERSION: 00010000
PSCI FEATURES: OK
ALL TESTS PASSED
```

Then VM should stop (PSCI_SYSTEM_OFF).

## Files

- `test.S` - Pure ARM64 assembly test
- `link.ld` - Linker script (places code at 0x40080000)
- `test_main.zig` - (Alternative) Zig implementation (not currently used)
