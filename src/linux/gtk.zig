//! Thin GTK host application for the shared Linux VM lifecycle.

const std = @import("std");
const disk = @import("../disk.zig");
const global = @import("../global.zig");
const AppConfig = @import("AppConfig.zig");
const SavedConfig = @import("../cli/Config.zig");
const VM = @import("VM.zig");
const x86 = @import("../machine/x86/main.zig");
const mininat = @import("../net/mininat.zig");

const c = struct {
    pub const GtkApplication = opaque {};
    pub const GtkButton = opaque {};
    pub const GtkWindow = opaque {};
    pub const GtkBox = opaque {};
    pub const GtkCheckButton = opaque {};
    pub const GtkComboBox = opaque {};
    pub const GtkComboBoxText = opaque {};
    pub const GtkEditable = opaque {};
    pub const GtkDrawingArea = opaque {};
    pub const GtkEntry = opaque {};
    pub const GtkEventController = opaque {};
    pub const GtkEventControllerKey = opaque {};
    pub const GtkEventControllerMotion = opaque {};
    pub const GtkEventControllerScroll = opaque {};
    pub const GtkGestureClick = opaque {};
    pub const GtkGestureSingle = opaque {};
    pub const GtkFileChooser = opaque {};
    pub const GtkNativeDialog = opaque {};
    pub const GtkSpinButton = opaque {};
    pub const GtkLabel = opaque {};
    pub const GtkScrolledWindow = opaque {};
    pub const GtkWidget = opaque {};
    pub const GFile = opaque {};
    pub const cairo_t = opaque {};
    pub const cairo_surface_t = opaque {};

    pub const gboolean = c_int;
    pub const FALSE: gboolean = 0;
    pub const TRUE: gboolean = 1;
    pub const G_SOURCE_REMOVE: gboolean = 0;
    pub const G_SOURCE_CONTINUE: gboolean = 1;
    pub const G_APPLICATION_DEFAULT_FLAGS: c_uint = 0;
    pub const GTK_ORIENTATION_VERTICAL: c_int = 1;
    pub const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
    pub const GTK_FILE_CHOOSER_ACTION_OPEN: c_int = 0;
    pub const GTK_FILE_CHOOSER_ACTION_SAVE: c_int = 1;
    pub const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: c_int = 2;
    pub const GTK_RESPONSE_ACCEPT: c_int = -3;
    pub const GDK_CONTROL_MASK: c_uint = 1 << 2;
    pub const GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES: c_uint = 3;
    pub const CAIRO_FORMAT_ARGB32: c_int = 0;

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
    pub extern fn gtk_button_new_with_label(text: [*:0]const u8) ?*GtkWidget;
    pub extern fn gtk_button_set_label(button: *GtkButton, text: [*:0]const u8) void;
    pub extern fn gtk_check_button_new_with_label(text: [*:0]const u8) ?*GtkWidget;
    pub extern fn gtk_check_button_get_active(button: *GtkCheckButton) gboolean;
    pub extern fn gtk_check_button_set_active(button: *GtkCheckButton, active: gboolean) void;
    pub extern fn gtk_combo_box_text_new() ?*GtkWidget;
    pub extern fn gtk_combo_box_text_append_text(
        combo_box: *GtkComboBoxText,
        text: [*:0]const u8,
    ) void;
    pub extern fn gtk_combo_box_text_remove_all(combo_box: *GtkComboBoxText) void;
    pub extern fn gtk_combo_box_text_get_active_text(
        combo_box: *GtkComboBoxText,
    ) ?[*:0]u8;
    pub extern fn gtk_combo_box_set_active(combo_box: *GtkComboBox, index: c_int) void;
    pub extern fn gtk_entry_new() ?*GtkWidget;
    pub extern fn gtk_drawing_area_new() ?*GtkWidget;
    pub extern fn gtk_drawing_area_set_content_width(area: *GtkDrawingArea, width: c_int) void;
    pub extern fn gtk_drawing_area_set_content_height(area: *GtkDrawingArea, height: c_int) void;
    pub extern fn gtk_drawing_area_set_draw_func(
        area: *GtkDrawingArea,
        draw_func: *const fn (
            *GtkDrawingArea,
            *cairo_t,
            c_int,
            c_int,
            ?*anyopaque,
        ) callconv(.c) void,
        data: ?*anyopaque,
        destroy: ?*const anyopaque,
    ) void;
    pub extern fn gtk_entry_set_placeholder_text(
        entry: *GtkEntry,
        text: [*:0]const u8,
    ) void;
    pub extern fn gtk_editable_get_text(editable: *GtkEditable) [*:0]const u8;
    pub extern fn gtk_editable_set_text(editable: *GtkEditable, text: [*:0]const u8) void;
    pub extern fn gtk_file_chooser_native_new(
        title: [*:0]const u8,
        parent: *GtkWindow,
        action: c_int,
        accept_label: [*:0]const u8,
        cancel_label: [*:0]const u8,
    ) ?*GtkNativeDialog;
    pub extern fn gtk_file_chooser_get_file(chooser: *GtkFileChooser) ?*GFile;
    pub extern fn gtk_file_chooser_set_current_name(
        chooser: *GtkFileChooser,
        name: [*:0]const u8,
    ) void;
    pub extern fn gtk_native_dialog_show(dialog: *GtkNativeDialog) void;
    pub extern fn gtk_native_dialog_destroy(dialog: *GtkNativeDialog) void;
    pub extern fn gtk_spin_button_new_with_range(
        minimum: f64,
        maximum: f64,
        step: f64,
    ) ?*GtkWidget;
    pub extern fn gtk_spin_button_get_value_as_int(spin_button: *GtkSpinButton) c_int;
    pub extern fn gtk_spin_button_set_value(spin_button: *GtkSpinButton, value: f64) void;
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
    pub extern fn gtk_event_controller_motion_new() ?*GtkEventController;
    pub extern fn gtk_event_controller_scroll_new(flags: c_uint) ?*GtkEventController;
    pub extern fn gtk_gesture_click_new() ?*GtkEventController;
    pub extern fn gtk_gesture_single_set_button(gesture: *GtkGestureSingle, button: c_uint) void;
    pub extern fn gtk_gesture_single_get_current_button(gesture: *GtkGestureSingle) c_uint;
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
    pub extern fn gtk_widget_set_sensitive(widget: *GtkWidget, sensitive: gboolean) void;
    pub extern fn gtk_widget_set_focusable(widget: *GtkWidget, focusable: gboolean) void;
    pub extern fn gtk_widget_get_width(widget: *GtkWidget) c_int;
    pub extern fn gtk_widget_get_height(widget: *GtkWidget) c_int;
    pub extern fn gtk_widget_queue_draw(widget: *GtkWidget) void;
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
    pub extern fn g_file_get_path(file: *GFile) ?[*:0]u8;
    pub extern fn g_free(memory: ?*anyopaque) void;
    pub extern fn cairo_image_surface_create_for_data(
        data: [*]u8,
        format: c_int,
        width: c_int,
        height: c_int,
        stride: c_int,
    ) ?*cairo_surface_t;
    pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;
    pub extern fn cairo_set_source_rgb(context: *cairo_t, red: f64, green: f64, blue: f64) void;
    pub extern fn cairo_set_source_surface(
        context: *cairo_t,
        surface: *cairo_surface_t,
        x: f64,
        y: f64,
    ) void;
    pub extern fn cairo_translate(context: *cairo_t, x: f64, y: f64) void;
    pub extern fn cairo_scale(context: *cairo_t, x: f64, y: f64) void;
    pub extern fn cairo_paint(context: *cairo_t) void;
};

