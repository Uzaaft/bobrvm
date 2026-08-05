//! Statically-specialized guest runtime.
//!
//! Backend selection is dynamic only at the outer tagged union. Lifecycle
//! calls inside each variant are monomorphized and require no vtable.

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const comptime_contract = @import("../comptime.zig");

pub const State = enum(u8) {
    stopped,
    starting,
    running,
    pausing,
    paused,
    stopping,
    failed,
};

pub fn Runtime(comptime Backend: type) type {
    comptime validateBackend(Backend);

    return struct {
        backend: Backend,
        state: State,

        const Self = @This();

        pub fn init(config: *const Backend.Config) Backend.InitError!Self {
            const backend = try Backend.init(config);
            return .{ .backend = backend, .state = .stopped };
        }

        pub fn deinit(self: *Self) void {
            assert(self.state != .starting);
            assert(self.state != .pausing);
            self.backend.deinit();
            self.state = .stopped;
        }

        pub fn start(self: *Self) Backend.StartError!void {
            if (self.state != .stopped and self.state != .paused) {
                return error.InvalidState;
            }
            self.state = .starting;
            self.backend.start() catch |err| {
                self.state = .failed;
                return err;
            };
        }

        pub fn requestStop(self: *Self) void {
            if (self.state == .stopped or self.state == .stopping) return;
            self.state = .stopping;
            self.backend.requestStop();
        }

        pub fn pause(self: *Self) void {
            if (self.state != .running) return;
            self.state = .pausing;
            self.backend.pause();
        }

        pub fn resumeVM(self: *Self) void {
            if (self.state != .paused) return;
            self.state = .starting;
            self.backend.resumeVM();
        }

        pub fn tick(self: *Self) void {
            self.backend.tick();
            if (self.backend.state()) |state| self.state = state;
        }

        pub fn displayView(self: *Self) ?*anyopaque {
            return self.backend.displayView();
        }
    };
}

fn validateBackend(comptime Backend: type) void {
    comptime_contract.requireDecl(Backend, "Config");
    comptime_contract.requireDecl(Backend, "InitError");
    comptime_contract.requireDecl(Backend, "StartError");
    comptime_contract.requireFn(
        Backend,
        "init",
        fn (*const Backend.Config) Backend.InitError!Backend,
    );
    comptime_contract.requireFn(Backend, "deinit", fn (*Backend) void);
    comptime_contract.requireFn(Backend, "start", fn (*Backend) Backend.StartError!void);
    comptime_contract.requireFn(Backend, "requestStop", fn (*Backend) void);
    comptime_contract.requireFn(Backend, "pause", fn (*Backend) void);
    comptime_contract.requireFn(Backend, "resumeVM", fn (*Backend) void);
    comptime_contract.requireFn(Backend, "tick", fn (*Backend) void);
    comptime_contract.requireFn(Backend, "state", fn (*Backend) ?State);
    comptime_contract.requireFn(Backend, "displayView", fn (*Backend) ?*anyopaque);
}

test "runtime specializes lifecycle without a vtable" {
    const Backend = struct {
        starts: u8 = 0,
        current: ?State = null,

        pub const Config = struct {};
        pub const InitError = error{};
        pub const StartError = error{ InvalidState, StartFailed };

        pub fn init(_: *const Config) InitError!@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn start(self: *@This()) StartError!void {
            self.starts += 1;
            self.current = .running;
        }
        pub fn requestStop(self: *@This()) void {
            self.current = .stopped;
        }
        pub fn pause(self: *@This()) void {
            self.current = .paused;
        }
        pub fn resumeVM(self: *@This()) void {
            self.current = .running;
        }
        pub fn tick(_: *@This()) void {}
        pub fn state(self: *@This()) ?State {
            const result = self.current;
            self.current = null;
            return result;
        }
        pub fn displayView(_: *@This()) ?*anyopaque {
            return null;
        }
    };

    var runtime = try Runtime(Backend).init(&.{});
    defer runtime.deinit();
    try runtime.start();
    try std.testing.expectEqual(State.starting, runtime.state);
    runtime.tick();
    try std.testing.expectEqual(State.running, runtime.state);
    try std.testing.expectEqual(@as(u8, 1), runtime.backend.starts);
    runtime.pause();
    runtime.tick();
    try std.testing.expectEqual(State.paused, runtime.state);
    runtime.resumeVM();
    runtime.tick();
    try std.testing.expectEqual(State.running, runtime.state);
    runtime.requestStop();
    runtime.tick();
    try std.testing.expectEqual(State.stopped, runtime.state);
}
