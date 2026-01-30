/* Minimal linker script for bare-metal ARM64 test */

ENTRY(_start)

SECTIONS
{
    /* Start at KERNEL_BASE */
    . = 0x40080000;

    /* All code and data together */
    .all : {
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        *(.data)
        *(.data.*)
        *(.bss)
        *(.bss.*)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note.*)
        *(.eh_frame*)
        *(.ARM.*)
    }
}
