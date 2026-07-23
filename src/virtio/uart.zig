//! PL011 UART emulation.
//!
//! TX output is forwarded to a host callback. RX input is buffered in a
//! FIFO and delivered to the guest via the RX interrupt (level-triggered,
//! asserted while the FIFO is non-empty and RX interrupts are unmasked).

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const global = @import("../global.zig");

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

/// Interrupt bits (RIS/MIS/IMSC/ICR).
pub const INT = struct {
    pub const RX: u32 = 1 << 4; // Receive
    pub const TX: u32 = 1 << 5; // Transmit
    pub const RT: u32 = 1 << 6; // Receive timeout
};

/// Simple UART state.
pub const Uart = struct {
    output_callback: ?*const fn (data: []const u8, userdata: ?*anyopaque) void = null,
    output_userdata: ?*anyopaque = null,

    /// IRQ line callback (level-triggered).
    irq_callback: ?*const fn (level: bool, userdata: ?*anyopaque) void = null,
    irq_userdata: ?*anyopaque = null,

    // Registers
    cr: u32 = 0x0300, // Control: TX/RX enabled
    lcr_h: u32 = 0,
    ibrd: u32 = 0,
    fbrd: u32 = 0,
    imsc: u32 = 0,
    ifls: u32 = 0,

    // RX FIFO (ring buffer). Guarded by mutex: the host input thread
    // pushes while the vCPU thread pops.
    rx_fifo: [RX_FIFO_SIZE]u8 = undefined,
    rx_head: usize = 0,
    rx_len: usize = 0,
    rx_mutex: std.Io.Mutex = .init,

    /// Last IRQ level we reported, to avoid redundant callbacks.
    irq_level: bool = false,

    pub const RX_FIFO_SIZE: usize = 4096;

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

    pub fn setIrqCallback(
        self: *Uart,
        callback: *const fn (level: bool, userdata: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.irq_callback = callback;
        self.irq_userdata = userdata;
    }

    /// Queue host input for the guest. Drops bytes if the FIFO is full.
    pub fn queueInput(self: *Uart, data: []const u8) void {
        self.rx_mutex.lockUncancelable(global.io());
        for (data) |byte| {
            if (self.rx_len >= RX_FIFO_SIZE) break;
            const tail = (self.rx_head + self.rx_len) % RX_FIFO_SIZE;
            self.rx_fifo[tail] = byte;
            self.rx_len += 1;
        }
        self.rx_mutex.unlock(global.io());
        self.updateIrq();
    }

    fn rxPop(self: *Uart) ?u8 {
        self.rx_mutex.lockUncancelable(global.io());
        defer self.rx_mutex.unlock(global.io());
        if (self.rx_len == 0) return null;
        const byte = self.rx_fifo[self.rx_head];
        self.rx_head = (self.rx_head + 1) % RX_FIFO_SIZE;
        self.rx_len -= 1;
        return byte;
    }

    fn rxEmpty(self: *Uart) bool {
        self.rx_mutex.lockUncancelable(global.io());
        defer self.rx_mutex.unlock(global.io());
        return self.rx_len == 0;
    }

    /// Raw interrupt status: RX (and timeout) assert while data is queued.
    fn ris(self: *Uart) u32 {
        var status: u32 = 0;
        if (!self.rxEmpty()) status |= INT.RX | INT.RT;
        return status;
    }

    /// Recompute the IRQ line and notify on level change.
    fn updateIrq(self: *Uart) void {
        const level = (self.ris() & self.imsc) != 0;
        if (level == self.irq_level) return;
        self.irq_level = level;
        if (self.irq_callback) |cb| {
            cb(level, self.irq_userdata);
        }
    }

    pub fn read(self: *Uart, offset: u12) u32 {
        return switch (offset) {
            Reg.UARTDR => blk: {
                const byte = self.rxPop() orelse 0;
                self.updateIrq();
                break :blk byte;
            },
            Reg.UARTRSR => 0, // No errors
            Reg.UARTFR => blk: {
                var fr: u32 = FR.TXFE; // TX always ready
                if (self.rxEmpty()) fr |= FR.RXFE;
                break :blk fr;
            },
            Reg.UARTCR => self.cr,
            Reg.UARTLCR_H => self.lcr_h,
            Reg.UARTIBRD => self.ibrd,
            Reg.UARTFBRD => self.fbrd,
            Reg.UARTIMSC => self.imsc,
            Reg.UARTIFLS => self.ifls,
            Reg.UARTRIS => self.ris(),
            Reg.UARTMIS => self.ris() & self.imsc,
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
            Reg.UARTIMSC => {
                self.imsc = value;
                self.updateIrq();
            },
            Reg.UARTIFLS => self.ifls = value,
            Reg.UARTICR => {
                // RX/RT are level interrupts tied to FIFO state; a write
                // here only re-evaluates the line.
                self.updateIrq();
            },
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

// =============================================================================
// Tests
// =============================================================================

test "Uart RX fifo delivers input and tracks flags" {
    var uart = Uart.init();

    // Empty: RXFE set, no interrupt
    try std.testing.expect(uart.read(Reg.UARTFR) & FR.RXFE != 0);
    try std.testing.expectEqual(@as(u32, 0), uart.read(Reg.UARTRIS) & INT.RX);

    uart.queueInput("hi");
    try std.testing.expect(uart.read(Reg.UARTFR) & FR.RXFE == 0);
    try std.testing.expect(uart.read(Reg.UARTRIS) & INT.RX != 0);

    try std.testing.expectEqual(@as(u32, 'h'), uart.read(Reg.UARTDR));
    try std.testing.expectEqual(@as(u32, 'i'), uart.read(Reg.UARTDR));
    try std.testing.expect(uart.read(Reg.UARTFR) & FR.RXFE != 0);
}

test "Uart IRQ line follows mask" {
    var uart = Uart.init();

    const Ctx = struct {
        var level: bool = false;
        fn cb(l: bool, _: ?*anyopaque) void {
            level = l;
        }
    };
    uart.setIrqCallback(Ctx.cb, null);

    // Input with RX masked: no IRQ
    uart.queueInput("x");
    try std.testing.expect(!Ctx.level);

    // Unmask RX: IRQ asserts
    uart.write(Reg.UARTIMSC, INT.RX | INT.RT);
    try std.testing.expect(Ctx.level);

    // Drain FIFO: IRQ deasserts
    _ = uart.read(Reg.UARTDR);
    try std.testing.expect(!Ctx.level);
}
