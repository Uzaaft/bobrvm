//! Thin GTK host application for the shared Linux VM lifecycle.

const std = @import("std");
const VM = @import("VM.zig");
const run_kernel = @import("run_kernel.zig");
const x86 = @import("../machine/x86/main.zig");

const c = struct {
    pub const GtkApplication = opaque {};
    pub const GtkWindow = opaque {};
    pub const GtkBox = opaque {};
    pub const GtkLabel = opaque {};
    pub const GtkWidget = opaque {};

    pub const gboolean = c_int;
    pub const FALSE: gboolean = 0;
    pub const TRUE: gboolean = 1;
    pub const G_SOURCE_REMOVE: gboolean = 0;
    pub const G_SOURCE_CONTINUE: gboolean = 1;
    pub const G_APPLICATION_DEFAULT_FLAGS: c_uint = 0;
    pub const GTK_ORIENTATION_VERTICAL: c_int = 1;

    pub extern fn gtk_application_new(
        application_id: [*:0]const u8,
        flags: c_uint,
    ) ?*GtkApplication;
    pub extern fn gtk_application_window_new(application: *GtkApplication) ?*GtkWidget;
    pub extern fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
    pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
    pub extern fn gtk_window_set_child(window: *GtkWindow, child: *GtkWidget) void;
    pub extern fn gtk_window_present(window: *GtkWindow) void;
    pub extern fn gtk_window_destroy(window: *GtkWindow) void;
    pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) ?*GtkWidget;
    pub extern fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;
    pub extern fn gtk_label_new(text: [*:0]const u8) ?*GtkWidget;
    pub extern fn gtk_label_set_text(label: *GtkLabel, text: [*:0]const u8) void;
    pub extern fn gtk_widget_set_margin_top(widget: *GtkWidget, margin: c_int) void;
    pub extern fn gtk_widget_set_margin_bottom(widget: *GtkWidget, margin: c_int) void;
    pub extern fn gtk_widget_set_margin_start(widget: *GtkWidget, margin: c_int) void;
    pub extern fn gtk_widget_set_margin_end(widget: *GtkWidget, margin: c_int) void;
    pub extern fn g_application_run(
        application: *anyopaque,
        argc: c_int,
        argv: ?[*]?[*:0]u8,
    ) c_int;
    pub extern fn g_object_unref(object: *anyopaque) void;
    pub extern fn g_signal_connect_data(
        instance: *anyopaque,
        detailed_signal: [*:0]const u8,
        handler: *const anyopaque,
        data: ?*anyopaque,
        destroy_data: ?*const anyopaque,
        connect_flags: c_uint,
    ) c_ulong;
    pub extern fn g_timeout_add(
        interval_ms: c_uint,
        function: *const fn (?*anyopaque) callconv(.c) gboolean,
        data: ?*anyopaque,
    ) c_uint;
};

const memory_bytes: usize = 512 * 1024 * 1024;
const exits_max: u64 = 100_000_000;

const State = struct {
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: ?[]const u8,
    disk_path: ?[]const u8,
    vm: ?*VM = null,
    window: ?*c.GtkWindow = null,
    status: ?*c.GtkLabel = null,
    closing: bool = false,

    fn start(self: *State) void {
        const vm = VM.create(self.allocator, .{
            .memory_bytes = memory_bytes,
            .kernel_path = self.kernel_path,
            .initrd_path = self.initrd_path,
            .disk_path = self.disk_path,
            .command_line = run_kernel.command_line,
            .exits_max = exits_max,
        }, x86.SerialSink.bind(State, self, writeSerial)) catch |err| {
            self.setError(err);
            return;
        };
        self.vm = vm;
        vm.start() catch |err| {
            vm.destroy();
            self.vm = null;
            self.setError(err);
            return;
        };
        c.gtk_label_set_text(self.status.?, "Running");
        _ = c.g_timeout_add(16, tick, self);
    }

    fn finish(self: *State) void {
        const vm = self.vm orelse return;
        const outcome = vm.join() catch |err| {
            self.setError(err);
            vm.destroy();
            self.vm = null;
            return;
        };
        vm.destroy();
        self.vm = null;
        c.gtk_label_set_text(self.status.?, switch (outcome) {
            .guest_shutdown => "Guest shut down",
            .stopped => "Stopped",
        });
        if (self.closing) c.gtk_window_destroy(self.window.?);
    }

    fn setError(self: *State, err: anyerror) void {
        var buffer: [160]u8 = undefined;
        const message = std.fmt.bufPrintZ(&buffer, "VM error: {s}", .{@errorName(err)}) catch
            "VM error";
        c.gtk_label_set_text(self.status.?, message.ptr);
    }

    fn writeSerial(_: *State, bytes: []const u8) void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const written = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
            if (written <= 0) return;
            remaining = remaining[@intCast(written)..];
        }
    }
};

pub fn main(minimal: std.process.Init.Minimal) void {
    var args = minimal.args.iterate();
    _ = args.skip();
    const kernel_path = args.next() orelse {
        writeStderr("usage: bobrvm-gtk <bzImage> [initrd] [writable-disk]\n");
        std.process.exit(2);
    };
    var state = State{
        .allocator = std.heap.c_allocator,
        .kernel_path = kernel_path,
        .initrd_path = args.next(),
        .disk_path = args.next(),
    };
    const app = c.gtk_application_new("com.bobrvm.Bobrvm", c.G_APPLICATION_DEFAULT_FLAGS) orelse {
        writeStderr("error: unable to create GTK application\n");
        std.process.exit(1);
    };
    defer c.g_object_unref(app);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&activate), &state, null, 0);
    const status = c.g_application_run(@ptrCast(app), 0, null);
    if (state.vm) |vm| {
        vm.requestStop();
        state.finish();
    }
    if (status != 0) std.process.exit(@intCast(status));
}

fn activate(app: *c.GtkApplication, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const window_widget = c.gtk_application_window_new(app) orelse return;
    const window: *c.GtkWindow = @ptrCast(window_widget);
    state.window = window;
    c.gtk_window_set_title(window, "bobrvm");
    c.gtk_window_set_default_size(window, 720, 160);
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12) orelse return;
    const box: *c.GtkBox = @ptrCast(box_widget);
    c.gtk_widget_set_margin_top(@ptrCast(box), 24);
    c.gtk_widget_set_margin_bottom(@ptrCast(box), 24);
    c.gtk_widget_set_margin_start(@ptrCast(box), 24);
    c.gtk_widget_set_margin_end(@ptrCast(box), 24);
    const title = c.gtk_label_new("bobrvm Linux virtual machine") orelse return;
    const status_widget = c.gtk_label_new("Starting…") orelse return;
    const status: *c.GtkLabel = @ptrCast(status_widget);
    state.status = status;
    c.gtk_box_append(box, title);
    c.gtk_box_append(box, @ptrCast(status));
    c.gtk_window_set_child(window, @ptrCast(box));
    _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&closeRequest), state, null, 0);
    c.gtk_window_present(window);
    state.start();
}

fn closeRequest(_: *c.GtkWindow, userdata: ?*anyopaque) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.FALSE));
    const vm = state.vm orelse return c.FALSE;
    state.closing = true;
    vm.requestStop();
    c.gtk_label_set_text(state.status.?, "Stopping…");
    return c.TRUE;
}

fn tick(userdata: ?*anyopaque) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.G_SOURCE_REMOVE));
    const vm = state.vm orelse return c.G_SOURCE_REMOVE;
    if (vm.state() != .stopped) return c.G_SOURCE_CONTINUE;
    state.finish();
    return c.G_SOURCE_REMOVE;
}

fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}