const exits_max: u64 = 100_000_000;
const output_pending_bytes: usize = 64 * 1024;
const console_history_bytes: usize = 64 * 1024;
const display_width: u32 = 1280;
const display_height: u32 = 800;
const display_bytes: usize = display_width * display_height * 4;

const State = struct {
    allocator: std.mem.Allocator,
    memory_bytes: usize,
    vcpu_count: u8,
    firmware_path: ?[]const u8,
    kernel_path: ?[]const u8,
    initrd_path: ?[]const u8,
    disk_path: ?[]const u8,
    iso_path: ?[]const u8,
    shared_dir: ?[]const u8,
    network_enabled: bool,
    forwards: [AppConfig.MAX_FORWARDS]mininat.Forward,
    forward_count: u8,
    command_line: []const u8,
    loaded_firmware_path: ?[]u8 = null,
    loaded_command_line: ?[]u8 = null,
    vm: ?*VM = null,
    window: ?*c.GtkWindow = null,
    status: ?*c.GtkLabel = null,
    console: ?*c.GtkLabel = null,
    display: ?*c.GtkWidget = null,
    vm_name_entry: ?*c.GtkEntry = null,
    vm_selector: ?*c.GtkComboBoxText = null,
    iso_entry: ?*c.GtkEntry = null,
    disk_entry: ?*c.GtkEntry = null,
    kernel_entry: ?*c.GtkEntry = null,
    initrd_entry: ?*c.GtkEntry = null,
    shared_entry: ?*c.GtkEntry = null,
    forward_entry: ?*c.GtkEntry = null,
    memory_spin: ?*c.GtkSpinButton = null,
    vcpu_spin: ?*c.GtkSpinButton = null,
    disk_size_spin: ?*c.GtkSpinButton = null,
    network_check: ?*c.GtkCheckButton = null,
    start_button: ?*c.GtkWidget = null,
    pause_button: ?*c.GtkWidget = null,
    stop_button: ?*c.GtkWidget = null,
    output_lock: std.Io.Mutex = .init,
    output_pending: [output_pending_bytes]u8 = undefined,
    output_head: usize = 0,
    output_len: usize = 0,
    console_history: [console_history_bytes + 1]u8 = undefined,
    console_len: usize = 0,
    escape_state: enum { none, escape, csi } = .none,
    frame_pixels: []u8,
    frame_width: u32 = 0,
    frame_height: u32 = 0,
    frame_generation: u64 = 0,
    closing: bool = false,

    fn start(self: *State) void {
        if (self.vm != null) return;
        const firmware_path = self.firmware_path orelse if (self.iso_path != null or
            self.disk_path != null and self.kernel_path == null)
            defaultFirmwarePath()
        else
            null;
        if (self.kernel_path == null and firmware_path == null) {
            c.gtk_label_set_text(
                self.status.?,
                "No VM configured — choose installation media or a kernel",
            );
            return;
        }
        const vm = VM.create(self.allocator, .{
            .memory_bytes = self.memory_bytes,
            .vcpu_count = self.vcpu_count,
            .firmware_path = firmware_path,
            .kernel_path = self.kernel_path,
            .initrd_path = self.initrd_path,
            .disk_path = self.disk_path,
            .disk2_path = self.iso_path,
            .disk2_read_only = true,
            .shared_dir = self.shared_dir,
            .network_enabled = self.network_enabled,
            .forwards = self.forwards[0..self.forward_count],
            .display_enabled = true,
            .display_width = display_width,
            .display_height = display_height,
            .command_line = self.command_line,
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
        self.setRunningControls(true);
        _ = c.g_timeout_add(16, tick, self);
    }

    fn startFromForm(self: *State) void {
        if (!self.readForm()) return;
        self.start();
    }

    fn readForm(self: *State) bool {
        self.iso_path = entryValue(self.iso_entry.?);
        self.disk_path = entryValue(self.disk_entry.?);
        self.kernel_path = entryValue(self.kernel_entry.?);
        self.initrd_path = entryValue(self.initrd_entry.?);
        self.shared_dir = entryValue(self.shared_entry.?);
        const memory_mib = c.gtk_spin_button_get_value_as_int(self.memory_spin.?);
        const vcpu_count = c.gtk_spin_button_get_value_as_int(self.vcpu_spin.?);
        if (memory_mib <= 0 or vcpu_count <= 0) {
            self.setError(error.InvalidConfig);
            return false;
        }
        self.memory_bytes = @as(usize, @intCast(memory_mib)) * 1024 * 1024;
        self.vcpu_count = @intCast(vcpu_count);
        self.network_enabled = c.gtk_check_button_get_active(self.network_check.?) != c.FALSE;
        if (!self.readForwards()) return false;
        return true;
    }

    fn readForwards(self: *State) bool {
        self.forward_count = 0;
        const value = entryValue(self.forward_entry.?) orelse return true;
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |part_untrimmed| {
            const part = std.mem.trim(u8, part_untrimmed, " \t");
            if (part.len == 0 or self.forward_count == self.forwards.len) {
                self.setError(error.InvalidPortForward);
                return false;
            }
            const forward = AppConfig.parseForward(part) catch {
                self.setError(error.InvalidPortForward);
                return false;
            };
            for (self.forwards[0..self.forward_count]) |earlier| {
                if (earlier.host_port == forward.host_port) {
                    self.setError(error.InvalidPortForward);
                    return false;
                }
            }
            self.forwards[self.forward_count] = forward;
            self.forward_count += 1;
        }
        if (self.forward_count > 0) {
            self.network_enabled = true;
            c.gtk_check_button_set_active(self.network_check.?, c.TRUE);
        }
        return true;
    }

    fn saveConfiguration(self: *State) void {
        if (!self.readForm()) return;
        const name = entryValue(self.vm_name_entry.?) orelse return self.setError(error.InvalidName);
        const firmware = self.firmware_path orelse if (self.iso_path != null or
            self.disk_path != null and self.kernel_path == null)
            defaultFirmwarePath()
        else
            null;
        var config = SavedConfig{
            .name = name,
            .memory_mb = self.memory_bytes / (1024 * 1024),
            .vcpu_count = self.vcpu_count,
            .firmware_path = firmware,
            .disk_path = self.disk_path,
            .disk2_path = self.iso_path,
            .disk2_read_only = true,
            .kernel_path = self.kernel_path,
            .initrd_path = self.initrd_path,
            .cmdline = self.command_line,
            .enable_gpu = true,
            .enable_net = self.network_enabled,
            .shared_dir = self.shared_dir,
            .display_width = display_width,
            .display_height = display_height,
        };
        config.forward_count = self.forward_count;
        for (self.forwards[0..self.forward_count], 0..) |forward, index| {
            config.forwards[index] = .{
                .host_port = forward.host_port,
                .guest_port = forward.guest_port,
            };
        }
        config.save(self.allocator) catch |err| return self.setError(err);
        self.refreshLibrary(name);
        c.gtk_label_set_text(self.status.?, "Configuration saved");
    }

    fn loadConfiguration(self: *State) void {
        const name_owned = c.gtk_combo_box_text_get_active_text(self.vm_selector.?) orelse return;
        defer c.g_free(name_owned);
        var loaded = SavedConfig.load(self.allocator, std.mem.span(name_owned)) catch |err| {
            return self.setError(err);
        };
        defer loaded.deinit();
        const config = loaded.config;
        setEntryValue(self, self.vm_name_entry.?, config.name);
        setEntryValue(self, self.disk_entry.?, config.disk_path);
        setEntryValue(self, self.iso_entry.?, config.disk2_path);
        setEntryValue(self, self.kernel_entry.?, config.kernel_path);
        setEntryValue(self, self.initrd_entry.?, config.initrd_path);
        setEntryValue(self, self.shared_entry.?, config.shared_dir);
        c.gtk_spin_button_set_value(self.memory_spin.?, @floatFromInt(config.memory_mb));
        c.gtk_spin_button_set_value(self.vcpu_spin.?, @floatFromInt(config.vcpu_count));
        c.gtk_check_button_set_active(
            self.network_check.?,
            if (config.enable_net) c.TRUE else c.FALSE,
        );
        self.forward_count = config.forward_count;
        for (config.forwards[0..config.forward_count], 0..) |forward, index| {
            self.forwards[index] = .{
                .host_port = forward.host_port,
                .guest_port = forward.guest_port,
            };
        }
        self.writeForwards();
        const firmware_copy = if (config.firmware_path) |path|
            self.allocator.dupe(u8, path) catch return self.setError(error.OutOfMemory)
        else
            null;
        const command_copy = self.allocator.dupe(u8, config.cmdline) catch {
            if (firmware_copy) |path| self.allocator.free(path);
            return self.setError(error.OutOfMemory);
        };
        if (self.loaded_firmware_path) |path| self.allocator.free(path);
        if (self.loaded_command_line) |command| self.allocator.free(command);
        self.loaded_firmware_path = firmware_copy;
        self.loaded_command_line = command_copy;
        self.firmware_path = firmware_copy;
        self.command_line = command_copy;
        c.gtk_label_set_text(self.status.?, "Configuration loaded");
    }

    fn writeForwards(self: *State) void {
        var buffer: [AppConfig.MAX_FORWARDS * 12]u8 = undefined;
        var length: usize = 0;
        for (self.forwards[0..self.forward_count], 0..) |forward, index| {
            const formatted = std.fmt.bufPrint(buffer[length..], "{s}{}:{}", .{
                if (index == 0) "" else ", ",
                forward.host_port,
                forward.guest_port,
            }) catch return self.setError(error.InvalidPortForward);
            length += formatted.len;
        }
        setEntryValue(self, self.forward_entry.?, buffer[0..length]);
    }

    fn deleteConfiguration(self: *State) void {
        const name_owned = c.gtk_combo_box_text_get_active_text(self.vm_selector.?) orelse return;
        defer c.g_free(name_owned);
        SavedConfig.delete(self.allocator, std.mem.span(name_owned)) catch |err| {
            return self.setError(err);
        };
        self.refreshLibrary(null);
        c.gtk_label_set_text(self.status.?, "Configuration removed");
    }

    fn refreshLibrary(self: *State, selected: ?[]const u8) void {
        const selector = self.vm_selector orelse return;
        c.gtk_combo_box_text_remove_all(selector);
        const names = SavedConfig.listAll(self.allocator) catch |err| return self.setError(err);
        defer {
            for (names) |name| self.allocator.free(name);
            self.allocator.free(names);
        }
        var selected_index: c_int = -1;
        for (names, 0..) |name, index| {
            const terminated = self.allocator.dupeZ(u8, name) catch continue;
            defer self.allocator.free(terminated);
            c.gtk_combo_box_text_append_text(selector, terminated.ptr);
            if (selected) |wanted| {
                if (std.mem.eql(u8, wanted, name)) selected_index = @intCast(index);
            }
        }
        if (selected_index < 0 and names.len > 0) selected_index = 0;
        c.gtk_combo_box_set_active(@ptrCast(selector), selected_index);
    }

    fn stop(self: *State) void {
        const vm = self.vm orelse return;
        if (vm.state() != .running and vm.state() != .paused) return;
        vm.requestStop();
        c.gtk_label_set_text(self.status.?, "Stopping…");
        c.gtk_widget_set_sensitive(self.stop_button.?, c.FALSE);
    }

    fn setRunningControls(self: *State, running: bool) void {
        c.gtk_widget_set_sensitive(self.start_button.?, if (running) c.FALSE else c.TRUE);
        c.gtk_widget_set_sensitive(self.pause_button.?, if (running) c.TRUE else c.FALSE);
        c.gtk_widget_set_sensitive(self.stop_button.?, if (running) c.TRUE else c.FALSE);
        if (!running) c.gtk_button_set_label(@ptrCast(self.pause_button.?), "Pause");
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
        self.setRunningControls(false);
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

    fn refreshDisplay(self: *State) void {
        const vm = self.vm orelse return;
        const scanout = vm.copyScanout(self.frame_pixels) orelse return;
        if (scanout.generation == self.frame_generation and
            scanout.width == self.frame_width and scanout.height == self.frame_height) return;
        self.frame_width = scanout.width;
        self.frame_height = scanout.height;
        self.frame_generation = scanout.generation;
        c.gtk_widget_queue_draw(self.display.?);
    }

    fn injectPointer(self: *State, x: f64, y: f64) void {
        const vm = self.vm orelse return;
        const widget = self.display orelse return;
        const widget_width = c.gtk_widget_get_width(widget);
        const widget_height = c.gtk_widget_get_height(widget);
        if (widget_width <= 0 or widget_height <= 0) return;
        const frame_width = if (self.frame_width > 0) self.frame_width else display_width;
        const frame_height = if (self.frame_height > 0) self.frame_height else display_height;
        const scale = @min(
            @as(f64, @floatFromInt(widget_width)) / @as(f64, @floatFromInt(frame_width)),
            @as(f64, @floatFromInt(widget_height)) / @as(f64, @floatFromInt(frame_height)),
        );
        const shown_width = @as(f64, @floatFromInt(frame_width)) * scale;
        const shown_height = @as(f64, @floatFromInt(frame_height)) * scale;
        const local_x = std.math.clamp(
            x - (@as(f64, @floatFromInt(widget_width)) - shown_width) / 2,
            0,
            shown_width,
        );
        const local_y = std.math.clamp(
            y - (@as(f64, @floatFromInt(widget_height)) - shown_height) / 2,
            0,
            shown_height,
        );
        const absolute_x: i32 = @intFromFloat(local_x * 32767 / shown_width);
        const absolute_y: i32 = @intFromFloat(local_y * 32767 / shown_height);
        vm.injectPointer(absolute_x, absolute_y) catch {};
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
    var argument_buffer: [32][]const u8 = undefined;
    var argument_count: usize = 0;
    while (args.next()) |argument| {
        if (argument_count == argument_buffer.len) {
            writeStderr("error: too many GTK launch arguments\n");
            std.process.exit(1);
        }
        argument_buffer[argument_count] = argument;
        argument_count += 1;
    }
    const config = AppConfig.parse(argument_buffer[0..argument_count]) catch |err| {
        var buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "error: invalid GTK arguments: {s}\n", .{
            @errorName(err),
        }) catch "error: invalid GTK arguments\n";
        writeStderr(message);
        std.process.exit(1);
    };
    const frame_pixels = std.heap.c_allocator.alloc(u8, display_bytes) catch {
        writeStderr("error: unable to allocate display buffer\n");
        std.process.exit(1);
    };
    defer std.heap.c_allocator.free(frame_pixels);
    var state = State{
        .allocator = std.heap.c_allocator,
        .memory_bytes = config.memory_bytes,
        .vcpu_count = config.vcpu_count,
        .firmware_path = config.firmware_path,
        .kernel_path = config.kernel_path,
        .initrd_path = config.initrd_path,
        .disk_path = config.disk_path,
        .iso_path = config.iso_path,
        .shared_dir = config.shared_dir,
        .network_enabled = config.network_enabled,
        .forwards = config.forwards,
        .forward_count = config.forward_count,
        .command_line = config.command_line,
        .frame_pixels = frame_pixels,
    };
    defer {
        if (state.loaded_firmware_path) |path| state.allocator.free(path);
        if (state.loaded_command_line) |command| state.allocator.free(command);
    }
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
    c.gtk_window_set_default_size(window, 1100, 900);
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12) orelse return;
    const box: *c.GtkBox = @ptrCast(box_widget);
    c.gtk_widget_set_margin_top(@ptrCast(box), 16);
    c.gtk_widget_set_margin_bottom(@ptrCast(box), 16);
    c.gtk_widget_set_margin_start(@ptrCast(box), 16);
    c.gtk_widget_set_margin_end(@ptrCast(box), 16);
    const title = c.gtk_label_new("bobrvm Linux virtual machine") orelse return;
    c.gtk_widget_add_css_class(title, "title-2");
    c.gtk_box_append(box, title);
    const library = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8) orelse return;
    const selector_widget = c.gtk_combo_box_text_new() orelse return;
    state.vm_selector = @ptrCast(selector_widget);
    const name_widget = c.gtk_entry_new() orelse return;
    const name_entry: *c.GtkEntry = @ptrCast(name_widget);
    state.vm_name_entry = name_entry;
    c.gtk_entry_set_placeholder_text(name_entry, "VM name");
    const load_button = c.gtk_button_new_with_label("Load") orelse return;
    const save_button = c.gtk_button_new_with_label("Save") orelse return;
    const delete_button = c.gtk_button_new_with_label("Remove") orelse return;
    _ = c.g_signal_connect_data(load_button, "clicked", @ptrCast(&loadClicked), state, null, 0);
    _ = c.g_signal_connect_data(save_button, "clicked", @ptrCast(&saveClicked), state, null, 0);
    _ = c.g_signal_connect_data(
        delete_button,
        "clicked",
        @ptrCast(&deleteClicked),
        state,
        null,
        0,
    );
    c.gtk_widget_set_hexpand(name_widget, c.TRUE);
    c.gtk_box_append(@ptrCast(library), selector_widget);
    c.gtk_box_append(@ptrCast(library), name_widget);
    c.gtk_box_append(@ptrCast(library), load_button);
    c.gtk_box_append(@ptrCast(library), save_button);
    c.gtk_box_append(@ptrCast(library), delete_button);
    c.gtk_box_append(box, library);
    const iso_entry = addPathRow(
        box,
        state,
        "Installer ISO",
        "Choose a bootable ISO image",
        state.iso_path,
        &chooseIsoClicked,
    ) orelse return;
    state.iso_entry = iso_entry;
    const disk_entry = addPathRow(
        box,
        state,
        "Virtual Disk",
        "Choose an existing raw disk",
        state.disk_path,
        &chooseDiskClicked,
    ) orelse return;
    state.disk_entry = disk_entry;
    const kernel_entry = addPathRow(
        box,
        state,
        "Kernel",
        "Optional bzImage for direct boot",
        state.kernel_path,
        &chooseKernelClicked,
    ) orelse return;
    state.kernel_entry = kernel_entry;
    const initrd_entry = addPathRow(
        box,
        state,
        "Initrd",
        "Optional initramfs for direct boot",
        state.initrd_path,
        &chooseInitrdClicked,
    ) orelse return;
    state.initrd_entry = initrd_entry;
    const shared_entry = addPathRow(
        box,
        state,
        "Shared Folder",
        "Optional host directory mounted with tag ‘host’",
        state.shared_dir,
        &chooseSharedClicked,
    ) orelse return;
    state.shared_entry = shared_entry;
    const forward_row_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8) orelse return;
    const forward_row: *c.GtkBox = @ptrCast(forward_row_widget);
    const forward_label = c.gtk_label_new("Port Forwards") orelse return;
    const forward_widget = c.gtk_entry_new() orelse return;
    const forward_entry: *c.GtkEntry = @ptrCast(forward_widget);
    state.forward_entry = forward_entry;
    c.gtk_entry_set_placeholder_text(forward_entry, "2222:22, 8080:80");
    c.gtk_widget_set_hexpand(forward_widget, c.TRUE);
    c.gtk_box_append(forward_row, forward_label);
    c.gtk_box_append(forward_row, forward_widget);
    c.gtk_box_append(box, forward_row_widget);
    state.writeForwards();
    const hardware = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12) orelse return;
    const memory_label = c.gtk_label_new("Memory (MiB)") orelse return;
    const memory_spin_widget = c.gtk_spin_button_new_with_range(128, 65_536, 128) orelse return;
    const memory_spin: *c.GtkSpinButton = @ptrCast(memory_spin_widget);
    c.gtk_spin_button_set_value(memory_spin, @floatFromInt(state.memory_bytes / (1024 * 1024)));
    state.memory_spin = memory_spin;
    const vcpu_label = c.gtk_label_new("CPUs") orelse return;
    const vcpu_spin_widget = c.gtk_spin_button_new_with_range(1, 64, 1) orelse return;
    const vcpu_spin: *c.GtkSpinButton = @ptrCast(vcpu_spin_widget);
    c.gtk_spin_button_set_value(vcpu_spin, @floatFromInt(state.vcpu_count));
    state.vcpu_spin = vcpu_spin;
    const network_widget = c.gtk_check_button_new_with_label("Networking") orelse return;
    const network: *c.GtkCheckButton = @ptrCast(network_widget);
    c.gtk_check_button_set_active(network, if (state.network_enabled) c.TRUE else c.FALSE);
    state.network_check = network;
    const storage = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8) orelse return;
    const disk_size_label = c.gtk_label_new("Disk (GiB)") orelse return;
    const disk_size_widget = c.gtk_spin_button_new_with_range(1, 4096, 1) orelse return;
    const disk_size: *c.GtkSpinButton = @ptrCast(disk_size_widget);
    c.gtk_spin_button_set_value(disk_size, 64);
    state.disk_size_spin = disk_size;
    const create_disk = c.gtk_button_new_with_label("Create Disk…") orelse return;
    const grow_disk = c.gtk_button_new_with_label("Grow Disk") orelse return;
    _ = c.g_signal_connect_data(
        create_disk,
        "clicked",
        @ptrCast(&createDiskClicked),
        state,
        null,
        0,
    );
    _ = c.g_signal_connect_data(grow_disk, "clicked", @ptrCast(&growDiskClicked), state, null, 0);
    c.gtk_box_append(@ptrCast(hardware), memory_label);
    c.gtk_box_append(@ptrCast(hardware), memory_spin_widget);
    c.gtk_box_append(@ptrCast(hardware), vcpu_label);
    c.gtk_box_append(@ptrCast(hardware), vcpu_spin_widget);
    c.gtk_box_append(@ptrCast(hardware), network_widget);
    c.gtk_box_append(@ptrCast(storage), disk_size_label);
    c.gtk_box_append(@ptrCast(storage), disk_size_widget);
    c.gtk_box_append(@ptrCast(storage), create_disk);
    c.gtk_box_append(@ptrCast(storage), grow_disk);
    const controls = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8) orelse return;
    const start_button = c.gtk_button_new_with_label("Start") orelse return;
    const pause_button = c.gtk_button_new_with_label("Pause") orelse return;
    const stop_button = c.gtk_button_new_with_label("Stop") orelse return;
    state.start_button = start_button;
    state.pause_button = pause_button;
    state.stop_button = stop_button;
    _ = c.g_signal_connect_data(start_button, "clicked", @ptrCast(&startClicked), state, null, 0);
    _ = c.g_signal_connect_data(pause_button, "clicked", @ptrCast(&pauseClicked), state, null, 0);
    _ = c.g_signal_connect_data(stop_button, "clicked", @ptrCast(&stopClicked), state, null, 0);
    c.gtk_box_append(@ptrCast(controls), start_button);
    c.gtk_box_append(@ptrCast(controls), pause_button);
    c.gtk_box_append(@ptrCast(controls), stop_button);
    const status_widget = c.gtk_label_new("Ready") orelse return;
    const status: *c.GtkLabel = @ptrCast(status_widget);
    state.status = status;
    const display_widget = c.gtk_drawing_area_new() orelse return;
    const display: *c.GtkDrawingArea = @ptrCast(display_widget);
    state.display = display_widget;
    c.gtk_drawing_area_set_content_width(display, @intCast(display_width));
    c.gtk_drawing_area_set_content_height(display, @intCast(display_height));
    c.gtk_drawing_area_set_draw_func(display, drawDisplay, state, null);
    c.gtk_widget_set_hexpand(display_widget, c.TRUE);
    c.gtk_widget_set_vexpand(display_widget, c.TRUE);
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
    c.gtk_box_append(box, @ptrCast(hardware));
    c.gtk_box_append(box, @ptrCast(storage));
    c.gtk_box_append(box, @ptrCast(controls));
    c.gtk_box_append(box, @ptrCast(status));
    c.gtk_box_append(box, display_widget);
    c.gtk_box_append(box, scrolled_widget);
    c.gtk_window_set_child(window, @ptrCast(box));
    const keys = c.gtk_event_controller_key_new() orelse return;
    _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&keyPressed), state, null, 0);
    _ = c.g_signal_connect_data(keys, "key-released", @ptrCast(&keyReleased), state, null, 0);
    c.gtk_widget_add_controller(window_widget, keys);
    c.gtk_widget_set_focusable(display_widget, c.TRUE);
    const motion = c.gtk_event_controller_motion_new() orelse return;
    _ = c.g_signal_connect_data(motion, "motion", @ptrCast(&pointerMotion), state, null, 0);
    c.gtk_widget_add_controller(display_widget, motion);
    const click = c.gtk_gesture_click_new() orelse return;
    c.gtk_gesture_single_set_button(@ptrCast(click), 0);
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&pointerPressed), state, null, 0);
    _ = c.g_signal_connect_data(click, "released", @ptrCast(&pointerReleased), state, null, 0);
    c.gtk_widget_add_controller(display_widget, click);
    const scroll = c.gtk_event_controller_scroll_new(
        c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES,
    ) orelse return;
    _ = c.g_signal_connect_data(scroll, "scroll", @ptrCast(&pointerScroll), state, null, 0);
    c.gtk_widget_add_controller(display_widget, scroll);
    _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&closeRequest), state, null, 0);
    state.setRunningControls(false);
    state.refreshLibrary(null);
    c.gtk_window_present(window);
    if (state.kernel_path != null or state.firmware_path != null or
        state.iso_path != null or state.disk_path != null)
    {
        state.start();
    }
}

