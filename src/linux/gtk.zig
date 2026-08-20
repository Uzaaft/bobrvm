//! Thin GTK host application for the shared Linux VM lifecycle.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../agent/main.zig");
const config_policy = @import("../config.zig");
const disk = @import("../disk.zig");
const global = @import("../global.zig");
const AppConfig = @import("AppConfig.zig");
const Preferences = @import("Preferences.zig");
const SavedConfig = @import("../cli/Config.zig");
const VM = @import("VM.zig");
const x86 = @import("../machine/x86/main.zig");
const mininat = @import("../net/mininat.zig");

const c = struct {
    pub const AdwApplication = opaque {};
    pub const AdwApplicationWindow = opaque {};
    pub const AdwActionRow = opaque {};
    pub const AdwAlertDialog = opaque {};
    pub const AdwBanner = opaque {};
    pub const AdwDialog = opaque {};
    pub const AdwEntryRow = opaque {};
    pub const AdwHeaderBar = opaque {};
    pub const AdwPreferencesDialog = opaque {};
    pub const AdwPreferencesGroup = opaque {};
    pub const AdwPreferencesPage = opaque {};
    pub const AdwPreferencesRow = opaque {};
    pub const AdwSpinRow = opaque {};
    pub const AdwSwitchRow = opaque {};
    pub const AdwToolbarView = opaque {};
    pub const AdwToast = opaque {};
    pub const AdwViewStack = opaque {};
    pub const AdwViewStackPage = opaque {};
    pub const AdwViewSwitcher = opaque {};
    pub const GtkApplication = opaque {};
    pub const GtkButton = opaque {};
    pub const GtkWindow = opaque {};
    pub const GtkBox = opaque {};
    pub const GtkComboBox = opaque {};
    pub const GtkComboBoxText = opaque {};
    pub const GtkEditable = opaque {};
    pub const GtkDrawingArea = opaque {};
    pub const GtkEventController = opaque {};
    pub const GtkEventControllerKey = opaque {};
    pub const GtkEventControllerMotion = opaque {};
    pub const GtkEventControllerScroll = opaque {};
    pub const GtkGestureClick = opaque {};
    pub const GtkGestureSingle = opaque {};
    pub const GtkFileChooser = opaque {};
    pub const GtkNativeDialog = opaque {};
    pub const GtkLabel = opaque {};
    pub const GtkScrolledWindow = opaque {};
    pub const GtkAdjustment = opaque {};
    pub const GtkWidget = opaque {};
    pub const GFile = opaque {};
    pub const GAsyncResult = opaque {};
    pub const GCancellable = opaque {};
    pub const GError = opaque {};
    pub const GParamSpec = opaque {};
    pub const GdkClipboard = opaque {};
    pub const GdkDisplay = opaque {};
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
    pub const ADW_RESPONSE_DESTRUCTIVE: c_int = 2;

    pub extern fn adw_alert_dialog_new(
        heading: [*:0]const u8,
        body: [*:0]const u8,
    ) ?*AdwDialog;
    pub extern fn adw_alert_dialog_add_response(
        dialog: *AdwAlertDialog,
        id: [*:0]const u8,
        label: [*:0]const u8,
    ) void;
    pub extern fn adw_alert_dialog_set_close_response(
        dialog: *AdwAlertDialog,
        response: [*:0]const u8,
    ) void;
    pub extern fn adw_alert_dialog_set_default_response(
        dialog: *AdwAlertDialog,
        response: [*:0]const u8,
    ) void;
    pub extern fn adw_alert_dialog_set_response_appearance(
        dialog: *AdwAlertDialog,
        response: [*:0]const u8,
        appearance: c_int,
    ) void;
    pub extern fn adw_dialog_present(dialog: *AdwDialog, parent: *GtkWidget) void;
    pub extern fn adw_application_new(
        application_id: [*:0]const u8,
        flags: c_uint,
    ) ?*AdwApplication;
    pub extern fn adw_application_window_new(application: *GtkApplication) ?*GtkWidget;
    pub extern fn adw_application_window_set_content(
        window: *AdwApplicationWindow,
        content: *GtkWidget,
    ) void;
    pub extern fn adw_action_row_new() ?*GtkWidget;
    pub extern fn adw_action_row_add_suffix(row: *AdwActionRow, child: *GtkWidget) void;
    pub extern fn adw_action_row_set_subtitle(
        row: *AdwActionRow,
        subtitle: [*:0]const u8,
    ) void;
    pub extern fn adw_banner_new(title: [*:0]const u8) ?*GtkWidget;
    pub extern fn adw_entry_row_new() ?*GtkWidget;
    pub extern fn adw_entry_row_add_suffix(row: *AdwEntryRow, child: *GtkWidget) void;
    pub extern fn adw_header_bar_new() ?*GtkWidget;
    pub extern fn adw_header_bar_set_title_widget(
        header_bar: *AdwHeaderBar,
        title_widget: *GtkWidget,
    ) void;
    pub extern fn adw_header_bar_pack_end(
        header_bar: *AdwHeaderBar,
        child: *GtkWidget,
    ) void;
    pub extern fn adw_header_bar_pack_start(
        header_bar: *AdwHeaderBar,
        child: *GtkWidget,
    ) void;
    pub extern fn adw_preferences_dialog_new() ?*AdwDialog;
    pub extern fn adw_preferences_dialog_add(
        dialog: *AdwPreferencesDialog,
        page: *AdwPreferencesPage,
    ) void;
    pub extern fn adw_toolbar_view_new() ?*GtkWidget;
    pub extern fn adw_toolbar_view_add_top_bar(
        toolbar_view: *AdwToolbarView,
        widget: *GtkWidget,
    ) void;
    pub extern fn adw_toolbar_view_set_content(
        toolbar_view: *AdwToolbarView,
        content: *GtkWidget,
    ) void;
    pub extern fn adw_preferences_group_new() ?*GtkWidget;
    pub extern fn adw_preferences_group_set_title(
        group: *AdwPreferencesGroup,
        title: [*:0]const u8,
    ) void;
    pub extern fn adw_preferences_group_set_description(
        group: *AdwPreferencesGroup,
        description: [*:0]const u8,
    ) void;
    pub extern fn adw_preferences_group_add(
        group: *AdwPreferencesGroup,
        child: *GtkWidget,
    ) void;
    pub extern fn adw_preferences_page_new() ?*GtkWidget;
    pub extern fn adw_preferences_page_add(
        page: *AdwPreferencesPage,
        group: *AdwPreferencesGroup,
    ) void;
    pub extern fn adw_preferences_page_set_description(
        page: *AdwPreferencesPage,
        description: [*:0]const u8,
    ) void;
    pub extern fn adw_preferences_page_set_icon_name(
        page: *AdwPreferencesPage,
        icon_name: [*:0]const u8,
    ) void;
    pub extern fn adw_preferences_page_set_name(
        page: *AdwPreferencesPage,
        name: [*:0]const u8,
    ) void;
    pub extern fn adw_preferences_page_set_title(
        page: *AdwPreferencesPage,
        title: [*:0]const u8,
    ) void;
    pub extern fn adw_preferences_row_set_title(
        row: *AdwPreferencesRow,
        title: [*:0]const u8,
    ) void;
    pub extern fn adw_preferences_row_set_use_underline(
        row: *AdwPreferencesRow,
        use_underline: gboolean,
    ) void;
    pub extern fn adw_spin_row_new_with_range(
        minimum: f64,
        maximum: f64,
        step: f64,
    ) ?*GtkWidget;
    pub extern fn adw_spin_row_get_value(row: *AdwSpinRow) f64;
    pub extern fn adw_spin_row_set_value(row: *AdwSpinRow, value: f64) void;
    pub extern fn adw_switch_row_new() ?*GtkWidget;
    pub extern fn adw_switch_row_get_active(row: *AdwSwitchRow) gboolean;
    pub extern fn adw_switch_row_set_active(row: *AdwSwitchRow, active: gboolean) void;
    pub extern fn adw_toast_new(title: [*:0]const u8) ?*AdwToast;
    pub extern fn adw_preferences_dialog_add_toast(
        dialog: *AdwPreferencesDialog,
        toast: *AdwToast,
    ) void;
    pub extern fn adw_view_stack_new() ?*GtkWidget;
    pub extern fn adw_view_stack_add_titled(
        stack: *AdwViewStack,
        child: *GtkWidget,
        name: [*:0]const u8,
        title: [*:0]const u8,
    ) ?*AdwViewStackPage;
    pub extern fn adw_view_stack_set_visible_child_name(
        stack: *AdwViewStack,
        name: [*:0]const u8,
    ) void;
    pub extern fn adw_view_stack_page_set_icon_name(
        page: *AdwViewStackPage,
        icon_name: [*:0]const u8,
    ) void;
    pub extern fn adw_view_switcher_new() ?*GtkWidget;
    pub extern fn adw_view_switcher_set_stack(
        view_switcher: *AdwViewSwitcher,
        stack: *AdwViewStack,
    ) void;
    pub extern fn gtk_application_new(
        application_id: [*:0]const u8,
        flags: c_uint,
    ) ?*GtkApplication;
    pub extern fn gtk_application_window_new(application: *GtkApplication) ?*GtkWidget;
    pub extern fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
    pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: c_int, height: c_int) void;
    pub extern fn gtk_window_set_child(window: *GtkWindow, child: *GtkWidget) void;
    pub extern fn gtk_window_is_active(window: *GtkWindow) gboolean;
    pub extern fn gtk_window_present(window: *GtkWindow) void;
    pub extern fn gtk_window_destroy(window: *GtkWindow) void;
    pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) ?*GtkWidget;
    pub extern fn gtk_box_append(box: *GtkBox, child: *GtkWidget) void;
    pub extern fn gtk_button_new_from_icon_name(icon_name: [*:0]const u8) ?*GtkWidget;
    pub extern fn gtk_button_new_with_label(text: [*:0]const u8) ?*GtkWidget;
    pub extern fn gtk_button_set_icon_name(button: *GtkButton, icon_name: [*:0]const u8) void;
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
    pub extern fn gtk_scrolled_window_get_vadjustment(
        scrolled_window: *GtkScrolledWindow,
    ) *GtkAdjustment;
    pub extern fn gtk_adjustment_get_upper(adjustment: *GtkAdjustment) f64;
    pub extern fn gtk_adjustment_set_value(adjustment: *GtkAdjustment, value: f64) void;
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
    pub extern fn gtk_widget_set_tooltip_text(
        widget: *GtkWidget,
        text: [*:0]const u8,
    ) void;
    pub extern fn gtk_widget_set_size_request(
        widget: *GtkWidget,
        width: c_int,
        height: c_int,
    ) void;
    pub extern fn gtk_widget_get_width(widget: *GtkWidget) c_int;
    pub extern fn gtk_widget_get_height(widget: *GtkWidget) c_int;
    pub extern fn gtk_widget_queue_draw(widget: *GtkWidget) void;
    pub extern fn g_application_run(
        application: *anyopaque,
        argc: c_int,
        argv: ?[*]?[*:0]u8,
    ) c_int;
    pub extern fn g_object_unref(object: *anyopaque) void;
    pub extern fn g_object_ref_sink(object: *anyopaque) *anyopaque;
    pub extern fn g_signal_connect_data(
        instance: *anyopaque,
        detailed_signal: [*:0]const u8,
        handler: *const anyopaque,
        data: ?*anyopaque,
        destroy_data: ?*const anyopaque,
        connect_flags: c_uint,
    ) c_ulong;
    pub extern fn g_signal_handler_disconnect(instance: *anyopaque, handler_id: c_ulong) void;
    pub extern fn g_timeout_add(
        interval_ms: c_uint,
        function: *const fn (?*anyopaque) callconv(.c) gboolean,
        data: ?*anyopaque,
    ) c_uint;
    pub extern fn g_idle_add(
        function: *const fn (?*anyopaque) callconv(.c) gboolean,
        data: ?*anyopaque,
    ) c_uint;
    pub extern fn gdk_keyval_to_unicode(keyval: c_uint) c_uint;
    pub extern fn gdk_display_get_default() ?*GdkDisplay;
    pub extern fn gdk_display_get_clipboard(display: *GdkDisplay) *GdkClipboard;
    pub extern fn gdk_clipboard_set_text(clipboard: *GdkClipboard, text: [*:0]const u8) void;
    pub extern fn gdk_clipboard_read_text_async(
        clipboard: *GdkClipboard,
        cancellable: ?*GCancellable,
        callback: *const fn (?*anyopaque, *GAsyncResult, ?*anyopaque) callconv(.c) void,
        data: ?*anyopaque,
    ) void;
    pub extern fn gdk_clipboard_read_text_finish(
        clipboard: *GdkClipboard,
        result: *GAsyncResult,
        err: *?*GError,
    ) ?[*:0]u8;
    pub extern fn g_unichar_to_utf8(character: c_uint, output: [*]u8) c_int;
    pub extern fn g_file_get_path(file: *GFile) ?[*:0]u8;
    pub extern fn g_free(memory: ?*anyopaque) void;
    pub extern fn g_error_free(err: *GError) void;
    pub extern fn cairo_image_surface_create_for_data(
        data: [*]u8,
        format: c_int,
        width: c_int,
        height: c_int,
        stride: c_int,
    ) ?*cairo_surface_t;
    pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;
    pub extern fn cairo_surface_mark_dirty(surface: *cairo_surface_t) void;
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
const display_width_in_window_max: u32 = 960;
const display_height_with_console_max: u32 = 480;
const sessions_max: usize = 8;

