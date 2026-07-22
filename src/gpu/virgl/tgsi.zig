//! TGSI (text) → Metal Shading Language translator.
//!
//! The guest mesa virgl driver serializes shaders as TGSI *text* (via
//! tgsi_dump) and ships that string in the create_object SHADER command.
//! This module parses that text and emits MSL, so guest OpenGL shaders run
//! as real Metal functions instead of the fixed-function passthrough
//! stand-in.
//!
//! Scope grows opcode-by-opcode. The first slice handles the passthrough
//! shape (DCL IN/OUT with semantics, full-register MOV, END) which is what
//! trivial vertex/fragment programs reduce to; it is validated by compiling
//! the emitted MSL on a real Metal device. More opcodes (MUL/ADD/MAD/DP4,
//! swizzles, CONST/TEMP/IMM, samplers) land in later passes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Stage = enum { vertex, fragment, geometry, tess_ctrl, tess_eval, compute };

pub const RegFile = enum { in, out, temp, constant, immediate, sampler, unknown };

pub const Semantic = enum { position, color, generic, psize, fog, other };

pub const Operand = struct {
    file: RegFile,
    index: u32,
};

pub const Decl = struct {
    file: RegFile,
    index: u32,
    semantic: Semantic = .other,
    semantic_index: u32 = 0,
};

pub const Instr = struct {
    op: [16]u8 = [_]u8{0} ** 16,
    op_len: usize = 0,
    dst: ?Operand = null,
    srcs: [4]Operand = undefined,
    nsrc: usize = 0,

    pub fn opName(self: *const Instr) []const u8 {
        return self.op[0..self.op_len];
    }
};

pub const Error = error{
    NoHeader,
    TooManyDecls,
    TooManyInstrs,
    Malformed,
} || Allocator.Error;

pub const MAX_DECLS = 32;
pub const MAX_INSTRS = 256;

/// Parsed TGSI program.
pub const Program = struct {
    stage: Stage,
    in_decls: [MAX_DECLS]Decl = undefined,
    n_in: usize = 0,
    out_decls: [MAX_DECLS]Decl = undefined,
    n_out: usize = 0,
    instrs: [MAX_INSTRS]Instr = undefined,
    n_instr: usize = 0,
};

fn parseFile(s: []const u8) RegFile {
    if (std.mem.eql(u8, s, "IN")) return .in;
    if (std.mem.eql(u8, s, "OUT")) return .out;
    if (std.mem.eql(u8, s, "TEMP")) return .temp;
    if (std.mem.eql(u8, s, "CONST")) return .constant;
    if (std.mem.eql(u8, s, "IMM")) return .immediate;
    if (std.mem.eql(u8, s, "SAMP")) return .sampler;
    return .unknown;
}

fn parseSemantic(s: []const u8) Semantic {
    if (std.mem.startsWith(u8, s, "POSITION")) return .position;
    if (std.mem.startsWith(u8, s, "COLOR")) return .color;
    if (std.mem.startsWith(u8, s, "GENERIC")) return .generic;
    if (std.mem.startsWith(u8, s, "PSIZE")) return .psize;
    if (std.mem.startsWith(u8, s, "FOG")) return .fog;
    return .other;
}

/// Parse "FILE[idx]" (ignoring any trailing swizzle/writemask) into an
/// Operand. Returns null if it does not look like a register reference.
fn parseOperand(token: []const u8) ?Operand {
    const lb = std.mem.indexOfScalar(u8, token, '[') orelse return null;
    const rb = std.mem.indexOfScalar(u8, token, ']') orelse return null;
    if (rb <= lb + 1) return null;
    const file = parseFile(token[0..lb]);
    const idx = std.fmt.parseInt(u32, token[lb + 1 .. rb], 10) catch return null;
    return .{ .file = file, .index = idx };
}

/// Strip a leading "N:" instruction number and surrounding whitespace.
fn stripLeadingNumber(line: []const u8) []const u8 {
    var s = std.mem.trim(u8, line, " \t");
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
        const head = s[0..colon];
        var all_digit = head.len > 0;
        for (head) |c| {
            if (c < '0' or c > '9') {
                all_digit = false;
                break;
            }
        }
        if (all_digit) s = std.mem.trim(u8, s[colon + 1 ..], " \t");
    }
    return s;
}

