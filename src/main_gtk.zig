//! Linux GTK executable root.

const std = @import("std");
const global = @import("global.zig");
const gtk = @import("linux/gtk.zig");
const logging = @import("logging.zig");

pub const std_options = logging.std_options;

pub fn main(minimal: std.process.Init.Minimal) void {
    global.state.initWithLogging(.{ .stderr = true });
    defer global.state.deinit();
    gtk.main(minimal);
}