const SessionRegistry = struct {
    sessions: [sessions_max]?*State = @splat(null),
    count: usize = 0,
    retired: ?*State = null,
    clipboard_owner: ?*State = null,

    fn add(self: *SessionRegistry, session: *State) error{TooManySessions}!void {
        if (self.count == self.sessions.len) return error.TooManySessions;
        for (&self.sessions) |*slot| {
            if (slot.* != null) continue;
            slot.* = session;
            self.count += 1;
            return;
        }
        unreachable;
    }

    fn retire(self: *SessionRegistry, session: *State) void {
        for (&self.sessions) |*slot| {
            if (slot.* != session) continue;
            slot.* = null;
            self.count -= 1;
            session.retired_next = self.retired;
            self.retired = session;
            if (self.clipboard_owner == session) self.clipboard_owner = null;
            session.clipboard_active.store(false, .release);
            return;
        }
    }

    fn claimClipboard(self: *SessionRegistry, session: *State) void {
        if (self.clipboard_owner) |owner| owner.clipboard_active.store(false, .release);
        self.clipboard_owner = session;
        session.clipboard_active.store(true, .release);
    }
};

const SnapshotStatus = enum(u8) {
    idle,
    running,
    succeeded,
    failed,
};

const State = struct {
    allocator: std.mem.Allocator,
    app: *c.GtkApplication,
    registry: *SessionRegistry,
    library_shell: bool,
    session_arena: ?*std.heap.ArenaAllocator = null,
    session_name: ?[]const u8 = null,
    retired_next: ?*State = null,
    default_memory_bytes: usize,
    default_vcpu_count: u8,
    memory_bytes: usize,
    vcpu_count: u8,
    display_width: u32,
    display_height: u32,
    gpu_memory_bytes: u64,
    firmware_path: ?[]const u8,
    vars_path: ?[]const u8,
    kernel_path: ?[]const u8,
    initrd_path: ?[]const u8,
    disk_path: ?[]const u8,
    iso_path: ?[]const u8,
    shared_dir: ?[]const u8,
    restore_path: ?[]const u8,
    network_enabled: bool,
    audio_enabled: bool,
    gpu_3d_enabled: bool,
    forwards: [AppConfig.MAX_FORWARDS]mininat.Forward,
    forward_count: u8,
    command_line: []const u8,
    load_saved_configuration: bool,
    loaded_firmware_path: ?[]u8 = null,
    loaded_vars_path: ?[]const u8 = null,
    loaded_command_line: ?[]u8 = null,
    vm: ?*VM = null,
    window: ?*c.GtkWindow = null,
    preferences_dialog: ?*c.AdwPreferencesDialog = null,
    view_stack: ?*c.AdwViewStack = null,
    configuration_groups: [4]?*c.GtkWidget = @splat(null),
    status: ?*c.GtkLabel = null,
    console: ?*c.GtkLabel = null,
    display: ?*c.GtkWidget = null,
    vm_name_entry: ?*c.GtkEditable = null,
    vm_selector: ?*c.GtkComboBoxText = null,
    iso_entry: ?*c.GtkEditable = null,
    disk_entry: ?*c.GtkEditable = null,
    kernel_entry: ?*c.GtkEditable = null,
    initrd_entry: ?*c.GtkEditable = null,
    shared_entry: ?*c.GtkEditable = null,
    restore_entry: ?*c.GtkEditable = null,
    forward_entry: ?*c.GtkEditable = null,
    memory_spin: ?*c.AdwSpinRow = null,
    vcpu_spin: ?*c.AdwSpinRow = null,
    display_width_spin: ?*c.AdwSpinRow = null,
    display_height_spin: ?*c.AdwSpinRow = null,
    gpu_memory_spin: ?*c.AdwSpinRow = null,
    disk_size_spin: ?*c.AdwSpinRow = null,
    network_check: ?*c.AdwSwitchRow = null,
    audio_check: ?*c.AdwSwitchRow = null,
    gpu_3d_check: ?*c.AdwSwitchRow = null,
    settings_memory_spin: ?*c.AdwSpinRow = null,
    settings_vcpu_spin: ?*c.AdwSpinRow = null,
    start_button: ?*c.GtkWidget = null,
    pause_button: ?*c.GtkWidget = null,
    stop_button: ?*c.GtkWidget = null,
    shutdown_button: ?*c.GtkWidget = null,
    reboot_button: ?*c.GtkWidget = null,
    trim_button: ?*c.GtkWidget = null,
    sync_time_button: ?*c.GtkWidget = null,
    send_file_button: ?*c.GtkWidget = null,
    snapshot_button: ?*c.GtkWidget = null,
    guest_tools: ?*c.GtkLabel = null,
    console_scroll: ?*c.GtkScrolledWindow = null,
    clipboard: ?*c.GdkClipboard = null,
    clipboard_signal_handler: c_ulong = 0,
    clipboard_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    clipboard_lock: std.Io.Mutex = .init,
    clipboard_text: []u8,
    clipboard_text_len: usize = 0,
    guest_clipboard_pending: bool = false,
    host_clipboard_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ignore_clipboard_change: bool = false,
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
    snapshot_thread: ?std.Thread = null,
    snapshot_status: std.atomic.Value(SnapshotStatus) =
        std.atomic.Value(SnapshotStatus).init(.idle),
    snapshot_error: ?anyerror = null,
    closing: bool = false,
    preferences_shortcut_pressed: bool = false,

    fn start(self: *State) void {
        if (self.vm != null) return;
        self.ensureFrameBuffer() catch |err| {
            self.setError(err);
            return;
        };
        const firmware_path = self.firmware_path orelse if (self.kernel_path == null and
            (self.iso_path != null or self.disk_path != null))
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
            .vars_path = self.vars_path,
            .kernel_path = self.kernel_path,
            .initrd_path = self.initrd_path,
            .disk_path = self.disk_path,
            .disk2_path = self.iso_path,
            .disk2_read_only = true,
            .shared_dir = self.shared_dir,
            .restore_path = self.restore_path,
            .network_enabled = self.network_enabled,
            .audio_enabled = self.audio_enabled,
            .gpu_3d_enabled = self.gpu_3d_enabled,
            .forwards = self.forwards[0..self.forward_count],
            .display_enabled = true,
            .display_width = self.display_width,
            .display_height = self.display_height,
            .gpu_memory_bytes = self.gpu_memory_bytes,
            .command_line = self.command_line,
            .exits_max = exits_max,
        }, x86.SerialSink.bind(State, self, writeSerial)) catch |err| {
            self.setError(err);
            return;
        };
        self.restore_path = null;
        setEntryValue(self, self.restore_entry.?, null);
        self.vm = vm;
        vm.setClipboardHandlers(guestClipboard, requestHostClipboard, self);
        vm.start() catch |err| {
            vm.destroy();
            self.vm = null;
            self.setError(err);
            return;
        };
        c.gtk_label_set_text(self.status.?, "Running");
        c.adw_view_stack_set_visible_child_name(self.view_stack.?, "display");
        self.setRunningControls(true);
        _ = c.g_timeout_add(16, tick, self);
    }

    fn startFromForm(self: *State) void {
        if (!self.readForm()) return;
        if (self.library_shell) {
            self.openSession() catch |err| self.setError(err);
            return;
        }
        self.start();
    }

    fn openSession(self: *State) !void {
        const session = try self.allocator.create(State);
        errdefer self.allocator.destroy(session);
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const frame_pixels = try allocateFrameBuffer(
            self.allocator,
            self.display_width,
            self.display_height,
        );
        errdefer self.allocator.free(frame_pixels);
        const clipboard_text = try self.allocator.alloc(
            u8,
            agent.native.clipboard_text_bytes_max + 1,
        );
        errdefer self.allocator.free(clipboard_text);
        session.* = .{
            .allocator = self.allocator,
            .app = self.app,
            .registry = self.registry,
            .library_shell = false,
            .session_arena = arena,
            .session_name = try dupeOptional(owned, entryValue(self.vm_name_entry.?)),
            .default_memory_bytes = self.default_memory_bytes,
            .default_vcpu_count = self.default_vcpu_count,
            .memory_bytes = self.memory_bytes,
            .vcpu_count = self.vcpu_count,
            .display_width = self.display_width,
            .display_height = self.display_height,
            .gpu_memory_bytes = self.gpu_memory_bytes,
            .firmware_path = try dupeOptional(owned, self.firmware_path),
            .vars_path = try dupeOptional(owned, self.vars_path),
            .kernel_path = try dupeOptional(owned, self.kernel_path),
            .initrd_path = try dupeOptional(owned, self.initrd_path),
            .disk_path = try dupeOptional(owned, self.disk_path),
            .iso_path = try dupeOptional(owned, self.iso_path),
            .shared_dir = try dupeOptional(owned, self.shared_dir),
            .restore_path = try dupeOptional(owned, self.restore_path),
            .network_enabled = self.network_enabled,
            .audio_enabled = self.audio_enabled,
            .gpu_3d_enabled = self.gpu_3d_enabled,
            .forwards = self.forwards,
            .forward_count = self.forward_count,
            .command_line = try owned.dupe(u8, self.command_line),
            .load_saved_configuration = false,
            .frame_pixels = frame_pixels,
            .clipboard_text = clipboard_text,
        };
        try self.registry.add(session);
        activate(self.app, session);
    }

    fn ensureFrameBuffer(self: *State) !void {
        const pixels = try std.math.mul(
            usize,
            @intCast(self.display_width),
            @intCast(self.display_height),
        );
        const bytes = try std.math.mul(usize, pixels, 4);
        if (bytes == self.frame_pixels.len) return;
        self.frame_pixels = try self.allocator.realloc(self.frame_pixels, bytes);
        self.frame_width = 0;
        self.frame_height = 0;
        self.frame_generation = 0;
    }

    fn readForm(self: *State) bool {
        self.iso_path = entryValue(self.iso_entry.?);
        self.disk_path = entryValue(self.disk_entry.?);
        self.kernel_path = entryValue(self.kernel_entry.?);
        self.initrd_path = entryValue(self.initrd_entry.?);
        self.shared_dir = entryValue(self.shared_entry.?);
        self.restore_path = entryValue(self.restore_entry.?);
        const memory_mib: c_int = @intFromFloat(c.adw_spin_row_get_value(self.memory_spin.?));
        const vcpu_count: c_int = @intFromFloat(c.adw_spin_row_get_value(self.vcpu_spin.?));
        const display_width_value: c_int = @intFromFloat(
            c.adw_spin_row_get_value(self.display_width_spin.?),
        );
        const display_height_value: c_int = @intFromFloat(
            c.adw_spin_row_get_value(self.display_height_spin.?),
        );
        const gpu_memory_mib: c_int = @intFromFloat(
            c.adw_spin_row_get_value(self.gpu_memory_spin.?),
        );
        if (memory_mib <= 0 or vcpu_count <= 0 or display_width_value <= 0 or
            display_height_value <= 0 or gpu_memory_mib <= 0)
        {
            self.setError(error.InvalidConfig);
            return false;
        }
        self.memory_bytes = @as(usize, @intCast(memory_mib)) * 1024 * 1024;
        self.vcpu_count = @intCast(vcpu_count);
        self.display_width = @intCast(display_width_value);
        self.display_height = @intCast(display_height_value);
        self.gpu_memory_bytes = @as(u64, @intCast(gpu_memory_mib)) * 1024 * 1024;
        config_policy.validate(.{
            .memory_bytes = self.memory_bytes,
            .vcpu_count = self.vcpu_count,
            .display_width = self.display_width,
            .display_height = self.display_height,
            .gpu_memory_bytes = self.gpu_memory_bytes,
            .disk_path = self.disk_path,
            .disk2_path = self.iso_path,
            .disk2_read_only = true,
        }) catch |err| {
            self.setError(err);
            return false;
        };
        self.network_enabled = c.adw_switch_row_get_active(self.network_check.?) != c.FALSE;
        self.audio_enabled = c.adw_switch_row_get_active(self.audio_check.?) != c.FALSE;
        self.gpu_3d_enabled = c.adw_switch_row_get_active(self.gpu_3d_check.?) != c.FALSE;
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
            c.adw_switch_row_set_active(self.network_check.?, c.TRUE);
        }
        return true;
    }

    fn saveConfiguration(self: *State) void {
        if (!self.readForm()) return;
        const name = entryValue(self.vm_name_entry.?) orelse {
            return self.setError(error.InvalidName);
        };
        const firmware = self.firmware_path orelse if (self.kernel_path == null and
            (self.iso_path != null or self.disk_path != null))
            defaultFirmwarePath()
        else
            null;
        const vars_path_owned = if (firmware != null) vars: {
            const template = defaultVarsTemplatePath() orelse {
                return self.setError(error.FirmwareVariablesUnavailable);
            };
            break :vars SavedConfig.ensureVars(self.allocator, name, template) catch |err| {
                return self.setError(err);
            };
        } else null;
        var adopted_vars = false;
        defer if (!adopted_vars) {
            if (vars_path_owned) |path| self.allocator.free(path);
        };
        var config = SavedConfig{
            .name = name,
            .memory_mb = self.memory_bytes / (1024 * 1024),
            .vcpu_count = self.vcpu_count,
            .firmware_path = firmware,
            .vars_path = vars_path_owned,
            .disk_path = self.disk_path,
            .disk2_path = self.iso_path,
            .disk2_read_only = true,
            .kernel_path = self.kernel_path,
            .initrd_path = self.initrd_path,
            .cmdline = self.command_line,
            .enable_gpu = true,
            .enable_net = self.network_enabled,
            .enable_snd = self.audio_enabled,
            .enable_virgl = self.gpu_3d_enabled,
            .shared_dir = self.shared_dir,
            .display_width = self.display_width,
            .display_height = self.display_height,
            .gpu_memory_mb = self.gpu_memory_bytes / (1024 * 1024),
        };
        config.forward_count = self.forward_count;
        for (self.forwards[0..self.forward_count], 0..) |forward, index| {
            config.forwards[index] = .{
                .host_port = forward.host_port,
                .guest_port = forward.guest_port,
            };
        }
        config.save(self.allocator) catch |err| return self.setError(err);
        if (self.loaded_vars_path) |path| self.allocator.free(path);
        self.loaded_vars_path = vars_path_owned;
        self.vars_path = vars_path_owned;
        adopted_vars = true;
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
        setEntryValue(self, self.restore_entry.?, null);
        self.restore_path = null;
        c.adw_spin_row_set_value(self.memory_spin.?, @floatFromInt(config.memory_mb));
        c.adw_spin_row_set_value(self.vcpu_spin.?, @floatFromInt(config.vcpu_count));
        c.adw_spin_row_set_value(
            self.display_width_spin.?,
            @floatFromInt(config.display_width),
        );
        c.adw_spin_row_set_value(
            self.display_height_spin.?,
            @floatFromInt(config.display_height),
        );
        c.adw_spin_row_set_value(self.gpu_memory_spin.?, @floatFromInt(config.gpu_memory_mb));
        self.display_width = config.display_width;
        self.display_height = config.display_height;
        self.gpu_memory_bytes = config.gpu_memory_mb * 1024 * 1024;
        c.gtk_drawing_area_set_content_width(
            @ptrCast(self.display.?),
            @intCast(@min(self.display_width, display_width_in_window_max)),
        );
        c.gtk_drawing_area_set_content_height(
            @ptrCast(self.display.?),
            @intCast(@min(self.display_height, display_height_with_console_max)),
        );
        c.adw_switch_row_set_active(
            self.network_check.?,
            if (config.enable_net) c.TRUE else c.FALSE,
        );
        self.audio_enabled = config.enable_snd;
        c.adw_switch_row_set_active(
            self.audio_check.?,
            if (config.enable_snd) c.TRUE else c.FALSE,
        );
        self.gpu_3d_enabled = config.enable_virgl;
        c.adw_switch_row_set_active(
            self.gpu_3d_check.?,
            if (config.enable_virgl) c.TRUE else c.FALSE,
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
        const vars_copy = if (config.vars_path) |path|
            self.allocator.dupe(u8, path) catch {
                if (firmware_copy) |firmware_path| self.allocator.free(firmware_path);
                return self.setError(error.OutOfMemory);
            }
        else
            null;
        const command_copy = self.allocator.dupe(u8, config.cmdline) catch {
            if (firmware_copy) |path| self.allocator.free(path);
            if (vars_copy) |path| self.allocator.free(path);
            return self.setError(error.OutOfMemory);
        };
        if (self.loaded_firmware_path) |path| self.allocator.free(path);
        if (self.loaded_vars_path) |path| self.allocator.free(path);
        if (self.loaded_command_line) |command| self.allocator.free(command);
        self.loaded_firmware_path = firmware_copy;
        self.loaded_vars_path = vars_copy;
        self.loaded_command_line = command_copy;
        self.firmware_path = firmware_copy;
        self.vars_path = vars_copy;
        self.command_line = command_copy;
        c.gtk_label_set_text(self.status.?, "Configuration loaded");
    }

    fn loadSelectedOrNew(self: *State) void {
        const selected = c.gtk_combo_box_text_get_active_text(self.vm_selector.?) orelse {
            self.newConfiguration();
            return;
        };
        c.g_free(selected);
        self.loadConfiguration();
    }

    fn newConfiguration(self: *State) void {
        if (self.vm != null) return;
        self.clearLoadedConfiguration();
        const defaults = AppConfig{
            .memory_bytes = self.default_memory_bytes,
            .vcpu_count = self.default_vcpu_count,
        };
        self.resetConfigurationState(&defaults);
        self.resetConfigurationForm(&defaults);
        c.gtk_combo_box_set_active(@ptrCast(self.vm_selector.?), -1);
        c.gtk_label_set_text(self.status.?, "New configuration");
    }

    fn resetConfigurationState(self: *State, defaults: *const AppConfig) void {
        self.memory_bytes = defaults.memory_bytes;
        self.vcpu_count = defaults.vcpu_count;
        self.display_width = defaults.display_width;
        self.display_height = defaults.display_height;
        self.gpu_memory_bytes = defaults.gpu_memory_bytes;
        self.firmware_path = null;
        self.vars_path = null;
        self.kernel_path = null;
        self.initrd_path = null;
        self.disk_path = null;
        self.iso_path = null;
        self.shared_dir = null;
        self.restore_path = null;
        self.network_enabled = defaults.network_enabled;
        self.audio_enabled = defaults.audio_enabled;
        self.gpu_3d_enabled = defaults.gpu_3d_enabled;
        self.command_line = defaults.command_line;
        self.forward_count = 0;
    }

    fn resetConfigurationForm(self: *State, defaults: *const AppConfig) void {
        setEntryValue(self, self.vm_name_entry.?, null);
        for ([_]*c.GtkEditable{
            self.disk_entry.?,
            self.iso_entry.?,
            self.kernel_entry.?,
            self.initrd_entry.?,
            self.shared_entry.?,
            self.restore_entry.?,
            self.forward_entry.?,
        }) |entry| setEntryValue(self, entry, null);
        c.adw_spin_row_set_value(
            self.memory_spin.?,
            @floatFromInt(defaults.memory_bytes / 1024 / 1024),
        );
        c.adw_spin_row_set_value(self.vcpu_spin.?, @floatFromInt(defaults.vcpu_count));
        c.adw_spin_row_set_value(
            self.display_width_spin.?,
            @floatFromInt(defaults.display_width),
        );
        c.adw_spin_row_set_value(
            self.display_height_spin.?,
            @floatFromInt(defaults.display_height),
        );
        c.adw_spin_row_set_value(
            self.gpu_memory_spin.?,
            @floatFromInt(defaults.gpu_memory_bytes / 1024 / 1024),
        );
        c.adw_spin_row_set_value(self.disk_size_spin.?, 64);
        c.adw_switch_row_set_active(
            self.network_check.?,
            if (defaults.network_enabled) c.TRUE else c.FALSE,
        );
        c.adw_switch_row_set_active(
            self.audio_check.?,
            if (defaults.audio_enabled) c.TRUE else c.FALSE,
        );
        c.adw_switch_row_set_active(
            self.gpu_3d_check.?,
            if (defaults.gpu_3d_enabled) c.TRUE else c.FALSE,
        );
        c.gtk_drawing_area_set_content_width(
            @ptrCast(self.display.?),
            @intCast(@min(defaults.display_width, display_width_in_window_max)),
        );
        c.gtk_drawing_area_set_content_height(
            @ptrCast(self.display.?),
            @intCast(@min(defaults.display_height, display_height_with_console_max)),
        );
    }

    fn clearLoadedConfiguration(self: *State) void {
        if (self.loaded_firmware_path) |path| self.allocator.free(path);
        if (self.loaded_vars_path) |path| self.allocator.free(path);
        if (self.loaded_command_line) |command| self.allocator.free(command);
        self.loaded_firmware_path = null;
        self.loaded_vars_path = null;
        self.loaded_command_line = null;
    }

    fn savePreferences(self: *State) void {
        const memory_mib: c_int = @intFromFloat(
            c.adw_spin_row_get_value(self.settings_memory_spin.?),
        );
        const vcpu_count: c_int = @intFromFloat(
            c.adw_spin_row_get_value(self.settings_vcpu_spin.?),
        );
        if (memory_mib <= 0 or vcpu_count <= 0) return self.setError(error.InvalidConfig);
        const preferences = Preferences{
            .memory_mib = @intCast(memory_mib),
            .vcpu_count = @intCast(vcpu_count),
        };
        preferences.save(self.allocator) catch |err| return self.setError(err);
        self.default_memory_bytes = @as(usize, @intCast(memory_mib)) * 1024 * 1024;
        self.default_vcpu_count = @intCast(vcpu_count);
        c.gtk_label_set_text(self.status.?, "Default settings saved");
        const toast = c.adw_toast_new("Default settings saved") orelse return;
        c.adw_preferences_dialog_add_toast(self.preferences_dialog.?, toast);
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
        self.loadSelectedOrNew();
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
        for (self.configuration_groups) |group| {
            c.gtk_widget_set_sensitive(group.?, if (running) c.FALSE else c.TRUE);
        }
        c.gtk_widget_set_sensitive(self.start_button.?, if (running) c.FALSE else c.TRUE);
        c.gtk_widget_set_sensitive(self.pause_button.?, if (running) c.TRUE else c.FALSE);
        c.gtk_widget_set_sensitive(self.stop_button.?, if (running) c.TRUE else c.FALSE);
        self.setManagementControls(false);
        if (!running) {
            c.gtk_button_set_icon_name(
                @ptrCast(self.pause_button.?),
                "media-playback-pause-symbolic",
            );
            c.gtk_widget_set_tooltip_text(self.pause_button.?, "Pause Virtual Machine");
        }
    }

    fn refreshGuestTools(self: *State) void {
        const vm = self.vm orelse {
            c.gtk_label_set_text(self.guest_tools.?, "Unavailable");
            self.setManagementControls(false);
            return;
        };
        c.gtk_label_set_text(self.guest_tools.?, switch (vm.guestToolsStatus()) {
            .disconnected => "Not Connected",
            .connecting => "Connecting…",
            .ready => "Ready",
            .protocol_error => "Protocol Error",
        });
        if (self.snapshot_status.load(.acquire) == .running) {
            self.setManagementControls(false);
            return;
        }
        self.setManagementControls(vm.guestManagementReady());
        const file_transfer = vm.guestToolsCapabilities() &
            agent.native.HostCapability.file_transfer != 0;
        c.gtk_widget_set_sensitive(
            self.send_file_button.?,
            if (file_transfer) c.TRUE else c.FALSE,
        );
    }

    fn setManagementControls(self: *State, enabled: bool) void {
        const sensitive = if (enabled) c.TRUE else c.FALSE;
        c.gtk_widget_set_sensitive(self.shutdown_button.?, sensitive);
        c.gtk_widget_set_sensitive(self.reboot_button.?, sensitive);
        c.gtk_widget_set_sensitive(self.trim_button.?, sensitive);
        c.gtk_widget_set_sensitive(self.sync_time_button.?, sensitive);
        c.gtk_widget_set_sensitive(self.snapshot_button.?, sensitive);
        if (!enabled) c.gtk_widget_set_sensitive(self.send_file_button.?, c.FALSE);
    }

    fn beginSnapshot(self: *State, directory: []const u8) void {
        const vm = self.vm orelse return;
        if (self.snapshot_status.load(.acquire) != .idle) return;
        const path = self.allocator.dupe(u8, directory) catch {
            return self.setError(error.OutOfMemory);
        };
        self.snapshot_error = null;
        self.snapshot_status.store(.running, .release);
        self.snapshot_thread = std.Thread.spawn(
            .{},
            snapshotThreadMain,
            .{ self, vm, path },
        ) catch |err| {
            self.allocator.free(path);
            self.snapshot_status.store(.idle, .release);
            return self.setError(err);
        };
        c.gtk_widget_set_sensitive(self.pause_button.?, c.FALSE);
        c.gtk_widget_set_sensitive(self.stop_button.?, c.FALSE);
        self.setManagementControls(false);
        c.gtk_label_set_text(self.status.?, "Creating quiesced snapshot…");
    }

    fn finishSnapshot(self: *State) void {
        const status = self.snapshot_status.load(.acquire);
        if (status == .idle or status == .running) return;
        if (self.snapshot_thread) |thread| thread.join();
        self.snapshot_thread = null;
        self.snapshot_status.store(.idle, .release);
        if (status == .failed) {
            self.setError(self.snapshot_error orelse error.SnapshotFailed);
        } else {
            c.gtk_label_set_text(self.status.?, "Snapshot created");
        }
        if (self.closing) {
            if (self.vm) |vm| vm.requestStop();
        } else {
            c.gtk_widget_set_sensitive(self.pause_button.?, c.TRUE);
            c.gtk_widget_set_sensitive(self.stop_button.?, c.TRUE);
            self.refreshGuestTools();
        }
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

    fn flushClipboard(self: *State) void {
        if (!self.clipboard_active.load(.acquire)) {
            _ = self.host_clipboard_requested.swap(false, .acq_rel);
            self.clipboard_lock.lockUncancelable(global.io());
            self.guest_clipboard_pending = false;
            self.clipboard_lock.unlock(global.io());
            return;
        }
        if (self.host_clipboard_requested.swap(false, .acq_rel)) {
            if (self.clipboard) |clipboard| {
                c.gdk_clipboard_read_text_async(clipboard, null, hostClipboardRead, self);
            }
        }

        self.clipboard_lock.lockUncancelable(global.io());
        defer self.clipboard_lock.unlock(global.io());
        if (!self.guest_clipboard_pending) return;
        const clipboard = self.clipboard orelse return;
        self.clipboard_text[self.clipboard_text_len] = 0;
        self.ignore_clipboard_change = true;
        c.gdk_clipboard_set_text(
            clipboard,
            self.clipboard_text[0..self.clipboard_text_len :0].ptr,
        );
        self.guest_clipboard_pending = false;
    }

    fn injectPointer(self: *State, x: f64, y: f64) void {
        const vm = self.vm orelse return;
        const widget = self.display orelse return;
        const widget_width = c.gtk_widget_get_width(widget);
        const widget_height = c.gtk_widget_get_height(widget);
        if (widget_width <= 0 or widget_height <= 0) return;
        const frame_width = if (self.frame_width > 0) self.frame_width else self.display_width;
        const frame_height = if (self.frame_height > 0) self.frame_height else self.display_height;
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
        _ = c.g_idle_add(scrollConsoleToEnd, self);
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
    const preferences = Preferences.load(std.heap.c_allocator) catch Preferences{};
    const app_adw = c.adw_application_new(
        "com.bobrvm.Bobrvm",
        c.G_APPLICATION_DEFAULT_FLAGS,
    ) orelse {
        writeStderr("error: unable to create Libadwaita application\n");
        std.process.exit(1);
    };
    defer c.g_object_unref(app_adw);
    const app: *c.GtkApplication = @ptrCast(app_adw);
    var registry = SessionRegistry{};
    const initial_pixels = std.math.mul(
        usize,
        @intCast(config.display_width),
        @intCast(config.display_height),
    ) catch {
        writeStderr("error: invalid display size\n");
        std.process.exit(1);
    };
    const initial_bytes = std.math.mul(usize, initial_pixels, 4) catch {
        writeStderr("error: invalid display size\n");
        std.process.exit(1);
    };
    const frame_pixels = std.heap.c_allocator.alloc(u8, initial_bytes) catch {
        writeStderr("error: unable to allocate display buffer\n");
        std.process.exit(1);
    };
    const clipboard_text = std.heap.c_allocator.alloc(
        u8,
        agent.native.clipboard_text_bytes_max + 1,
    ) catch {
        writeStderr("error: unable to allocate clipboard buffer\n");
        std.process.exit(1);
    };
    defer std.heap.c_allocator.free(clipboard_text);
    var state = State{
        .allocator = std.heap.c_allocator,
        .app = app,
        .registry = &registry,
        .library_shell = argument_count == 0,
        .default_memory_bytes = @intCast(preferences.memory_mib * 1024 * 1024),
        .default_vcpu_count = preferences.vcpu_count,
        .memory_bytes = if (argument_count == 0)
            @intCast(preferences.memory_mib * 1024 * 1024)
        else
            config.memory_bytes,
        .vcpu_count = if (argument_count == 0) preferences.vcpu_count else config.vcpu_count,
        .display_width = config.display_width,
        .display_height = config.display_height,
        .gpu_memory_bytes = config.gpu_memory_bytes,
        .firmware_path = config.firmware_path,
        .vars_path = config.vars_path,
        .kernel_path = config.kernel_path,
        .initrd_path = config.initrd_path,
        .disk_path = config.disk_path,
        .iso_path = config.iso_path,
        .shared_dir = config.shared_dir,
        .restore_path = config.restore_path,
        .network_enabled = config.network_enabled,
        .audio_enabled = config.audio_enabled,
        .gpu_3d_enabled = config.gpu_3d_enabled,
        .forwards = config.forwards,
        .forward_count = config.forward_count,
        .command_line = config.command_line,
        .load_saved_configuration = argument_count == 0,
        .frame_pixels = frame_pixels,
        .clipboard_text = clipboard_text,
    };
    defer {
        state.allocator.free(state.frame_pixels);
        if (state.loaded_firmware_path) |path| state.allocator.free(path);
        if (state.loaded_vars_path) |path| state.allocator.free(path);
        if (state.loaded_command_line) |command| state.allocator.free(command);
    }
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&activate), &state, null, 0);
    const status = c.g_application_run(@ptrCast(app), 0, null);
    if (state.snapshot_thread) |thread| {
        thread.join();
        state.snapshot_thread = null;
    }
    if (state.vm) |vm| {
        vm.requestStop();
        state.finish();
    }
    for (registry.sessions) |session_optional| {
        if (session_optional) |session| deinitSession(session);
    }
    var retired = registry.retired;
    while (retired) |session| {
        retired = session.retired_next;
        deinitSession(session);
    }
    if (status != 0) std.process.exit(@intCast(status));
}

