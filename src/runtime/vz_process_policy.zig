//! Switch the Virtualization.framework helper between responsive and efficient
//! host scheduling as guest work starts and stops.

pub const Controller = @This();

const std = @import("std");

const global = @import("../global.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vz_policy);

const helper_path_suffix = "/com.apple.Virtualization.VirtualMachine";
const helper_count_max: usize = 64;
const process_count_max: usize = 4096;
const process_path_bytes_max: usize = 4096;
const sample_interval_ns: u64 = 250 * std.time.ns_per_ms;
const background_delay_ns: u64 = std.time.ns_per_s;
const busy_percent: u64 = 2;
const prio_darwin_process: c_int = 4;
const prio_darwin_background: c_int = 0x1000;
const rusage_info_v0: c_int = 0;

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffer_size: c_int) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: *anyopaque, buffer_size: u32) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfo) c_int;
extern "c" fn setpriority(which: c_int, who: u32, priority: c_int) c_int;
extern "c" fn mach_absolute_time() u64;

alloc: Allocator,
mutex: std.Io.Mutex = .init,
existing_helpers: [helper_count_max]c_int = @splat(0),
existing_helper_count: usize = 0,
helper_pid: c_int = 0,
mode: Mode = .foreground,
timebase: std.c.mach_timebase_info_data,
last_sample_ns: u64 = 0,
last_cpu_ns: u64 = 0,
last_activity_ns: u64 = 0,

const Mode = enum {
    foreground,
    background,
};

const RusageInfo = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    package_idle_wakeups: u64,
    interrupt_wakeups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    physical_footprint: u64,
    process_start_time: u64,
    process_exit_time: u64,
};

pub fn create(alloc: Allocator) !*Controller {
    const self = try alloc.create(Controller);
    errdefer alloc.destroy(self);
    var timebase: std.c.mach_timebase_info_data = undefined;
    if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) {
        return error.TimebaseUnavailable;
    }
    self.* = .{
        .alloc = alloc,
        .timebase = timebase,
    };
    self.existing_helper_count = listHelpers(&self.existing_helpers);
    return self;
}

pub fn destroy(self: *Controller) void {
    self.mutex.lockUncancelable(global.io());
    self.setModeLocked(.foreground);
    self.mutex.unlock(global.io());
    const alloc = self.alloc;
    self.* = undefined;
    alloc.destroy(self);
}

/// Associate the one VZ XPC helper created after this controller's snapshot.
/// Ambiguous discovery disables policy changes rather than touching another VM.
pub fn discover(self: *Controller) void {
    var helpers: [helper_count_max]c_int = @splat(0);
    const helper_count = listHelpers(&helpers);
    const helper_pid = selectNewHelper(
        self.existing_helpers[0..self.existing_helper_count],
        helpers[0..helper_count],
    ) orelse return;
    const cpu_ns = sampleCpuNs(helper_pid, self.timebase) orelse return;
    const now_ns = monotonicNs(self.timebase);

    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.helper_pid != 0) return;
    self.helper_pid = helper_pid;
    self.last_sample_ns = now_ns;
    self.last_cpu_ns = cpu_ns;
    self.last_activity_ns = now_ns;
    log.debug("tracking VZ helper pid {d}", .{helper_pid});
}

/// Promote the guest before accepting host work. This is safe from the Docker
/// and MiniNat worker threads; policy transitions are serialized here.
pub fn activity(self: *Controller) void {
    const now_ns = monotonicNs(self.timebase);
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.last_activity_ns = now_ns;
    self.setModeLocked(.foreground);
}

