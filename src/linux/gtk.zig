//! Thin GTK host application for the shared Linux VM lifecycle.

const std = @import("std");
const global = @import("../global.zig");
const VM = @import("VM.zig");
const run_kernel = @import("run_kernel.zig");
const x86 = @import("../machine/x86/main.zig");

const c = struct {
    pub const GtkApplication = opaque {};
    pub const GtkWindow = opaque {};
    pub const GtkBox = opaque {};
    pub const GtkEventController = opaque {};
    pub const GtkEventControllerKey = opaque {};
    pub const GtkLabel = opaque {};
    pub const GtkScrolledWindow = opaque {};
    pub const GtkWidget = opaque {};

    pub const gboolean = c_int;
    pub const FALSE: gboolean = 0;
    pub const TRUE: gboolean = 1;
    pub const G_SOURCE_REMOVE: gboolean = 0;
    pub const G_SOURCE_CONTINUE: gboolean = 1;
    pub const G_APPLICATION_DEFAULT_FLAGS: c_uint = 0;
    pub const GTK_ORIENTATION_VERTICAL: c_int = 1;
    pub const GDK_CONTROL_MASK: c_uint = 1 << 2;

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
    pub extern fn gtk_label_set_selectable(label: *GtkLabel, setting: gboolean) void;
    pub extern fn gtk_label_set_text(label: *GtkLabel, text: [*:0]const u8) void;
    pub extern fn gtk_label_set_xalign(label: *GtkLabel, alignment: f32) void;
    pub extern fn gtk_label_set_yalign(label: *GtkLabel, alignment: f32) void;
    pub extern fn gtk_scrolled_window_new() ?*GtkWidget;
    pub extern fn gtk_scrolled_window_set_child(
        scrolled_window: *GtkScrolledWindow,
        child: *GtkWidget,
    ) void;
    pub extern fn gtk_event_controller_key_new() ?*GtkEventController;
    pub extern fn gtk_widget_add_controller(
        widget: *GtkWidget,
        controller: *GtkEventController,
    ) void;
    pub extern fn gtk_widget_add_css_class(widget: *GtkWidget, class_name: [*:0]const u8) void;
    pub extern fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: gboolean) void;
    pub extern fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: gboolean) void;
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
    pub extern fn gdk_keyval_to_unicode(keyval: c_uint) c_uint;
    pub extern fn g_unichar_to_utf8(character: c_uint, output: [*]u8) c_int;
};

const memory_bytes: usize = 512 * 1024 * 1024;
const exits_max: u64 = 100_000_000;
const output_pending_bytes: usize = 64 * 1024;
const console_history_bytes: usize = 64 * 1024;

