//! Linux direct-kernel boot command.

const std = @import("std");
const global = @import("../global.zig");
const x86 = @import("../machine/x86/main.zig");
const VM = @import("VM.zig");

const memory_bytes: usize = 512 * 1024 * 1024;
const exits_max: u64 = 100_000_000;
const benchmark_samples: usize = 3;
pub const command_line =
    "console=ttyS0,115200 earlycon=uart,io,0x3f8,115200n8 " ++
    "nokaslr acpi=off pci=conf1 panic=-1 reboot=t";

pub const Error = VM.CreateError || VM.StartError || VM.JoinError;

pub const BootBenchmark = struct {
    samples: usize,
    vcpus: u8,
    create_us_min: u64,
    boot_us_min: u64,
    boot_us_median: u64,
    total_us_min: u64,
};

pub fn execute(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: ?[]const u8,
    disk_path: ?[]const u8,
) Error!void {
    var output = Stdout{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .disk_path = disk_path,
        .network_enabled = true,
        .command_line = command_line,
        .exits_max = exits_max,
    }, x86.SerialSink.bind(Stdout, &output, Stdout.write));
    defer vm.destroy();
    try vm.start();
    _ = try vm.join();
    if (disk_path != null) output.writeFastBlockStats(vm.fastBlockStats());
}

pub fn executeFirmware(
    allocator: std.mem.Allocator,
    firmware_path: []const u8,
    disk_path: ?[]const u8,
    iso_path: ?[]const u8,
) Error!void {
    var output = Stdout{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .firmware_path = firmware_path,
        .disk_path = disk_path,
        .disk2_path = iso_path,
        .disk2_read_only = true,
        .network_enabled = true,
        .command_line = command_line,
        .exits_max = exits_max,
    }, x86.SerialSink.bind(Stdout, &output, Stdout.write));
    defer vm.destroy();
    try vm.start();
    _ = try vm.join();
}

pub fn executeFirmwareSmoke(
    allocator: std.mem.Allocator,
    firmware_path: []const u8,
    disk_path: []const u8,
    iso_path: []const u8,
) !void {
    var output = Stdout{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .firmware_path = firmware_path,
        .disk_path = disk_path,
        .disk2_path = iso_path,
        .disk2_read_only = true,
        .network_enabled = true,
        .display_enabled = true,
        .command_line = command_line,
        .exits_max = exits_max,
    }, x86.SerialSink.bind(Stdout, &output, Stdout.write));
    defer vm.destroy();
    try vm.start();
    const pixels = try allocator.alloc(u8, 1280 * 800 * 4);
    defer allocator.free(pixels);
    var scanout: ?x86.Machine.Scanout = null;
    for (0..100) |attempt| {
        if (scanout == null) {
            scanout = vm.copyScanout(pixels);
            if (scanout != null) {
                std.log.info("firmware scanout ready after {} ms", .{attempt * 100});
            }
        }
        const storage_ready = vm.fastBlockStats().kicks > 0 or
            vm.secondaryBlockNotifications() > 0;
        if (scanout != null and storage_ready) break;
        if (vm.state() != .running) return error.FirmwareStoppedEarly;
        std.Io.Clock.Duration.sleep(.{
            .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
            .clock = .awake,
        }, global.io()) catch {};
    }
    const active_scanout = scanout orelse {
        vm.requestStop();
        _ = try vm.join();
        output.writeFirmwareStats(
            vm.pciConfigReads(),
            vm.pciDeviceReads(),
            vm.mmioExitStats(),
            vm.fastBlockStats().kicks,
            vm.secondaryBlockNotifications(),
        );
        return error.FirmwareDidNotProduceScanout;
    };
    if (active_scanout.width == 0 or active_scanout.height == 0) {
        return error.FirmwareDidNotProduceScanout;
    }
    try vm.verifySnapshotRoundTrip(allocator);
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
        .clock = .awake,
    }, global.io()) catch {};
    if (vm.state() != .running or vm.copyScanout(pixels) == null) {
        return error.FirmwareSnapshotResumeFailed;
    }
    var snapshot_path_buffer: [128]u8 = undefined;
    const snapshot_path = try std.fmt.bufPrint(
        &snapshot_path_buffer,
        "/tmp/bobrvm-kvm-snapshot-smoke-{}.img",
        .{std.os.linux.getpid()},
    );
    defer std.Io.Dir.cwd().deleteFile(global.io(), snapshot_path) catch {};
    try vm.suspendToDisk(snapshot_path);
    vm.requestStop();
    if (try vm.join() != .stopped) return error.UnexpectedRunOutcome;
    const primary = vm.fastBlockStats();
    output.writeFirmwareStats(
        vm.pciConfigReads(),
        vm.pciDeviceReads(),
        vm.mmioExitStats(),
        primary.kicks,
        vm.secondaryBlockNotifications(),
    );
    if (primary.kicks == 0 and vm.secondaryBlockNotifications() == 0) {
        return error.FirmwareDidNotProbeStorage;
    }
    try verifyFirmwareSnapshotRestore(
        allocator,
        firmware_path,
        disk_path,
        iso_path,
        snapshot_path,
        pixels,
    );
}