fn addPathRow(
    box: *c.GtkBox,
    state: *State,
    label_text: [*:0]const u8,
    placeholder: [*:0]const u8,
    initial_value: ?[]const u8,
    clicked: *const anyopaque,
) ?*c.GtkEntry {
    const row_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8) orelse return null;
    const row: *c.GtkBox = @ptrCast(row_widget);
    const label = c.gtk_label_new(label_text) orelse return null;
    const entry_widget = c.gtk_entry_new() orelse return null;
    const entry: *c.GtkEntry = @ptrCast(entry_widget);
    c.gtk_entry_set_placeholder_text(entry, placeholder);
    setEntryValue(state, entry, initial_value);
    c.gtk_widget_set_hexpand(entry_widget, c.TRUE);
    const browse = c.gtk_button_new_with_label("Browse…") orelse return null;
    _ = c.g_signal_connect_data(browse, "clicked", clicked, state, null, 0);
    c.gtk_box_append(row, label);
    c.gtk_box_append(row, entry_widget);
    c.gtk_box_append(row, browse);
    c.gtk_box_append(box, row_widget);
    return entry;
}

fn setEntryValue(state: *State, entry: *c.GtkEntry, value: ?[]const u8) void {
    const bytes = value orelse {
        c.gtk_editable_set_text(@ptrCast(entry), "");
        return;
    };
    const terminated = state.allocator.dupeZ(u8, bytes) catch return;
    defer state.allocator.free(terminated);
    c.gtk_editable_set_text(@ptrCast(entry), terminated.ptr);
}

