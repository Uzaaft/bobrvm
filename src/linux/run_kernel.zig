//! Linux direct-kernel boot command.

const std = @import("std");
const file_compat = @import("../compat/file.zig");
const global = @import("../global.zig");
const boot = @import("../machine/x86/boot.zig");
const x86 = @import("../machine/x86/main.zig");

const memory_bytes: usize = 512 * 1024 * 1024;
const kernel_bytes_max: usize = 512 * 1024 * 1024;
const initrd_bytes_max: usize = 1024 * 1024 * 1024;
const exits_max: u64 = 100_000_000;
const command_line =
    "console=ttyS0,115200 earlycon=uart,io,0x3f8,115200n8 " ++
    "nokaslr acpi=off pci=conf1 panic=-1 reboot=t";

pub const Error = boot.ParseError || x86.Machine.InitError || x86.Machine.AttachDiskError ||
    x86.Machine.RunError || error{
    OpenKernelFailed,
    ReadKernelFailed,
    OpenInitrdFailed,
    ReadInitrdFailed,
};

pub fn execute(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: ?[]const u8,
    disk_path: ?[]const u8,
) Error!void {
    const kernel = try readFile(
        allocator,
        kernel_path,
        kernel_bytes_max,
        .kernel,
    );
    defer allocator.free(kernel);
    const image = try boot.Image.parse(kernel);

    const initrd = if (initrd_path) |path|
        try readFile(
            allocator,
            path,
            initrd_bytes_max,
            .initrd,
        )
    else
        null;
    defer if (initrd) |bytes| allocator.free(bytes);

    var machine = try x86.Machine.init(memory_bytes, image, command_line, initrd);
    defer machine.deinit();
    if (disk_path) |path| try machine.attachDisk(allocator, path, false);
    var output = Stdout{};
    try machine.run(x86.SerialSink.bind(Stdout, &output, Stdout.write), exits_max);
    if (disk_path != null) output.writeFastBlockStats(machine.fastBlockStats());
}

fn readFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes_max: usize,
    kind: enum { kernel, initrd },
) error{ OpenKernelFailed, ReadKernelFailed, OpenInitrdFailed, ReadInitrdFailed }![]u8 {
    const file = std.Io.Dir.cwd().openFile(global.io(), path, .{
        .mode = .read_only,
    }) catch return switch (kind) {
        .kernel => error.OpenKernelFailed,
        .initrd => error.OpenInitrdFailed,
    };
    defer file.close(global.io());
    return file_compat.readToEndAlloc(file, allocator, bytes_max) catch return switch (kind) {
        .kernel => error.ReadKernelFailed,
        .initrd => error.ReadInitrdFailed,
    };
}

const Stdout = struct {
    fn write(_: *Stdout, bytes: []const u8) void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const count = std.c.write(
                std.posix.STDOUT_FILENO,
                remaining.ptr,
                remaining.len,
            );
            if (count <= 0) return;
            remaining = remaining[@intCast(count)..];
        }
    }

    fn writeFastBlockStats(self: *Stdout, stats: x86.Machine.FastBlockStats) void {
        const healthy = stats.enabled and !stats.worker_failed and stats.kicks > 0 and
            stats.interrupts > 0 and stats.notify_mmio_exits == 0;
        const marker = if (healthy)
            "BOBRVM_KVM_FAST_BLOCK_OK"
        else
            "BOBRVM_KVM_FAST_BLOCK_FAILED";
        var buffer: [192]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "{s} kicks={d} interrupts={d} notify_mmio_exits={d}\n",
            .{ marker, stats.kicks, stats.interrupts, stats.notify_mmio_exits },
        ) catch unreachable;
        self.write(line);
    }
};
