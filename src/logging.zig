//! Process-wide logging shared by the CLI and C embedding surface.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const global = @import("global.zig");
const os = @import("os/main.zig");

pub const compiled_level: std.log.Level = @enumFromInt(build_options.log_level);

pub const std_options: std.Options = .{
    // Keep expensive debug arguments out of non-debug builds unless the
    // caller explicitly opts in with -Dlog-level=debug.
    .log_level = compiled_level,
    .logFn = log,
};

pub fn enabled(level: std.log.Level) bool {
    return @intFromEnum(level) <= @intFromEnum(compiled_level);
}

fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    macos: {
        if (comptime !builtin.target.os.tag.isDarwin()) break :macos;
        if (!global.state.logging.macos) break :macos;

        const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
        const log_type: os.log.LogType = switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };
        macosLogger(scope).log(
            std.heap.c_allocator,
            log_type,
            prefix ++ format,
            args,
        );
    }

    stderr: {
        if (!global.state.logging.stderr) break :stderr;

        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();

        const level_text = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        nosuspend stderr.file_writer.interface.print(
            level_text ++ prefix ++ format ++ "\n",
            args,
        ) catch break :stderr;
        nosuspend stderr.file_writer.interface.flush() catch break :stderr;
    }
}

/// Apple recommends creating os_log handles once and reusing them. Each Zig
/// scope gets one process-lifetime handle; losing racing creators release theirs.
fn macosLogger(comptime scope: @TypeOf(.EnumLiteral)) *os.log.Log {
    const Scoped = struct {
        var cached: std.atomic.Value(?*os.log.Log) = .init(null);
    };
    if (Scoped.cached.load(.acquire)) |logger| return logger;

    const created = os.log.Log.create(build_options.bundle_id, @tagName(scope));
    if (Scoped.cached.cmpxchgStrong(
        null,
        created,
        .acq_rel,
        .acquire,
    )) |existing| {
        created.release();
        return existing.?;
    }
    return created;
}

test "compiled log level enables equal and higher severity" {
    inline for (std.meta.tags(std.log.Level)) |level| {
        try std.testing.expectEqual(
            @intFromEnum(level) <= @intFromEnum(compiled_level),
            enabled(level),
        );
    }
}
