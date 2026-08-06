// Bare-metal ARM64 test for bobrvm hypervisor.
// Pure assembly version - no Zig dependencies.
//
// Tests: UART output, PSCI VERSION, PSCI FEATURES, PSCI CPU_ON,
// per-vCPU GICv3 system registers, PSCI SYSTEM_OFF
//
// Expected output:
//   BOBRVM TEST START
//   UART: OK
//   PSCI VERSION: 00010000
//   PSCI FEATURES: OK
//   PSCI CPU_ON + GICV3: OK
//   ALL TESTS PASSED

.equ UART_BASE,     0x09000000
.equ UART_DR,       0x000
.equ UART_FR,       0x018
.equ UART_FR_TXFF,  0x20

// PSCI function IDs (loaded as 32-bit values)
.equ PSCI_VERSION_HI,   0x8400
.equ PSCI_FEATURES_HI,  0x8400
.equ PSCI_FEATURES_LO,  0x000A
.equ PSCI_CPU_ON_HI,    0xC400
.equ PSCI_CPU_ON_LO,    0x0003
.equ PSCI_SYSOFF_HI,    0x8400
.equ PSCI_SYSOFF_LO,    0x0008

.section .text
.globl _start

_start:
    // Set up stack
    mov     x0, #0x4010
    lsl     x0, x0, #16
    mov     sp, x0

    // Print "BOBRVM TEST START\r\n"
    adr     x0, msg_start
    bl      uart_puts

    // Print "UART: OK\r\n"
    adr     x0, msg_uart_ok
    bl      uart_puts

    // Print "PSCI VERSION: "
    adr     x0, msg_psci_ver
    bl      uart_puts

    // Call PSCI_VERSION (0x84000000)
    movz    w0, #PSCI_VERSION_HI, lsl #16
    hvc     #0
    mov     x19, x0             // Save version

    // Print version as hex
    mov     x0, x19
    bl      uart_print_hex32
    bl      uart_newline

    // Check version >= 1.0
    lsr     x0, x19, #16
    cmp     x0, #1
    b.lt    test_failed

    // Print "PSCI FEATURES: "
    adr     x0, msg_psci_feat
    bl      uart_puts

    // Call PSCI_FEATURES (0x8400000A) for VERSION (0x84000000)
    movz    w0, #PSCI_FEATURES_HI, lsl #16
    movk    w0, #PSCI_FEATURES_LO
    movz    w1, #PSCI_VERSION_HI, lsl #16
    hvc     #0
    cbnz    x0, test_failed

    // Print "OK\r\n"
    adr     x0, msg_ok
    bl      uart_puts

    // Bring CPU 1 online at secondary_start. The secondary verifies that
    // its feature register and trapped ICC interface match CPU 0's.
    adr     x19, secondary_status
    str     xzr, [x19]
    movz    w0, #PSCI_CPU_ON_HI, lsl #16
    movk    w0, #PSCI_CPU_ON_LO
    mov     x1, #1
    adr     x2, secondary_start
    mov     x3, #0
    hvc     #0
    cbnz    x0, test_failed

wait_for_secondary:
    ldar    x20, [x19]
    cbz     x20, wait_for_secondary
    cmp     x20, #1
    b.ne    test_failed

    adr     x0, msg_smp_ok
    bl      uart_puts

    // Print "ALL TESTS PASSED\r\n"
    adr     x0, msg_passed
    bl      uart_puts

    // Shutdown via PSCI (0x84000008)
poweroff:
    movz    w0, #PSCI_SYSOFF_HI, lsl #16
    movk    w0, #PSCI_SYSOFF_LO
    hvc     #0

halt:
    wfi
    b       halt

test_failed:
    adr     x0, msg_failed
    bl      uart_puts
    b       poweroff

.balign 4
secondary_start:
    // ID_AA64PFR0_EL1.GIC == 1 advertises the GICv3 system-register
    // interface. This must be identical on every vCPU.
    mrs     x9, ID_AA64PFR0_EL1
    ubfx    x9, x9, #24, #4
    cmp     x9, #1
    b.ne    secondary_failed

    // Use the generic encoding for ICC_PMR_EL1 so this test assembles for
    // baseline ARMv8 even though the VMM advertises the GICv3 extension.
    mov     x10, #0xA5
    msr     S3_0_C4_C6_0, x10
    isb
    mrs     x11, S3_0_C4_C6_0
    cmp     x11, #0xA5
    b.ne    secondary_failed

    mov     x10, #1
    b       secondary_complete

secondary_failed:
    mov     x10, #2

secondary_complete:
    adr     x11, secondary_status
    stlr    x10, [x11]
secondary_halt:
    wfi
    b       secondary_halt

// uart_puts: Print null-terminated string at x0
uart_puts:
    mov     x3, x30
    mov     x4, x0
1:  ldrb    w0, [x4], #1
    cbz     w0, 2f
    bl      uart_putc
    b       1b
2:  mov     x30, x3
    ret

// uart_putc: Print character in w0
uart_putc:
    mov     x1, #UART_BASE
1:  ldr     w2, [x1, #UART_FR]
    tst     w2, #UART_FR_TXFF
    b.ne    1b
    str     w0, [x1, #UART_DR]
    ret

// uart_newline: Print \r\n
uart_newline:
    mov     x3, x30
    mov     w0, #'\r'
    bl      uart_putc
    mov     w0, #'\n'
    bl      uart_putc
    mov     x30, x3
    ret

// uart_print_hex32: Print w0 as 8 hex digits
uart_print_hex32:
    mov     x3, x30
    mov     w5, w0              // Use 32-bit value
    adr     x6, hex_chars
    mov     x7, #8
1:  ror     w5, w5, #28         // Rotate 32-bit register
    and     w0, w5, #0xF
    ldrb    w0, [x6, w0, uxtw]
    bl      uart_putc
    subs    x7, x7, #1
    b.ne    1b
    mov     x30, x3
    ret

.section .rodata
hex_chars:
    .ascii "0123456789ABCDEF"
msg_start:
    .asciz "BOBRVM TEST START\r\n"
msg_uart_ok:
    .asciz "UART: OK\r\n"
msg_psci_ver:
    .asciz "PSCI VERSION: "
msg_psci_feat:
    .asciz "PSCI FEATURES: "
msg_ok:
    .asciz "OK\r\n"
msg_smp_ok:
    .asciz "PSCI CPU_ON + GICV3: OK\r\n"
msg_passed:
    .asciz "ALL TESTS PASSED\r\n"
msg_failed:
    .asciz "TEST FAILED\r\n"

.section .data
.balign 8
secondary_status:
    .quad 0