const State = struct {
    allocator: std.mem.Allocator,
    kernel_path: []const u8,
    initrd_path: ?[]const u8,
    disk_path: ?[]const u8,
    vm: ?*VM = null,
    window: ?*c.GtkWindow = null,
    status: ?*c.GtkLabel = null,
    console: ?*c.GtkLabel = null,
    output_lock: std.Io.Mutex = .init,
    output_pending: [output_pending_bytes]u8 = undefined,
    output_head: usize = 0,
    output_len: usize = 0,
    console_history: [console_history_bytes + 1]u8 = undefined,
    console_len: usize = 0,
    escape_state: enum { none, escape, csi } = .none,
    closing: bool = false,

    fn start(self: *State) void {
        const vm = VM.create(self.allocator, .{
            .memory_bytes = memory_bytes,
            .kernel_path = self.kernel_path,
            .initrd_path = self.initrd_path,
            .disk_path = self.disk_path,
            .network_enabled = true,
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

    fn writeSerial(self: *State, bytes: []const u8) void {
        self.queueOutput(bytes);
        var remaining = bytes;
        while (remaining.len > 0) {
            const written = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
            if (written <= 0) return;
            remaining = remaining[@intCast(written)..];
        }
    }

    fn queueOutput(self: *State, bytes: []const u8) void {
        self.output_lock.lockUncancelable(global.io());
        defer self.output_lock.unlock(global.io());
        for (bytes) |byte| {
            if (self.output_len == self.output_pending.len) {
                self.output_head = (self.output_head + 1) % self.output_pending.len;
                self.output_len -= 1;
            }
            const tail = (self.output_head + self.output_len) % self.output_pending.len;
            self.output_pending[tail] = byte;
            self.output_len += 1;
        }
    }

    fn flushOutput(self: *State) void {
        var batch: [4096]u8 = undefined;
        while (true) {
            self.output_lock.lockUncancelable(global.io());
            const count = @min(batch.len, self.output_len);
            for (batch[0..count], 0..) |*byte, index| {
                byte.* = self.output_pending[(self.output_head + index) % self.output_pending.len];
            }
            self.output_head = (self.output_head + count) % self.output_pending.len;
            self.output_len -= count;
            self.output_lock.unlock(global.io());
            if (count == 0) return;
            self.appendConsole(batch[0..count]);
        }
    }

    fn appendConsole(self: *State, bytes: []const u8) void {
        var cleaned: [4096]u8 = undefined;
        var cleaned_len: usize = 0;
        for (bytes) |byte| {
            if (self.filterConsoleByte(byte)) |printable| {
                cleaned[cleaned_len] = printable;
                cleaned_len += 1;
            }
        }
        if (cleaned_len == 0) return;
        if (cleaned_len > self.console_history.len - 1) unreachable;
        const retained_max = self.console_history.len - 1 - cleaned_len;
        if (self.console_len > retained_max) {
            const removed = self.console_len - retained_max;
            std.mem.copyForwards(
                u8,
                self.console_history[0..retained_max],
                self.console_history[removed..self.console_len],
            );
            self.console_len = retained_max;
        }
        @memcpy(self.console_history[self.console_len..][0..cleaned_len], cleaned[0..cleaned_len]);
        self.console_len += cleaned_len;
        self.console_history[self.console_len] = 0;
        c.gtk_label_set_text(self.console.?, self.console_history[0..self.console_len :0].ptr);
    }

    fn filterConsoleByte(self: *State, byte: u8) ?u8 {
        switch (self.escape_state) {
            .none => if (byte == 0x1b) {
                self.escape_state = .escape;
                return null;
            },
            .escape => {
                self.escape_state = if (byte == '[') .csi else .none;
                return null;
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) self.escape_state = .none;
                return null;
            },
        }
        if (byte == '\r') return null;
        if (byte == '\n' or byte == '\t' or (byte >= 0x20 and byte < 0x7f)) return byte;
        return if (byte >= 0x80) '?' else null;
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
    c.gtk_window_set_default_size(window, 900, 640);
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12) orelse return;
    const box: *c.GtkBox = @ptrCast(box_widget);
    c.gtk_widget_set_margin_top(@ptrCast(box), 16);
    c.gtk_widget_set_margin_bottom(@ptrCast(box), 16);
    c.gtk_widget_set_margin_start(@ptrCast(box), 16);
    c.gtk_widget_set_margin_end(@ptrCast(box), 16);
    const title = c.gtk_label_new("bobrvm Linux virtual machine") orelse return;
    const status_widget = c.gtk_label_new("Starting…") orelse return;
    const status: *c.GtkLabel = @ptrCast(status_widget);
    state.status = status;
    const console_widget = c.gtk_label_new("") orelse return;
    const console: *c.GtkLabel = @ptrCast(console_widget);
    state.console = console;
    c.gtk_label_set_selectable(console, c.TRUE);
    c.gtk_label_set_xalign(console, 0);
    c.gtk_label_set_yalign(console, 0);
    c.gtk_widget_add_css_class(console_widget, "monospace");
    c.gtk_widget_set_hexpand(console_widget, c.TRUE);
    c.gtk_widget_set_vexpand(console_widget, c.TRUE);
    const scrolled_widget = c.gtk_scrolled_window_new() orelse return;
    const scrolled: *c.GtkScrolledWindow = @ptrCast(scrolled_widget);
    c.gtk_widget_set_hexpand(scrolled_widget, c.TRUE);
    c.gtk_widget_set_vexpand(scrolled_widget, c.TRUE);
    c.gtk_scrolled_window_set_child(scrolled, console_widget);
    c.gtk_box_append(box, title);
    c.gtk_box_append(box, @ptrCast(status));
    c.gtk_box_append(box, scrolled_widget);
    c.gtk_window_set_child(window, @ptrCast(box));
    const keys = c.gtk_event_controller_key_new() orelse return;
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&keyPressed), state, null, 0);
    c.gtk_widget_add_controller(window_widget, keys);
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
    state.flushOutput();
    const vm = state.vm orelse return c.G_SOURCE_REMOVE;
    if (vm.state() != .stopped) return c.G_SOURCE_CONTINUE;
    state.finish();
    return c.G_SOURCE_REMOVE;
}

fn keyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    userdata: ?*anyopaque,
) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.FALSE));
    const vm = state.vm orelse return c.FALSE;
    const sequence = keySequence(keyval, modifiers) orelse return c.FALSE;
    const written = vm.writeConsole(sequence) catch return c.FALSE;
    return if (written == sequence.len) c.TRUE else c.FALSE;
}

fn keySequence(keyval: c_uint, modifiers: c_uint) ?[]const u8 {
    return switch (keyval) {
        0xff08 => "\x7f",
        0xff09 => "\t",
        0xff0d => "\r",
        0xff1b => "\x1b",
        0xff50 => "\x1b[H",
        0xff51 => "\x1b[D",
        0xff52 => "\x1b[A",
        0xff53 => "\x1b[C",
        0xff54 => "\x1b[B",
        0xff57 => "\x1b[F",
        0xffff => "\x1b[3~",
        else => unicodeKeySequence(keyval, modifiers),
    };
}

threadlocal var key_buffer: [6]u8 = undefined;

fn unicodeKeySequence(keyval: c_uint, modifiers: c_uint) ?[]const u8 {
    const character = c.gdk_keyval_to_unicode(keyval);
    if (character == 0) return null;
    if (modifiers & c.GDK_CONTROL_MASK != 0) {
        const control: ?u8 = switch (character) {
            ' ', '@'...'_', 'a'...'z' => @truncate(character & 0x1f),
            '?' => 0x7f,
            else => null,
        };
        if (control) |byte| {
            key_buffer[0] = byte;
            return key_buffer[0..1];
        }
    }
    const len = c.g_unichar_to_utf8(character, &key_buffer);
    if (len <= 0 or len > key_buffer.len) return null;
    return key_buffer[0..@intCast(len)];
}

fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, bytes.ptr, bytes.len);
}