fn deinitSession(state: *State) void {
    if (state.snapshot_thread) |thread| {
        thread.join();
        state.snapshot_thread = null;
    }
    if (state.vm) |vm| {
        vm.requestStop();
        state.finish();
    }
    state.clearLoadedConfiguration();
    state.allocator.free(state.frame_pixels);
    state.allocator.free(state.clipboard_text);
    if (state.session_arena) |arena| {
        arena.deinit();
        state.allocator.destroy(arena);
    }
    state.allocator.destroy(state);
}

fn activate(app: *c.GtkApplication, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const window_widget = c.adw_application_window_new(app) orelse return;
    const application_window: *c.AdwApplicationWindow = @ptrCast(window_widget);
    const window: *c.GtkWindow = @ptrCast(window_widget);
    state.window = window;
    if (c.gdk_display_get_default()) |display| {
        state.clipboard = c.gdk_display_get_clipboard(display);
        state.clipboard_signal_handler = c.g_signal_connect_data(
            state.clipboard.?,
            "changed",
            @ptrCast(&clipboardChanged),
            state,
            null,
            0,
        );
    }
    var title_buffer: [160]u8 = undefined;
    const title = if (state.session_name) |name|
        std.fmt.bufPrintZ(&title_buffer, "bobrvm — {s}", .{name}) catch "bobrvm"
    else
        "bobrvm";
    c.gtk_window_set_title(window, title.ptr);
    c.gtk_window_set_default_size(window, 1000, 760);
    const toolbar_widget = c.adw_toolbar_view_new() orelse return;
    const toolbar: *c.AdwToolbarView = @ptrCast(toolbar_widget);
    const view_stack_widget = c.adw_view_stack_new() orelse return;
    const view_stack: *c.AdwViewStack = @ptrCast(view_stack_widget);
    state.view_stack = view_stack;
    const header_widget = c.adw_header_bar_new() orelse return;
    const header: *c.AdwHeaderBar = @ptrCast(header_widget);
    const switcher_widget = c.adw_view_switcher_new() orelse return;
    const switcher: *c.AdwViewSwitcher = @ptrCast(switcher_widget);
    c.adw_view_switcher_set_stack(switcher, view_stack);
    c.adw_header_bar_set_title_widget(header, switcher_widget);
    c.adw_toolbar_view_add_top_bar(toolbar, header_widget);
    if (builtin.mode == .Debug) {
        const banner = c.adw_banner_new("Debug build — performance may be degraded") orelse return;
        c.adw_toolbar_view_add_top_bar(toolbar, banner);
    }
    const configuration_widget = c.adw_preferences_page_new() orelse return;
    const configuration: *c.AdwPreferencesPage = @ptrCast(configuration_widget);
    c.adw_preferences_page_set_title(configuration, "Machine");
    c.adw_preferences_page_set_description(
        configuration,
        "Configure a saved virtual machine, then start it from the header bar",
    );
    c.adw_preferences_page_set_icon_name(configuration, "computer-symbolic");
    const library_group = addPreferencesGroup(
        configuration,
        "Virtual Machines",
        "Open a saved configuration or name and save a new one",
    ) orelse return;
    state.configuration_groups[0] = @ptrCast(library_group);
    const saved_row = addActionRow(
        library_group,
        "Saved Machine",
        "Select a configuration from the local library",
    ) orelse return;
    const selector_widget = c.gtk_combo_box_text_new() orelse return;
    state.vm_selector = @ptrCast(selector_widget);
    c.adw_action_row_add_suffix(saved_row, selector_widget);
    _ = addRowButton(
        saved_row,
        "document-open-symbolic",
        "Load",
        &loadClicked,
        state,
    ) orelse return;
    state.vm_name_entry = addEntryRow(library_group, state, "Name", null) orelse return;
    const configuration_actions = addActionRow(
        library_group,
        "Configuration",
        "Create, save, or remove a virtual machine configuration",
    ) orelse return;
    _ = addRowButton(
        configuration_actions,
        "document-new-symbolic",
        "New",
        &newClicked,
        state,
    ) orelse return;
    _ = addRowButton(
        configuration_actions,
        "document-save-symbolic",
        "Save",
        &saveClicked,
        state,
    ) orelse return;
    const delete_button = addRowButton(
        configuration_actions,
        "edit-delete-symbolic",
        "Remove…",
        &deleteClicked,
        state,
    ) orelse return;
    c.gtk_widget_add_css_class(delete_button, "destructive-action");
    const storage_group = addPreferencesGroup(
        configuration,
        "Storage and Boot",
        "Boot from UEFI media or use a kernel directly, and manage guest storage",
    ) orelse return;
    state.configuration_groups[1] = @ptrCast(storage_group);
    const iso_entry = addPathRow(
        storage_group,
        state,
        "Installer ISO",
        "Choose a bootable ISO image",
        state.iso_path,
        &chooseIsoClicked,
    ) orelse return;
    state.iso_entry = iso_entry;
    const disk_entry = addPathRow(
        storage_group,
        state,
        "Virtual Disk",
        "Choose an existing raw disk",
        state.disk_path,
        &chooseDiskClicked,
    ) orelse return;
    state.disk_entry = disk_entry;
    const kernel_entry = addPathRow(
        storage_group,
        state,
        "Kernel",
        "Optional bzImage for direct boot",
        state.kernel_path,
        &chooseKernelClicked,
    ) orelse return;
    state.kernel_entry = kernel_entry;
    const initrd_entry = addPathRow(
        storage_group,
        state,
        "Initrd",
        "Optional initramfs for direct boot",
        state.initrd_path,
        &chooseInitrdClicked,
    ) orelse return;
    state.initrd_entry = initrd_entry;
    const shared_entry = addPathRow(
        storage_group,
        state,
        "Shared Folder",
        "Optional host directory mounted with tag ‘host’",
        state.shared_dir,
        &chooseSharedClicked,
    ) orelse return;
    state.shared_entry = shared_entry;
    const restore_entry = addPathRow(
        storage_group,
        state,
        "Restore Snapshot",
        "Optional snapshot directory for the next start",
        state.restore_path,
        &chooseRestoreClicked,
    ) orelse return;
    state.restore_entry = restore_entry;
    state.forward_entry = addEntryRow(
        storage_group,
        state,
        "Port Forwards",
        null,
    ) orelse return;
    c.gtk_widget_set_tooltip_text(
        @ptrCast(state.forward_entry.?),
        "Comma-separated host and guest port pairs, such as 2222:22, 8080:80",
    );
    state.writeForwards();
    const hardware_group = addPreferencesGroup(
        configuration,
        "Hardware",
        "Resource and device changes are applied on the next start",
    ) orelse return;
    state.configuration_groups[2] = @ptrCast(hardware_group);
    state.memory_spin = addSpinRow(
        hardware_group,
        "Memory",
        "Guest memory in MiB",
        128,
        65_536,
        128,
        @floatFromInt(state.memory_bytes / 1024 / 1024),
    ) orelse return;
    state.vcpu_spin = addSpinRow(
        hardware_group,
        "Processors",
        "Number of virtual CPUs",
        1,
        64,
        1,
        @floatFromInt(state.vcpu_count),
    ) orelse return;
    state.network_check = addSwitchRow(
        hardware_group,
        "_Networking",
        "Connect the guest through the host network",
        state.network_enabled,
    ) orelse return;
    state.audio_check = addSwitchRow(
        hardware_group,
        "_Audio",
        "Expose a virtual sound device to the guest",
        state.audio_enabled,
    ) orelse return;
    const graphics_group = addPreferencesGroup(
        configuration,
        "Graphics",
        "Set the maximum display size and shared graphics memory",
    ) orelse return;
    state.configuration_groups[3] = @ptrCast(graphics_group);
    state.display_width_spin = addSpinRow(
        graphics_group,
        "Display Width",
        "Maximum guest width in pixels",
        config_policy.display_dimension_min,
        config_policy.display_dimension_max,
        16,
        @floatFromInt(state.display_width),
    ) orelse return;
    state.display_height_spin = addSpinRow(
        graphics_group,
        "Display Height",
        "Maximum guest height in pixels",
        config_policy.display_dimension_min,
        config_policy.display_dimension_max,
        16,
        @floatFromInt(state.display_height),
    ) orelse return;
    state.gpu_memory_spin = addSpinRow(
        graphics_group,
        "Graphics Memory",
        "Shared graphics memory in MiB",
        64,
        2048,
        64,
        @floatFromInt(state.gpu_memory_bytes / 1024 / 1024),
    ) orelse return;
    state.gpu_3d_check = addSwitchRow(
        graphics_group,
        "_3D Acceleration",
        "Enable accelerated OpenGL and Vulkan rendering",
        state.gpu_3d_enabled,
    ) orelse return;
    const disk_size = addSpinRow(
        storage_group,
        "Disk Image Size",
        "Size in GiB for a new or expanded raw disk image",
        1,
        4096,
        1,
        64,
    ) orelse return;
    state.disk_size_spin = disk_size;
    const disk_row: *c.AdwActionRow = @ptrCast(disk_size);
    _ = addRowButton(
        disk_row,
        "document-new-symbolic",
        "Create Disk…",
        &createDiskClicked,
        state,
    ) orelse return;
    _ = addRowButton(
        disk_row,
        "drive-harddisk-symbolic",
        "Grow Disk",
        &growDiskClicked,
        state,
    ) orelse return;
    const controls_group = addPreferencesGroup(
        configuration,
        "Guest Integration",
        "Management actions become available when guest tools connect",
    ) orelse return;
    const start_button = createIconButton(
        "media-playback-start-symbolic",
        "Start Virtual Machine",
        &startClicked,
        state,
    ) orelse return;
    const pause_button = createIconButton(
        "media-playback-pause-symbolic",
        "Pause Virtual Machine",
        &pauseClicked,
        state,
    ) orelse return;
    const stop_button = createIconButton(
        "media-playback-stop-symbolic",
        "Stop Virtual Machine",
        &stopClicked,
        state,
    ) orelse return;
    state.start_button = start_button;
    state.pause_button = pause_button;
    state.stop_button = stop_button;
    c.adw_header_bar_pack_start(header, start_button);
    c.adw_header_bar_pack_start(header, pause_button);
    c.adw_header_bar_pack_start(header, stop_button);
    const status_row = addActionRow(
        controls_group,
        "Status",
        "Virtual machine and configuration activity",
    ) orelse return;
    const status_widget = c.gtk_label_new("Ready") orelse return;
    state.status = @ptrCast(status_widget);
    c.adw_action_row_add_suffix(status_row, status_widget);
    const tools_row = addActionRow(
        controls_group,
        "Guest Tools",
        "Integration agent connection state",
    ) orelse return;
    const guest_tools_widget = c.gtk_label_new("Unavailable") orelse return;
    state.guest_tools = @ptrCast(guest_tools_widget);
    c.adw_action_row_add_suffix(tools_row, guest_tools_widget);
    const power_row = addActionRow(
        controls_group,
        "Power",
        "Ask the guest operating system to shut down or restart",
    ) orelse return;
    state.shutdown_button = addRowButton(
        power_row,
        "system-shutdown-symbolic",
        "Shut Down Guest",
        &shutdownGuestClicked,
        state,
    ) orelse return;
    state.reboot_button = addRowButton(
        power_row,
        "system-reboot-symbolic",
        "Reboot Guest",
        &rebootGuestClicked,
        state,
    ) orelse return;
    const guest_actions = addActionRow(
        controls_group,
        "Actions",
        "Maintain the guest, transfer a file, or create a snapshot",
    ) orelse return;
    state.trim_button = addRowButton(
        guest_actions,
        "edit-clear-all-symbolic",
        "Trim Disks",
        &trimClicked,
        state,
    ) orelse return;
    state.sync_time_button = addRowButton(
        guest_actions,
        "preferences-system-time-symbolic",
        "Synchronize Time",
        &syncTimeClicked,
        state,
    ) orelse return;
    state.send_file_button = addRowButton(
        guest_actions,
        "document-send-symbolic",
        "Send File…",
        &sendFileClicked,
        state,
    ) orelse return;
    state.snapshot_button = addRowButton(
        guest_actions,
        "document-save-symbolic",
        "Create Snapshot…",
        &snapshotClicked,
        state,
    ) orelse return;
    const display_widget = c.gtk_drawing_area_new() orelse return;
    const display: *c.GtkDrawingArea = @ptrCast(display_widget);
    state.display = display_widget;
    c.gtk_drawing_area_set_content_width(
        display,
        @intCast(@min(state.display_width, display_width_in_window_max)),
    );
    c.gtk_drawing_area_set_content_height(
        display,
        @intCast(@min(state.display_height, display_height_with_console_max)),
    );
    c.gtk_drawing_area_set_draw_func(display, drawDisplay, state, null);
    c.gtk_widget_set_hexpand(display_widget, c.TRUE);
    // Keep the serial console reachable when firmware hands off to a guest
    // initramfs that does not contain virtio_gpu.
    c.gtk_widget_set_vexpand(display_widget, c.FALSE);
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
    state.console_scroll = scrolled;
    c.gtk_widget_set_hexpand(scrolled_widget, c.TRUE);
    c.gtk_widget_set_vexpand(scrolled_widget, c.TRUE);
    c.gtk_widget_set_size_request(scrolled_widget, -1, 240);
    c.gtk_scrolled_window_set_child(scrolled, console_widget);
    const display_box_widget = createPageBox() orelse return;
    const display_box: *c.GtkBox = @ptrCast(display_box_widget);
    const display_group = addBoxPreferencesGroup(
        display_box,
        "Display",
        "The guest framebuffer accepts keyboard, pointer, and scroll input",
    ) orelse return;
    c.gtk_widget_add_css_class(display_widget, "card");
    c.adw_preferences_group_add(display_group, display_widget);
    const console_box_widget = createPageBox() orelse return;
    const console_box: *c.GtkBox = @ptrCast(console_box_widget);
    const console_group = addBoxPreferencesGroup(
        console_box,
        "Serial Console",
        "Boot and guest console output remains available when graphics are offline",
    ) orelse return;
    c.gtk_widget_set_vexpand(@ptrCast(console_group), c.TRUE);
    c.gtk_widget_add_css_class(scrolled_widget, "card");
    c.adw_preferences_group_add(console_group, scrolled_widget);
    const preferences_dialog = c.adw_preferences_dialog_new() orelse return;
    _ = c.g_object_ref_sink(preferences_dialog);
    state.preferences_dialog = @ptrCast(preferences_dialog);
    const settings_page_widget = c.adw_preferences_page_new() orelse return;
    const settings_page: *c.AdwPreferencesPage = @ptrCast(settings_page_widget);
    c.adw_preferences_page_set_name(settings_page, "general");
    c.adw_preferences_page_set_title(settings_page, "General");
    c.adw_preferences_page_set_icon_name(settings_page, "preferences-system-symbolic");
    const settings_group = addPreferencesGroup(
        settings_page,
        "New Virtual Machines",
        "Defaults used when creating a virtual machine",
    ) orelse return;
    state.settings_memory_spin = addSpinRow(
        settings_group,
        "Memory",
        "Default guest memory in MiB",
        128,
        65_536,
        128,
        @floatFromInt(state.default_memory_bytes / 1024 / 1024),
    ) orelse return;
    state.settings_vcpu_spin = addSpinRow(
        settings_group,
        "Processors",
        "Default number of virtual CPUs",
        1,
        64,
        1,
        @floatFromInt(state.default_vcpu_count),
    ) orelse return;
    const save_row = addActionRow(
        settings_group,
        "Defaults",
        "Use these values for new configurations",
    ) orelse return;
    const save_defaults = c.gtk_button_new_with_label("Save Defaults") orelse return;
    c.gtk_widget_add_css_class(save_defaults, "suggested-action");
    _ = c.g_signal_connect_data(
        save_defaults,
        "clicked",
        @ptrCast(&savePreferencesClicked),
        state,
        null,
        0,
    );
    c.adw_action_row_add_suffix(save_row, save_defaults);
    c.adw_preferences_dialog_add(state.preferences_dialog.?, settings_page);
    const preferences_button = createIconButton(
        "preferences-system-symbolic",
        "Preferences",
        &preferencesClicked,
        state,
    ) orelse return;
    c.adw_header_bar_pack_end(header, preferences_button);
    const library_page = c.adw_view_stack_add_titled(
        view_stack,
        configuration_widget,
        "machine",
        "Machine",
    ) orelse return;
    c.adw_view_stack_page_set_icon_name(library_page, "computer-symbolic");
    const display_page = c.adw_view_stack_add_titled(
        view_stack,
        display_box_widget,
        "display",
        "Display",
    ) orelse return;
    c.adw_view_stack_page_set_icon_name(display_page, "video-display-symbolic");
    const console_page = c.adw_view_stack_add_titled(
        view_stack,
        console_box_widget,
        "console",
        "Console",
    ) orelse return;
    c.adw_view_stack_page_set_icon_name(console_page, "utilities-terminal-symbolic");
    c.adw_toolbar_view_set_content(toolbar, view_stack_widget);
    c.adw_application_window_set_content(application_window, toolbar_widget);
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
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&windowDestroyed), state, null, 0);
    _ = c.g_signal_connect_data(
        window,
        "notify::is-active",
        @ptrCast(&windowActiveChanged),
        state,
        null,
        0,
    );
    state.setRunningControls(false);
    state.refreshLibrary(null);
    if (state.load_saved_configuration) state.loadSelectedOrNew();
    c.gtk_window_present(window);
    state.registry.claimClipboard(state);
    if (state.kernel_path != null or state.firmware_path != null or
        state.iso_path != null or state.disk_path != null)
    {
        state.start();
    }
}

