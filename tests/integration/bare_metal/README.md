# Bare-metal integration test

This minimal arm64 program tests PL011 output, the PSCI `VERSION`,
`FEATURES`, `CPU_ON`, and `SYSTEM_OFF` calls, and the GICv3 system-register
interface on a secondary vCPU without booting Linux.

```sh
zig build test-bare-metal
```

Expected output:

```text
BOBRVM TEST START
UART: OK
PSCI VERSION: 00010000
PSCI FEATURES: OK
PSCI CPU_ON + GICV3: OK
ALL TESTS PASSED
```

The VM exits after `PSCI_SYSTEM_OFF`. `test.S` is the test program and
`link.ld` places it at `0x40080000`.

CI runs this test on a physical Apple Silicon self-hosted runner with the
`self-hosted`, `macOS`, `ARM64`, and `bobrvm-hypervisor` labels. GitHub-hosted
macOS runners cannot execute it because they do not support nested
virtualization.
