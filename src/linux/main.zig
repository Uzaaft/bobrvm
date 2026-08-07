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
    if (std.mem.eql(u8, command, "kvm-lifecycle-smoke")) {
        const kernel_path = args.next() orelse {
            writeAll("error: kvm-lifecycle-smoke requires a bzImage path\n");
            std.process.exit(1);
        };
        run_kernel.executeStopSmoke(std.heap.c_allocator, kernel_path) catch |err| {
            printNamedError("KVM lifecycle smoke", err);
            std.process.exit(1);
        };
        writeAll("KVM lifecycle: host stop joined cleanly\n");
        return;
    }
    if (std.mem.eql(u8, command, "kvm-console-smoke")) {
        const kernel_path = args.next() orelse return missingConsoleSmokeArgument();
        const initrd_path = args.next() orelse return missingConsoleSmokeArgument();
        const disk_path = args.next() orelse return missingConsoleSmokeArgument();
        run_kernel.executeConsoleSmoke(
            std.heap.c_allocator,
            kernel_path,
            initrd_path,
            disk_path,
        ) catch |err| {
            printNamedError("KVM console smoke", err);
            std.process.exit(1);
        };
        writeAll("KVM console: guest accepted serial input\n");
        return;
    }
    if (std.mem.eql(u8, command, "kvm-network-smoke")) {
        const kernel_path = args.next() orelse return missingNetworkSmokeArgument();
        const initrd_path = args.next() orelse return missingNetworkSmokeArgument();
        const disk_path = args.next() orelse return missingNetworkSmokeArgument();
        run_kernel.executeNetworkSmoke(
            std.heap.c_allocator,
            kernel_path,
            initrd_path,
            disk_path,
        ) catch |err| {
            printNamedError("KVM network smoke", err);
            std.process.exit(1);
        };
        writeAll("KVM network: guest reached the built-in gateway\n");
        return;
    }
    if (std.mem.eql(u8, command, "kvm-boot-benchmark")) {
        const kernel_path = args.next() orelse return missingBootBenchmarkArgument();
        const initrd_path = args.next() orelse return missingBootBenchmarkArgument();
        const disk_path = args.next() orelse return missingBootBenchmarkArgument();
        const result = run_kernel.executeBootBenchmark(
            std.heap.c_allocator,
            kernel_path,
            initrd_path,
            disk_path,
        ) catch |err| {
            printNamedError("KVM boot benchmark", err);
            std.process.exit(1);
        };
        printBootBenchmark(result);
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

fn missingConsoleSmokeArgument() noreturn {
    writeAll("error: kvm-console-smoke requires bzImage, initrd, and disk paths\n");
    std.process.exit(1);
}

fn missingNetworkSmokeArgument() noreturn {
    writeAll("error: kvm-network-smoke requires bzImage, initrd, and disk paths\n");
    std.process.exit(1);
}

fn missingBootBenchmarkArgument() noreturn {
    writeAll("error: kvm-boot-benchmark requires bzImage, initrd, and disk paths\n");
    std.process.exit(1);
}

fn printBootBenchmark(result: run_kernel.BootBenchmark) void {
    var buffer: [256]u8 = undefined;
    const output = std.fmt.bufPrint(
        &buffer,
        "KVM boot benchmark: samples={d} vcpus={d} create_us_min={d} " ++
            "boot_us_min={d} boot_us_median={d} total_us_min={d}\n",
        .{
            result.samples,
            result.vcpus,
            result.create_us_min,
            result.boot_us_min,
            result.boot_us_median,
            result.total_us_min,
        },
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
        \\  kvm-lifecycle-smoke <bzImage>  Verify host-requested VM stop
        \\  kvm-console-smoke <bzImage> <initrd> <disk>  Verify serial input
        \\  kvm-network-smoke <bzImage> <initrd> <disk>  Verify built-in NAT
        \\  kvm-boot-benchmark <bzImage> <initrd> <disk>  Measure boot readiness
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