fn addPathRow(
    group: *c.AdwPreferencesGroup,
    state: *State,
    label_text: [*:0]const u8,
    placeholder: [*:0]const u8,
    initial_value: ?[]const u8,
    clicked: *const anyopaque,
) ?*c.GtkEditable {
    const row_widget = c.adw_entry_row_new() orelse return null;
    const row: *c.AdwEntryRow = @ptrCast(row_widget);
    const entry: *c.GtkEditable = @ptrCast(row_widget);
    c.adw_preferences_row_set_title(@ptrCast(row), label_text);
    c.gtk_widget_set_tooltip_text(row_widget, placeholder);
    setEntryValue(state, entry, initial_value);
    const browse = c.gtk_button_new_from_icon_name("folder-open-symbolic") orelse return null;
    c.gtk_widget_set_tooltip_text(browse, "Choose Location…");
    _ = c.g_signal_connect_data(browse, "clicked", clicked, state, null, 0);
    c.adw_entry_row_add_suffix(row, browse);
    c.adw_preferences_group_add(group, row_widget);
    return entry;
}

fn addPreferencesGroup(
    page: *c.AdwPreferencesPage,
    title: [*:0]const u8,
    description: [*:0]const u8,
) ?*c.AdwPreferencesGroup {
    const widget = createPreferencesGroup(title, description) orelse return null;
    const group: *c.AdwPreferencesGroup = @ptrCast(widget);
    c.adw_preferences_page_add(page, group);
    return group;
}

