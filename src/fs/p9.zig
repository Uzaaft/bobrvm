//! 9P2000.L file server (shared folders).
//!
//! Serves one exported host directory to the guest over virtio-9p
//! (`mount -t 9p -o trans=virtio,version=9p2000.L <tag> /mnt`). Pure
//! request→response over byte buffers: the virtio transport collects a
//! T-message and hands it to handle(), which encodes the R-message.
//!
//! Scope: everything a dev-workflow mount needs — version/attach/walk/
//! open/create/read/write/readdir/getattr/setattr(size,mode)/mkdir/
//! unlinkat/statfs/fsync/readlink/clunk. Not implemented (Rlerror
//! EOPNOTSUPP): symlink/mknod/link/rename/xattr/locks.
//!
//! Security: walks reject "" / "." / ".." and names containing '/', so
//! the export root cannot be escaped.
//!
//! The guest is Linux: Tlopen/Tlcreate flags arrive as LINUX O_* values
//! and Rlerror wants LINUX errno numbers — both are translated here
//! (Darwin's differ).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;

const log = std.log.scoped(.p9);

// Darwin libc (not exposed by zig 0.16's std.c). Plain symbols are correct
// on arm64 (the $INODE64 suffix is an x86_64-only artifact).
extern "c" fn lstat(path: [*:0]const u8, st: *std.c.Stat) c_int;
extern "c" fn truncate(path: [*:0]const u8, length: std.c.off_t) c_int;

// Message types (9P2000.L + classic core).
pub const Tlerror = 6; // R only
pub const Tstatfs = 8;
pub const Tlopen = 12;
pub const Tlcreate = 14;
pub const Treadlink = 22;
pub const Tgetattr = 24;
pub const Tsetattr = 26;
pub const Treaddir = 40;
pub const Tfsync = 50;
pub const Tmkdir = 72;
pub const Tunlinkat = 76;
pub const Tversion = 100;
pub const Tattach = 104;
pub const Tflush = 108;
pub const Twalk = 110;
pub const Tread = 116;
pub const Twrite = 118;
pub const Tclunk = 120;
pub const Tremove = 122;

// Linux errno values (the guest's dialect).
pub const L_ENOENT: u32 = 2;
pub const L_EIO: u32 = 5;
pub const L_EBADF: u32 = 9;
pub const L_EACCES: u32 = 13;
pub const L_EEXIST: u32 = 17;
pub const L_ENOTDIR: u32 = 20;
pub const L_EISDIR: u32 = 21;
pub const L_EINVAL: u32 = 22;
pub const L_ENOSPC: u32 = 28;
pub const L_ENOTEMPTY: u32 = 39;
pub const L_EOPNOTSUPP: u32 = 95;

// Linux open(2) flag values (arrive in Tlopen/Tlcreate).
const L_O_WRONLY: u32 = 0o1;
const L_O_RDWR: u32 = 0o2;
const L_O_CREAT: u32 = 0o100;
const L_O_EXCL: u32 = 0o200;
const L_O_TRUNC: u32 = 0o1000;
const L_O_APPEND: u32 = 0o2000;
const L_O_DIRECTORY: u32 = 0o200000;

pub const MSIZE_MAX: u32 = 128 * 1024;
const walk_scratch_bytes: usize = 8 * 1024;

/// One guest file handle.
const Fid = struct {
    /// Path relative to the export root ("" = the root itself).
    rel: []u8,
    /// Open host file descriptor (set by lopen/lcreate).
    fd: ?std.c.fd_t = null,
    /// Linux open flags recorded at lopen/lcreate so a snapshot restore
    /// can re-open the file the same way (null = never opened).
    open_linux_flags: ?u32 = null,
};

