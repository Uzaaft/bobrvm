const std = @import("std");
const testing = std.testing;
const tgsi = @import("gpu/virgl/tgsi.zig");

const text_bytes_max = 4096;
const structured_bytes_max = 512;
const opcodes = [_][]const u8{
    "MOV", "ADD", "MAD", "DP4", "RCP", "CMP", "TEX", "UMAD", "XOR", "END",
};

fn checkProgram(text: []const u8) !void {
    const program = tgsi.parse(text) catch return;
    try testing.expect(program.n_in <= tgsi.MAX_DECLS);
    try testing.expect(program.n_out <= tgsi.MAX_DECLS);
    try testing.expect(program.n_instr <= tgsi.MAX_INSTRS);
    for (program.instrs[0..program.n_instr]) |instruction| {
        try testing.expect(instruction.op_len <= instruction.op.len);
        try testing.expect(instruction.nsrc <= instruction.srcs.len);
    }

    var msl = tgsi.emit(testing.allocator, &program) catch |err| switch (err) {
        error.Malformed => return,
        else => return err,
    };
    defer msl.deinit(testing.allocator);
    try testing.expect(std.unicode.utf8ValidateSlice(msl.source));
    try testing.expect(msl.stage == .vertex or msl.stage == .fragment);
    try testing.expect(msl.entry.len > 0);
}

fn append(buffer: []u8, offset: *usize, comptime format: []const u8, args: anytype) !void {
    const written = try std.fmt.bufPrint(buffer[offset.*..], format, args);
    offset.* += written.len;
}

fn checkStructured(smith: *testing.Smith) !void {
    var text: [structured_bytes_max]u8 = undefined;
    var len: usize = 0;
    const fragment = smith.value(bool);
    try append(&text, &len, "{s}\n", .{if (fragment) "FRAG" else "VERT"});
    const opcode = opcodes[smith.valueRangeAtMost(u8, 0, opcodes.len - 1)];
    try append(&text, &len, "{s}", .{opcode});
    const operand_count = smith.valueRangeAtMost(u8, 0, 5);
    for (0..operand_count) |index| {
        try append(
            &text,
            &len,
            "{s}TEMP[{d}]",
            .{ if (index == 0) " " else ", ", smith.valueRangeAtMost(u8, 0, 63) },
        );
    }
    try append(&text, &len, "\n", .{});
    try checkProgram(text[0..len]);
}

fn checkTgsi(_: void, smith: *testing.Smith) !void {
    var body: [text_bytes_max]u8 = undefined;
    const body_len = smith.slice(&body);
    var text: ["VERT\n".len + text_bytes_max]u8 = undefined;
    const header = if (smith.value(bool)) "VERT\n" else "FRAG\n";
    @memcpy(text[0..header.len], header);
    @memcpy(text[header.len..][0..body_len], body[0..body_len]);
    try checkProgram(text[0 .. header.len + body_len]);
    try checkStructured(smith);
}

const seed_zero: [64]u8 = @splat(0);
const seed_ones: [64]u8 = @splat(0xFF);

test "TGSI parser and emitter properties" {
    return testing.fuzz({}, checkTgsi, .{ .corpus = &.{ &seed_zero, &seed_ones } });
}