fn verifyFirmwareSnapshotRestore(
    allocator: std.mem.Allocator,
    firmware_path: []const u8,
    disk_path: []const u8,
    iso_path: []const u8,
    snapshot_path: []const u8,
    pixels: []u8,
) !void {
    var output = Stdout{};
    const restored = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .firmware_path = firmware_path,
        .disk_path = disk_path,
        .disk2_path = iso_path,
        .disk2_read_only = true,
        .network_enabled = true,
        .display_enabled = true,
        .restore_path = snapshot_path,
        .command_line = command_line,
        .exits_max = exits_max,
    }, x86.SerialSink.bind(Stdout, &output, Stdout.write));
    defer restored.destroy();
    try restored.start();
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
        .clock = .awake,
    }, global.io()) catch {};
    if (restored.state() != .running or restored.copyScanout(pixels) == null) {
        return error.FirmwareSnapshotRestoreFailed;
    }
    restored.requestStop();
    if (try restored.join() != .stopped) return error.UnexpectedRunOutcome;
}

pub fn executeStopSmoke(allocator: std.mem.Allocator, kernel_path: []const u8) !void {
    var output = DiscardOutput{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = 128 * 1024 * 1024,
        .kernel_path = kernel_path,
        .command_line = command_line,
        .exits_max = exits_max,
    }, x86.SerialSink.bind(DiscardOutput, &output, DiscardOutput.write));
    defer vm.destroy();
    try vm.start();
    std.Io.Clock.Duration.sleep(.{
        .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms },
        .clock = .awake,
    }, global.io()) catch {};
    vm.requestStop();
    if (try vm.join() != .stopped) return error.UnexpectedRunOutcome;
}

pub fn executeConsoleSmoke(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: []const u8,
    disk_path: []const u8,
) !void {
    var output = SmokeOutput{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .disk_path = disk_path,
        .network_enabled = true,
        .command_line = command_line ++ " bobrvm.console_test=1",
        .exits_max = exits_max,
    }, x86.SerialSink.bind(SmokeOutput, &output, SmokeOutput.write));
    defer vm.destroy();
    try vm.start();

    if (!waitForSignal(vm, &output.ready, 500)) return error.ConsoleReadyTimeout;
    const input = "bobrvm-input-ok\n";
    if (try vm.writeConsole(input) != input.len) return error.ConsoleInputQueueFull;
    if (!waitForSignal(vm, &output.accepted, 500)) return error.ConsoleInputTimeout;
    if (try vm.join() != .guest_shutdown) return error.UnexpectedRunOutcome;
}

pub fn executeNetworkSmoke(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: []const u8,
    disk_path: []const u8,
) !void {
    var output = SmokeOutput{};
    const vm = try VM.create(allocator, .{
        .memory_bytes = memory_bytes,
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .disk_path = disk_path,
        .network_enabled = true,
        .command_line = command_line ++ " bobrvm.network_test=1",
        .exits_max = exits_max,
    }, x86.SerialSink.bind(SmokeOutput, &output, SmokeOutput.write));
    defer vm.destroy();
    try vm.start();

    if (!waitForSignal(vm, &output.network, 500)) return error.NetworkTimeout;
    if (try vm.join() != .guest_shutdown) return error.UnexpectedRunOutcome;
}

pub fn executeBootBenchmark(
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: []const u8,
    disk_path: []const u8,
) !BootBenchmark {
    const vcpu_count: u8 = 2;
    var create_ns: [benchmark_samples]u64 = undefined;
    var boot_ns: [benchmark_samples]u64 = undefined;
    var total_ns: [benchmark_samples]u64 = undefined;

    for (0..benchmark_samples) |index| {
        var output = BootOutput{};
        const create_start_ns = monotonicNs();
        const vm = try VM.create(allocator, .{
            .memory_bytes = memory_bytes,
            .vcpu_count = vcpu_count,
            .kernel_path = kernel_path,
            .initrd_path = initrd_path,
            .disk_path = disk_path,
            .command_line = command_line,
            .exits_max = exits_max,
        }, x86.SerialSink.bind(BootOutput, &output, BootOutput.write));
        defer vm.destroy();
        const boot_start_ns = monotonicNs();
        try vm.start();
        if (!waitForSignal(vm, &output.ready, 500)) return error.BootReadyTimeout;
        const ready_ns = output.ready_ns.load(.acquire);
        vm.requestStop();
        _ = try vm.join();

        create_ns[index] = boot_start_ns - create_start_ns;
        boot_ns[index] = ready_ns - boot_start_ns;
        total_ns[index] = ready_ns - create_start_ns;
    }
    sortSamples(&create_ns);
    sortSamples(&boot_ns);
    sortSamples(&total_ns);
    return .{
        .samples = benchmark_samples,
        .vcpus = vcpu_count,
        .create_us_min = create_ns[0] / std.time.ns_per_us,
        .boot_us_min = boot_ns[0] / std.time.ns_per_us,
        .boot_us_median = boot_ns[benchmark_samples / 2] / std.time.ns_per_us,
        .total_us_min = total_ns[0] / std.time.ns_per_us,
    };
}

