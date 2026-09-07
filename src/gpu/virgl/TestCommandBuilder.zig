//! Test-only virgl wire command builder. Borrows caller-owned word storage.

const Self = @This();

buf: []u32,
i: usize = 0,

pub fn w(self: *Self, v: u32) void {
    self.buf[self.i] = v;
    self.i += 1;
}

pub fn cmd(self: *Self, opcode: u32, objtype: u32, len: u32) void {
    self.w(opcode | (objtype << 8) | (len << 16));
}

pub fn f(self: *Self, v: f32) void {
    self.w(@bitCast(v));
}

pub fn shader(self: *Self, handle: u32, text: []const u8) void {
    const nwords: u32 = @intCast((text.len + 1 + 3) / 4);
    self.cmd(1, 4, 1 + 4 + nwords);
    self.w(handle);
    self.w(0);
    self.w(0);
    self.w(0);
    self.w(0);
    var k: usize = 0;
    while (k < nwords) : (k += 1) {
        var word: u32 = 0;
        inline for (0..4) |bb| {
            const idx = k * 4 + bb;
            if (idx < text.len) word |= @as(u32, text[idx]) << (bb * 8);
        }
        self.w(word);
    }
}
