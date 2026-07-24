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

pub const RegFile = enum { in, out, temp, constant, immediate, sampler, system, unknown };

pub const Semantic = enum { position, color, generic, psize, fog, instanceid, vertexid, other };

pub const Operand = struct {
    file: RegFile,
    index: u32,
    /// For CONST 2D addressing CONST[dim][index]: dim is the uniform-buffer
    /// binding (0 = the default/inline block at buffer(1)); index is the
    /// element. Non-CONST operands leave dim = 0.
    dim: u32 = 0,
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
    uses_instance_id: bool = false,
    uses_vertex_id: bool = false,
    /// Bitmask of referenced UBO dims (bit d => CONST[d][..] used, d>=1).
    /// Dim 0 is the default inline block (uses_const).
    ubo_used: u16 = 0,
    /// Semantic of each declared SV[n] system-value register.
    sv_semantic: [MAX_DECLS]Semantic = @splat(.other),
};

pub const MAX_IMM = 64;

fn parseFile(s: []const u8) RegFile {
    if (std.mem.eql(u8, s, "IN")) return .in;
    if (std.mem.eql(u8, s, "OUT")) return .out;
    if (std.mem.eql(u8, s, "TEMP")) return .temp;
    if (std.mem.eql(u8, s, "CONST")) return .constant;
    if (std.mem.eql(u8, s, "IMM")) return .immediate;
    if (std.mem.eql(u8, s, "SAMP")) return .sampler;
    if (std.mem.eql(u8, s, "SV")) return .system;
    return .unknown;
}

