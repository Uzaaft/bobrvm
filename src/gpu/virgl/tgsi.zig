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
    /// Swizzle (src) or writemask (dst) as up to 4 component chars.
    swz: [4]u8 = .{ 'x', 'y', 'z', 'w' },
    swz_len: u8 = 4,
    negate: bool = false,
    abs_val: bool = false,

    /// The swizzle padded to 4 chars (TGSI replicates the last component).
    pub fn swz4(self: Operand) [4]u8 {
        var out = self.swz;
        var i: usize = self.swz_len;
        const last = if (self.swz_len > 0) self.swz[self.swz_len - 1] else 'x';
        while (i < 4) : (i += 1) out[i] = last;
        return out;
    }
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
    /// Highest TEMP index referenced (-1 = none); temps are emitted as
    /// local float4 t0..tN.
    max_temp: i64 = -1,
    /// Parsed IMM immediates (declared as const float4 immK).
    imms: [MAX_IMM][4]f32 = undefined,
    imm_present: [MAX_IMM]bool = [_]bool{false} ** MAX_IMM,
    /// Whether any CONST[] was referenced (needs a uniform buffer binding).
    uses_const: bool = false,
    uses_sampler: bool = false,
};

pub const MAX_IMM = 64;

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

/// Parse a register reference "[-|]FILE[idx][.swz][|]" into an Operand,
/// capturing negate/abs modifiers and the swizzle/writemask. Returns null
/// if it does not look like a register reference.
fn parseOperand(token_in: []const u8) ?Operand {
    var token = std.mem.trim(u8, token_in, " \t");
    var negate = false;
    var abs_val = false;
    if (token.len > 0 and token[0] == '-') {
        negate = true;
        token = token[1..];
    }
    if (token.len >= 2 and token[0] == '|' and token[token.len - 1] == '|') {
        abs_val = true;
        token = token[1 .. token.len - 1];
    }

    const lb = std.mem.indexOfScalar(u8, token, '[') orelse return null;
    const rb = std.mem.indexOfScalar(u8, token, ']') orelse return null;
    if (rb <= lb + 1) return null;
    const file = parseFile(token[0..lb]);
    const idx = std.fmt.parseInt(u32, token[lb + 1 .. rb], 10) catch return null;

    var op = Operand{ .file = file, .index = idx, .negate = negate, .abs_val = abs_val };

    // Optional ".swz" after the closing bracket.
    if (rb + 1 < token.len and token[rb + 1] == '.') {
        const swz = token[rb + 2 ..];
        var n: u8 = 0;
        for (swz) |c| {
            const norm: u8 = switch (c) {
                'x', 'r' => 'x',
                'y', 'g' => 'y',
                'z', 'b' => 'z',
                'w', 'a' => 'w',
                else => break,
            };
            if (n >= 4) break;
            op.swz[n] = norm;
            n += 1;
        }
        if (n > 0) op.swz_len = n;
    }
    return op;
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
    // Field defaults apply (n_* = 0, uses_* = false); `undefined` would
    // leave the bool flags as garbage when never set by trackOperand.
    var prog: Program = .{ .stage = .vertex };

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
        if (std.mem.startsWith(u8, line, "IMM")) {
            parseImm(&prog, line);
            continue;
        }
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

/// Parse "IMM[k] FLT32 { a, b, c, d }" into prog.imms[k].
fn parseImm(prog: *Program, line: []const u8) void {
    const lb = std.mem.indexOfScalar(u8, line, '[') orelse return;
    const rb = std.mem.indexOfScalar(u8, line, ']') orelse return;
    if (rb <= lb + 1) return;
    const idx = std.fmt.parseInt(usize, line[lb + 1 .. rb], 10) catch return;
    if (idx >= MAX_IMM) return;

    const ob = std.mem.indexOfScalar(u8, line, '{') orelse return;
    const cb = std.mem.indexOfScalar(u8, line, '}') orelse return;
    if (cb <= ob + 1) return;

    var vals = [_]f32{ 0, 0, 0, 0 };
    var it = std.mem.tokenizeAny(u8, line[ob + 1 .. cb], ", \t");
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i >= 4) break;
        vals[i] = std.fmt.parseFloat(f32, tok) catch 0;
    }
    prog.imms[idx] = vals;
    prog.imm_present[idx] = true;
}