fn entryValue(entry: *c.GtkEntry) ?[]const u8 {
    const value = std.mem.span(c.gtk_editable_get_text(@ptrCast(entry)));
    return if (value.len == 0) null else value;
}

fn startClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.startFromForm();
}

fn stopClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.stop();
}

fn pauseClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    switch (vm.state()) {
        .running => if (vm.requestPause()) {
            c.gtk_button_set_label(@ptrCast(state.pause_button.?), "Resume");
            c.gtk_label_set_text(state.status.?, "Paused");
        },
        .paused => if (vm.requestResume()) {
            c.gtk_button_set_label(@ptrCast(state.pause_button.?), "Pause");
            c.gtk_label_set_text(state.status.?, "Running");
        },
        else => {},
    }
}

fn loadClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.loadConfiguration();
}

fn saveClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.saveConfiguration();
}

fn deleteClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.deleteConfiguration();
}

fn chooseIsoClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    chooseFile(state, state.iso_entry.?, "Choose installer ISO");
}

fn chooseDiskClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    chooseFile(state, state.disk_entry.?, "Choose virtual disk");
}

fn chooseKernelClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    chooseFile(state, state.kernel_entry.?, "Choose Linux kernel");
}

fn chooseInitrdClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    chooseFile(state, state.initrd_entry.?, "Choose initial ramdisk");
}

