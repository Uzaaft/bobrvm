//! Minimal TOML-subset parser for project files.
//!
//! Supports exactly what bobrvm.toml needs: top-level `key = value`
//! pairs with basic/literal strings, integers, booleans, and
//! single-line string arrays, plus `#` comments. No tables/sections,
//! no dotted keys, no multi-line values, no dates or floats — a
//! project file needs none of that, and unknown syntax fails loudly
//! (with the offending line number) instead of being half-parsed.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    string_array: []const []const u8,
};

pub const ParseError = error{
    Syntax,
    DuplicateKey,
    OutOfMemory,
};

pub const Table = struct {
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,

    pub fn deinit(self: *Table, alloc: Allocator) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            freeValue(alloc, entry.value_ptr.*);
        }
        self.map.deinit(alloc);
    }

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.map.get(key);
    }
};

fn freeValue(alloc: Allocator, value: Value) void {
    switch (value) {
        .string => |s| alloc.free(s),
        .string_array => |items| {
            for (items) |item| alloc.free(item);
            alloc.free(items);
        },
        else => {},
    }
}

/// Parse the subset. On error.Syntax/DuplicateKey, `error_line` (when
/// provided) holds the 1-based line number of the offending line.
pub fn parse(alloc: Allocator, text: []const u8, error_line: ?*usize) ParseError!Table {
    var table = Table{};
    errdefer table.deinit(alloc);

    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        if (error_line) |out| out.* = line_number;

        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.Syntax;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        if (!isBareKey(key)) return error.Syntax;
        const value_text = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (value_text.len == 0) return error.Syntax;

        const value = try parseValue(alloc, value_text);
        errdefer freeValue(alloc, value);

        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);
        const slot = try table.map.getOrPut(alloc, key_copy);
        if (slot.found_existing) return error.DuplicateKey;
        slot.value_ptr.* = value;
    }
    return table;
}

/// Strip a `#` comment, honoring quotes so `"#"` in strings survives.
fn stripComment(line: []const u8) []const u8 {
    var in_basic = false;
    var in_literal = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (in_basic) {
            if (byte == '\\') index += 1 // skip the escaped byte
            else if (byte == '"') in_basic = false;
            continue;
        }
        if (in_literal) {
            if (byte == '\'') in_literal = false;
            continue;
        }
        switch (byte) {
            '"' => in_basic = true,
            '\'' => in_literal = true,
            '#' => return line[0..index],
            else => {},
        }
    }
    return line;
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

fn parseValue(alloc: Allocator, text: []const u8) ParseError!Value {
    if (text[0] == '"' or text[0] == '\'') {
        return .{ .string = try parseString(alloc, text) };
    }
    if (text[0] == '[') {
        return .{ .string_array = try parseStringArray(alloc, text) };
    }
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    const integer = std.fmt.parseInt(i64, text, 10) catch return error.Syntax;
    return .{ .integer = integer };
}

/// Basic ("...", with \\ \" \n \t \r escapes) or literal ('...',
/// verbatim) string. The whole token must be consumed.
fn parseString(alloc: Allocator, text: []const u8) ParseError![]const u8 {
    var consumed: usize = undefined;
    const parsed = try parseStringToken(alloc, text, &consumed);
    errdefer alloc.free(parsed);
    if (consumed != text.len) return error.Syntax;
    return parsed;
}

fn parseStringToken(alloc: Allocator, text: []const u8, consumed: *usize) ParseError![]const u8 {
    if (text.len < 2) return error.Syntax;
    const quote = text[0];
    if (quote == '\'') {
        const end = std.mem.indexOfScalarPos(u8, text, 1, '\'') orelse return error.Syntax;
        consumed.* = end + 1;
        return alloc.dupe(u8, text[1..end]);
    }
    if (quote != '"') return error.Syntax;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 1;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '"') {
            consumed.* = index + 1;
            return out.toOwnedSlice(alloc);
        }
        if (byte == '\\') {
            if (index + 1 >= text.len) return error.Syntax;
            const escaped: u8 = switch (text[index + 1]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => return error.Syntax,
            };
            try out.append(alloc, escaped);
            index += 2;
            continue;
        }
        try out.append(alloc, byte);
        index += 1;
    }
    return error.Syntax;
}

