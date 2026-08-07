//! Minimal x86 PC machine for direct Linux boot on KVM.

const std = @import("std");
const kvm = @import("../../hypervisor/kvm/main.zig");
const boot = @import("boot.zig");

const gdt_address: u64 = 0x500;

pub const SerialSink = struct {
    userdata: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) void,

    pub fn bind(
        comptime Context: type,
        context: *Context,
        comptime write_fn: *const fn (*Context, []const u8) void,
    ) SerialSink {
        const Adapter = struct {
            fn write(userdata: *anyopaque, bytes: []const u8) void {
                const typed: *Context = @ptrCast(@alignCast(userdata));
                write_fn(typed, bytes);
            }
        };
        return .{ .userdata = context, .write_fn = Adapter.write };
    }

    pub fn write(self: SerialSink, bytes: []const u8) void {
        self.write_fn(self.userdata, bytes);
    }
};

pub const Machine = struct {
    host: kvm.Kvm,
    vm: kvm.VM,
    vcpu: kvm.Vcpu,
    memory: []align(std.heap.page_size_min) u8,
    layout: boot.Layout,
    exits_total: u64 = 0,
    mmio_exits_total: u64 = 0,
    last_mmio_address: ?u64 = null,

    pub const InitError = kvm.OpenError || kvm.CreateError || boot.LoadError;
    pub const RunError = kvm.RunError || error{
        ExitLimitReached,
        GuestShutdown,
        InternalError,
        InvalidIoExit,
        InvalidMmioExit,
        UnknownExit,
    };

    pub fn init(
        memory_bytes: usize,
        image: boot.Image,
        command_line: []const u8,
        initrd: ?[]const u8,
    ) InitError!Machine {
        var host = try kvm.Kvm.open();
        errdefer host.deinit();
        var vm = try host.createVm();
        errdefer vm.deinit();
        const memory = try vm.mapMemory(0, 0, memory_bytes);
        try vm.createPcInterrupts();

        const layout = try image.load(memory, command_line, initrd);
        writeGdt(memory);
        var cpuid = try host.supportedCpuid();
        var vcpu = try vm.createVcpu(0);
        errdefer vcpu.deinit();
        try vcpu.setCpuid(&cpuid);
        try vcpu.setProtectedModeEntry(
            layout.entry_address,
            layout.boot_params_address,
            gdt_address,
        );

        return .{
            .host = host,
            .vm = vm,
            .vcpu = vcpu,
            .memory = memory,
            .layout = layout,
        };
    }

    pub fn deinit(self: *Machine) void {
        self.vcpu.deinit();
        self.vm.deinit();
        self.host.deinit();
        self.memory = undefined;
    }

    pub fn run(self: *Machine, serial: SerialSink, exits_max: u64) RunError!void {
        while (self.exits_total < exits_max) {
            self.exits_total += 1;
            switch (try self.vcpu.runOnce()) {
                .io => try self.handleIo(serial),
                .halted, .interrupted => continue,
                .shutdown => return error.GuestShutdown,
                .internal_error => return error.InternalError,
                .mmio => try self.handleMmio(),
                .unknown => return error.UnknownExit,
            }
        }
        return error.ExitLimitReached;
    }

    fn handleIo(self: *Machine, serial: SerialSink) RunError!void {
        const access = self.vcpu.ioExit() orelse return error.InvalidIoExit;
        switch (access.direction) {
            .write => handleIoWrite(access, serial),
            .read => handleIoRead(access),
        }
    }

    fn handleIoWrite(access: kvm.IoExit, serial: SerialSink) void {
        if (access.size != 1) return;
        if (access.port == 0x3f8 or access.port == 0xe9) serial.write(access.data);
    }

    fn handleIoRead(access: kvm.IoExit) void {
        @memset(access.data, 0xff);
        if (access.size != 1) return;
        const value: u8 = switch (access.port) {
            0x3f8 => 0x00,
            0x3fa => 0x01,
            0x3fd => 0x60,
            0x3fe => 0xb0,
            else => return,
        };
        @memset(access.data, value);
    }

    fn handleMmio(self: *Machine) RunError!void {
        const access = self.vcpu.mmioExit() orelse return error.InvalidMmioExit;
        self.mmio_exits_total += 1;
        self.last_mmio_address = access.address;
        handleAbsentMmio(access);
    }

    fn handleAbsentMmio(access: kvm.MmioExit) void {
        if (access.direction == .read) @memset(access.data, 0xff);
    }

    fn writeGdt(memory: []u8) void {
        const descriptors = [_]u64{
            0,
            0x00cf_9b00_0000_ffff,
            0x00cf_9300_0000_ffff,
        };
        for (descriptors, 0..) |descriptor, index| {
            const offset = @as(usize, gdt_address) + index * 8;
            std.mem.writeInt(u64, memory[offset..][0..8], descriptor, .little);
        }
    }
};

test "x86 machine GDT contains flat code and data segments" {
    var memory = [_]u8{0} ** 4096;
    Machine.writeGdt(&memory);
    try std.testing.expectEqual(
        @as(u64, 0x00cf_9b00_0000_ffff),
        std.mem.readInt(u64, memory[gdt_address + 8 ..][0..8], .little),
    );
    try std.testing.expectEqual(
        @as(u64, 0x00cf_9300_0000_ffff),
        std.mem.readInt(u64, memory[gdt_address + 16 ..][0..8], .little),
    );
}

test "absent MMIO reads return all bits set" {
    var data = [_]u8{ 0, 0, 0, 0 };
    const access = kvm.MmioExit{
        .direction = .read,
        .address = 0xfed0_0000,
        .data = &data,
    };

    Machine.handleAbsentMmio(access);

    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, &data);
}

test "absent MMIO writes preserve exit data" {
    var data = [_]u8{ 0x12, 0x34 };
    const access = kvm.MmioExit{
        .direction = .write,
        .address = 0xfed0_0000,
        .data = &data,
    };

    Machine.handleAbsentMmio(access);

    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, &data);
}