fn addBoxPreferencesGroup(
    box: *c.GtkBox,
    title: [*:0]const u8,
    description: [*:0]const u8,
) ?*c.AdwPreferencesGroup {
    const widget = createPreferencesGroup(title, description) orelse return null;
    const group: *c.AdwPreferencesGroup = @ptrCast(widget);
    c.gtk_box_append(box, widget);
    return group;
}

fn createPreferencesGroup(
    title: [*:0]const u8,
    description: [*:0]const u8,
) ?*c.GtkWidget {
    const widget = c.adw_preferences_group_new() orelse return null;
    c.adw_preferences_group_set_title(@ptrCast(widget), title);
    c.adw_preferences_group_set_description(@ptrCast(widget), description);
    return widget;
}

fn addActionRow(
    group: *c.AdwPreferencesGroup,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
) ?*c.AdwActionRow {
    const widget = c.adw_action_row_new() orelse return null;
    const row: *c.AdwActionRow = @ptrCast(widget);
    c.adw_preferences_row_set_title(@ptrCast(row), title);
    c.adw_action_row_set_subtitle(row, subtitle);
    c.adw_preferences_group_add(group, widget);
    return row;
}

fn addEntryRow(
    group: *c.AdwPreferencesGroup,
    state: *State,
    title: [*:0]const u8,
    value: ?[]const u8,
) ?*c.GtkEditable {
    const widget = c.adw_entry_row_new() orelse return null;
    c.adw_preferences_row_set_title(@ptrCast(widget), title);
    const editable: *c.GtkEditable = @ptrCast(widget);
    setEntryValue(state, editable, value);
    c.adw_preferences_group_add(group, widget);
    return editable;
}

