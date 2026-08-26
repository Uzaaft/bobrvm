//! macOS per-process resource and energy accounting.
//!
//! proc_pid_rusage counters are cumulative for a process lifetime. Taking two
//! snapshots around a controlled interval yields CPU time, wakeups, I/O,
//! instructions, cycles, and energy without sampling the measured process.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    ProcessUnavailable,
    TimebaseUnavailable,
    UnsupportedHost,
};

pub const Snapshot = struct {
    pid: i32,
    user_cpu_ns: u64,
    system_cpu_ns: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    resident_bytes: u64,
    physical_footprint_bytes: u64,
    disk_read_bytes: u64,
    disk_write_bytes: u64,
    instructions: u64,
    cycles: u64,
    energy_nj: ?u64,
};

pub const Delta = struct {
    pid: i32,
    user_cpu_ns: u64,
    system_cpu_ns: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    resident_bytes: u64,
    physical_footprint_bytes: u64,
    disk_read_bytes: u64,
    disk_write_bytes: u64,
    instructions: u64,
    cycles: u64,
    energy_nj: ?u64,

    pub fn between(before: Snapshot, after: Snapshot) Delta {
        std.debug.assert(before.pid == after.pid);
        return .{
            .pid = after.pid,
            .user_cpu_ns = after.user_cpu_ns -| before.user_cpu_ns,
            .system_cpu_ns = after.system_cpu_ns -| before.system_cpu_ns,
            .package_idle_wakeups = after.package_idle_wakeups -|
                before.package_idle_wakeups,
            .interrupt_wakeups = after.interrupt_wakeups -| before.interrupt_wakeups,
            .pageins = after.pageins -| before.pageins,
            .resident_bytes = after.resident_bytes,
            .physical_footprint_bytes = after.physical_footprint_bytes,
            .disk_read_bytes = after.disk_read_bytes -| before.disk_read_bytes,
            .disk_write_bytes = after.disk_write_bytes -| before.disk_write_bytes,
            .instructions = after.instructions -| before.instructions,
            .cycles = after.cycles -| before.cycles,
            .energy_nj = optionalDelta(before.energy_nj, after.energy_nj),
        };
    }

    pub fn cpuTimeNs(self: Delta) u64 {
        return self.user_cpu_ns +| self.system_cpu_ns;
    }
};

pub const Totals = struct {
    user_cpu_ns: u64 = 0,
    system_cpu_ns: u64 = 0,
    package_idle_wakeups: u64 = 0,
    interrupt_wakeups: u64 = 0,
    pageins: u64 = 0,
    resident_bytes: u64 = 0,
    physical_footprint_bytes: u64 = 0,
    disk_read_bytes: u64 = 0,
    disk_write_bytes: u64 = 0,
    instructions: u64 = 0,
    cycles: u64 = 0,
    energy_nj: ?u64 = 0,

    pub fn add(self: *Totals, delta: Delta) void {
        self.user_cpu_ns +|= delta.user_cpu_ns;
        self.system_cpu_ns +|= delta.system_cpu_ns;
        self.package_idle_wakeups +|= delta.package_idle_wakeups;
        self.interrupt_wakeups +|= delta.interrupt_wakeups;
        self.pageins +|= delta.pageins;
        self.resident_bytes +|= delta.resident_bytes;
        self.physical_footprint_bytes +|= delta.physical_footprint_bytes;
        self.disk_read_bytes +|= delta.disk_read_bytes;
        self.disk_write_bytes +|= delta.disk_write_bytes;
        self.instructions +|= delta.instructions;
        self.cycles +|= delta.cycles;
        self.energy_nj = optionalAdd(self.energy_nj, delta.energy_nj);
    }

    pub fn cpuTimeNs(self: Totals) u64 {
        return self.user_cpu_ns +| self.system_cpu_ns;
    }
};

fn optionalDelta(before: ?u64, after: ?u64) ?u64 {
    if (before == null or after == null) return null;
    return after.? -| before.?;
}

fn optionalAdd(total: ?u64, value: ?u64) ?u64 {
    if (total == null or value == null) return null;
    return total.? +| value.?;
}

fn machTicksToNs(ticks: u64, numer: u32, denom: u32) u64 {
    std.debug.assert(numer > 0);
    std.debug.assert(denom > 0);
    const ns = @as(u128, ticks) * numer / denom;
    return @intCast(@min(ns, @as(u128, std.math.maxInt(u64))));
}

