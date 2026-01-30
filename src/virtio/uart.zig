//! Simple PL011 UART emulation for earlycon.
//!
//! Minimal implementation that captures TX output and provides
//! status registers. Used for kernel earlycon before virtio-console
//! is initialized.

const std = @import("std");

const log = std.log.scoped(.uart);

/// PL011 register offsets.
pub const Reg = struct {
    pub const UARTDR: u12 = 0x000; // Data Register
    pub const UARTRSR: u12 = 0x004; // Receive Status Register
    pub const UARTFR: u12 = 0x018; // Flag Register
    pub const UARTILPR: u12 = 0x020; // IrDA Low-Power Counter
    pub const UARTIBRD: u12 = 0x024; // Integer Baud Rate
    pub const UARTFBRD: u12 = 0x028; // Fractional Baud Rate
    pub const UARTLCR_H: u12 = 0x02C; // Line Control
    pub const UARTCR: u12 = 0x030; // Control Register
    pub const UARTIFLS: u12 = 0x034; // Interrupt FIFO Level
    pub const UARTIMSC: u12 = 0x038; // Interrupt Mask
    pub const UARTRIS: u12 = 0x03C; // Raw Interrupt Status
    pub const UARTMIS: u12 = 0x040; // Masked Interrupt Status
    pub const UARTICR: u12 = 0x044; // Interrupt Clear
    pub const UARTDMACR: u12 = 0x048; // DMA Control
    pub const UARTPeriphID0: u12 = 0xFE0;
    pub const UARTPeriphID1: u12 = 0xFE4;
    pub const UARTPeriphID2: u12 = 0xFE8;
    pub const UARTPeriphID3: u12 = 0xFEC;
    pub const UARTPCellID0: u12 = 0xFF0;
    pub const UARTPCellID1: u12 = 0xFF4;
    pub const UARTPCellID2: u12 = 0xFF8;
    pub const UARTPCellID3: u12 = 0xFFC;
};

/// Flag Register bits.
pub const FR = struct {
    pub const TXFE: u32 = 1 << 7; // TX FIFO empty
    pub const RXFF: u32 = 1 << 6; // RX FIFO full
    pub const TXFF: u32 = 1 << 5; // TX FIFO full
    pub const RXFE: u32 = 1 << 4; // RX FIFO empty
    pub const BUSY: u32 = 1 << 3; // UART busy
};

/// Simple UART state.
pub const Uart = struct {
    output_callback: ?*const fn (data: []const u8, userdata: ?*anyopaque) void = null,
    output_userdata: ?*anyopaque = null,

    // Registers
    cr: u32 = 0x0300, // Control: TX/RX enabled
    lcr_h: u32 = 0,
    ibrd: u32 = 0,
    fbrd: u32 = 0,
    imsc: u32 = 0,
    ifls: u32 = 0,

    pub fn init() Uart {
        return .{};
    }

    pub fn setOutputCallback(
        self: *Uart,
        callback: *const fn (data: []const u8, userdata: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.output_callback = callback;
        self.output_userdata = userdata;
    }

    pub fn read(self: *Uart, offset: u12) u32 {
        return switch (offset) {
            Reg.UARTDR => 0, // No input
            Reg.UARTRSR => 0, // No errors
            Reg.UARTFR => FR.TXFE | FR.RXFE, // TX empty, RX empty (ready to write)
            Reg.UARTCR => self.cr,
            Reg.UARTLCR_H => self.lcr_h,
            Reg.UARTIBRD => self.ibrd,
            Reg.UARTFBRD => self.fbrd,
            Reg.UARTIMSC => self.imsc,
            Reg.UARTIFLS => self.ifls,
            Reg.UARTRIS => 0,
            Reg.UARTMIS => 0,
            // PrimeCell ID registers (required for Linux driver detection)
            Reg.UARTPeriphID0 => 0x11,
            Reg.UARTPeriphID1 => 0x10,
            Reg.UARTPeriphID2 => 0x14, // Rev 1, designer 0x41 (ARM)
            Reg.UARTPeriphID3 => 0x00,
            Reg.UARTPCellID0 => 0x0D,
            Reg.UARTPCellID1 => 0xF0,
            Reg.UARTPCellID2 => 0x05,
            Reg.UARTPCellID3 => 0xB1,
            else => 0,
        };
    }

    pub fn write(self: *Uart, offset: u12, value: u32) void {
        switch (offset) {
            Reg.UARTDR => {
                // TX data - output the character
                const char: u8 = @truncate(value);
                if (self.output_callback) |cb| {
                    cb(&[_]u8{char}, self.output_userdata);
                }
            },
            Reg.UARTRSR => {}, // Clear errors (ignore)
            Reg.UARTCR => self.cr = value,
            Reg.UARTLCR_H => self.lcr_h = value,
            Reg.UARTIBRD => self.ibrd = value,
            Reg.UARTFBRD => self.fbrd = value,
            Reg.UARTIMSC => self.imsc = value,
            Reg.UARTIFLS => self.ifls = value,
            Reg.UARTICR => {}, // Clear interrupts (ignore)
            else => {},
        }
    }
};

// MMIO callback wrappers for runner
pub fn mmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
    const uart: *Uart = @ptrCast(@alignCast(context));
    _ = size;
    return uart.read(@truncate(offset));
}

pub fn mmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
    const uart: *Uart = @ptrCast(@alignCast(context));
    _ = size;
    uart.write(@truncate(offset), @truncate(value));
}
