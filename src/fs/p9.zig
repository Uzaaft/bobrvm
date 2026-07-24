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
        return .{
            .alloc = alloc,
            .root = try alloc.dupe(u8, root_path),
            .fids = std.AutoHashMap(u32, Fid).init(alloc),
        };
    }

    pub fn deinit(self: *P9Server) void {
        var iter = self.fids.valueIterator();
        while (iter.next()) |fid| self.dropFid(fid);
        self.fids.deinit();
        self.alloc.free(self.root);
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
            const path = try self.hostPath(owned);
            defer self.alloc.free(path);
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
            if (self.off + 1 > self.buf.len) return error.Truncated;
            defer self.off += 1;
            return self.buf[self.off];
        }
        fn u16v(self: *Reader) !u16 {
            if (self.off + 2 > self.buf.len) return error.Truncated;
            defer self.off += 2;
            return std.mem.readInt(u16, self.buf[self.off..][0..2], .little);
        }
        fn u32v(self: *Reader) !u32 {
            if (self.off + 4 > self.buf.len) return error.Truncated;
            defer self.off += 4;
            return std.mem.readInt(u32, self.buf[self.off..][0..4], .little);
        }
        fn u64v(self: *Reader) !u64 {
            if (self.off + 8 > self.buf.len) return error.Truncated;
            defer self.off += 8;
            return std.mem.readInt(u64, self.buf[self.off..][0..8], .little);
        }
        fn str(self: *Reader) ![]const u8 {
            const len = try self.u16v();
            if (self.off + len > self.buf.len) return error.Truncated;
            defer self.off += len;
            return self.buf[self.off..][0..len];
        }
        fn bytes(self: *Reader, len: usize) ![]const u8 {
            if (self.off + len > self.buf.len) return error.Truncated;
            defer self.off += len;
            return self.buf[self.off..][0..len];
        }
    };

    const Writer = struct {
        buf: []u8,
        off: usize = 7, // header written by finish()

        fn u8v(self: *Writer, v: u8) void {
            self.buf[self.off] = v;
            self.off += 1;
        }
        fn u16v(self: *Writer, v: u16) void {
            std.mem.writeInt(u16, self.buf[self.off..][0..2], v, .little);
            self.off += 2;
        }
        fn u32v(self: *Writer, v: u32) void {
            std.mem.writeInt(u32, self.buf[self.off..][0..4], v, .little);
            self.off += 4;
        }
        fn u64v(self: *Writer, v: u64) void {
            std.mem.writeInt(u64, self.buf[self.off..][0..8], v, .little);
            self.off += 8;
        }
        fn str(self: *Writer, s: []const u8) void {
            self.u16v(@intCast(s.len));
            @memcpy(self.buf[self.off..][0..s.len], s);
            self.off += s.len;
        }
        fn qid(self: *Writer, q: Qid) void {
            self.u8v(q.type);
            self.u32v(q.version);
            self.u64v(q.path);
        }
        fn finish(self: *Writer, msg_type: u8, tag: u16) usize {
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
        w.u32v(ecode);
        return w.finish(Tlerror + 1, tag);
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
        if (rel.len == 0) return self.alloc.dupeZ(u8, self.root);
        return std.fmt.allocPrintSentinel(self.alloc, "{s}/{s}", .{ self.root, rel }, 0);
    }

    fn validName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
        if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
        return true;
    }

    fn statRel(self: *P9Server, rel: []const u8) !std.c.Stat {
        const path = try self.hostPath(rel);
        defer self.alloc.free(path);
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
        var w = Writer{ .buf = resp };
        if (req.len < 7) return lerror(&w, 0, L_EINVAL);
        var r = Reader{ .buf = req, .off = 4 };
        const msg_type = r.u8v() catch unreachable;
        const tag = r.u16v() catch unreachable;

        return self.dispatch(msg_type, tag, &r, &w) catch |err| switch (err) {
            error.Truncated => lerror(&w, tag, L_EINVAL),
            error.Errno => lerror(&w, tag, errnoToLinux()),
            error.Stat => lerror(&w, tag, L_ENOENT),
            error.BadFid => lerror(&w, tag, L_EBADF),
            error.NotSupported => lerror(&w, tag, L_EOPNOTSUPP),
            error.Invalid => lerror(&w, tag, L_EINVAL),
            error.Access => lerror(&w, tag, L_EACCES),
            error.OutOfMemory => lerror(&w, tag, L_EIO),
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
    };

    fn getFid(self: *P9Server, id: u32) Error!*Fid {
        return self.fids.getPtr(id) orelse error.BadFid;
    }

    fn dispatch(self: *P9Server, msg_type: u8, tag: u16, r: *Reader, w: *Writer) Error!usize {
        switch (msg_type) {
            Tversion => {
                const client_msize = try r.u32v();
                const version = try r.str();
                self.msize = @min(client_msize, MSIZE_MAX);
                // Fresh session: drop all fids.
                var iter = self.fids.valueIterator();
                while (iter.next()) |fid| self.dropFid(fid);
                self.fids.clearRetainingCapacity();
                w.u32v(self.msize);
                if (std.mem.eql(u8, version, "9P2000.L")) {
                    w.str("9P2000.L");
                } else {
                    w.str("unknown");
                }
                return w.finish(Tversion + 1, tag);
            },
            Tattach => {
                const fid = try r.u32v();
                const st = self.statRel("") catch return error.Stat;
                const rel = try self.alloc.dupe(u8, "");
                errdefer self.alloc.free(rel);
                if (self.fids.fetchRemove(fid)) |old| {
                    var v = old.value;
                    self.dropFid(&v);
                }
                try self.fids.put(fid, .{ .rel = rel });
                w.qid(qidFromStat(st));
                return w.finish(Tattach + 1, tag);
            },
            Twalk => {
                const fid = try r.u32v();
                const newfid = try r.u32v();
                const nwname = try r.u16v();
                const src = try self.getFid(fid);

                var rel = std.ArrayListUnmanaged(u8).empty;
                defer rel.deinit(self.alloc);
                try rel.appendSlice(self.alloc, src.rel);

                var qids = std.ArrayListUnmanaged(Qid).empty;
                defer qids.deinit(self.alloc);

                var i: u16 = 0;
                while (i < nwname) : (i += 1) {
                    const name = try r.str();
                    if (!validName(name)) {
                        if (qids.items.len == 0) return error.Access;
                        break;
                    }
                    const prev_len = rel.items.len;
                    if (rel.items.len > 0) try rel.append(self.alloc, '/');
                    try rel.appendSlice(self.alloc, name);
                    const st = self.statRel(rel.items) catch {
                        rel.shrinkRetainingCapacity(prev_len);
                        break;
                    };
                    try qids.append(self.alloc, qidFromStat(st));
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

                w.u16v(@intCast(qids.items.len));
                for (qids.items) |q| w.qid(q);
                return w.finish(Twalk + 1, tag);
            },
            Tlopen => {
                const fid_id = try r.u32v();
                const flags = try r.u32v();
                const fid = try self.getFid(fid_id);
                const path = try self.hostPath(fid.rel);
                defer self.alloc.free(path);

                const fd = std.c.open(path.ptr, linuxFlagsToDarwin(flags));
                if (fd < 0) return error.Errno;
                if (fid.fd) |old| _ = std.c.close(old);
                fid.fd = fd;
                fid.open_linux_flags = flags;

                var st: std.c.Stat = undefined;
                if (std.c.fstat(fd, &st) != 0) return error.Errno;
                w.qid(qidFromStat(st));
                w.u32v(0); // iounit: use msize-derived default
                return w.finish(Tlopen + 1, tag);
            },
            Tlcreate => {
                const fid_id = try r.u32v();
                const name = try r.str();
                const flags = try r.u32v();
                const mode = try r.u32v();
                _ = try r.u32v(); // gid
                if (!validName(name)) return error.Access;
                const fid = try self.getFid(fid_id);

                const dir_rel = try self.alloc.dupe(u8, fid.rel);
                defer self.alloc.free(dir_rel);
                const rel = if (dir_rel.len == 0)
                    try self.alloc.dupe(u8, name)
                else
                    try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir_rel, name });
                errdefer self.alloc.free(rel);
                const path = try self.hostPath(rel);
                defer self.alloc.free(path);

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
                w.qid(qidFromStat(st));
                w.u32v(0);
                return w.finish(Tlcreate + 1, tag);
            },
            Tgetattr => {
                const fid_id = try r.u32v();
                _ = try r.u64v(); // request_mask: we always fill the basics
                const fid = try self.getFid(fid_id);
                const st = self.statRel(fid.rel) catch return error.Stat;

                w.u64v(0x000007ff); // valid: P9_GETATTR_BASIC
                w.qid(qidFromStat(st));
                w.u32v(st.mode);
                w.u32v(st.uid);
                w.u32v(st.gid);
                w.u64v(st.nlink);
                w.u64v(@bitCast(@as(i64, st.rdev)));
                w.u64v(@bitCast(st.size));
                w.u64v(4096); // blksize
                w.u64v(@bitCast(st.blocks));
                w.u64v(@bitCast(@as(i64, st.atimespec.sec)));
                w.u64v(@bitCast(@as(i64, st.atimespec.nsec)));
                w.u64v(@bitCast(@as(i64, st.mtimespec.sec)));
                w.u64v(@bitCast(@as(i64, st.mtimespec.nsec)));
                w.u64v(@bitCast(@as(i64, st.ctimespec.sec)));
                w.u64v(@bitCast(@as(i64, st.ctimespec.nsec)));
                w.u64v(0); // btime sec
                w.u64v(0); // btime nsec
                w.u64v(0); // gen
                w.u64v(0); // data_version
                return w.finish(Tgetattr + 1, tag);
            },
            Tsetattr => {
                const fid_id = try r.u32v();
                const valid = try r.u32v();
                const mode = try r.u32v();
                _ = try r.u32v(); // uid
                _ = try r.u32v(); // gid
                const size = try r.u64v();
                const fid = try self.getFid(fid_id);
                const path = try self.hostPath(fid.rel);
                defer self.alloc.free(path);

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
                return w.finish(Tsetattr + 1, tag);
            },
            Treaddir => {
                const fid_id = try r.u32v();
                const offset = try r.u64v();
                const count = try r.u32v();
                const fid = try self.getFid(fid_id);
                const path = try self.hostPath(fid.rel);
                defer self.alloc.free(path);

                const dir = std.c.opendir(path.ptr) orelse return error.Errno;
                defer _ = std.c.closedir(dir);

                const max = @min(count, self.msize - 11 - 4);
                w.u32v(0); // count patched below
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
                    w.qid(.{
                        .type = if (ent.type == 4) 0x80 else if (ent.type == 10) 0x02 else 0x00,
                        .version = 0,
                        .path = ent.ino,
                    });
                    w.u64v(index); // offset of NEXT entry
                    w.u8v(ent.type);
                    w.str(name);
                }
                std.mem.writeInt(u32, w.buf[data_start - 4 ..][0..4], @intCast(w.off - data_start), .little);
                return w.finish(Treaddir + 1, tag);
            },
            Tread => {
                const fid_id = try r.u32v();
                const offset = try r.u64v();
                const count = try r.u32v();
                const fid = try self.getFid(fid_id);
                const fd = fid.fd orelse return error.BadFid;

                const max = @min(count, self.msize - 11 - 4);
                w.u32v(0); // count patched below
                const data_start = w.off;
                const n = std.c.pread(fd, w.buf[w.off..].ptr, max, @intCast(offset));
                if (n < 0) return error.Errno;
                w.off += @intCast(n);
                std.mem.writeInt(u32, w.buf[data_start - 4 ..][0..4], @intCast(n), .little);
                return w.finish(Tread + 1, tag);
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
                w.u32v(@intCast(n));
                return w.finish(Twrite + 1, tag);
            },
            Tmkdir => {
                const fid_id = try r.u32v();
                const name = try r.str();
                const mode = try r.u32v();
                if (!validName(name)) return error.Access;
                const fid = try self.getFid(fid_id);
                const rel = if (fid.rel.len == 0)
                    try self.alloc.dupe(u8, name)
                else
                    try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ fid.rel, name });
                defer self.alloc.free(rel);
                const path = try self.hostPath(rel);
                defer self.alloc.free(path);

                if (std.c.mkdir(path.ptr, @intCast(mode & 0o7777)) != 0) return error.Errno;
                const st = self.statRel(rel) catch return error.Stat;
                w.qid(qidFromStat(st));
                return w.finish(Tmkdir + 1, tag);
            },
            Tunlinkat => {
                const fid_id = try r.u32v();
                const name = try r.str();
                const flags = try r.u32v();
                if (!validName(name)) return error.Access;
                const fid = try self.getFid(fid_id);
                const rel = if (fid.rel.len == 0)
                    try self.alloc.dupe(u8, name)
                else
                    try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ fid.rel, name });
                defer self.alloc.free(rel);
                const path = try self.hostPath(rel);
                defer self.alloc.free(path);

                // Linux AT_REMOVEDIR=0x200; Darwin's is 0x80.
                const removedir = flags & 0x200 != 0;
                const rc = if (removedir) std.c.rmdir(path.ptr) else std.c.unlink(path.ptr);
                if (rc != 0) return error.Errno;
                return w.finish(Tunlinkat + 1, tag);
            },
            Tremove => {
                const fid_id = try r.u32v();
                const fid = try self.getFid(fid_id);
                const path = try self.hostPath(fid.rel);
                defer self.alloc.free(path);
                const st = self.statRel(fid.rel) catch return error.Stat;
                const rc = if (std.c.S.ISDIR(st.mode)) std.c.rmdir(path.ptr) else std.c.unlink(path.ptr);
                if (self.fids.fetchRemove(fid_id)) |old| {
                    var v = old.value;
                    self.dropFid(&v);
                }
                if (rc != 0) return error.Errno;
                return w.finish(Tremove + 1, tag);
            },
            Treadlink => {
                const fid_id = try r.u32v();
                const fid = try self.getFid(fid_id);
                const path = try self.hostPath(fid.rel);
                defer self.alloc.free(path);
                var target: [1024]u8 = undefined;
                const n = std.c.readlink(path.ptr, &target, target.len);
                if (n < 0) return error.Errno;
                w.str(target[0..@intCast(n)]);
                return w.finish(Treadlink + 1, tag);
            },
            Tstatfs => {
                _ = try r.u32v();
                w.u32v(0x01021997); // V9FS_MAGIC
                w.u32v(4096); // bsize
                w.u64v(1 << 28); // blocks (fabricated ~1TB)
                w.u64v(1 << 27); // bfree
                w.u64v(1 << 27); // bavail
                w.u64v(1 << 20); // files
                w.u64v(1 << 19); // ffree
                w.u64v(0); // fsid
                w.u32v(255); // namelen
                return w.finish(Tstatfs + 1, tag);
            },
            Tfsync => {
                const fid_id = try r.u32v();
                const fid = try self.getFid(fid_id);
                if (fid.fd) |fd| {
                    if (std.c.fsync(fd) != 0) return error.Errno;
                }
                return w.finish(Tfsync + 1, tag);
            },
            Tclunk => {
                const fid_id = try r.u32v();
                if (self.fids.fetchRemove(fid_id)) |old| {
                    var v = old.value;
                    self.dropFid(&v);
                } else return error.BadFid;
                return w.finish(Tclunk + 1, tag);
            },
            Tflush => {
                _ = try r.u16v(); // oldtag: we're synchronous, nothing in flight
                return w.finish(Tflush + 1, tag);
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
        const n = srv.handle(req, &resp);
        try expectRType(resp[0..n], Tattach + 1);
        try testing.expectEqual(@as(u8, 0x80), resp[7]); // root qid is a dir
    }
    // TWALK fid1 -> fid2 "hello.txt"
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Twalk, 2, p.u32v(1).u32v(2).u16v(1).str("hello.txt").slice());
        defer testing.allocator.free(req);
        const n = srv.handle(req, &resp);
        try expectRType(resp[0..n], Twalk + 1);
        try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[7..9], .little));
    }
    // TLOPEN fid2 rdonly + TREAD
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tlopen, 3, p.u32v(2).u32v(0).slice());
        defer testing.allocator.free(req);
        const n = srv.handle(req, &resp);
        try expectRType(resp[0..n], Tlopen + 1);

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
        const n2 = srv.handle(req2, &resp);
        try expectRType(resp[0..n2], Treaddir + 1);
        try testing.expect(std.mem.indexOf(u8, resp[0..n2], "hello.txt") != null);
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
        const n2 = srv.handle(req2, &resp);
        try expectRType(resp[0..n2], Tlcreate + 1);

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
        const n = srv.handle(req, &resp);
        try expectRType(resp[0..n], Tmkdir + 1);

        var p2 = TestPayload{};
        const req2 = try tmsg(testing.allocator, Tunlinkat, 11, p2.u32v(1).str("subdir").u32v(0x200).slice());
        defer testing.allocator.free(req2);
        const n2 = srv.handle(req2, &resp);
        try expectRType(resp[0..n2], Tunlinkat + 1);
    }
    // TGETATTR on fid 2
    {
        var p = TestPayload{};
        const req = try tmsg(testing.allocator, Tgetattr, 12, p.u32v(2).u64v(0x7ff).slice());
        defer testing.allocator.free(req);
        const n = srv.handle(req, &resp);
        try expectRType(resp[0..n], Tgetattr + 1);
        const size = std.mem.readInt(u64, resp[7 + 8 + 13 + 4 + 4 + 4 + 8 + 8 ..][0..8], .little);
        try testing.expectEqual(@as(u64, 12), size); // "host says hi"
    }
    // TCLUNK everything
    {
        for ([_]u32{ 1, 2, 3 }) |fid| {
            var p = TestPayload{};
            const req = try tmsg(testing.allocator, Tclunk, 13, p.u32v(fid).slice());
            defer testing.allocator.free(req);
            const n = srv.handle(req, &resp);
            try expectRType(resp[0..n], Tclunk + 1);
        }
    }
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