/// Sample at a bounded rate. Quiet guests move to efficiency cores; detached
/// CPU work is promoted on the next sample even without a host connection.
pub fn tick(self: *Controller, active_connections: u32) void {
    const now_ns = monotonicNs(self.timebase);
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    if (self.helper_pid == 0) return;
    if (now_ns -| self.last_sample_ns < sample_interval_ns) return;

    const cpu_ns = sampleCpuNs(self.helper_pid, self.timebase) orelse {
        self.helper_pid = 0;
        self.mode = .foreground;
        return;
    };
    const elapsed_ns = now_ns -| self.last_sample_ns;
    const cpu_delta_ns = cpu_ns -| self.last_cpu_ns;
    self.last_sample_ns = now_ns;
    self.last_cpu_ns = cpu_ns;

    if (active_connections > 0 or isBusy(cpu_delta_ns, elapsed_ns)) {
        self.last_activity_ns = now_ns;
        self.setModeLocked(.foreground);
        return;
    }
    if (now_ns -| self.last_activity_ns >= background_delay_ns) {
        self.setModeLocked(.background);
    }
}

fn setModeLocked(self: *Controller, mode: Mode) void {
    if (self.helper_pid == 0 or self.mode == mode) return;
    const priority: c_int = if (mode == .background) prio_darwin_background else 0;
    if (setpriority(prio_darwin_process, @intCast(self.helper_pid), priority) != 0) {
        log.warn("could not set VZ helper pid {d} to {s}", .{
            self.helper_pid,
            @tagName(mode),
        });
        return;
    }
    self.mode = mode;
}

fn listHelpers(buffer: *[helper_count_max]c_int) usize {
    var pids: [process_count_max]c_int = undefined;
    const process_count_raw = proc_listallpids(&pids, @sizeOf(@TypeOf(pids)));
    if (process_count_raw <= 0) return 0;
    const process_count: usize = @min(@as(usize, @intCast(process_count_raw)), pids.len);
    var helper_count: usize = 0;
    for (pids[0..process_count]) |pid| {
        if (pid <= 0 or !isHelper(pid)) continue;
        if (helper_count == buffer.len) break;
        buffer[helper_count] = pid;
        helper_count += 1;
    }
    return helper_count;
}

fn isHelper(pid: c_int) bool {
    var path: [process_path_bytes_max]u8 = undefined;
    const path_len = proc_pidpath(pid, &path, path.len);
    if (path_len <= 0) return false;
    return std.mem.endsWith(u8, path[0..@intCast(path_len)], helper_path_suffix);
}

fn selectNewHelper(existing: []const c_int, current: []const c_int) ?c_int {
    var selected: ?c_int = null;
    for (current) |pid| {
        if (std.mem.indexOfScalar(c_int, existing, pid) != null) continue;
        if (selected != null) return null;
        selected = pid;
    }
    return selected;
}

fn sampleCpuNs(pid: c_int, timebase: std.c.mach_timebase_info_data) ?u64 {
    var usage: RusageInfo = std.mem.zeroes(RusageInfo);
    if (proc_pid_rusage(pid, rusage_info_v0, &usage) != 0) return null;
    return ticksToNs(usage.user_time +| usage.system_time, timebase);
}

fn monotonicNs(timebase: std.c.mach_timebase_info_data) u64 {
    return ticksToNs(mach_absolute_time(), timebase);
}

fn ticksToNs(ticks: u64, timebase: std.c.mach_timebase_info_data) u64 {
    const ns = @as(u128, ticks) * timebase.numer / timebase.denom;
    return @intCast(@min(ns, @as(u128, std.math.maxInt(u64))));
}

fn isBusy(cpu_delta_ns: u64, elapsed_ns: u64) bool {
    if (elapsed_ns == 0) return false;
    return @as(u128, cpu_delta_ns) * 100 >= @as(u128, elapsed_ns) * busy_percent;
}

test "VZ policy selects exactly one newly created helper" {
    try std.testing.expectEqual(@as(?c_int, 13), selectNewHelper(&.{ 7, 11 }, &.{ 7, 11, 13 }));
    try std.testing.expectEqual(@as(?c_int, null), selectNewHelper(&.{7}, &.{ 7, 11, 13 }));
    try std.testing.expectEqual(@as(?c_int, null), selectNewHelper(&.{7}, &.{7}));
}

test "VZ policy classifies sustained work without overflowing" {
    try std.testing.expect(isBusy(20, 1000));
    try std.testing.expect(!isBusy(19, 1000));
    try std.testing.expect(isBusy(std.math.maxInt(u64), std.math.maxInt(u64)));
}