fn parseSemantic(s: []const u8) Semantic {
    if (std.mem.startsWith(u8, s, "POSITION")) return .position;
    if (std.mem.startsWith(u8, s, "COLOR")) return .color;
    if (std.mem.startsWith(u8, s, "GENERIC")) return .generic;
    if (std.mem.startsWith(u8, s, "PSIZE")) return .psize;
    if (std.mem.startsWith(u8, s, "FOG")) return .fog;
    if (std.mem.startsWith(u8, s, "INSTANCEID")) return .instanceid;
    if (std.mem.startsWith(u8, s, "VERTEXID")) return .vertexid;
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
    const first = std.fmt.parseInt(u32, token[lb + 1 .. rb], 10) catch return null;

    var op = Operand{ .file = file, .index = first, .negate = negate, .abs_val = abs_val };

    // Second bracket => 2D CONST[dim][index]: first is the buffer dim.
    var after = rb + 1;
    if (after < token.len and token[after] == '[') {
        if (std.mem.indexOfScalarPos(u8, token, after, ']')) |rb2| {
            if (rb2 > after + 1) {
                const second = std.fmt.parseInt(u32, token[after + 1 .. rb2], 10) catch return null;
                op.dim = first;
                op.index = second;
                after = rb2 + 1;
            }
        }
    }

    // Optional ".swz" after the (last) closing bracket.
    if (after < token.len and token[after] == '.') {
        const swz = token[after + 1 ..];
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
        .system => {
            if (operand.index < MAX_DECLS) prog.sv_semantic[operand.index] = decl.semantic;
            if (decl.semantic == .instanceid) prog.uses_instance_id = true;
            if (decl.semantic == .vertexid) prog.uses_vertex_id = true;
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
        .constant => if (o.dim == 0) {
            prog.uses_const = true;
        } else if (o.dim < 16) {
            prog.ubo_used |= (@as(u16, 1) << @intCast(o.dim));
        },
        .sampler => prog.uses_sampler = true,
        .system => if (o.index < MAX_DECLS) {
            switch (prog.sv_semantic[o.index]) {
                .instanceid => prog.uses_instance_id = true,
                .vertexid => prog.uses_vertex_id = true,
                else => {},
            }
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
        .constant => if (o.dim == 0) {
            try app(w, alloc, "c[{d}]", .{o.index});
        } else {
            try app(w, alloc, "c{d}[{d}]", .{ o.dim, o.index });
        },
        .system => {
            const sem = if (o.index < prog.sv_semantic.len) prog.sv_semantic[o.index] else Semantic.other;
            switch (sem) {
                .instanceid => try app(w, alloc, "float4(float(vs_iid))", .{}),
                .vertexid => try app(w, alloc, "float4(float(vs_vid))", .{}),
                else => try app(w, alloc, "float4(0.0)", .{}),
            }
        },
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

fn isSupportedName(op: []const u8) bool {
    const ops = [_][]const u8{
        "MOV",   "ADD", "SUB", "MUL",   "MAD",   "DP2", "DP3", "DP4",
        "MAX",   "MIN", "RCP", "RSQ",   "FRC",   "FLR", "ABS", "SQRT",
        "TEX",   "TXP", "TXB", "TXL",   "TXF",   "CMP", "LRP", "SLT",
        "SGE",   "SEQ", "SNE",
        "POW",   "EX2", "LG2", "SIN",   "COS",   "TRUNC", "ROUND",
        "SSG",   "DDX", "DDY", "CEIL",  "XPD",   "NRM",   "DST",   "LIT",
        "I2F",   "U2F", "F2I", "F2U",   "INEG",  "IABS",  "UADD",  "UMUL",
        "UMAD",  "IMUL_HI", "ISHR", "USHR", "SHL", "AND",  "OR",    "XOR",
        "NOT",   "ISLT", "ISGE", "USLT", "USGE", "IMAX",  "IMIN",  "UMAX", "UMIN",
    };
    for (ops) |o| if (std.mem.eql(u8, op, o)) return true;
    return false;
}

/// Emit the float4 right-hand-side expression for a supported opcode.
/// Metal operator/function for an integer binary TGSI opcode, or null.
fn intBinOp(op: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, op, "UADD")) return "+";
    if (std.mem.eql(u8, op, "UMUL") or std.mem.eql(u8, op, "UMAD")) return "*";
    if (std.mem.eql(u8, op, "SHL")) return "<<";
    if (std.mem.eql(u8, op, "ISHR") or std.mem.eql(u8, op, "USHR")) return ">>";
    if (std.mem.eql(u8, op, "AND")) return "&";
    if (std.mem.eql(u8, op, "OR")) return "|";
    if (std.mem.eql(u8, op, "XOR")) return "^";
    if (std.mem.eql(u8, op, "IMAX") or std.mem.eql(u8, op, "UMAX")) return "max";
    if (std.mem.eql(u8, op, "IMIN") or std.mem.eql(u8, op, "UMIN")) return "min";
    return null;
}

/// Whether an integer binary op operates on signed int4 (vs uint4).
fn intOpSigned(op: []const u8) bool {
    return std.mem.eql(u8, op, "ISHR") or std.mem.eql(u8, op, "ISLT") or
        std.mem.eql(u8, op, "ISGE") or std.mem.eql(u8, op, "IMAX") or
        std.mem.eql(u8, op, "IMIN");
}

fn appendRhsNamed(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program, instr: *const Instr, op: []const u8) !void {
    const s = instr.srcs;
    // --- integer / bitwise ops (registers reinterpreted via as_type) ---
    if (std.mem.eql(u8, op, "I2F")) {
        try app(w, alloc, "float4(as_type<int4>(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "U2F")) {
        try app(w, alloc, "float4(as_type<uint4>(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "F2I")) {
        try app(w, alloc, "as_type<float4>(int4(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "F2U")) {
        try app(w, alloc, "as_type<float4>(uint4(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "INEG")) {
        try app(w, alloc, "as_type<float4>(-as_type<int4>(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "IABS")) {
        try app(w, alloc, "as_type<float4>(abs(as_type<int4>(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")))", .{});
    } else if (std.mem.eql(u8, op, "NOT")) {
        try app(w, alloc, "as_type<float4>(~as_type<uint4>(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "ISLT") or std.mem.eql(u8, op, "ISGE") or
        std.mem.eql(u8, op, "USLT") or std.mem.eql(u8, op, "USGE"))
    {
        const ty = if (op[0] == 'I') "int4" else "uint4";
        const cmp: []const u8 = if (std.mem.endsWith(u8, op, "SLT")) "<" else ">=";
        // true -> 0xFFFFFFFF (int -1), false -> 0, per TGSI integer set-ops.
        try app(w, alloc, "as_type<float4>(-int4(as_type<{s}>(", .{ty});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ") {s} as_type<{s}>(", .{ cmp, ty });
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ")))", .{});
    } else if (intBinOp(op)) |mcop| {
        // dst = as_type<float4>( as_type<T>(s0) OP as_type<T>(s1) ), T per op.
        const ty = if (intOpSigned(op)) "int4" else "uint4";
        try app(w, alloc, "as_type<float4>(", .{});
        if (std.mem.eql(u8, op, "UMAD")) {
            // s0*s1 + s2 (unsigned).
            try app(w, alloc, "as_type<uint4>(", .{});
            try appendSrc(w, alloc, prog, s[0]);
            try app(w, alloc, ") * as_type<uint4>(", .{});
            try appendSrc(w, alloc, prog, s[1]);
            try app(w, alloc, ") + as_type<uint4>(", .{});
            try appendSrc(w, alloc, prog, s[2]);
            try app(w, alloc, ")", .{});
        } else if (!std.mem.eql(u8, mcop, "max") and !std.mem.eql(u8, mcop, "min")) {
            // binary infix operator (arith/bitwise/shift)
            try app(w, alloc, "as_type<{s}>(", .{ty});
            try appendSrc(w, alloc, prog, s[0]);
            try app(w, alloc, ") {s} as_type<{s}>(", .{ mcop, ty });
            try appendSrc(w, alloc, prog, s[1]);
            try app(w, alloc, ")", .{});
        } else {
            // function-style (max/min)
            try app(w, alloc, "{s}(as_type<{s}>(", .{ mcop, ty });
            try appendSrc(w, alloc, prog, s[0]);
            try app(w, alloc, "), as_type<{s}>(", .{ty});
            try appendSrc(w, alloc, prog, s[1]);
            try app(w, alloc, "))", .{});
        }
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "CEIL")) {
        try app(w, alloc, "ceil(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "XPD")) {
        // 3-component cross product; w = 1 (TGSI convention).
        try app(w, alloc, "float4(cross((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xyz, (", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ").xyz), 1.0)", .{});
    } else if (std.mem.eql(u8, op, "NRM")) {
        // Normalize the xyz of src0; w = 1.
        try app(w, alloc, "float4(normalize((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xyz), 1.0)", .{});
    } else if (std.mem.eql(u8, op, "DST")) {
        // Distance vector: dst = (1, src0.y*src1.y, src0.z, src1.w).
        try app(w, alloc, "float4(1.0, (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").y * (", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ").y, (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").z, (", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ").w)", .{});
    } else if (std.mem.eql(u8, op, "LIT")) {
        // Fixed-function lighting coefficients.
        // dst = (1, max(src.x,0), (src.x>0 ? pow(max(src.y,0), clamp(src.w)) : 0), 1)
        try app(w, alloc, "float4(1.0, max((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x, 0.0), ((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x > 0.0 ? pow(max((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").y, 0.0), clamp((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").w, -128.0, 128.0)) : 0.0), 1.0)", .{});
    } else if (std.mem.eql(u8, op, "CMP")) {
        // dst = (src0 < 0) ? src1 : src2, per component.
        try app(w, alloc, "select(", .{});
        try appendSrc(w, alloc, prog, s[2]);
        try app(w, alloc, ", ", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ", (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ") < 0.0f)", .{});
    } else if (std.mem.eql(u8, op, "LRP")) {
        // dst = src0*src1 + (1-src0)*src2 = mix(src2, src1, src0).
        try app(w, alloc, "mix(", .{});
        try appendSrc(w, alloc, prog, s[2]);
        try app(w, alloc, ", ", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ", ", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "SLT") or std.mem.eql(u8, op, "SGE") or
        std.mem.eql(u8, op, "SEQ") or std.mem.eql(u8, op, "SNE"))
    {
        const cmp: []const u8 = if (std.mem.eql(u8, op, "SLT")) "<" else if (std.mem.eql(u8, op, "SGE")) ">=" else if (std.mem.eql(u8, op, "SEQ")) "==" else "!=";
        try app(w, alloc, "float4((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ") {s} (", .{cmp});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, "))", .{});
    } else if (std.mem.eql(u8, op, "POW")) {
        try app(w, alloc, "float4(pow((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x, (", .{});
        try appendSrc(w, alloc, prog, s[1]);
        try app(w, alloc, ").x))", .{});
    } else if (std.mem.eql(u8, op, "EX2")) {
        try app(w, alloc, "float4(exp2((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x))", .{});
    } else if (std.mem.eql(u8, op, "LG2")) {
        try app(w, alloc, "float4(log2((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x))", .{});
    } else if (std.mem.eql(u8, op, "SIN")) {
        try app(w, alloc, "float4(sin((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x))", .{});
    } else if (std.mem.eql(u8, op, "COS")) {
        try app(w, alloc, "float4(cos((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").x))", .{});
    } else if (std.mem.eql(u8, op, "TRUNC")) {
        try app(w, alloc, "trunc(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "ROUND")) {
        try app(w, alloc, "rint(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "SSG")) {
        try app(w, alloc, "sign(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "DDX")) {
        try app(w, alloc, "dfdx(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "DDY")) {
        try app(w, alloc, "dfdy(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ")", .{});
    } else if (std.mem.eql(u8, op, "TEX")) {
        // dst = tex0.sample(smp0, coord.xy)   (2D targets only for now;
        // the sampler operand selects the unit — single unit so far.)
        try app(w, alloc, "tex0.sample(smp0, (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xy)", .{});
    } else if (std.mem.eql(u8, op, "TXB")) {
        // LOD bias in coord.w.
        try app(w, alloc, "tex0.sample(smp0, (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xy, bias((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").w))", .{});
    } else if (std.mem.eql(u8, op, "TXL")) {
        // Explicit LOD in coord.w.
        try app(w, alloc, "tex0.sample(smp0, (", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xy, level((", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").w))", .{});
    } else if (std.mem.eql(u8, op, "TXF")) {
        // texelFetch: integer texel coords in .xy, LOD in .w; no filtering.
        try app(w, alloc, "tex0.read(uint2(as_type<int4>(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").xy), uint(as_type<int4>(", .{});
        try appendSrc(w, alloc, prog, s[0]);
        try app(w, alloc, ").w))", .{});
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

/// Emit a `constant float4* cN [[buffer(1+N)]]` param for each referenced
/// UBO dim (CONST[N][..], N>=1). buffer(1) is reserved for the inline
/// default block, so UBO dim N maps to buffer(1+N).
fn emitUboParams(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program, need_comma: *bool) !void {
    var d: u5 = 1;
    while (d < 16) : (d += 1) {
        if (prog.ubo_used & (@as(u16, 1) << @intCast(d)) == 0) continue;
        if (need_comma.*) try app(w, alloc, ", ", .{});
        try app(w, alloc, "constant float4* c{d} [[buffer({d})]]", .{ d, d + 1 });
        need_comma.* = true;
    }
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
        need_comma = true;
    }
    try emitUboParams(w, alloc, prog, &need_comma);
    if (prog.uses_instance_id) {
        if (need_comma) try app(w, alloc, ", ", .{});
        try app(w, alloc, "uint vs_iid [[instance_id]]", .{});
        need_comma = true;
    }
    if (prog.uses_vertex_id) {
        if (need_comma) try app(w, alloc, ", ", .{});
        try app(w, alloc, "uint vs_vid [[vertex_id]]", .{});
        need_comma = true;
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

    // MRT output struct (>1 color output). Single-output keeps float4.
    const mrt = prog.n_out > 1;
    if (mrt) {
        try app(w, alloc, "struct FSOut {{\n", .{});
        for (prog.out_decls[0..prog.n_out]) |d| {
            try app(w, alloc, "    float4 c{d} [[color({d})]];\n", .{ d.index, d.index });
        }
        try app(w, alloc, "}};\n", .{});
    }

    // Build the parameter list (omit an empty [[stage_in]] — invalid MSL).
    if (mrt) {
        try app(w, alloc, "fragment FSOut fs_main(", .{});
    } else {
        try app(w, alloc, "fragment float4 fs_main(", .{});
    }
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
    try emitUboParams(w, alloc, prog, &need_comma);
    if (prog.uses_sampler) {
        if (need_comma) try app(w, alloc, ", ", .{});
        try app(w, alloc, "texture2d<float> tex0 [[texture(0)]], sampler smp0 [[sampler(0)]]", .{});
    }
    // Count fragment color outputs (OUT[n]); >1 => MRT, emit a struct
    // with [[color(n)]] members. ==1 keeps the plain float4 return so the
    // mesa-validated single-target path is byte-identical.
    const n_color = prog.n_out;
    if (n_color > 1) {
        try app(w, alloc, ") {{\n", .{});
        var ci: usize = 0;
        while (ci < n_color) : (ci += 1) {
            try app(w, alloc, "    float4 out{d} = float4(0.0,0.0,0.0,1.0);\n", .{prog.out_decls[ci].index});
        }
        try emitLocals(w, alloc, prog);
        try emitBody(w, alloc, prog);
        try app(w, alloc, "    FSOut fso;\n", .{});
        ci = 0;
        while (ci < n_color) : (ci += 1) {
            const idx = prog.out_decls[ci].index;
            try app(w, alloc, "    fso.c{d} = out{d};\n", .{ idx, idx });
        }
        try app(w, alloc, "    return fso;\n}}\n", .{});
    } else {
        try app(w, alloc, ") {{\n    float4 out0 = float4(0.0,0.0,0.0,1.0);\n", .{});
        try emitLocals(w, alloc, prog);
        try emitBody(w, alloc, prog);
        try app(w, alloc, "    return out0;\n}}\n", .{});
    }
}

fn emitBody(w: *std.ArrayListUnmanaged(u8), alloc: Allocator, prog: *const Program) !void {
    for (prog.instrs[0..prog.n_instr]) |*instr| {
        var op = instr.opName();
        if (std.mem.eql(u8, op, "END") or std.mem.eql(u8, op, "RET")) continue;

        // Control flow and side-effect statements (no dst register).
        if (std.mem.eql(u8, op, "IF") or std.mem.eql(u8, op, "UIF")) {
            // The condition is the instruction's first (only) operand,
            // which the generic parser stores in `dst`.
            const cond = instr.dst orelse continue;
            try app(w, alloc, "    if ((", .{});
            try appendSrc(w, alloc, prog, cond);
            try app(w, alloc, ").x != 0.0f) {{\n", .{});
            continue;
        }
        if (std.mem.eql(u8, op, "ELSE")) {
            try app(w, alloc, "    }} else {{\n", .{});
            continue;
        }
        if (std.mem.eql(u8, op, "ENDIF")) {
            try app(w, alloc, "    }}\n", .{});
            continue;
        }
        if (std.mem.eql(u8, op, "KILL")) {
            try app(w, alloc, "    discard_fragment();\n", .{});
            continue;
        }
        if (std.mem.eql(u8, op, "KILL_IF")) {
            // Kill when ANY component of the (first-operand) src is
            // negative. That operand is stored in `dst` by the parser.
            const cond = instr.dst orelse continue;
            try app(w, alloc, "    if (any((", .{});
            try appendSrc(w, alloc, prog, cond);
            try app(w, alloc, ") < 0.0f)) discard_fragment();\n", .{});
            continue;
        }

        // "_SAT" suffix: clamp the result to [0, 1].
        var saturate = false;
        if (std.mem.endsWith(u8, op, "_SAT")) {
            saturate = true;
            op = op[0 .. op.len - 4];
        }

        const dst = instr.dst orelse {
            try app(w, alloc, "    // no-dst: {s}\n", .{op});
            continue;
        };
        if (!isSupportedName(op)) {
            try app(w, alloc, "    // unsupported: {s}\n", .{op});
            continue;
        }
        // dst.<mask> = (<rhs>).<mask>;
        try app(w, alloc, "    ", .{});
        try appendBase(w, alloc, prog, dst);
        try app(w, alloc, ".", .{});
        try appendMask(w, alloc, dst);
        if (saturate) {
            try app(w, alloc, " = saturate(", .{});
        } else {
            try app(w, alloc, " = (", .{});
        }
        try appendRhsNamed(w, alloc, prog, instr, op);
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