fn addSpinRow(
    group: *c.AdwPreferencesGroup,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    minimum: f64,
    maximum: f64,
    step: f64,
    value: f64,
) ?*c.AdwSpinRow {
    const widget = c.adw_spin_row_new_with_range(minimum, maximum, step) orelse return null;
    const row: *c.AdwSpinRow = @ptrCast(widget);
    c.adw_preferences_row_set_title(@ptrCast(row), title);
    c.adw_action_row_set_subtitle(@ptrCast(row), subtitle);
    c.adw_spin_row_set_value(row, value);
    c.adw_preferences_group_add(group, widget);
    return row;
}

fn addSwitchRow(
    group: *c.AdwPreferencesGroup,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    active: bool,
) ?*c.AdwSwitchRow {
    const widget = c.adw_switch_row_new() orelse return null;
    const row: *c.AdwSwitchRow = @ptrCast(widget);
    c.adw_preferences_row_set_title(@ptrCast(row), title);
    c.adw_preferences_row_set_use_underline(@ptrCast(row), c.TRUE);
    c.adw_action_row_set_subtitle(@ptrCast(row), subtitle);
    c.adw_switch_row_set_active(row, if (active) c.TRUE else c.FALSE);
    c.adw_preferences_group_add(group, widget);
    return row;
}

