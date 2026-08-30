//! Atomic replacement of project warm-state checkpoints.

const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");

pub fn replace(
    alloc: Allocator,
    final_path: []const u8,
    context: anytype,
    save: anytype,
) !void {
    const temporary_path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}.tmp",
        .{final_path},
        0,
    );
    defer alloc.free(temporary_path);

    const io = global.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, temporary_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer cwd.deleteFile(io, temporary_path) catch {};
    try save(context, temporary_path);
    try cwd.rename(temporary_path, cwd, final_path, io);
}

const TestSaver = struct {
    content: []const u8,
    fail_after_write: bool,

    fn save(self: *const TestSaver, path: [:0]const u8) !void {
        const io = global.io();
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.writePositionalAll(io, self.content, 0);
        if (self.fail_after_write) return error.SaveFailed;
    }
};

test "checkpoint: failed save preserves the previous checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = global.io();
    var path_buffer: [1024]u8 = undefined;
    const directory_len = try tmp.dir.realPath(io, &path_buffer);
    const final_path = try std.fmt.bufPrint(
        path_buffer[directory_len..],
        "/warm.img",
        .{},
    );
    const path = path_buffer[0 .. directory_len + final_path.len];

    const previous = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try previous.writePositionalAll(io, "previous", 0);
    previous.close(io);

    const saver = TestSaver{ .content = "partial", .fail_after_write = true };
    try std.testing.expectError(
        error.SaveFailed,
        replace(std.testing.allocator, path, &saver, TestSaver.save),
    );

    const checkpoint = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer checkpoint.close(io);
    var content: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, content.len), try checkpoint.readPositionalAll(
        io,
        &content,
        0,
    ));
    try std.testing.expectEqualStrings("previous", &content);

    const temporary_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.tmp", .{path});
    defer std.testing.allocator.free(temporary_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(io, temporary_path, .{ .mode = .read_only }),
    );
}

test "checkpoint: successful save atomically replaces the checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = global.io();
    var path_buffer: [1024]u8 = undefined;
    const directory_len = try tmp.dir.realPath(io, &path_buffer);
    const final_path = try std.fmt.bufPrint(
        path_buffer[directory_len..],
        "/warm.img",
        .{},
    );
    const path = path_buffer[0 .. directory_len + final_path.len];

    const previous = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try previous.writePositionalAll(io, "old", 0);
    previous.close(io);
    const previous_inode = (try std.Io.Dir.cwd().statFile(io, path, .{})).inode;

    const saver = TestSaver{ .content = "new", .fail_after_write = false };
    try replace(std.testing.allocator, path, &saver, TestSaver.save);

    const saved_inode = (try std.Io.Dir.cwd().statFile(io, path, .{})).inode;
    try std.testing.expect(saved_inode != previous_inode);
    const checkpoint = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer checkpoint.close(io);
    var content: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, content.len), try checkpoint.readPositionalAll(
        io,
        &content,
        0,
    ));
    try std.testing.expectEqualStrings("new", &content);
}