fn chooseSharedClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    chooseFolder(state, state.shared_entry.?, "Choose shared host folder");
}

fn createDiskClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const dialog = c.gtk_file_chooser_native_new(
        "Create virtual disk",
        state.window.?,
        c.GTK_FILE_CHOOSER_ACTION_SAVE,
        "Create",
        "Cancel",
    ) orelse return;
    c.gtk_file_chooser_set_current_name(@ptrCast(dialog), "disk.raw");
    _ = c.g_signal_connect_data(
        dialog,
        "response",
        @ptrCast(&diskPathChosen),
        state,
        null,
        0,
    );
    c.gtk_native_dialog_show(dialog);
}

fn growDiskClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    if (state.vm != null) return state.setError(error.VmMustBeStopped);
    const path = entryValue(state.disk_entry.?) orelse return state.setError(error.InvalidPath);
    const size_gib = c.gtk_spin_button_get_value_as_int(state.disk_size_spin.?);
    if (size_gib <= 0) return state.setError(error.InvalidDiskSize);
    const size_bytes = std.math.mul(u64, @intCast(size_gib), 1024 * 1024 * 1024) catch {
        return state.setError(error.InvalidDiskSize);
    };
    disk.growRaw(path, size_bytes) catch |err| return state.setError(err);
    c.gtk_label_set_text(state.status.?, "Virtual disk grown");
}

