//! Linux command-line entry point.

const std = @import("std");
const kvm = @import("../hypervisor/kvm/main.zig");
const run_kernel = @import("run_kernel.zig");

pub fn main(minimal: std.process.Init.Minimal) void {
    var args = minimal.args.iterate();
    _ = args.skip();
    const command = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "kvm-info")) {
        printKvmInfo() catch |err| {
            printError(err);
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, command, "kvm-smoke")) {
        kvm.runSmoke() catch |err| {
            printSmokeError(err);
            std.process.exit(1);
        };
        writeAll("KVM smoke: marker I/O exit followed by halt\n");
        return;
    }
    if (std.mem.eql(u8, command, "run-kernel")) {
        const kernel_path = args.next() orelse {
            writeAll("error: run-kernel requires a bzImage path\n");
            std.process.exit(1);
        };
        const initrd_path = args.next();
        run_kernel.execute(
            std.heap.c_allocator,
            kernel_path,
            initrd_path,
            args.next(),
        ) catch |err| {
            printNamedError("direct kernel boot", err);
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-v"))
    {
        writeAll("bobrvm 0.1.0\n");
        return;
    }
    if (std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h"))
    {
        printUsage();
        return;
    }

    writeAll("error: unknown command\n");
    printUsage();
    std.process.exit(1);
}

fn printKvmInfo() kvm.OpenError!void {
    var host = try kvm.Kvm.open();
    defer host.deinit();

    var buffer: [512]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer,
        \\KVM API: {d}
        \\vCPU run mapping: {d} bytes
        \\user memory: {}
        \\irqfd: {}
        \\irqfd resample: {}
        \\ioeventfd: {}
        \\immediate exit: {}
        \\userspace MSRs: {}
        \\fast device path: {}
        \\
    , .{
        kvm.API_VERSION,
        host.vcpu_run_size,
        host.capabilities.user_memory,
        host.capabilities.irqfd,
        host.capabilities.irqfd_resample,
        host.capabilities.ioeventfd,
        host.capabilities.immediate_exit,
        host.capabilities.x86_user_space_msr,
        host.capabilities.supportsFastDevicePath(),
    }) catch unreachable;
    writeAll(output);
}

fn printError(err: kvm.OpenError) void {
    const message = switch (err) {
        error.AccessDenied => "cannot access /dev/kvm; check group membership and permissions",
        error.DeviceUnavailable => "KVM is unavailable; enable CPU virtualization and load kvm",
        error.UnsupportedApiVersion => "the host exposes an unsupported KVM API version",
        error.MissingUserMemory => "KVM lacks required userspace-memory support",
        error.IoctlFailed => "a KVM capability query failed",
    };
    var buffer: [256]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "error: {s}\n", .{message}) catch unreachable;
    writeAll(output);
}

fn printSmokeError(err: anyerror) void {
    printNamedError("KVM smoke", err);
}

fn printNamedError(operation: []const u8, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    const output = std.fmt.bufPrint(
        &buffer,
        "error: {s} failed: {s}\n",
        .{ operation, @errorName(err) },
    ) catch unreachable;
    writeAll(output);
}

fn printUsage() void {
    writeAll(
        \\bobrvm - fast Linux virtualization
        \\
        \\Usage: bobrvm <command>
        \\
        \\Commands:
        \\  kvm-info    Validate KVM and show acceleration capabilities
        \\  kvm-smoke   Run a tiny x86 payload through KVM
        \\  run-kernel  Direct boot: run-kernel <bzImage> [initrd] [writable-disk]
        \\  version     Show version information
        \\  help        Show this help message
        \\
    );
}

fn writeAll(bytes: []const u8) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        if (written <= 0) return;
        remaining = remaining[@intCast(written)..];
    }
}