pub const P9Server = struct {
    alloc: Allocator,
    /// Absolute host path of the exported directory (owned).
    root: []u8,
    fids: std.AutoHashMap(u32, Fid),
    msize: u32 = MSIZE_MAX,

    pub fn init(alloc: Allocator, root_path: []const u8) !P9Server {
        const root = try alloc.dupe(u8, root_path);
        return initEmbedded(alloc, root);
    }

    pub fn initEmbedded(alloc: Allocator, root_storage: []u8) P9Server {
        assert(@sizeOf(u8) == 1);
        assert(@sizeOf([]u8) == 2 * @sizeOf(usize));
        return .{
            .alloc = alloc,
            .root = root_storage,
            .fids = std.AutoHashMap(u32, Fid).init(alloc),
        };
    }

    pub fn deinit(self: *P9Server) void {
        self.deinitFids();
        self.alloc.free(self.root);
        self.root = &.{};
    }

    pub fn deinitEmbedded(self: *P9Server) void {
        self.deinitFids();
        self.root = &.{};
    }

    fn deinitFids(self: *P9Server) void {
        var iter = self.fids.valueIterator();
        while (iter.next()) |fid| self.dropFid(fid);
        self.fids.deinit();
    }

    fn dropFid(self: *P9Server, fid: *Fid) void {
        if (fid.fd) |fd| _ = std.c.close(fd);
        self.alloc.free(fid.rel);
    }

    /// Recreate a fid from snapshot state, re-opening the file when it
    /// had been opened (best effort: a vanished file leaves the fid
    /// unopened and later ops on it return EBADF, matching a file
    /// deleted underneath a live mount).
    pub fn restoreFid(
        self: *P9Server,
        alloc: Allocator,
        id: u32,
        rel: []const u8,
        open_flags: ?u32,
    ) !void {
        _ = alloc;
        const owned = try self.alloc.dupe(u8, rel);
        errdefer self.alloc.free(owned);
        var fid = Fid{ .rel = owned, .open_linux_flags = open_flags };
        if (open_flags) |flags| {
            var path_storage: [std.fs.max_path_bytes]u8 = undefined;
            const path = try self.hostPathInto(owned, &path_storage);
            const fd = std.c.open(path.ptr, linuxFlagsToDarwin(flags));
            if (fd >= 0) fid.fd = fd;
        }
        if (self.fids.fetchRemove(id)) |old| {
            var v = old.value;
            self.dropFid(&v);
        }
        try self.fids.put(id, fid);
    }

    // =========================================================================
    // Wire helpers
    // =========================================================================

    const Reader = struct {
        buf: []const u8,
        off: usize = 0,

        fn u8v(self: *Reader) !u8 {
            if (1 > self.buf.len - self.off) return error.Truncated;
            defer self.off += 1;
            return self.buf[self.off];
        }
        fn u16v(self: *Reader) !u16 {
            if (2 > self.buf.len - self.off) return error.Truncated;
            defer self.off += 2;
            return std.mem.readInt(u16, self.buf[self.off..][0..2], .little);
        }
        fn u32v(self: *Reader) !u32 {
            if (4 > self.buf.len - self.off) return error.Truncated;
            defer self.off += 4;
            return std.mem.readInt(u32, self.buf[self.off..][0..4], .little);
        }
        fn u64v(self: *Reader) !u64 {
            if (8 > self.buf.len - self.off) return error.Truncated;
            defer self.off += 8;
            return std.mem.readInt(u64, self.buf[self.off..][0..8], .little);
        }
        fn str(self: *Reader) ![]const u8 {
            const len = try self.u16v();
            if (len > self.buf.len - self.off) return error.Truncated;
            defer self.off += len;
            return self.buf[self.off..][0..len];
        }
        fn bytes(self: *Reader, len: usize) ![]const u8 {
            if (len > self.buf.len - self.off) return error.Truncated;
            defer self.off += len;
            return self.buf[self.off..][0..len];
        }
    };

    const Writer = struct {
        buf: []u8,
        limit: usize,
        off: usize = 7, // header written by finish()

        fn ensureUnusedCapacity(self: *Writer, len: usize) Error!void {
            if (self.off > self.limit or len > self.limit - self.off) return error.NoSpace;
        }
        fn setLimit(self: *Writer, limit: usize) void {
            self.limit = @min(self.buf.len, limit);
        }
        fn u8v(self: *Writer, v: u8) Error!void {
            try self.ensureUnusedCapacity(1);
            self.buf[self.off] = v;
            self.off += 1;
        }
        fn u16v(self: *Writer, v: u16) Error!void {
            try self.ensureUnusedCapacity(2);
            std.mem.writeInt(u16, self.buf[self.off..][0..2], v, .little);
            self.off += 2;
        }
        fn u32v(self: *Writer, v: u32) Error!void {
            try self.ensureUnusedCapacity(4);
            std.mem.writeInt(u32, self.buf[self.off..][0..4], v, .little);
            self.off += 4;
        }
        fn u64v(self: *Writer, v: u64) Error!void {
            try self.ensureUnusedCapacity(8);
            std.mem.writeInt(u64, self.buf[self.off..][0..8], v, .little);
            self.off += 8;
        }
        fn str(self: *Writer, s: []const u8) Error!void {
            if (s.len > std.math.maxInt(u16)) return error.NoSpace;
            const encoded_len = std.math.add(usize, @sizeOf(u16), s.len) catch
                return error.NoSpace;
            try self.ensureUnusedCapacity(encoded_len);
            try self.u16v(@intCast(s.len));
            @memcpy(self.buf[self.off..][0..s.len], s);
            self.off += s.len;
        }
        fn qid(self: *Writer, q: Qid) Error!void {
            try self.ensureUnusedCapacity(13);
            try self.u8v(q.type);
            try self.u32v(q.version);
            try self.u64v(q.path);
        }
        fn finish(self: *Writer, msg_type: u8, tag: u16) Error!usize {
            if (self.off > self.limit or self.off > std.math.maxInt(u32)) {
                return error.NoSpace;
            }
            std.mem.writeInt(u32, self.buf[0..4], @intCast(self.off), .little);
            self.buf[4] = msg_type;
            std.mem.writeInt(u16, self.buf[5..7], tag, .little);
            return self.off;
        }
    };

    const Qid = struct { type: u8, version: u32, path: u64 };

    fn qidFromStat(st: std.c.Stat) Qid {
        const S = std.c.S;
        const t: u8 = if (S.ISDIR(st.mode)) 0x80 else if (S.ISLNK(st.mode)) 0x02 else 0x00;
        return .{
            .type = t,
            .version = @truncate(@as(u64, @bitCast(@as(i64, st.mtimespec.sec)))),
            .path = st.ino,
        };
    }

    fn lerror(w: *Writer, tag: u16, ecode: u32) usize {
        w.off = 7;
        w.u32v(ecode) catch return 0;
        return w.finish(Tlerror + 1, tag) catch return 0;
    }

    fn errnoToLinux() u32 {
        return switch (std.c.errno(@as(c_int, -1))) {
            .NOENT => L_ENOENT,
            .ACCES, .PERM => L_EACCES,
            .EXIST => L_EEXIST,
            .NOTDIR => L_ENOTDIR,
            .ISDIR => L_EISDIR,
            .INVAL => L_EINVAL,
            .NOSPC => L_ENOSPC,
            .NOTEMPTY => L_ENOTEMPTY,
            .BADF => L_EBADF,
            else => L_EIO,
        };
    }

    // =========================================================================
    // Path handling
    // =========================================================================

    /// Absolute, NUL-terminated host path for a fid-relative path.
    fn hostPath(self: *P9Server, rel: []const u8) ![:0]u8 {
        return self.hostPathAlloc(self.alloc, rel);
    }

    fn hostPathAlloc(self: *P9Server, alloc: Allocator, rel: []const u8) ![:0]u8 {
        assert(rel.len <= MSIZE_MAX);
        assert(self.root.len <= std.math.maxInt(u32));
        if (rel.len == 0) return alloc.dupeZ(u8, self.root);
        return std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ self.root, rel }, 0);
    }

    fn hostPathInto(self: *P9Server, rel: []const u8, storage: []u8) Error![:0]u8 {
        assert(storage.len > 0);
        assert(rel.len <= MSIZE_MAX);
        const separator_len: usize = @intFromBool(rel.len > 0);
        const prefix_len = std.math.add(usize, self.root.len, separator_len) catch
            return error.Invalid;
        const path_len = std.math.add(usize, prefix_len, rel.len) catch return error.Invalid;
        if (path_len >= storage.len) return error.Invalid;

        @memcpy(storage[0..self.root.len], self.root);
        if (rel.len > 0) storage[self.root.len] = '/';
        @memcpy(storage[prefix_len..path_len], rel);
        storage[path_len] = 0;
        return storage[0..path_len :0];
    }

    fn childRelAlloc(self: *P9Server, parent: []const u8, name: []const u8) Error![]u8 {
        assert(parent.len <= MSIZE_MAX);
        assert(validName(name));
        const separator_len: usize = @intFromBool(parent.len > 0);
        const prefix_len = std.math.add(usize, parent.len, separator_len) catch
            return error.Invalid;
        const rel_len = std.math.add(usize, prefix_len, name.len) catch return error.Invalid;
        if (rel_len > MSIZE_MAX) return error.Invalid;

        const rel = try self.alloc.alloc(u8, rel_len);
        @memcpy(rel[0..parent.len], parent);
        if (parent.len > 0) rel[parent.len] = '/';
        @memcpy(rel[prefix_len..], name);
        return rel;
    }

    fn childRelInto(parent: []const u8, name: []const u8, storage: []u8) Error![]u8 {
        assert(storage.len > 0);
        assert(validName(name));
        const separator_len: usize = @intFromBool(parent.len > 0);
        const prefix_len = std.math.add(usize, parent.len, separator_len) catch
            return error.Invalid;
        const rel_len = std.math.add(usize, prefix_len, name.len) catch return error.Invalid;
        if (rel_len > storage.len or rel_len > MSIZE_MAX) return error.Invalid;

        @memcpy(storage[0..parent.len], parent);
        if (parent.len > 0) storage[parent.len] = '/';
        @memcpy(storage[prefix_len..rel_len], name);
        return storage[0..rel_len];
    }

    fn validName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
        if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
        return true;
    }

    fn statRel(self: *P9Server, rel: []const u8) !std.c.Stat {
        return self.statRelAlloc(self.alloc, rel);
    }

    fn statRelAlloc(self: *P9Server, alloc: Allocator, rel: []const u8) !std.c.Stat {
        assert(rel.len <= MSIZE_MAX);
        assert(self.root.len <= std.math.maxInt(u32));
        const path = try self.hostPathAlloc(alloc, rel);
        defer alloc.free(path);
        var st: std.c.Stat = undefined;
        if (lstat(path.ptr, &st) != 0) return error.Stat;
        return st;
    }

    // =========================================================================
    // Dispatch
    // =========================================================================

    /// Handle one T-message; encodes the R-message into resp and returns
    /// its length. resp must hold at least msize bytes.
    pub fn handle(self: *P9Server, req: []const u8, resp: []u8) usize {
        var w = Writer{ .buf = resp, .limit = @min(resp.len, self.msize) };
        if (req.len < 7) return lerror(&w, 0, L_EINVAL);
        const declared_size = std.mem.readInt(u32, req[0..4], .little);
        const tag = std.mem.readInt(u16, req[5..7], .little);
        if (declared_size < 7 or declared_size > req.len or declared_size > self.msize) {
            return lerror(&w, tag, L_EINVAL);
        }
        var r = Reader{ .buf = req[0..declared_size], .off = 4 };
        const msg_type = r.u8v() catch unreachable;
        _ = r.u16v() catch unreachable;

        return self.dispatch(msg_type, tag, &r, &w) catch |err| switch (err) {
            error.Truncated => lerror(&w, tag, L_EINVAL),
            error.Errno => lerror(&w, tag, errnoToLinux()),
            error.Stat => lerror(&w, tag, L_ENOENT),
            error.BadFid => lerror(&w, tag, L_EBADF),
            error.NotSupported => lerror(&w, tag, L_EOPNOTSUPP),
            error.Invalid => lerror(&w, tag, L_EINVAL),
            error.Access => lerror(&w, tag, L_EACCES),
            error.OutOfMemory => lerror(&w, tag, L_EIO),
            error.NoSpace => lerror(&w, tag, L_EINVAL),
        };
    }

    const Error = error{
        Truncated,
        Errno,
        Stat,
        BadFid,
        NotSupported,
        Invalid,
        Access,
        OutOfMemory,
        NoSpace,
    };

    fn getFid(self: *P9Server, id: u32) Error!*Fid {
        return self.fids.getPtr(id) orelse error.BadFid;
    }

    fn dispatch(self: *P9Server, msg_type: u8, tag: u16, r: *Reader, w: *Writer) Error!usize {
        switch (msg_type) {
            Tversion => {
                const client_msize = try r.u32v();
                const version = try r.str();
                const response_version = if (std.mem.eql(u8, version, "9P2000.L"))
                    "9P2000.L"
                else
                    "unknown";
                const response_size = 7 + @sizeOf(u32) + @sizeOf(u16) + response_version.len;
                if (client_msize < response_size) return error.Invalid;
                self.msize = @min(client_msize, MSIZE_MAX);
                w.setLimit(self.msize);
                // Fresh session: drop all fids.
                var iter = self.fids.valueIterator();
                while (iter.next()) |fid| self.dropFid(fid);
                self.fids.clearRetainingCapacity();
                try w.u32v(self.msize);
                try w.str(response_version);
                return try w.finish(Tversion + 1, tag);
            },
            Tattach => {
                const fid = try r.u32v();
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto("", &path_storage);
                var st: std.c.Stat = undefined;
                if (lstat(path.ptr, &st) != 0) return error.Stat;
                const rel = try self.alloc.dupe(u8, "");
                errdefer self.alloc.free(rel);
                if (self.fids.fetchRemove(fid)) |old| {
                    var v = old.value;
                    self.dropFid(&v);
                }
                try self.fids.put(fid, .{ .rel = rel });
                try w.qid(qidFromStat(st));
                return try w.finish(Tattach + 1, tag);
            },
            Twalk => {
                const fid = try r.u32v();
                const newfid = try r.u32v();
                const nwname = try r.u16v();
                const src = try self.getFid(fid);

                var stack_allocator = std.heap.stackFallback(walk_scratch_bytes, self.alloc);
                const temp_alloc = stack_allocator.get();
                var rel = std.ArrayListUnmanaged(u8).empty;
                defer rel.deinit(temp_alloc);
                try rel.appendSlice(temp_alloc, src.rel);

                var qids = std.ArrayListUnmanaged(Qid).empty;
                defer qids.deinit(temp_alloc);

                var i: u16 = 0;
                while (i < nwname) : (i += 1) {
                    const name = try r.str();
                    if (!validName(name)) {
                        if (qids.items.len == 0) return error.Access;
                        break;
                    }
                    const prev_len = rel.items.len;
                    if (rel.items.len > 0) try rel.append(temp_alloc, '/');
                    try rel.appendSlice(temp_alloc, name);
                    const st = self.statRelAlloc(temp_alloc, rel.items) catch {
                        rel.shrinkRetainingCapacity(prev_len);
                        break;
                    };
                    try qids.append(temp_alloc, qidFromStat(st));
                }

                // Only a FULL walk moves/creates newfid (9p semantics).
                if (qids.items.len == nwname) {
                    const owned = try self.alloc.dupe(u8, rel.items);
                    errdefer self.alloc.free(owned);
                    if (self.fids.fetchRemove(newfid)) |old| {
                        var v = old.value;
                        self.dropFid(&v);
                    }
                    try self.fids.put(newfid, .{ .rel = owned });
                } else if (nwname > 0 and qids.items.len == 0) {
                    return lerror(w, tag, L_ENOENT);
                }

                try w.u16v(@intCast(qids.items.len));
                for (qids.items) |q| try w.qid(q);
                return try w.finish(Twalk + 1, tag);
            },
            Tlopen => {
                const fid_id = try r.u32v();
                const flags = try r.u32v();
                const fid = try self.getFid(fid_id);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(fid.rel, &path_storage);

                const fd = std.c.open(path.ptr, linuxFlagsToDarwin(flags));
                if (fd < 0) return error.Errno;
                if (fid.fd) |old| _ = std.c.close(old);
                fid.fd = fd;
                fid.open_linux_flags = flags;

                var st: std.c.Stat = undefined;
                if (std.c.fstat(fd, &st) != 0) return error.Errno;
                try w.qid(qidFromStat(st));
                try w.u32v(0); // iounit: use msize-derived default
                return try w.finish(Tlopen + 1, tag);
            },
            Tlcreate => {
                const fid_id = try r.u32v();
                const name = try r.str();
                const flags = try r.u32v();
                const mode = try r.u32v();
                _ = try r.u32v(); // gid
                if (!validName(name)) return error.Access;
                const fid = try self.getFid(fid_id);

                const rel = try self.childRelAlloc(fid.rel, name);
                errdefer self.alloc.free(rel);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(rel, &path_storage);

                var oflags = linuxFlagsToDarwin(flags);
                oflags.CREAT = true;
                const fd = std.c.open(path.ptr, oflags, @as(std.c.mode_t, @intCast(mode & 0o7777)));
                if (fd < 0) return error.Errno;

                // The fid now refers to the created (open) file.
                if (fid.fd) |old| _ = std.c.close(old);
                self.alloc.free(fid.rel);
                fid.rel = rel;
                fid.fd = fd;
                // On restore, re-open WITHOUT re-creating/truncating.
                fid.open_linux_flags = flags & ~@as(u32, L_O_CREAT | L_O_EXCL | L_O_TRUNC);

                var st: std.c.Stat = undefined;
                if (std.c.fstat(fd, &st) != 0) return error.Errno;
                try w.qid(qidFromStat(st));
                try w.u32v(0);
                return try w.finish(Tlcreate + 1, tag);
            },
            Tgetattr => {
                const fid_id = try r.u32v();
                _ = try r.u64v(); // request_mask: we always fill the basics
                const fid = try self.getFid(fid_id);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(fid.rel, &path_storage);
                var st: std.c.Stat = undefined;
                if (lstat(path.ptr, &st) != 0) return error.Stat;

                try w.u64v(0x000007ff); // valid: P9_GETATTR_BASIC
                try w.qid(qidFromStat(st));
                try w.u32v(st.mode);
                try w.u32v(st.uid);
                try w.u32v(st.gid);
                try w.u64v(st.nlink);
                try w.u64v(@bitCast(@as(i64, st.rdev)));
                try w.u64v(@bitCast(st.size));
                try w.u64v(4096); // blksize
                try w.u64v(@bitCast(st.blocks));
                try w.u64v(@bitCast(@as(i64, st.atimespec.sec)));
                try w.u64v(@bitCast(@as(i64, st.atimespec.nsec)));
                try w.u64v(@bitCast(@as(i64, st.mtimespec.sec)));
                try w.u64v(@bitCast(@as(i64, st.mtimespec.nsec)));
                try w.u64v(@bitCast(@as(i64, st.ctimespec.sec)));
                try w.u64v(@bitCast(@as(i64, st.ctimespec.nsec)));
                try w.u64v(0); // btime sec
                try w.u64v(0); // btime nsec
                try w.u64v(0); // gen
                try w.u64v(0); // data_version
                return try w.finish(Tgetattr + 1, tag);
            },
            Tsetattr => {
                const fid_id = try r.u32v();
                const valid = try r.u32v();
                const mode = try r.u32v();
                _ = try r.u32v(); // uid
                _ = try r.u32v(); // gid
                const size = try r.u64v();
                const fid = try self.getFid(fid_id);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(fid.rel, &path_storage);

                const SETATTR_MODE: u32 = 0x1;
                const SETATTR_SIZE: u32 = 0x8;
                if (valid & SETATTR_SIZE != 0) {
                    if (fid.fd) |fd| {
                        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.Errno;
                    } else if (truncate(path.ptr, @intCast(size)) != 0) {
                        return error.Errno;
                    }
                }
                if (valid & SETATTR_MODE != 0) {
                    if (std.c.chmod(path.ptr, @intCast(mode & 0o7777)) != 0) return error.Errno;
                }
                // Timestamps/ownership: accepted and ignored.
                return try w.finish(Tsetattr + 1, tag);
            },
            Treaddir => {
                const fid_id = try r.u32v();
                const offset = try r.u64v();
                const count = try r.u32v();
                const fid = try self.getFid(fid_id);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(fid.rel, &path_storage);

                const dir = std.c.opendir(path.ptr) orelse return error.Errno;
                defer _ = std.c.closedir(dir);

                const max = @min(count, self.msize - 11 - 4);
                try w.u32v(0); // count patched below
                const data_start = w.off;

                // offset = number of entries already delivered.
                var index: u64 = 0;
                while (std.c.readdir(dir)) |ent| {
                    const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
                    if (index < offset) {
                        index += 1;
                        continue;
                    }
                    const entry_len = 13 + 8 + 1 + 2 + name.len;
                    if (w.off - data_start + entry_len > max) break;
                    index += 1;
                    try w.qid(.{
                        .type = if (ent.type == 4) 0x80 else if (ent.type == 10) 0x02 else 0x00,
                        .version = 0,
                        .path = ent.ino,
                    });
                    try w.u64v(index); // offset of NEXT entry
                    try w.u8v(ent.type);
                    try w.str(name);
                }
                std.mem.writeInt(u32, w.buf[data_start - 4 ..][0..4], @intCast(w.off - data_start), .little);
                return try w.finish(Treaddir + 1, tag);
            },
            Tread => {
                const fid_id = try r.u32v();
                const offset = try r.u64v();
                const count = try r.u32v();
                const fid = try self.getFid(fid_id);
                const fd = fid.fd orelse return error.BadFid;

                const max = @min(count, self.msize - 11 - 4);
                try w.u32v(0); // count patched below
                const data_start = w.off;
                const capacity = w.limit - w.off;
                const n = std.c.pread(
                    fd,
                    w.buf[w.off..w.limit].ptr,
                    @min(max, capacity),
                    @intCast(offset),
                );
                if (n < 0) return error.Errno;
                w.off += @intCast(n);
                std.mem.writeInt(u32, w.buf[data_start - 4 ..][0..4], @intCast(n), .little);
                return try w.finish(Tread + 1, tag);
            },
            Twrite => {
                const fid_id = try r.u32v();
                const offset = try r.u64v();
                const count = try r.u32v();
                const data = try r.bytes(count);
                const fid = try self.getFid(fid_id);
                const fd = fid.fd orelse return error.BadFid;

                const n = std.c.pwrite(fd, data.ptr, data.len, @intCast(offset));
                if (n < 0) return error.Errno;
                try w.u32v(@intCast(n));
                return try w.finish(Twrite + 1, tag);
            },
            Tmkdir => {
                const fid_id = try r.u32v();
                const name = try r.str();
                const mode = try r.u32v();
                if (!validName(name)) return error.Access;
                const fid = try self.getFid(fid_id);
                var rel_storage: [std.fs.max_path_bytes]u8 = undefined;
                const rel = try childRelInto(fid.rel, name, &rel_storage);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(rel, &path_storage);

                if (std.c.mkdir(path.ptr, @intCast(mode & 0o7777)) != 0) return error.Errno;
                var st: std.c.Stat = undefined;
                if (lstat(path.ptr, &st) != 0) return error.Stat;
                try w.qid(qidFromStat(st));
                return try w.finish(Tmkdir + 1, tag);
            },
            Tunlinkat => {
                const fid_id = try r.u32v();
                const name = try r.str();
                const flags = try r.u32v();
                if (!validName(name)) return error.Access;
                const fid = try self.getFid(fid_id);
                var rel_storage: [std.fs.max_path_bytes]u8 = undefined;
                const rel = try childRelInto(fid.rel, name, &rel_storage);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(rel, &path_storage);

                // Linux AT_REMOVEDIR=0x200; Darwin's is 0x80.
                const removedir = flags & 0x200 != 0;
                const rc = if (removedir) std.c.rmdir(path.ptr) else std.c.unlink(path.ptr);
                if (rc != 0) return error.Errno;
                return try w.finish(Tunlinkat + 1, tag);
            },
            Tremove => {
                const fid_id = try r.u32v();
                const fid = try self.getFid(fid_id);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(fid.rel, &path_storage);
                var st: std.c.Stat = undefined;
                if (lstat(path.ptr, &st) != 0) return error.Stat;
                const rc = if (std.c.S.ISDIR(st.mode)) std.c.rmdir(path.ptr) else std.c.unlink(path.ptr);
                if (self.fids.fetchRemove(fid_id)) |old| {
                    var v = old.value;
                    self.dropFid(&v);
                }
                if (rc != 0) return error.Errno;
                return try w.finish(Tremove + 1, tag);
            },
            Treadlink => {
                const fid_id = try r.u32v();
                const fid = try self.getFid(fid_id);
                var path_storage: [std.fs.max_path_bytes]u8 = undefined;
                const path = try self.hostPathInto(fid.rel, &path_storage);
                var target: [1024]u8 = undefined;
                const n = std.c.readlink(path.ptr, &target, target.len);
                if (n < 0) return error.Errno;
                try w.str(target[0..@intCast(n)]);
                return try w.finish(Treadlink + 1, tag);
            },
            Tstatfs => {
                _ = try r.u32v();
                try w.u32v(0x01021997); // V9FS_MAGIC
                try w.u32v(4096); // bsize
                try w.u64v(1 << 28); // blocks (fabricated ~1TB)
                try w.u64v(1 << 27); // bfree
                try w.u64v(1 << 27); // bavail
                try w.u64v(1 << 20); // files
                try w.u64v(1 << 19); // ffree
                try w.u64v(0); // fsid
                try w.u32v(255); // namelen
                return try w.finish(Tstatfs + 1, tag);
            },
            Tfsync => {
                const fid_id = try r.u32v();
                const fid = try self.getFid(fid_id);
                if (fid.fd) |fd| {
                    if (std.c.fsync(fd) != 0) return error.Errno;
                }
                return try w.finish(Tfsync + 1, tag);
            },
            Tclunk => {
                const fid_id = try r.u32v();
                if (self.fids.fetchRemove(fid_id)) |old| {
                    var v = old.value;
                    self.dropFid(&v);
                } else return error.BadFid;
                return try w.finish(Tclunk + 1, tag);
            },
            Tflush => {
                _ = try r.u16v(); // oldtag: we're synchronous, nothing in flight
                return try w.finish(Tflush + 1, tag);
            },
            else => return error.NotSupported,
        }
    }

    /// Translate Linux open(2) flags (the guest's) to Darwin's.
    fn linuxFlagsToDarwin(flags: u32) std.c.O {
        var o = std.c.O{};
        switch (flags & 0o3) {
            L_O_WRONLY => o.ACCMODE = .WRONLY,
            L_O_RDWR => o.ACCMODE = .RDWR,
            else => o.ACCMODE = .RDONLY,
        }
        if (flags & L_O_CREAT != 0) o.CREAT = true;
        if (flags & L_O_EXCL != 0) o.EXCL = true;
        if (flags & L_O_TRUNC != 0) o.TRUNC = true;
        if (flags & L_O_APPEND != 0) o.APPEND = true;
        if (flags & L_O_DIRECTORY != 0) o.DIRECTORY = true;
        o.NOFOLLOW = true; // never follow symlinks out of the export
        return o;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Build a T-message: header + provided payload bytes.
fn tmsg(alloc: Allocator, msg_type: u8, tag: u16, payload: []const u8) ![]u8 {
    const buf = try alloc.alloc(u8, 7 + payload.len);
    std.mem.writeInt(u32, buf[0..4], @intCast(buf.len), .little);
    buf[4] = msg_type;
    std.mem.writeInt(u16, buf[5..7], tag, .little);
    @memcpy(buf[7..], payload);
    return buf;
}

const TestPayload = struct {
    buf: [512]u8 = undefined,
    off: usize = 0,

    fn u16v(self: *TestPayload, v: u16) *TestPayload {
        std.mem.writeInt(u16, self.buf[self.off..][0..2], v, .little);
        self.off += 2;
        return self;
    }
    fn u32v(self: *TestPayload, v: u32) *TestPayload {
        std.mem.writeInt(u32, self.buf[self.off..][0..4], v, .little);
        self.off += 4;
        return self;
    }
    fn u64v(self: *TestPayload, v: u64) *TestPayload {
        std.mem.writeInt(u64, self.buf[self.off..][0..8], v, .little);
        self.off += 8;
        return self;
    }
    fn str(self: *TestPayload, s: []const u8) *TestPayload {
        _ = self.u16v(@intCast(s.len));
        @memcpy(self.buf[self.off..][0..s.len], s);
        self.off += s.len;
        return self;
    }
    fn bytes(self: *TestPayload, s: []const u8) *TestPayload {
        @memcpy(self.buf[self.off..][0..s.len], s);
        self.off += s.len;
        return self;
    }
    fn slice(self: *TestPayload) []const u8 {
        return self.buf[0..self.off];
    }
};

fn expectRType(resp: []const u8, expected: u8) !void {
    try testing.expect(resp.len >= 7);
    if (resp[4] == Tlerror + 1) {
        const ecode = std.mem.readInt(u32, resp[7..11], .little);
        std.debug.print("unexpected Rlerror ecode={}\n", .{ecode});
    }
    try testing.expectEqual(expected, resp[4]);
}

test "p9: full session — attach/walk/open/read/readdir/create/write/mkdir/unlink" {
    const io = @import("../global.zig").io();
    const root = ".zig-cache/p9-test-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, root ++ "/hello.txt", .{});
        defer f.close(io);
        try f.writePositionalAll(io, "host says hi", 0);
    }
    try std.Io.Dir.cwd().symLink(io, "hello.txt", root ++ "/hello.link", .{});

    var srv = try P9Server.init(testing.allocator, root);
    defer srv.deinit();
    var resp: [MSIZE_MAX]u8 = undefined;

    // TVERSION
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tversion, 0xFFFF, p.u32v(65536).str("9P2000.L").slice());
        defer testing.allocator.free(req);
        const n = srv.handle(req, &resp);
        try expectRType(resp[0..n], Tversion + 1);
        try testing.expect(std.mem.indexOf(u8, resp[0..n], "9P2000.L") != null);
    }
    // TATTACH fid 1
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tattach, 1, p.u32v(1).u32v(0xFFFF_FFFF).str("user").str("").u32v(1000).slice());
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Tattach + 1);
        try testing.expectEqual(@as(u8, 0x80), resp[7]); // root qid is a dir
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    }
    // TWALK fid1 -> fid2 "hello.txt"
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Twalk, 2, p.u32v(1).u32v(2).u16v(1).str("hello.txt").slice());
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Twalk + 1);
        try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[7..9], .little));
        try testing.expectEqual(@as(usize, 1), counted.allocations);
        try testing.expectEqual(@as(usize, 9), counted.allocated_bytes);
    }
    // TLOPEN fid2 rdonly + TREAD
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tlopen, 3, p.u32v(2).u32v(0).slice());
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Tlopen + 1);
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);

        var p2 = TestPayload{};
        const req2 = try tmsg(testing.allocator, Tread, 4, p2.u32v(2).u64v(0).u32v(100).slice());
        defer testing.allocator.free(req2);
        const n2 = srv.handle(req2, &resp);
        try expectRType(resp[0..n2], Tread + 1);
        const count = std.mem.readInt(u32, resp[7..11], .little);
        try testing.expectEqualStrings("host says hi", resp[11 .. 11 + count]);
    }
    // TREADDIR on the root (fid 1 needs open first)
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tlopen, 5, p.u32v(1).u32v(0o200000).slice());
        defer testing.allocator.free(req);
        _ = srv.handle(req, &resp);

        var p2 = TestPayload{};
        const req2 = try tmsg(testing.allocator, Treaddir, 6, p2.u32v(1).u64v(0).u32v(8192).slice());
        defer testing.allocator.free(req2);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n2 = srv.handle(req2, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n2], Treaddir + 1);
        try testing.expect(std.mem.indexOf(u8, resp[0..n2], "hello.txt") != null);
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    }
    // TWALK fid1 -> fid3 (clone root), TLCREATE guest.txt, TWRITE
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Twalk, 7, p.u32v(1).u32v(3).u16v(0).slice());
        defer testing.allocator.free(req);
        _ = srv.handle(req, &resp);

        var p2 = TestPayload{};
        const req2 = try tmsg(testing.allocator, Tlcreate, 8, p2.u32v(3).str("guest.txt").u32v(0o101101).u32v(0o644).u32v(100).slice());
        defer testing.allocator.free(req2);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n2 = srv.handle(req2, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n2], Tlcreate + 1);
        try testing.expectEqual(@as(usize, 1), counted.allocations);
        try testing.expectEqual(@as(usize, 9), counted.allocated_bytes);

        var p3 = TestPayload{};
        const req3 = try tmsg(testing.allocator, Twrite, 9, p3.u32v(3).u64v(0).u32v(9).bytes("from vm!!").slice());
        defer testing.allocator.free(req3);
        const n3 = srv.handle(req3, &resp);
        try expectRType(resp[0..n3], Twrite + 1);
        try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, resp[7..11], .little));

        // The write really landed on the host.
        const f = try std.Io.Dir.cwd().openFile(io, root ++ "/guest.txt", .{});
        defer f.close(io);
        var got: [16]u8 = undefined;
        const got_n = try f.readPositionalAll(io, &got, 0);
        try testing.expectEqualStrings("from vm!!", got[0..got_n]);
    }
    // TMKDIR + TUNLINKAT(REMOVEDIR)
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tmkdir, 10, p.u32v(1).str("subdir").u32v(0o755).u32v(100).slice());
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Tmkdir + 1);
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);

        var p2 = TestPayload{};
        const req2 = try tmsg(testing.allocator, Tunlinkat, 11, p2.u32v(1).str("subdir").u32v(0x200).slice());
        defer testing.allocator.free(req2);
        var counted2 = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted2.allocator();
        const n2 = srv.handle(req2, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n2], Tunlinkat + 1);
        try testing.expectEqual(@as(usize, 0), counted2.allocations);
        try testing.expectEqual(@as(usize, 0), counted2.allocated_bytes);
    }
    // TGETATTR on fid 2
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tgetattr, 12, p.u32v(2).u64v(0x7ff).slice());
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Tgetattr + 1);
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
        const size = std.mem.readInt(u64, resp[7 + 8 + 13 + 4 + 4 + 4 + 8 + 8 ..][0..8], .little);
        try testing.expectEqual(@as(u64, 12), size); // "host says hi"
    }
    // TSETATTR mode on fid 2
    {
        var p = TestPayload{};
        const payload = p.u32v(2).u32v(0x1).u32v(0o644).u32v(0).u32v(0).u64v(0).slice();
        const req = try tmsg(testing.allocator, Tsetattr, 13, payload);
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Tsetattr + 1);
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    }
    // TWALK to fid 4 "hello.link" + TREADLINK
    {
        var p = TestPayload{};
        const walk_payload = p.u32v(1).u32v(4).u16v(1).str("hello.link").slice();
        const walk = try tmsg(testing.allocator, Twalk, 14, walk_payload);
        defer testing.allocator.free(walk);
        const walk_n = srv.handle(walk, &resp);
        try expectRType(resp[0..walk_n], Twalk + 1);

        var p2 = TestPayload{};
        const req = try tmsg(testing.allocator, Treadlink, 15, p2.u32v(4).slice());
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Treadlink + 1);
        try testing.expectEqualStrings("hello.txt", resp[9..n]);
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
    }
    // TREMOVE fid 3 and its guest-created file
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tremove, 16, p.u32v(3).slice());
        defer testing.allocator.free(req);
        var counted = testing.FailingAllocator.init(testing.allocator, .{});
        srv.alloc = counted.allocator();
        const n = srv.handle(req, &resp);
        srv.alloc = testing.allocator;
        try expectRType(resp[0..n], Tremove + 1);
        try testing.expectEqual(@as(usize, 0), counted.allocations);
        try testing.expectEqual(@as(usize, 0), counted.allocated_bytes);
        try testing.expect(!srv.fids.contains(3));
        try testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().openFile(io, root ++ "/guest.txt", .{}),
        );
    }
    // TCLUNK everything
    {
        for ([_]u32{ 1, 2, 4 }) |fid| {
            var p = TestPayload{};
            const req = try tmsg(testing.allocator, Tclunk, 17, p.u32v(fid).slice());
            defer testing.allocator.free(req);
            const n = srv.handle(req, &resp);
            try expectRType(resp[0..n], Tclunk + 1);
        }
    }
}