fn chooseFile(state: *State, entry: *c.GtkEntry, title: [*:0]const u8) void {
    const dialog = c.gtk_file_chooser_native_new(
        title,
        state.window.?,
        c.GTK_FILE_CHOOSER_ACTION_OPEN,
        "Open",
        "Cancel",
    ) orelse return;
    _ = c.g_signal_connect_data(dialog, "response", @ptrCast(&fileChosen), entry, null, 0);
    c.gtk_native_dialog_show(dialog);
}

fn chooseFolder(state: *State, entry: *c.GtkEntry, title: [*:0]const u8) void {
    const dialog = c.gtk_file_chooser_native_new(
        title,
        state.window.?,
        c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "Open",
        "Cancel",
    ) orelse return;
    _ = c.g_signal_connect_data(dialog, "response", @ptrCast(&fileChosen), entry, null, 0);
    c.gtk_native_dialog_show(dialog);
}

fn fileChosen(
    dialog: *c.GtkNativeDialog,
    response: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    defer c.g_object_unref(dialog);
    defer c.gtk_native_dialog_destroy(dialog);
    if (response != c.GTK_RESPONSE_ACCEPT) return;
    const entry: *c.GtkEntry = @ptrCast(@alignCast(userdata orelse return));
    const file = c.gtk_file_chooser_get_file(@ptrCast(dialog)) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    c.gtk_editable_set_text(@ptrCast(entry), path);
}