fn monotonicNs() u64 {
    return @intCast(std.Io.Clock.awake.now(global.io()).nanoseconds);
}

fn sortSamples(samples: *[benchmark_samples]u64) void {
    for (1..samples.len) |index| {
        const value = samples[index];
        var destination = index;
        while (destination > 0 and samples[destination - 1] > value) {
            samples[destination] = samples[destination - 1];
            destination -= 1;
        }
        samples[destination] = value;
    }
}

fn waitForSignal(vm: *VM, signal: *const std.atomic.Value(bool), polls_max: usize) bool {
    for (0..polls_max) |_| {
        if (signal.load(.acquire)) return true;
        if (vm.state() == .stopped) return signal.load(.acquire);
        std.Io.Clock.Duration.sleep(.{
            .raw = .{ .nanoseconds = 10 * std.time.ns_per_ms },
            .clock = .awake,
        }, global.io()) catch {};
    }
    vm.requestStop();
    return false;
}

const DiscardOutput = struct {
    fn write(_: *DiscardOutput, _: []const u8) void {}
};

const SmokeOutput = struct {
    const ready_marker = "BOBRVM_CONSOLE_INPUT_READY";
    const accepted_marker = "BOBRVM_CONSOLE_INPUT_OK";
    const network_marker = "BOBRVM_NETWORK_OK";

    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    network: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ready_index: usize = 0,
    accepted_index: usize = 0,
    network_index: usize = 0,

    fn write(self: *SmokeOutput, bytes: []const u8) void {
        var stdout = Stdout{};
        stdout.write(bytes);
        self.feedMarker(bytes, ready_marker, &self.ready_index, &self.ready);
        self.feedMarker(bytes, accepted_marker, &self.accepted_index, &self.accepted);
        self.feedMarker(bytes, network_marker, &self.network_index, &self.network);
    }

    fn feedMarker(
        _: *SmokeOutput,
        bytes: []const u8,
        marker: []const u8,
        index: *usize,
        found: *std.atomic.Value(bool),
    ) void {
        for (bytes) |byte| {
            if (byte == marker[index.*]) {
                index.* += 1;
                if (index.* == marker.len) {
                    found.store(true, .release);
                    index.* = 0;
                }
            } else {
                index.* = @intFromBool(byte == marker[0]);
            }
        }
    }
};

const BootOutput = struct {
    const marker = "BOBRVM_ROOTFS_BOOT_OK";

    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ready_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    marker_index: usize = 0,

    fn write(self: *BootOutput, bytes: []const u8) void {
        if (self.ready.load(.acquire)) return;
        for (bytes) |byte| {
            if (byte == marker[self.marker_index]) {
                self.marker_index += 1;
                if (self.marker_index != marker.len) continue;
                self.ready_ns.store(monotonicNs(), .release);
                self.ready.store(true, .release);
                self.marker_index = 0;
                return;
            }
            self.marker_index = @intFromBool(byte == marker[0]);
        }
    }
};

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

    fn writeFirmwareStats(
        self: *Stdout,
        pci_reads: u64,
        device_reads: [32]u64,
        mmio: x86.Machine.MmioExitStats,
        primary_kicks: u64,
        secondary_notifications: u64,
    ) void {
        var buffer: [320]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "BOBRVM_KVM_FIRMWARE pci_reads={d} " ++
                "slots=2:{d},3:{d},5:{d},6:{d},7:{d},9:{d},10:{d} " ++
                "mmio={d} last_mmio=0x{x} primary_kicks={d} secondary_kicks={d}\n",
            .{
                pci_reads,
                device_reads[2],
                device_reads[3],
                device_reads[5],
                device_reads[6],
                device_reads[7],
                device_reads[9],
                device_reads[10],
                mmio.total,
                mmio.last orelse 0,
                primary_kicks,
                secondary_notifications,
            },
        ) catch unreachable;
        self.write(line);
    }
};
