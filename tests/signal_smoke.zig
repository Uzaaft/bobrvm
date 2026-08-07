const std = @import("std");
const signal = @import("signal");

fn cleanup() void {
    const message = "cleanup\n";
    _ = std.c.write(std.posix.STDOUT_FILENO, message.ptr, message.len);
}

fn runChild() !void {
    signal.registerCleanup(cleanup);
    try std.posix.raise(.TERM);
    return error.SignalDidNotTerminate;
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

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    const executable = args.next() orelse return error.MissingExecutablePath;
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--child")) return runChild();
        return error.UnknownArgument;
    }

    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ executable, "--child" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer {
        init.gpa.free(result.stdout);
        init.gpa.free(result.stderr);
    }
    try expectChild(result);
}