fn diskPathChosen(
    dialog: *c.GtkNativeDialog,
    response: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    defer c.g_object_unref(dialog);
    defer c.gtk_native_dialog_destroy(dialog);
    if (response != c.GTK_RESPONSE_ACCEPT) return;
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const file = c.gtk_file_chooser_get_file(@ptrCast(dialog)) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    const size_gib = c.gtk_spin_button_get_value_as_int(state.disk_size_spin.?);
    if (size_gib <= 0) return state.setError(error.InvalidDiskSize);
    const size_bytes = std.math.mul(u64, @intCast(size_gib), 1024 * 1024 * 1024) catch {
        return state.setError(error.InvalidDiskSize);
    };
    disk.createSparse(std.mem.span(path), size_bytes) catch |err| return state.setError(err);
    c.gtk_editable_set_text(@ptrCast(state.disk_entry.?), path);
    c.gtk_label_set_text(state.status.?, "Virtual disk created");
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
    state.refreshDisplay();
    if (vm.state() != .stopped) return c.G_SOURCE_CONTINUE;
    state.finish();
    return c.G_SOURCE_REMOVE;
}

fn drawDisplay(
    _: *c.GtkDrawingArea,
    context: *c.cairo_t,
    width: c_int,
    height: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    c.cairo_set_source_rgb(context, 0, 0, 0);
    c.cairo_paint(context);
    if (state.frame_width == 0 or state.frame_height == 0) return;
    const surface = c.cairo_image_surface_create_for_data(
        state.frame_pixels.ptr,
        c.CAIRO_FORMAT_ARGB32,
        @intCast(state.frame_width),
        @intCast(state.frame_height),
        @intCast(state.frame_width * 4),
    ) orelse return;
    defer c.cairo_surface_destroy(surface);
    const scale = @min(
        @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(state.frame_width)),
        @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(state.frame_height)),
    );
    const target_width = @as(f64, @floatFromInt(state.frame_width)) * scale;
    const target_height = @as(f64, @floatFromInt(state.frame_height)) * scale;
    c.cairo_translate(
        context,
        (@as(f64, @floatFromInt(width)) - target_width) / 2,
        (@as(f64, @floatFromInt(height)) - target_height) / 2,
    );
    c.cairo_scale(context, scale, scale);
    c.cairo_set_source_surface(context, surface, 0, 0);
    c.cairo_paint(context);
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
    if (linuxKeyCode(keyval)) |keycode| {
        vm.injectKey(keycode, true) catch return c.FALSE;
        return c.TRUE;
    }
    const sequence = keySequence(keyval, modifiers) orelse return c.FALSE;
    const written = vm.writeConsole(sequence) catch return c.FALSE;
    return if (written == sequence.len) c.TRUE else c.FALSE;
}

