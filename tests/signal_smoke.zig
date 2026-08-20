const std = @import("std");
const signal = @import("signal");

fn cleanup() void {
    const message = "cleanup\n";
    _ = std.c.write(std.posix.STDOUT_FILENO, message.ptr, message.len);
}

fn hostHandler(_: std.posix.SIG) callconv(.c) void {
    const message = "host\n";
    _ = std.c.write(std.posix.STDOUT_FILENO, message.ptr, message.len);
}

fn runChild() !void {
    signal.registerCleanup(cleanup);
    try std.posix.raise(.TERM);
    return error.SignalDidNotTerminate;
}

fn runUnregisterChild() !void {
    const host = std.posix.Sigaction{
        .handler = .{ .handler = hostHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &host, null);
    signal.registerCleanup(cleanup);
    signal.unregisterCleanup();
    try std.posix.raise(.TERM);
}

fn expectChild(result: std.process.RunResult) !void {
    switch (result.term) {
        .signal => |actual| if (actual != .TERM) {
            std.debug.print("expected SIGTERM, got {any}\n", .{result.term});
            return error.UnexpectedSignal;
        },
        else => {
            std.debug.print("expected SIGTERM, got {any}\nstderr:\n{s}\n", .{
                result.term,
                result.stderr,
            });
            return error.UnexpectedTermination;
        },
    }
    if (!std.mem.eql(u8, result.stdout, "cleanup\n")) {
        std.debug.print("expected cleanup marker, got:\n{s}\n", .{result.stdout});
        return error.CleanupNotCalled;
    }
}

fn expectUnregisterChild(result: std.process.RunResult) !void {
    switch (result.term) {
        .exited => |code| if (code != 0) return error.UnexpectedExit,
        else => return error.UnexpectedTermination,
    }
    if (!std.mem.eql(u8, result.stdout, "host\n")) return error.HostHandlerNotRestored;
}

fn runParentChild(
    init: std.process.Init,
    executable: []const u8,
    mode: []const u8,
) !std.process.RunResult {
    return std.process.run(init.gpa, init.io, .{
        .argv = &.{ executable, mode },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    const executable = args.next() orelse return error.MissingExecutablePath;
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--child")) return runChild();
        if (std.mem.eql(u8, arg, "--unregister-child")) return runUnregisterChild();
        return error.UnknownArgument;
    }

    const signal_result = try runParentChild(init, executable, "--child");
    defer init.gpa.free(signal_result.stdout);
    defer init.gpa.free(signal_result.stderr);
    try expectChild(signal_result);

    const unregister_result = try runParentChild(init, executable, "--unregister-child");
    defer init.gpa.free(unregister_result.stdout);
    defer init.gpa.free(unregister_result.stderr);
    try expectUnregisterChild(unregister_result);
}