fn trackOperand(prog: *Program, o: Operand) void {
    switch (o.file) {
        .temp => if (@as(i64, o.index) > prog.max_temp) {
            prog.max_temp = @intCast(o.index);
        },
        .constant => prog.uses_const = true,
        .sampler => prog.uses_sampler = true,
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

    if (instr.dst) |d| trackOperand(prog, d);
    for (instr.srcs[0..instr.nsrc]) |s| trackOperand(prog, s);

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

/// Write the MSL base name (no swizzle/modifiers) for an operand.
fn appendBase(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program, o: Operand) !void {
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
        .temp => try app(w, alloc, "t{d}", .{o.index}),
        .immediate => try app(w, alloc, "imm{d}", .{o.index}),
        .constant => try app(w, alloc, "c[{d}]", .{o.index}),
        else => try app(w, alloc, "float4(0.0)", .{}),
    }
}

/// Write a source operand as a float4 expression: base.swizzle with
/// optional abs()/negate applied.
fn appendSrc(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program, o: Operand) !void {
    if (o.negate) try app(w, alloc, "(-", .{});
    if (o.abs_val) try app(w, alloc, "abs(", .{});
    try appendBase(w, alloc, prog, o);
    const s = o.swz4();
    try app(w, alloc, ".{c}{c}{c}{c}", .{ s[0], s[1], s[2], s[3] });
    if (o.abs_val) try app(w, alloc, ")", .{});
    if (o.negate) try app(w, alloc, ")", .{});
}

/// Write the dst writemask (its swz chars).
fn appendMask(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, o: Operand) !void {
    var i: usize = 0;
    while (i < o.swz_len) : (i += 1) try app(w, alloc, "{c}", .{o.swz[i]});
}

fn isSupported(op: []const u8) bool {
    const ops = [_][]const u8{
        "MOV", "ADD", "SUB", "MUL", "MAD", "DP2", "DP3", "DP4",
        "MAX", "MIN", "RCP", "RSQ", "FRC", "FLR", "ABS", "SQRT",
        "TEX", "TXP",
    };
    for (ops) |o| if (std.mem.eql(u8, op, o)) return true;
    return false;
}

/// Emit the float4 right-hand-side expression for a supported opcode.
fn appendRhs(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program, instr: *const Instr) !void {
    const op = instr.opName();
    const s = instr.srcs;
    if (std.mem.eql(u8, op, "TEX")) {
        // dst = tex0.sample(smp0, coord.xy)   (2D targets only for now;
        // the sampler operand selects the unit — single unit so far.)
        try app(w, alloc, "tex0.sample(smp0, (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xy)", .{});
    } else if (std.mem.eql(u8, op, "TXP")) {
        // Projective: divide coords by w before sampling.
        try app(w, alloc, "tex0.sample(smp0, (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xy / (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").w)", .{});
    } else if (std.mem.eql(u8, op, "MOV")) {
        try appendSrc(w, alloc, prog, s[0]);
    } else if (std.mem.eql(u8, op, "ADD")) {
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, " + ", .{});
        try appendSrc(w, alloc, prog, s[1]);
    } else if (std.mem.eql(u8, op, "SUB")) {
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, " - ", .{});
        try appendSrc(w, alloc, prog, s[1]);
    } else if (std.mem.eql(u8, op, "MUL")) {
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, " * ", .{});
        try appendSrc(w, alloc, prog, s[1]);
    } else if (std.mem.eql(u8, op, "MAD")) {
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, " * ", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, " + ", .{});
        try appendSrc(w, alloc, prog, s[2]);
    } else if (std.mem.eql(u8, op, "MAX") or std.mem.eql(u8, op, "MIN")) {
        try app(w, alloc, "{s}(", .{if (op[1] == 'A') "max" else "min"});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ", ", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "DP4")) {
        try app(w, alloc, "float4(dot(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ", ", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "DP3")) {
        try app(w, alloc, "float4(dot((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xyz, (", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ").xyz))", .{});
    } else if (std.mem.eql(u8, op, "DP2")) {
        try app(w, alloc, "float4(dot((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xy, (", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ").xy))", .{});
    } else if (std.mem.eql(u8, op, "RCP")) {
        try app(w, alloc, "float4(1.0/(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x)", .{});
    } else if (std.mem.eql(u8, op, "RSQ")) {
        try app(w, alloc, "float4(rsqrt((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x))", .{});
    } else if (std.mem.eql(u8, op, "SQRT")) {
        try app(w, alloc, "sqrt(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "FRC")) {
        try app(w, alloc, "fract(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "FLR")) {
        try app(w, alloc, "floor(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "ABS")) {
        try app(w, alloc, "abs(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    }
}

/// Emit TEMP/IMM local declarations at the top of the function body.
fn emitLocals(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program) !void {
    var t: i64 = 0;
    while (t <= prog.max_temp) : (t += 1) {
        try app(w, alloc, "    float4 t{d} = float4(0.0);\n", .{t});
    }
    for (prog.imms[0..], 0..) |vals, k| {
        if (!prog.imm_present[k]) continue;
        try app(w, alloc, "    float4 imm{d} = float4({d}, {d}, {d}, {d});\n", .{ k, vals[0], vals[1], vals[2], vals[3] });
    }
}

/// Translate a parsed program to MSL. Only the MOV subset is emitted;
/// unsupported opcodes become comments so the shader still compiles.
pub fn emit(alloc: Allocator, prog: *const Program) Error!Msl {
    var w: std.ArrayListUnmanaged(u8) = .empty;
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
    const has_in = prog.n_in > 0;
    if (has_in) {
        try app(w, alloc, "struct VSIn {{\n", .{});
        for (prog.in_decls[0..prog.n_in]) |d| {
            try app(w, alloc, "    float4 a{d} [[attribute({d})]];\n", .{ d.index, d.index });
        }
        try app(w, alloc, "}};\n", .{});
    }

    try app(w, alloc, "struct VSOut {{\n", .{});
    var has_position = false;
    for (prog.out_decls[0..prog.n_out]) |d| {
        if (d.semantic == .position) {
            try app(w, alloc, "    float4 position [[position]];\n", .{});
            has_position = true;
        } else {
            // Varying linkage keys on the SEMANTIC index (GENERIC[n]),
            // not the register index — the FS declares its own registers.
            try app(w, alloc, "    float4 g{d} [[user(locn{d})]];\n", .{ d.index, d.semantic_index });
        }
    }
    if (!has_position) try app(w, alloc, "    float4 position [[position]];\n", .{});
    try app(w, alloc, "}};\n", .{});

    try app(w, alloc, "vertex VSOut vs_main(", .{});
    var need_comma = false;
    if (has_in) {
        try app(w, alloc, "VSIn in [[stage_in]]", .{});
        need_comma = true;
    }
    if (prog.uses_const) {
        if (need_comma) try app(w, alloc, ", ", .{});
        try app(w, alloc, "constant float4* c [[buffer(1)]]", .{});
    }
    try app(w, alloc, ") {{\n    VSOut out;\n", .{});
    if (!has_position) try app(w, alloc, "    out.position = float4(0.0,0.0,0.0,1.0);\n", .{});
    try emitLocals(w, alloc, prog);
    try emitBody(w, alloc, prog);
    try app(w, alloc, "    return out;\n}}\n", .{});
}

fn emitFragment(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program) !void {
    const has_in = prog.n_in > 0;
    if (has_in) {
        try app(w, alloc, "struct FSIn {{\n", .{});
        for (prog.in_decls[0..prog.n_in]) |d| {
            try app(w, alloc, "    float4 a{d} [[user(locn{d})]];\n", .{ d.index, d.semantic_index });
        }
        try app(w, alloc, "}};\n", .{});
    }

    // Build the parameter list (omit an empty [[stage_in]] — invalid MSL).
    try app(w, alloc, "fragment float4 fs_main(", .{});
    var need_comma = false;
    if (has_in) {
        try app(w, alloc, "FSIn in [[stage_in]]", .{});
        need_comma = true;
    }
    if (prog.uses_const) {
        if (need_comma) try app(w, alloc, ", ", .{});
        try app(w, alloc, "constant float4* c [[buffer(1)]]", .{});
        need_comma = true;
    }
    if (prog.uses_sampler) {
        if (need_comma) try app(w, alloc, ", ", .{});
        try app(w, alloc, "texture2d<float> tex0 [[texture(0)]], sampler smp0 [[sampler(0)]]", .{});
    }
    try app(w, alloc, ") {{\n    float4 out0 = float4(0.0,0.0,0.0,1.0);\n", .{});
    try emitLocals(w, alloc, prog);
    try emitBody(w, alloc, prog);
    try app(w, alloc, "    return out0;\n}}\n", .{});
}

fn emitBody(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program) !void {
    for (prog.instrs[0..prog.n_instr]) |*instr| {
        const op = instr.opName();
        if (std.mem.eql(u8, op, "END") or std.mem.eql(u8, op, "RET")) continue;
        const dst = instr.dst orelse {
            try app(w, alloc, "    // no-dst: {s}\n", .{op});
            continue;
        };
        if (!isSupported(op)) {
            try app(w, alloc, "    // unsupported: {s}\n", .{op});
            continue;
        }
        // dst.<mask> = (<rhs>).<mask>;
        try app(w, alloc, "    ", .{});
        try appendBase(w, alloc, prog, dst);
        try app(w, alloc, ".", .{});
        try appendMask(w, alloc, dst);
        try app(w, alloc, " = (", .{});
        try appendRhs(w, alloc, prog, instr);
        try app(w, alloc, ").", .{});
        try appendMask(w, alloc, dst);
        try app(w, alloc, ";\n", .{});
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
    try std.testing.expect(std.mem.indexOf(u8, msl.source, "out.position.xyzw = (in.a0.xyzw).xyzw;") != null);
}

test "parse and emit arithmetic shader (MAD, DP4, swizzle, IMM, TEMP)" {
    const src =
        \\VERT
        \\DCL IN[0]
        \\DCL IN[1]
        \\DCL OUT[0], POSITION
        \\DCL OUT[1], GENERIC[0]
        \\DCL TEMP[0]
        \\IMM[0] FLT32 { 0.5000, 0.5000, 0.0000, 1.0000}
        \\  0: MAD TEMP[0], IN[0], IMM[0].xxxx, IMM[0]
        \\  1: DP4 OUT[0].x, TEMP[0], IN[0]
        \\  2: MOV OUT[1].xy, IN[1].yx
        \\  3: END
    ;
    const prog = try parse(src);
    try std.testing.expectEqual(@as(i64, 0), prog.max_temp);
    try std.testing.expect(prog.imm_present[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), prog.imms[0][0], 0.001);

    var msl = try emit(std.testing.allocator, &prog);
    defer msl.deinit(std.testing.allocator);
    // MAD lowered to a*b+c; DP4 as dot; writemask + swizzle preserved.
    try std.testing.expect(std.mem.indexOf(u8, msl.source, "float4 t0 = float4(0.0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl.source, "imm0 = float4(0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl.source, "out.position.x = (float4(dot(") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl.source, "out.g1.xy = (in.a1.yxxx).xy;") != null);
}