/// Single-line array of strings: ["a", "b"] with an optional trailing
/// comma.
fn parseStringArray(alloc: Allocator, text: []const u8) ParseError![]const []const u8 {
    if (text[0] != '[' or text[text.len - 1] != ']') return error.Syntax;
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |item| alloc.free(item);
        items.deinit(alloc);
    }

    var rest = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
    while (rest.len > 0) {
        var consumed: usize = undefined;
        const item = try parseStringToken(alloc, rest, &consumed);
        {
            errdefer alloc.free(item);
            try items.append(alloc, item);
        }
        rest = std.mem.trimStart(u8, rest[consumed..], " \t");
        if (rest.len == 0) break;
        if (rest[0] != ',') return error.Syntax;
        rest = std.mem.trimStart(u8, rest[1..], " \t");
    }
    return items.toOwnedSlice(alloc);
}

const testing = std.testing;

test "toml: parses the full supported subset" {
    const text =
        \\# a project file
        \\name = "webapp"        # trailing comment
        \\memory = 4096
        \\gpu = true
        \\sound = false
        \\cmdline = "console=hvc0 quote=\" tab=\t"
        \\literal = 'no #escapes\ here'
        \\forwards = ["2222:22", "8080:80",]
        \\empty = []
        \\
    ;
    var table = try parse(testing.allocator, text, null);
    defer table.deinit(testing.allocator);

    try testing.expectEqualStrings("webapp", table.get("name").?.string);
    try testing.expectEqual(@as(i64, 4096), table.get("memory").?.integer);
    try testing.expect(table.get("gpu").?.boolean);
    try testing.expect(!table.get("sound").?.boolean);
    try testing.expectEqualStrings("console=hvc0 quote=\" tab=\t", table.get("cmdline").?.string);
    try testing.expectEqualStrings("no #escapes\\ here", table.get("literal").?.string);
    const forwards = table.get("forwards").?.string_array;
    try testing.expectEqual(@as(usize, 2), forwards.len);
    try testing.expectEqualStrings("2222:22", forwards[0]);
    try testing.expectEqualStrings("8080:80", forwards[1]);
    try testing.expectEqual(@as(usize, 0), table.get("empty").?.string_array.len);
    try testing.expect(table.get("missing") == null);
}

test "toml: rejects unsupported syntax with the line number" {
    const cases = [_]struct { text: []const u8, line: usize }{
        .{ .text = "key = \"fine\"\n[section]\n", .line = 2 },
        .{ .text = "bad key = 1\n", .line = 1 },
        .{ .text = "key =\n", .line = 1 },
        .{ .text = "key = \"unterminated\n", .line = 1 },
        .{ .text = "key = \"bad\\escape\"\n", .line = 1 },
        .{ .text = "key = 1.5\n", .line = 1 },
        .{ .text = "key = [\"a\" \"b\"]\n", .line = 1 },
        .{ .text = "key = \"x\" trailing\n", .line = 1 },
        .{ .text = "ok = 1\nok = 2\n", .line = 2 },
    };
    for (cases) |case| {
        var line: usize = 0;
        const result = parse(testing.allocator, case.text, &line);
        if (result) |*table| {
            var mutable = table.*;
            mutable.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expect(err == error.Syntax or err == error.DuplicateKey);
            try testing.expectEqual(case.line, line);
        }
    }
}

test "toml: parse allocation failure leaks nothing" {
    const text =
        \\name = "webapp"
        \\forwards = ["2222:22", "8080:80"]
        \\memory = 2048
        \\
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var table = try parse(alloc, text, null);
            table.deinit(alloc);
        }
    }.run, .{});
}