pub fn sample(pid: i32) Error!Snapshot {
    if (builtin.os.tag != .macos) return error.UnsupportedHost;
    return Darwin.sample(pid);
}

const Darwin = struct {
    const flavor_v4: c_int = 4;
    const flavor_v6: c_int = 6;

    const user_time = 0;
    const system_time = 1;
    const package_idle_wakeups = 2;
    const interrupt_wakeups = 3;
    const pageins = 4;
    const resident_bytes = 6;
    const physical_footprint_bytes = 7;
    const disk_read_bytes = 16;
    const disk_write_bytes = 17;
    const instructions = 29;
    const cycles = 30;
    const energy_nj = 40;

    /// Matches the current V6 layout; older flavors write a shorter prefix.
    const RusageInfo = extern struct {
        uuid: [16]u8,
        fields: [56]u64,
    };

    extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfo) c_int;

    fn sample(pid: i32) Error!Snapshot {
        var info: RusageInfo = std.mem.zeroes(RusageInfo);
        var has_energy = true;
        if (proc_pid_rusage(pid, flavor_v6, &info) != 0) {
            info = std.mem.zeroes(RusageInfo);
            has_energy = false;
            if (proc_pid_rusage(pid, flavor_v4, &info) != 0) {
                return error.ProcessUnavailable;
            }
        }
        var timebase: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) {
            return error.TimebaseUnavailable;
        }
        return .{
            .pid = pid,
            .user_cpu_ns = machTicksToNs(
                info.fields[user_time],
                timebase.numer,
                timebase.denom,
            ),
            .system_cpu_ns = machTicksToNs(
                info.fields[system_time],
                timebase.numer,
                timebase.denom,
            ),
            .package_idle_wakeups = info.fields[package_idle_wakeups],
            .interrupt_wakeups = info.fields[interrupt_wakeups],
            .pageins = info.fields[pageins],
            .resident_bytes = info.fields[resident_bytes],
            .physical_footprint_bytes = info.fields[physical_footprint_bytes],
            .disk_read_bytes = info.fields[disk_read_bytes],
            .disk_write_bytes = info.fields[disk_write_bytes],
            .instructions = info.fields[instructions],
            .cycles = info.fields[cycles],
            .energy_nj = if (has_energy) info.fields[energy_nj] else null,
        };
    }
};

test "host metrics converts Mach ticks without overflowing" {
    try std.testing.expectEqual(@as(u64, 1_000), machTicksToNs(24, 125, 3));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        machTicksToNs(std.math.maxInt(u64), std.math.maxInt(u32), 1),
    );
}

test "host metrics delta and totals saturate and preserve unavailable energy" {
    const before = Snapshot{
        .pid = 7,
        .user_cpu_ns = 100,
        .system_cpu_ns = 50,
        .package_idle_wakeups = 10,
        .interrupt_wakeups = 20,
        .pageins = 2,
        .resident_bytes = 1,
        .physical_footprint_bytes = 2,
        .disk_read_bytes = 30,
        .disk_write_bytes = 40,
        .instructions = 50,
        .cycles = 60,
        .energy_nj = 70,
    };
    var after = before;
    after.user_cpu_ns = 150;
    after.system_cpu_ns = 80;
    after.package_idle_wakeups = 9;
    after.physical_footprint_bytes = 200;
    after.energy_nj = null;

    const delta = Delta.between(before, after);
    try std.testing.expectEqual(@as(u64, 80), delta.cpuTimeNs());
    try std.testing.expectEqual(@as(u64, 0), delta.package_idle_wakeups);
    try std.testing.expectEqual(@as(u64, 200), delta.physical_footprint_bytes);
    try std.testing.expectEqual(@as(?u64, null), delta.energy_nj);
    var totals = Totals{};
    totals.add(delta);
    try std.testing.expectEqual(@as(?u64, null), totals.energy_nj);
}

test "host metrics samples the current macOS process" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const current = try sample(std.c.getpid());
    try std.testing.expectEqual(std.c.getpid(), current.pid);
    try std.testing.expect(current.resident_bytes > 0);
    try std.testing.expect(current.physical_footprint_bytes > 0);
}