/// Parse TGSI text into a Program.
pub fn parse(text: []const u8) Error!Program {
    var prog: Program = undefined;
    prog.n_in = 0;
    prog.n_out = 0;
    prog.n_instr = 0;

    var have_header = false;

    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;

        if (!have_header) {
            if (std.mem.eql(u8, line, "VERT")) {
                prog.stage = .vertex;
                have_header = true;
            } else if (std.mem.eql(u8, line, "FRAG")) {
                prog.stage = .fragment;
                have_header = true;
            } else if (std.mem.eql(u8, line, "GEOM")) {
                prog.stage = .geometry;
                have_header = true;
            } else if (std.mem.eql(u8, line, "COMP")) {
                prog.stage = .compute;
                have_header = true;
            } else {
                return Error.NoHeader;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "DCL ")) {
            try parseDecl(&prog, line[4..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "IMM")) continue; // not modeled yet
        if (std.mem.startsWith(u8, line, "PROPERTY")) continue;

        try parseInstr(&prog, stripLeadingNumber(line));
    }

    if (!have_header) return Error.NoHeader;
    return prog;
}

fn parseDecl(prog: *Program, rest: []const u8) Error!void {
    var parts = std.mem.tokenizeScalar(u8, rest, ',');
    const reg = std.mem.trim(u8, parts.next() orelse return Error.Malformed, " \t");
    const operand = parseOperand(reg) orelse return; // ignore non-register decls

    var decl = Decl{ .file = operand.file, .index = operand.index };
    if (parts.next()) |sem_raw| {
        const sem = std.mem.trim(u8, sem_raw, " \t");
        decl.semantic = parseSemantic(sem);
        if (std.mem.indexOfScalar(u8, sem, '[')) |lb| {
            if (std.mem.indexOfScalar(u8, sem, ']')) |rb| {
                if (rb > lb + 1) decl.semantic_index = std.fmt.parseInt(u32, sem[lb + 1 .. rb], 10) catch 0;
            }
        }
    }

    switch (operand.file) {
        .in => {
            if (prog.n_in >= MAX_DECLS) return Error.TooManyDecls;
            prog.in_decls[prog.n_in] = decl;
            prog.n_in += 1;
        },
        .out => {
            if (prog.n_out >= MAX_DECLS) return Error.TooManyDecls;
            prog.out_decls[prog.n_out] = decl;
            prog.n_out += 1;
        },
        else => {},
    }
}

fn parseInstr(prog: *Program, body: []const u8) Error!void {
    if (prog.n_instr >= MAX_INSTRS) return Error.TooManyInstrs;

    const sp = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
    const op = std.mem.trim(u8, body[0..sp], " \t");
    if (op.len == 0) return;

    var instr = Instr{};
    const n = @min(op.len, instr.op.len);
    @memcpy(instr.op[0..n], op[0..n]);
    instr.op_len = n;

    if (sp < body.len) {
        var operands = std.mem.tokenizeScalar(u8, body[sp..], ',');
        var first = true;
        while (operands.next()) |o_raw| {
            const o = std.mem.trim(u8, o_raw, " \t");
            const operand = parseOperand(o);
            if (first) {
                instr.dst = operand;
                first = false;
            } else if (operand) |op_val| {
                if (instr.nsrc < instr.srcs.len) {
                    instr.srcs[instr.nsrc] = op_val;
                    instr.nsrc += 1;
                }
            }
        }
    }

    prog.instrs[prog.n_instr] = instr;
    prog.n_instr += 1;
}

// =============================================================================
// MSL emission
// =============================================================================

/// A translated shader ready to hand to Metal.
pub const Msl = struct {
    source: []u8, // owned by caller
    entry: []const u8, // static string
    stage: Stage,

    pub fn deinit(self: *Msl, alloc: Allocator) void {
        alloc.free(self.source);
    }
};

/// Append formatted text to the buffer.
fn app(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try w.appendSlice(alloc, s);
}

/// Write the MSL name for an operand reference in the current stage.
fn opName(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program, o: Operand) !void {
    switch (o.file) {
        .in => try app(w, alloc, "in.a{d}", .{o.index}),
        .out => {
            if (prog.stage == .fragment) {
                try app(w, alloc, "out{d}", .{o.index});
            } else {
                var is_pos = false;
                for (prog.out_decls[0..prog.n_out]) |d| {
                    if (d.index == o.index and d.semantic == .position) is_pos = true;
                }
                if (is_pos) {
                    try app(w, alloc, "out.position", .{});
                } else {
                    try app(w, alloc, "out.g{d}", .{o.index});
                }
            }
        },
        else => try app(w, alloc, "float4(0.0)", .{}),
    }
}