fn createIconButton(
    icon_name: [*:0]const u8,
    tooltip: [*:0]const u8,
    clicked: *const anyopaque,
    state: *State,
) ?*c.GtkWidget {
    const button = c.gtk_button_new_from_icon_name(icon_name) orelse return null;
    c.gtk_widget_set_tooltip_text(button, tooltip);
    _ = c.g_signal_connect_data(button, "clicked", clicked, state, null, 0);
    return button;
}

fn addRowButton(
    row: *c.AdwActionRow,
    icon_name: [*:0]const u8,
    tooltip: [*:0]const u8,
    clicked: *const anyopaque,
    state: *State,
) ?*c.GtkWidget {
    const button = createIconButton(icon_name, tooltip, clicked, state) orelse return null;
    c.adw_action_row_add_suffix(row, button);
    return button;
}

fn createPageBox() ?*c.GtkWidget {
    const widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12) orelse return null;
    c.gtk_widget_add_css_class(widget, "background");
    c.gtk_widget_set_margin_top(widget, 16);
    c.gtk_widget_set_margin_bottom(widget, 16);
    c.gtk_widget_set_margin_start(widget, 16);
    c.gtk_widget_set_margin_end(widget, 16);
    return widget;
}

fn allocateFrameBuffer(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) (std.mem.Allocator.Error || error{Overflow})![]u8 {
    const pixels = try std.math.mul(usize, @intCast(width), @intCast(height));
    const bytes = try std.math.mul(usize, pixels, 4);
    return allocator.alloc(u8, bytes);
}

fn dupeOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) std.mem.Allocator.Error!?[]const u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

fn setEntryValue(state: *State, entry: *c.GtkEditable, value: ?[]const u8) void {
    const bytes = value orelse {
        c.gtk_editable_set_text(entry, "");
        return;
    };
    const terminated = state.allocator.dupeZ(u8, bytes) catch return;
    defer state.allocator.free(terminated);
    c.gtk_editable_set_text(entry, terminated.ptr);
}

fn entryValue(entry: *c.GtkEditable) ?[]const u8 {
    const value = std.mem.span(c.gtk_editable_get_text(entry));
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
            c.gtk_button_set_icon_name(
                @ptrCast(state.pause_button.?),
                "media-playback-start-symbolic",
            );
            c.gtk_widget_set_tooltip_text(state.pause_button.?, "Resume Virtual Machine");
            c.gtk_label_set_text(state.status.?, "Paused");
        },
        .paused => if (vm.requestResume()) {
            c.gtk_button_set_icon_name(
                @ptrCast(state.pause_button.?),
                "media-playback-pause-symbolic",
            );
            c.gtk_widget_set_tooltip_text(state.pause_button.?, "Pause Virtual Machine");
            c.gtk_label_set_text(state.status.?, "Running");
        },
        else => {},
    }
}

fn shutdownGuestClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    vm.requestGuestShutdown();
    c.gtk_label_set_text(state.status.?, "Guest shutdown requested");
}

fn rebootGuestClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    vm.requestGuestReboot();
    c.gtk_label_set_text(state.status.?, "Guest reboot requested");
}

fn trimClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    vm.trimGuestFilesystems();
    c.gtk_label_set_text(state.status.?, "Guest trim requested");
}

fn syncTimeClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    vm.syncGuestTime();
    c.gtk_label_set_text(state.status.?, "Guest time synchronized");
}

fn sendFileClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    if (state.vm == null) return;
    const dialog = c.gtk_file_chooser_native_new(
        "Send file to guest",
        state.window.?,
        c.GTK_FILE_CHOOSER_ACTION_OPEN,
        "Send",
        "Cancel",
    ) orelse return;
    _ = c.g_signal_connect_data(
        dialog,
        "response",
        @ptrCast(&sendFileChosen),
        state,
        null,
        0,
    );
    c.gtk_native_dialog_show(dialog);
}