fn keyReleased(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    _: c_uint,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    const keycode = linuxKeyCode(keyval) orelse return;
    vm.injectKey(keycode, false) catch {};
}

fn pointerMotion(
    _: *c.GtkEventControllerMotion,
    x: f64,
    y: f64,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.injectPointer(x, y);
}

fn pointerPressed(
    gesture: *c.GtkGestureClick,
    _: c_int,
    x: f64,
    y: f64,
    userdata: ?*anyopaque,
) callconv(.c) void {
    pointerButton(gesture, true, x, y, userdata);
}

fn pointerReleased(
    gesture: *c.GtkGestureClick,
    _: c_int,
    x: f64,
    y: f64,
    userdata: ?*anyopaque,
) callconv(.c) void {
    pointerButton(gesture, false, x, y, userdata);
}

fn pointerButton(
    gesture: *c.GtkGestureClick,
    pressed: bool,
    x: f64,
    y: f64,
    userdata: ?*anyopaque,
) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.injectPointer(x, y);
    const vm = state.vm orelse return;
    const button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    const keycode: u16 = switch (button) {
        1 => 0x110,
        2 => 0x112,
        3 => 0x111,
        else => return,
    };
    vm.injectButton(keycode, pressed) catch {};
}

fn pointerScroll(
    _: *c.GtkEventControllerScroll,
    x: f64,
    y: f64,
    userdata: ?*anyopaque,
) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.FALSE));
    const vm = state.vm orelse return c.FALSE;
    const horizontal: i32 = if (x < 0) 1 else if (x > 0) -1 else 0;
    const vertical: i32 = if (y < 0) 1 else if (y > 0) -1 else 0;
    vm.injectScroll(horizontal, vertical) catch return c.FALSE;
    return c.TRUE;
}

fn linuxKeyCode(keyval: c_uint) ?u16 {
    return switch (keyval) {
        'a', 'A' => 30,
        'b', 'B' => 48,
        'c', 'C' => 46,
        'd', 'D' => 32,
        'e', 'E' => 18,
        'f', 'F' => 33,
        'g', 'G' => 34,
        'h', 'H' => 35,
        'i', 'I' => 23,
        'j', 'J' => 36,
        'k', 'K' => 37,
        'l', 'L' => 38,
        'm', 'M' => 50,
        'n', 'N' => 49,
        'o', 'O' => 24,
        'p', 'P' => 25,
        'q', 'Q' => 16,
        'r', 'R' => 19,
        's', 'S' => 31,
        't', 'T' => 20,
        'u', 'U' => 22,
        'v', 'V' => 47,
        'w', 'W' => 17,
        'x', 'X' => 45,
        'y', 'Y' => 21,
        'z', 'Z' => 44,
        '1'...'9' => @intCast(2 + keyval - '1'),
        '0' => 11,
        '-' => 12,
        '=' => 13,
        0xff08 => 14,
        0xff09 => 15,
        '[', '{' => 26,
        ']', '}' => 27,
        0xff0d => 28,
        ';', ':' => 39,
        '\'', '"' => 40,
        '`', '~' => 41,
        '\\', '|' => 43,
        ',', '<' => 51,
        '.', '>' => 52,
        '/', '?' => 53,
        ' ' => 57,
        0xff1b => 1,
        0xffbe...0xffc7 => @intCast(59 + keyval - 0xffbe),
        0xffc8 => 87,
        0xffc9 => 88,
        0xffe1 => 42,
        0xffe2 => 54,
        0xffe3 => 29,
        0xffe4 => 97,
        0xffe9 => 56,
        0xffea => 100,
        0xffeb => 125,
        0xffec => 126,
        0xff50 => 102,
        0xff52 => 103,
        0xff55 => 104,
        0xff51 => 105,
        0xff53 => 106,
        0xff57 => 107,
        0xff54 => 108,
        0xff56 => 109,
        0xff63 => 110,
        0xffff => 111,
        else => null,
    };
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

fn defaultFirmwarePath() ?[]const u8 {
    const value = std.c.getenv("BOBRVM_OVMF_FD") orelse return null;
    const path = std.mem.span(value);
    return if (path.len == 0) null else path;
}