/// Translate a parsed program to MSL. Only the MOV subset is emitted;
/// unsupported opcodes become comments so the shader still compiles.
pub fn emit(alloc: Allocator, prog: *const Program) Error!Msl {
    var w = std.ArrayListUnmanaged(u8){};
    errdefer w.deinit(alloc);

    try app(&w, alloc, "#include <metal_stdlib>\nusing namespace metal;\n", .{});

    if (prog.stage == .vertex) {
        try emitVertex(&w, alloc, prog);
        return .{ .source = try w.toOwnedSlice(alloc), .entry = "vs_main", .stage = .vertex };
    } else if (prog.stage == .fragment) {
        try emitFragment(&w, alloc, prog);
        return .{ .source = try w.toOwnedSlice(alloc), .entry = "fs_main", .stage = .fragment };
    }
    return Error.Malformed;
}

fn emitVertex(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program) !void {
    try app(w, alloc, "struct VSIn {{\n", .{});
    for (prog.in_decls[0..prog.n_in]) |d| {
        try app(w, alloc, "    float4 a{d} [[attribute({d})]];\n", .{ d.index, d.index });
    }
    try app(w, alloc, "}};\n", .{});

    try app(w, alloc, "struct VSOut {{\n", .{});
    var has_position = false;
    for (prog.out_decls[0..prog.n_out]) |d| {
        if (d.semantic == .position) {
            try app(w, alloc, "    float4 position [[position]];\n", .{});
            has_position = true;
        } else {
            try app(w, alloc, "    float4 g{d} [[user(locn{d})]];\n", .{ d.index, d.index });
        }
    }
    if (!has_position) try app(w, alloc, "    float4 position [[position]];\n", .{});
    try app(w, alloc, "}};\n", .{});

    try app(w, alloc, "vertex VSOut vs_main(VSIn in [[stage_in]]) {{\n    VSOut out;\n", .{});
    if (!has_position) try app(w, alloc, "    out.position = float4(0.0,0.0,0.0,1.0);\n", .{});
    try emitBody(w, alloc, prog);
    try app(w, alloc, "    return out;\n}}\n", .{});
}

fn emitFragment(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program) !void {
    try app(w, alloc, "struct FSIn {{\n", .{});
    for (prog.in_decls[0..prog.n_in]) |d| {
        try app(w, alloc, "    float4 a{d} [[user(locn{d})]];\n", .{ d.index, d.index });
    }
    try app(w, alloc, "}};\n", .{});

    try app(w, alloc, "fragment float4 fs_main(FSIn in [[stage_in]]) {{\n    float4 out0 = float4(0.0,0.0,0.0,1.0);\n", .{});
    try emitBody(w, alloc, prog);
    try app(w, alloc, "    return out0;\n}}\n", .{});
}

fn emitBody(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program) !void {
    for (prog.instrs[0..prog.n_instr]) |*instr| {
        const op = instr.opName();
        if (std.mem.eql(u8, op, "END") or std.mem.eql(u8, op, "RET")) continue;
        if (std.mem.eql(u8, op, "MOV") and instr.dst != null and instr.nsrc >= 1) {
            try app(w, alloc, "    ", .{});
            try opName(w, alloc, prog, instr.dst.?);
            try app(w, alloc, " = ", .{});
            try opName(w, alloc, prog, instr.srcs[0]);
            try app(w, alloc, ";\n", .{});
        } else {
            try app(w, alloc, "    // unsupported: {s}\n", .{op});
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parse passthrough vertex shader" {
    const src =
        \\VERT
        \\DCL IN[0]
        \\DCL IN[1]
        \\DCL OUT[0], POSITION
        \\DCL OUT[1], GENERIC[0]
        \\  0: MOV OUT[0], IN[0]
        \\  1: MOV OUT[1], IN[1]
        \\  2: END
    ;
    const prog = try parse(src);
    try std.testing.expectEqual(Stage.vertex, prog.stage);
    try std.testing.expectEqual(@as(usize, 2), prog.n_in);
    try std.testing.expectEqual(@as(usize, 2), prog.n_out);
    try std.testing.expectEqual(Semantic.position, prog.out_decls[0].semantic);
    try std.testing.expectEqual(Semantic.generic, prog.out_decls[1].semantic);
    try std.testing.expectEqual(@as(usize, 3), prog.n_instr);
    try std.testing.expectEqualStrings("MOV", prog.instrs[0].opName());
}

test "emit MSL for passthrough vertex shader" {
    const src =
        \\VERT
        \\DCL IN[0]
        \\DCL OUT[0], POSITION
        \\  0: MOV OUT[0], IN[0]
        \\  1: END
    ;
    const prog = try parse(src);
    var msl = try emit(std.testing.allocator, &prog);
    defer msl.deinit(std.testing.allocator);

    try std.testing.expectEqual(Stage.vertex, msl.stage);
    try std.testing.expect(std.mem.indexOf(u8, msl.source, "vertex VSOut vs_main") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl.source, "out.position = in.a0;") != null);
}