fn sendFileChosen(
    dialog: *c.GtkNativeDialog,
    response: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    defer c.g_object_unref(dialog);
    defer c.gtk_native_dialog_destroy(dialog);
    if (response != c.GTK_RESPONSE_ACCEPT) return;
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    const file = c.gtk_file_chooser_get_file(@ptrCast(dialog)) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    vm.sendFileToGuest(std.mem.span(path)) catch |err| return state.setError(err);
    c.gtk_label_set_text(state.status.?, "File offered to guest");
}

fn snapshotClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    if (state.vm == null or state.snapshot_status.load(.acquire) != .idle) return;
    const dialog = c.gtk_file_chooser_native_new(
        "Choose snapshot directory",
        state.window.?,
        c.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "Snapshot",
        "Cancel",
    ) orelse return;
    _ = c.g_signal_connect_data(
        dialog,
        "response",
        @ptrCast(&snapshotDirectoryChosen),
        state,
        null,
        0,
    );
    c.gtk_native_dialog_show(dialog);
}

fn snapshotDirectoryChosen(
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
    state.beginSnapshot(std.mem.span(path));
}

fn snapshotThreadMain(state: *State, vm: *VM, path: []u8) void {
    defer state.allocator.free(path);
    vm.snapshotQuiesced(path) catch |err| {
        state.snapshot_error = err;
        state.snapshot_status.store(.failed, .release);
        return;
    };
    state.snapshot_status.store(.succeeded, .release);
}

fn guestClipboard(text: []const u8, userdata: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    if (!state.clipboard_active.load(.acquire)) return;
    if (text.len > agent.native.clipboard_text_bytes_max) return;
    if (!std.unicode.utf8ValidateSlice(text)) return;
    state.clipboard_lock.lockUncancelable(global.io());
    defer state.clipboard_lock.unlock(global.io());
    @memcpy(state.clipboard_text[0..text.len], text);
    state.clipboard_text_len = text.len;
    state.guest_clipboard_pending = true;
}

fn requestHostClipboard(userdata: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    if (!state.clipboard_active.load(.acquire)) return;
    state.host_clipboard_requested.store(true, .release);
}

fn clipboardChanged(_: *c.GdkClipboard, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    if (state.registry.clipboard_owner != state) return;
    if (state.ignore_clipboard_change) {
        state.ignore_clipboard_change = false;
        return;
    }
    if (state.vm) |vm| vm.hostClipboardGrab();
}

fn hostClipboardRead(
    _: ?*anyopaque,
    result: *c.GAsyncResult,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const clipboard = state.clipboard orelse return;
    var err: ?*c.GError = null;
    const text = c.gdk_clipboard_read_text_finish(clipboard, result, &err) orelse {
        if (err) |value| c.g_error_free(value);
        return;
    };
    defer c.g_free(text);
    if (state.registry.clipboard_owner != state) return;
    const bytes = std.mem.span(text);
    if (bytes.len > agent.native.clipboard_text_bytes_max) return;
    if (state.vm) |vm| vm.sendHostClipboard(bytes);
}

fn loadClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.loadConfiguration();
}

fn newClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.newConfiguration();
}

fn preferencesClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    c.adw_dialog_present(@ptrCast(state.preferences_dialog.?), @ptrCast(state.window.?));
}

fn savePreferencesClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.savePreferences();
}

fn saveClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.saveConfiguration();
}

fn deleteClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const selected = c.gtk_combo_box_text_get_active_text(state.vm_selector.?) orelse return;
    c.g_free(selected);
    const dialog = c.adw_alert_dialog_new(
        "Remove Virtual Machine?",
        "The saved configuration will be removed. Disk images and snapshots are kept.",
    ) orelse return;
    const alert: *c.AdwAlertDialog = @ptrCast(dialog);
    c.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    c.adw_alert_dialog_add_response(alert, "remove", "Remove");
    c.adw_alert_dialog_set_close_response(alert, "cancel");
    c.adw_alert_dialog_set_default_response(alert, "cancel");
    c.adw_alert_dialog_set_response_appearance(
        alert,
        "remove",
        c.ADW_RESPONSE_DESTRUCTIVE,
    );
    _ = c.g_signal_connect_data(dialog, "response", @ptrCast(&deleteResponse), state, null, 0);
    c.adw_dialog_present(dialog, @ptrCast(state.window.?));
}

fn deleteResponse(
    _: *c.AdwAlertDialog,
    response: [*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (!std.mem.eql(u8, std.mem.span(response), "remove")) return;
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

fn chooseRestoreClicked(_: *c.GtkButton, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    chooseFolder(state, state.restore_entry.?, "Choose snapshot directory");
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
    const size_gib: c_int = @intFromFloat(c.adw_spin_row_get_value(state.disk_size_spin.?));
    if (size_gib <= 0) return state.setError(error.InvalidDiskSize);
    const size_bytes = std.math.mul(u64, @intCast(size_gib), 1024 * 1024 * 1024) catch {
        return state.setError(error.InvalidDiskSize);
    };
    disk.growRaw(path, size_bytes) catch |err| return state.setError(err);
    c.gtk_label_set_text(state.status.?, "Virtual disk grown");
}

fn chooseFile(state: *State, entry: *c.GtkEditable, title: [*:0]const u8) void {
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

fn chooseFolder(state: *State, entry: *c.GtkEditable, title: [*:0]const u8) void {
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
    const entry: *c.GtkEditable = @ptrCast(@alignCast(userdata orelse return));
    const file = c.gtk_file_chooser_get_file(@ptrCast(dialog)) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    c.gtk_editable_set_text(entry, path);
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
    const size_gib: c_int = @intFromFloat(c.adw_spin_row_get_value(state.disk_size_spin.?));
    if (size_gib <= 0) return state.setError(error.InvalidDiskSize);
    const size_bytes = std.math.mul(u64, @intCast(size_gib), 1024 * 1024 * 1024) catch {
        return state.setError(error.InvalidDiskSize);
    };
    disk.createSparse(std.mem.span(path), size_bytes) catch |err| return state.setError(err);
    c.gtk_editable_set_text(state.disk_entry.?, path);
    c.gtk_label_set_text(state.status.?, "Virtual disk created");
}

fn closeRequest(_: *c.GtkWindow, userdata: ?*anyopaque) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.FALSE));
    const vm = state.vm orelse return c.FALSE;
    state.closing = true;
    if (state.snapshot_status.load(.acquire) == .running) {
        c.gtk_label_set_text(state.status.?, "Finishing snapshot before closing…");
        return c.TRUE;
    }
    vm.requestStop();
    c.gtk_label_set_text(state.status.?, "Stopping…");
    return c.TRUE;
}

fn windowDestroyed(window: *c.GtkWindow, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    if (state.window != window) return;
    state.window = null;
    if (state.clipboard) |clipboard| {
        if (state.clipboard_signal_handler != 0) {
            c.g_signal_handler_disconnect(clipboard, state.clipboard_signal_handler);
            state.clipboard_signal_handler = 0;
        }
    }
    if (state.preferences_dialog) |dialog| {
        c.g_object_unref(dialog);
        state.preferences_dialog = null;
    }
    if (state.session_arena != null) state.registry.retire(state);
}

fn windowActiveChanged(
    window: *c.GtkWindow,
    _: *c.GParamSpec,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (c.gtk_window_is_active(window) == c.FALSE) return;
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    state.registry.claimClipboard(state);
}

fn tick(userdata: ?*anyopaque) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.G_SOURCE_REMOVE));
    state.flushOutput();
    state.finishSnapshot();
    const vm = state.vm orelse return c.G_SOURCE_REMOVE;
    state.refreshDisplay();
    state.refreshGuestTools();
    state.flushClipboard();
    if (vm.state() != .stopped) return c.G_SOURCE_CONTINUE;
    state.finish();
    return c.G_SOURCE_REMOVE;
}

fn scrollConsoleToEnd(userdata: ?*anyopaque) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.G_SOURCE_REMOVE));
    const scrolled = state.console_scroll orelse return c.G_SOURCE_REMOVE;
    const adjustment = c.gtk_scrolled_window_get_vadjustment(scrolled);
    c.gtk_adjustment_set_value(adjustment, c.gtk_adjustment_get_upper(adjustment));
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
    c.cairo_surface_mark_dirty(surface);
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

fn displayResized(
    _: *c.GtkDrawingArea,
    width: c_int,
    height: c_int,
    userdata: ?*anyopaque,
) callconv(.c) void {
    if (width <= 0 or height <= 0) return;
    const state: *State = @ptrCast(@alignCast(userdata orelse return));
    const vm = state.vm orelse return;
    vm.requestDisplayResize(@intCast(width), @intCast(height));
}

fn keyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    modifiers: c_uint,
    userdata: ?*anyopaque,
) callconv(.c) c.gboolean {
    const state: *State = @ptrCast(@alignCast(userdata orelse return c.FALSE));
    if (modifiers & c.GDK_CONTROL_MASK != 0 and keyval == ',') {
        state.preferences_shortcut_pressed = true;
        c.adw_dialog_present(@ptrCast(state.preferences_dialog.?), @ptrCast(state.window.?));
        return c.TRUE;
    }
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
    if (keyval == ',' and state.preferences_shortcut_pressed) {
        state.preferences_shortcut_pressed = false;
        return;
    }
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

test "session registry reuses retired slots" {
    var registry = SessionRegistry{};
    var sessions: [sessions_max + 1]*State = undefined;
    for (&sessions) |*session| {
        session.* = try std.testing.allocator.create(State);
        session.*.retired_next = null;
    }
    defer for (sessions) |session| std.testing.allocator.destroy(session);

    for (sessions[0..sessions_max]) |session| try registry.add(session);
    try std.testing.expectError(error.TooManySessions, registry.add(sessions[sessions_max]));
    registry.retire(sessions[3]);
    try registry.add(sessions[sessions_max]);

    try std.testing.expectEqual(sessions_max, registry.count);
    try std.testing.expectEqual(sessions[3], registry.retired.?);
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

fn defaultVarsTemplatePath() ?[]const u8 {
    const value = std.c.getenv("BOBRVM_OVMF_VARS_FD") orelse return null;
    const path = std.mem.span(value);
    return if (path.len == 0) null else path;
}