test "p9: restore reopens saved fid" {
    const io = @import("../global.zig").io();
    const root = ".zig-cache/p9-test-restore";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, root ++ "/saved.txt", .{});
        file.close(io);
    }

    var srv = try P9Server.init(testing.allocator, root);
    defer srv.deinit();
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    srv.alloc = counted.allocator();
    try srv.restoreFid(testing.allocator, 7, "saved.txt", 0);
    srv.alloc = testing.allocator;

    const restored = srv.fids.get(7).?;
    try testing.expect(restored.fd != null);
    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(@as(usize, 9), counted.allocated_bytes);
}

test "p9: path escapes and unknown ops are rejected" {
    const io = @import("../global.zig").io();
    const root = ".zig-cache/p9-test-sec";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var srv = try P9Server.init(testing.allocator, root);
    defer srv.deinit();
    var resp: [MSIZE_MAX]u8 = undefined;

    var p0 = TestPayload{};
    const attach = try tmsg(testing.allocator, Tattach, 1, p0.u32v(1).u32v(0xFFFF_FFFF).str("u").str("").u32v(0).slice());
    defer testing.allocator.free(attach);
    _ = srv.handle(attach, &resp);

    // Walk ".." is refused.
    var p = TestPayload{};
    const req = try tmsg(testing.allocator, Twalk, 2, p.u32v(1).u32v(2).u16v(1).str("..").slice());
    defer testing.allocator.free(req);
    const n = srv.handle(req, &resp);
    try testing.expectEqual(@as(u8, Tlerror + 1), resp[4]);
    _ = n;

    // Unknown op -> EOPNOTSUPP.
    var p2 = TestPayload{};
    const req2 = try tmsg(testing.allocator, 16, 3, p2.u32v(1).slice()); // Tsymlink
    defer testing.allocator.free(req2);
    const n2 = srv.handle(req2, &resp);
    try testing.expectEqual(@as(u8, Tlerror + 1), resp[4]);
    const ecode = std.mem.readInt(u32, resp[7..11], .little);
    try testing.expectEqual(L_EOPNOTSUPP, ecode);
    _ = n2;

    // Bad fid -> EBADF.
    var p3 = TestPayload{};
    const req3 = try tmsg(testing.allocator, Tclunk, 4, p3.u32v(99).slice());
    defer testing.allocator.free(req3);
    _ = srv.handle(req3, &resp);
    try testing.expectEqual(L_EBADF, std.mem.readInt(u32, resp[7..11], .little));
}

