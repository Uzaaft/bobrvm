# Bare-metal integration test

This minimal arm64 program tests PL011 output and the PSCI `VERSION`,
`FEATURES`, and `SYSTEM_OFF` calls without booting Linux.

```sh
zig build bare-metal-test
./zig-out/bin/bobrvm run --kernel zig-out/test/bare_metal_test.bin
```

Expected output:

```text
BOBRVM TEST START
UART: OK
PSCI VERSION: 00010000
PSCI FEATURES: OK
ALL TESTS PASSED
```

The VM exits after `PSCI_SYSTEM_OFF`. `test.S` is the test program and
`link.ld` places it at `0x40080000`; `test_main.zig` is an unused alternative.