test "p9: request parsing is bounded by the declared message size" {
    var root = [_]u8{'.'};
    var server = P9Server.initEmbedded(testing.allocator, &root);
    defer server.deinitEmbedded();
    var response: [MSIZE_MAX]u8 = undefined;

    var payload = TestPayload{};
    const request = try tmsg(testing.allocator, Tflush, 42, payload.u16v(1).slice());
    defer testing.allocator.free(request);
    std.mem.writeInt(u32, request[0..4], 7, .little);

    const response_len = server.handle(request, &response);
    try testing.expectEqual(@as(usize, 11), response_len);
    try testing.expectEqual(@as(u8, Tlerror + 1), response[4]);
    try testing.expectEqual(@as(u16, 42), std.mem.readInt(u16, response[5..7], .little));
    try testing.expectEqual(L_EINVAL, std.mem.readInt(u32, response[7..11], .little));

    std.mem.writeInt(u32, request[0..4], @intCast(request.len + 1), .little);
    _ = server.handle(request, &response);
    try testing.expectEqual(L_EINVAL, std.mem.readInt(u32, response[7..11], .little));
}

test "p9: responses stay within the negotiated message size" {
    var root = [_]u8{'.'};
    var server = P9Server.initEmbedded(testing.allocator, &root);
    defer server.deinitEmbedded();
    var response: [64]u8 = undefined;

    var version_payload = TestPayload{};
    const version = try tmsg(
        testing.allocator,
        Tversion,
        1,
        version_payload.u32v(response.len).str("9P2000.L").slice(),
    );
    defer testing.allocator.free(version);
    try testing.expectEqual(@as(usize, 21), server.handle(version, &response));

    var attach_payload = TestPayload{};
    const attach = try tmsg(testing.allocator, Tattach, 2, attach_payload.u32v(1).slice());
    defer testing.allocator.free(attach);
    _ = server.handle(attach, &response);

    var getattr_payload = TestPayload{};
    const getattr = try tmsg(
        testing.allocator,
        Tgetattr,
        3,
        getattr_payload.u32v(1).u64v(std.math.maxInt(u64)).slice(),
    );
    defer testing.allocator.free(getattr);
    const response_len = server.handle(getattr, &response);
    try testing.expectEqual(@as(usize, 11), response_len);
    try testing.expectEqual(@as(u8, Tlerror + 1), response[4]);
    try testing.expectEqual(L_EINVAL, std.mem.readInt(u32, response[7..11], .little));
}

test "p9: version rejects a message size too small for its response" {
    var root = [_]u8{'.'};
    var server = P9Server.initEmbedded(testing.allocator, &root);
    defer server.deinitEmbedded();
    var response: [MSIZE_MAX]u8 = undefined;

    var payload = TestPayload{};
    const request = try tmsg(
        testing.allocator,
        Tversion,
        4,
        payload.u32v(20).str("9P2000.L").slice(),
    );
    defer testing.allocator.free(request);
    const response_len = server.handle(request, &response);
    try testing.expectEqual(@as(usize, 11), response_len);
    try testing.expectEqual(@as(u8, Tlerror + 1), response[4]);
    try testing.expectEqual(MSIZE_MAX, server.msize);
}
