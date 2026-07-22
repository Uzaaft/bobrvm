//! Virtio GPU Device (2D scanout).
//!
//! Implements virtio-gpu per virtio 1.2 spec section 5.7, processing
//! descriptor chains directly from guest memory. 2D only for now: the
//! guest DRM driver renders into resources backed by guest pages,
//! transfers them to a host copy, and flushes; the host presents the
//! scanout resource. 3D (virgl) arrives with the Metal backend.
//!
//! Queues:
//!   0: controlq (commands and responses)
//!   1: cursorq (cursor updates)

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");
const virgl = @import("../gpu/virgl/main.zig");
const gpu_module = @import("../gpu/main.zig");

const log = std.log.scoped(.virtio_gpu);

/// GPU feature bits.
pub const Features = struct {
    pub const VIRGL: u64 = 1 << 0;
    pub const EDID: u64 = 1 << 1;
    pub const RESOURCE_UUID: u64 = 1 << 2;
    pub const RESOURCE_BLOB: u64 = 1 << 3;
    pub const CONTEXT_INIT: u64 = 1 << 4;
};

/// GPU command types.
pub const CmdType = enum(u32) {
    // 2D commands
    get_display_info = 0x0100,
    resource_create_2d = 0x0101,
    resource_unref = 0x0102,
    set_scanout = 0x0103,
    resource_flush = 0x0104,
    transfer_to_host_2d = 0x0105,
    resource_attach_backing = 0x0106,
    resource_detach_backing = 0x0107,
    get_capset_info = 0x0108,
    get_capset = 0x0109,
    get_edid = 0x010a,

    // 3D commands
    ctx_create = 0x0200,
    ctx_destroy = 0x0201,
    ctx_attach_resource = 0x0202,
    ctx_detach_resource = 0x0203,
    resource_create_3d = 0x0204,
    transfer_to_host_3d = 0x0205,
    transfer_from_host_3d = 0x0206,
    submit_3d = 0x0207,

    // Cursor commands
    update_cursor = 0x0300,
    move_cursor = 0x0301,

    // Response types (success)
    resp_ok_nodata = 0x1100,
    resp_ok_display_info = 0x1101,
    resp_ok_capset_info = 0x1102,
    resp_ok_capset = 0x1103,
    resp_ok_edid = 0x1104,

    // Response types (error)
    resp_err_unspec = 0x1200,
    resp_err_out_of_memory = 0x1201,
    resp_err_invalid_scanout_id = 0x1202,
    resp_err_invalid_resource_id = 0x1203,
    resp_err_invalid_context_id = 0x1204,
    resp_err_invalid_parameter = 0x1205,

    _,
};

/// Control header (common to all commands).
pub const CtrlHeader = extern struct {
    type: u32,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    ring_idx: u8 = 0,
    _padding: [3]u8 = .{ 0, 0, 0 },
};

/// FLAG_FENCE: the driver requests a fence; the response must carry
/// the fence_id back with FLAG_FENCE set.
pub const FLAG_FENCE: u32 = 1 << 0;

/// Rectangle.
pub const Rect = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// Display info (per scanout).
pub const DisplayOne = extern struct {
    r: Rect = .{},
    enabled: u32 = 0,
    flags: u32 = 0,
};

/// Display info response.
pub const DisplayInfoResp = extern struct {
    header: CtrlHeader,
    pmodes: [16]DisplayOne = [_]DisplayOne{.{}} ** 16,
};

pub const ResourceCreate2D = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};

pub const ResourceUnref = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    _padding: u32 = 0,
};

pub const SetScanout = extern struct {
    header: CtrlHeader,
    r: Rect,
    scanout_id: u32,
    resource_id: u32,
};

pub const ResourceFlush = extern struct {
    header: CtrlHeader,
    r: Rect,
    resource_id: u32,
    _padding: u32 = 0,
};

pub const TransferToHost2D = extern struct {
    header: CtrlHeader,
    r: Rect,
    offset: u64,
    resource_id: u32,
    _padding: u32 = 0,
};

/// Memory entry for attach backing.
pub const MemEntry = extern struct {
    addr: u64,
    length: u32,
    _padding: u32 = 0,
};

pub const ResourceAttachBacking = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    nr_entries: u32,
};

pub const ResourceDetachBacking = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    _padding: u32 = 0,
};

pub const CtxCreate = extern struct {
    header: CtrlHeader,
    nlen: u32,
    context_init: u32,
    debug_name: [64]u8 = [_]u8{0} ** 64,
};

pub const CtxResource = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    _padding: u32 = 0,
};

pub const ResourceCreate3D = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    target: u32,
    format: u32,
    bind: u32,
    width: u32,
    height: u32,
    depth: u32,
    array_size: u32,
    last_level: u32,
    nr_samples: u32,
    flags: u32,
    _padding: u32 = 0,
};

pub const Submit3D = extern struct {
    header: CtrlHeader,
    size: u32,
    _padding: u32 = 0,
};

pub const GetCapsetInfo = extern struct {
    header: CtrlHeader,
    capset_index: u32,
    _padding: u32 = 0,
};

pub const CapsetInfoResp = extern struct {
    header: CtrlHeader,
    capset_id: u32,
    capset_max_version: u32,
    capset_max_size: u32,
    _padding: u32 = 0,
};

pub const GetCapset = extern struct {
    header: CtrlHeader,
    capset_id: u32,
    capset_version: u32,
};

/// Capset ids (VIRTIO_GPU_CAPSET_*).
pub const CAPSET_VIRGL: u32 = 1;
pub const CAPSET_VIRGL2: u32 = 2;

/// Capset blob sizes (virgl_caps_v1/v2 from virglrenderer). The kernel
/// transports these opaquely to mesa; sizes must be honest, contents
/// grow as the translator does.
pub const CAPS_V1_SIZE: u32 = 308;
pub const CAPS_V2_SIZE: u32 = 1384;

/// GPU config space.
pub const Config = extern struct {
    events_read: u32 = 0,
    events_clear: u32 = 0,
    num_scanouts: u32 = 1,
    num_capsets: u32 = 0,
};

/// A 2D resource: host pixel copy + guest backing pages.
pub const Resource2D = struct {
    id: u32,
    format: u32,
    width: u32,
    height: u32,
    /// Host copy of the pixels (width * height * 4).
    host_data: []u8,
    /// Guest backing pages (scatter-gather).
    entries: std.ArrayListUnmanaged(MemEntry),

    pub const BYTES_PER_PIXEL: u32 = 4;

    pub fn stride(self: *const Resource2D) u32 {
        return self.width * BYTES_PER_PIXEL;
    }
};

/// GPU device.
pub const Gpu = struct {
    alloc: Allocator,
    transport: *mmio.Transport,
    config: Config,

    /// Shadow avail-ring cursors for the two queues.
    ctrl_last_avail: u16,
    cursor_last_avail: u16,

    /// 2D resources.
    resources: std.AutoHashMap(u32, Resource2D),

    /// Guards resource host_data lifetime + scanout id: the vCPU thread
    /// mutates while the renderer thread reads via lockScanout.
    scanout_mutex: std.Thread.Mutex,

    /// Current scanout.
    scanout_resource_id: u32,

    /// Display dimensions.
    display_width: u32,
    display_height: u32,

    /// Guest memory accessor.
    guest_memory: ?ring.GetMemFn,

    /// Frame ready callback (scanout resource was flushed).
    frame_callback: ?*const fn (userdata: ?*anyopaque) void,
    frame_userdata: ?*anyopaque,

    /// 3D (virgl) support: guest contexts + resources + command decode.
    virgl_enabled: bool,
    gpu_device: gpu_module.GpuDevice,

    pub const Error = Allocator.Error;
    pub const QUEUE_SIZE: u16 = 256;
    pub const MAX_RESOURCE_DIM: u32 = 8192;
    pub const MAX_BACKING_ENTRIES: u32 = 16384;

    pub fn init(alloc: Allocator, enable_virgl: bool) Error!*Gpu {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        var features = virtio_version_1;
        if (enable_virgl) features |= Features.VIRGL;
        const transport = try mmio.Transport.init(alloc, 16, features, 2); // 16 = GPU device ID
        errdefer transport.deinit();

        const gpu = try alloc.create(Gpu);
        errdefer alloc.destroy(gpu);

        gpu.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = .{ .num_capsets = if (enable_virgl) 2 else 0 },
            .ctrl_last_avail = 0,
            .cursor_last_avail = 0,
            .resources = std.AutoHashMap(u32, Resource2D).init(alloc),
            .scanout_mutex = .{},
            .scanout_resource_id = 0,
            .display_width = 1280,
            .display_height = 800,
            .guest_memory = null,
            .frame_callback = null,
            .frame_userdata = null,
            .virgl_enabled = enable_virgl,
            .gpu_device = gpu_module.GpuDevice.init(alloc),
        };

        transport.setNotifyCallback(handleNotify, gpu);

        assert(gpu.transport.device_id == 16);

        return gpu;
    }

    pub fn deinit(self: *Gpu) void {
        var iter = self.resources.valueIterator();
        while (iter.next()) |res| {
            self.alloc.free(res.host_data);
            res.entries.deinit(self.alloc);
        }
        self.resources.deinit();
        self.gpu_device.deinit();
        self.transport.deinit();
        self.alloc.destroy(self);
    }

    /// Set display dimensions (before guest probes).
    pub fn setDisplaySize(self: *Gpu, width: u32, height: u32) void {
        assert(width > 0 and height > 0);
        assert(width <= MAX_RESOURCE_DIM and height <= MAX_RESOURCE_DIM);
        self.display_width = width;
        self.display_height = height;
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(self: *Gpu, accessor: ring.GetMemFn) void {
        self.guest_memory = accessor;
    }

    /// Set frame ready callback.
    pub fn setFrameCallback(
        self: *Gpu,
        callback: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.frame_callback = callback;
        self.frame_userdata = userdata;
    }

    pub const ScanoutView = struct {
        data: []const u8,
        width: u32,
        height: u32,
    };

    /// Current scanout pixels (BGRA/XRGB 4 bytes per pixel), or null.
    /// Caller must be on the vCPU thread (unsynchronized).
    pub fn scanout(self: *Gpu) ?ScanoutView {
        if (self.scanout_resource_id == 0) return null;
        const res = self.resources.get(self.scanout_resource_id) orelse return null;
        return .{ .data = res.host_data, .width = res.width, .height = res.height };
    }

    /// Acquire the scanout for reading from another thread (renderer).
    /// Must be paired with unlockScanout; the view is only valid while
    /// the lock is held.
    pub fn lockScanout(self: *Gpu) ?ScanoutView {
        self.scanout_mutex.lock();
        const view = self.scanout() orelse {
            self.scanout_mutex.unlock();
            return null;
        };
        return view;
    }

    pub fn unlockScanout(self: *Gpu) void {
        self.scanout_mutex.unlock();
    }

    // =========================================================================
    // MMIO Interface
    // =========================================================================

    pub fn read(self: *Gpu, offset: u12) u32 {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            return self.readConfig(offset - @intFromEnum(mmio.Reg.config));
        }
        return self.transport.read(offset);
    }

    pub fn write(self: *Gpu, offset: u12, value: u32) void {
        if (offset >= @intFromEnum(mmio.Reg.config)) {
            self.writeConfig(offset - @intFromEnum(mmio.Reg.config), value);
            return;
        }
        self.transport.write(offset, value);
    }

    fn readConfig(self: *Gpu, offset: u12) u32 {
        const config_bytes = std.mem.asBytes(&self.config);
        if (offset + 4 <= config_bytes.len) {
            return std.mem.readInt(u32, config_bytes[offset..][0..4], .little);
        }
        return 0;
    }

    fn writeConfig(self: *Gpu, offset: u12, value: u32) void {
        // events_clear is the only writable field
        if (offset == @offsetOf(Config, "events_clear")) {
            self.config.events_read &= ~value;
        }
    }

    fn handleNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Gpu = @ptrCast(@alignCast(userdata));
        switch (queue_idx) {
            0 => self.processControlQueue(),
            1 => self.processCursorQueue(),
            else => {},
        }
    }

    /// Poll both queues. Called from the vCPU loop.
    pub fn poll(self: *Gpu) void {
        self.processControlQueue();
        self.processCursorQueue();
    }

    // =========================================================================
    // Command Processing
    // =========================================================================

    fn processControlQueue(self: *Gpu) void {
        const qc = self.transport.queues[0];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        while (self.ctrl_last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.ctrl_last_avail, get_mem) orelse break;
            const written = self.processCommand(qc, head, get_mem);
            ring.pushUsed(qc, head, written, get_mem);
            self.ctrl_last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    fn processCursorQueue(self: *Gpu) void {
        const qc = self.transport.queues[1];
        if (!qc.ready or qc.num == 0) return;
        const get_mem = self.guest_memory orelse return;

        const avail_idx = ring.availIdx(qc, get_mem) orelse return;
        var processed: u32 = 0;

        // Cursor commands have no response; just consume them.
        while (self.cursor_last_avail != avail_idx) : (processed += 1) {
            const head = ring.availEntry(qc, self.cursor_last_avail, get_mem) orelse break;
            ring.pushUsed(qc, head, 0, get_mem);
            self.cursor_last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    /// Execute one command chain; returns bytes written to the response.
    fn processCommand(self: *Gpu, qc: mmio.QueueConfig, head: u16, get_mem: ring.GetMemFn) u32 {
        const chain = ring.Chain.collect(qc, head, get_mem);
        const req = chain.request(get_mem) orelse return 0;
        const resp = chain.response(get_mem) orelse return 0;
        if (req.len < @sizeOf(CtrlHeader) or resp.len < @sizeOf(CtrlHeader)) return 0;

        const header = std.mem.bytesToValue(CtrlHeader, req[0..@sizeOf(CtrlHeader)]);
        const cmd_type: CmdType = @enumFromInt(header.type);

        var resp_type: CmdType = .resp_ok_nodata;
        var resp_len: u32 = @sizeOf(CtrlHeader);

        // Serialize against the renderer thread reading the scanout.
        self.scanout_mutex.lock();
        defer self.scanout_mutex.unlock();

        switch (cmd_type) {
            .get_display_info => {
                resp_type = self.cmdGetDisplayInfo(resp, &resp_len);
            },
            .resource_create_2d => {
                resp_type = self.cmdResourceCreate2D(req);
            },
            .resource_unref => {
                resp_type = self.cmdResourceUnref(req);
            },
            .set_scanout => {
                resp_type = self.cmdSetScanout(req);
            },
            .resource_flush => {
                resp_type = self.cmdResourceFlush(req);
            },
            .transfer_to_host_2d => {
                resp_type = self.cmdTransferToHost2D(req, get_mem);
            },
            .resource_attach_backing => {
                resp_type = self.cmdResourceAttachBacking(req, &chain, get_mem);
            },
            .resource_detach_backing => {
                resp_type = self.cmdResourceDetachBacking(req);
            },
            .get_capset_info => {
                resp_type = self.cmdGetCapsetInfo(req, resp, &resp_len);
            },
            .get_capset => {
                resp_type = self.cmdGetCapset(req, resp, &resp_len);
            },
            .ctx_create => {
                resp_type = self.cmdCtxCreate(header);
            },
            .ctx_destroy => {
                if (self.virgl_enabled) {
                    self.gpu_device.destroyContextId(header.ctx_id);
                    resp_type = .resp_ok_nodata;
                } else {
                    resp_type = .resp_err_unspec;
                }
            },
            .ctx_attach_resource, .ctx_detach_resource => {
                // Resource<->context association: accepted (tracked later).
                resp_type = if (self.virgl_enabled) .resp_ok_nodata else .resp_err_unspec;
            },
            .resource_create_3d => {
                resp_type = self.cmdResourceCreate3D(req);
            },
            .transfer_to_host_3d, .transfer_from_host_3d => {
                // Accepted; data movement lands with the Metal backend.
                resp_type = if (self.virgl_enabled) .resp_ok_nodata else .resp_err_unspec;
            },
            .submit_3d => {
                resp_type = self.cmdSubmit3D(header, req, &chain, get_mem);
            },
            else => {
                log.warn("unhandled GPU command: 0x{x}", .{header.type});
                resp_type = .resp_err_unspec;
            },
        }

        // Write the response header (payload responses already wrote
        // theirs and set resp_len).
        var resp_header = CtrlHeader{ .type = @intFromEnum(resp_type) };
        if ((header.flags & FLAG_FENCE) != 0) {
            resp_header.flags = FLAG_FENCE;
            resp_header.fence_id = header.fence_id;
        }
        @memcpy(resp[0..@sizeOf(CtrlHeader)], std.mem.asBytes(&resp_header));

        return @min(resp_len, @as(u32, @intCast(resp.len)));
    }

    fn cmdGetDisplayInfo(self: *Gpu, resp: []u8, resp_len: *u32) CmdType {
        if (resp.len < @sizeOf(DisplayInfoResp)) return .resp_err_unspec;

        var info = DisplayInfoResp{
            .header = .{ .type = @intFromEnum(CmdType.resp_ok_display_info) },
        };
        info.pmodes[0] = .{
            .r = .{ .width = self.display_width, .height = self.display_height },
            .enabled = 1,
        };
        @memcpy(resp[0..@sizeOf(DisplayInfoResp)], std.mem.asBytes(&info));
        resp_len.* = @sizeOf(DisplayInfoResp);
        return .resp_ok_display_info;
    }

    fn cmdResourceCreate2D(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(ResourceCreate2D)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(ResourceCreate2D, req[0..@sizeOf(ResourceCreate2D)]);

        if (cmd.resource_id == 0) return .resp_err_invalid_resource_id;
        if (cmd.width == 0 or cmd.height == 0) return .resp_err_invalid_parameter;
        if (cmd.width > MAX_RESOURCE_DIM or cmd.height > MAX_RESOURCE_DIM) {
            return .resp_err_invalid_parameter;
        }

        const size = @as(usize, cmd.width) * cmd.height * Resource2D.BYTES_PER_PIXEL;
        const host_data = self.alloc.alloc(u8, size) catch return .resp_err_out_of_memory;
        @memset(host_data, 0);

        // Replace any existing resource with this id.
        if (self.resources.fetchRemove(cmd.resource_id)) |old| {
            self.alloc.free(old.value.host_data);
            var entries = old.value.entries;
            entries.deinit(self.alloc);
        }

        self.resources.put(cmd.resource_id, .{
            .id = cmd.resource_id,
            .format = cmd.format,
            .width = cmd.width,
            .height = cmd.height,
            .host_data = host_data,
            .entries = .{},
        }) catch {
            self.alloc.free(host_data);
            return .resp_err_out_of_memory;
        };

        return .resp_ok_nodata;
    }

    fn cmdResourceUnref(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(ResourceUnref)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(ResourceUnref, req[0..@sizeOf(ResourceUnref)]);

        if (self.resources.fetchRemove(cmd.resource_id)) |entry| {
            self.alloc.free(entry.value.host_data);
            var entries = entry.value.entries;
            entries.deinit(self.alloc);
            if (self.scanout_resource_id == cmd.resource_id) {
                self.scanout_resource_id = 0;
            }
            return .resp_ok_nodata;
        }
        return .resp_err_invalid_resource_id;
    }

    fn cmdSetScanout(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(SetScanout)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(SetScanout, req[0..@sizeOf(SetScanout)]);

        if (cmd.scanout_id != 0) return .resp_err_invalid_scanout_id;
        // resource_id 0 disables the scanout.
        if (cmd.resource_id != 0 and !self.resources.contains(cmd.resource_id)) {
            return .resp_err_invalid_resource_id;
        }
        self.scanout_resource_id = cmd.resource_id;
        return .resp_ok_nodata;
    }

    fn cmdResourceFlush(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(ResourceFlush)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(ResourceFlush, req[0..@sizeOf(ResourceFlush)]);

        if (cmd.resource_id == self.scanout_resource_id and self.scanout_resource_id != 0) {
            if (self.frame_callback) |cb| {
                cb(self.frame_userdata);
            }
        }
        return .resp_ok_nodata;
    }

    fn cmdTransferToHost2D(self: *Gpu, req: []const u8, get_mem: ring.GetMemFn) CmdType {
        if (req.len < @sizeOf(TransferToHost2D)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(TransferToHost2D, req[0..@sizeOf(TransferToHost2D)]);

        const res = self.resources.getPtr(cmd.resource_id) orelse
            return .resp_err_invalid_resource_id;
        if (res.entries.items.len == 0) return .resp_err_unspec;

        const r = cmd.r;
        if (r.x + r.width > res.width or r.y + r.height > res.height) {
            return .resp_err_invalid_parameter;
        }

        // Guest backing uses the resource's linear layout: copy the
        // rect row by row from the scattered guest pages.
        const stride = res.stride();
        const row_bytes = @as(usize, r.width) * Resource2D.BYTES_PER_PIXEL;
        var row: u32 = 0;
        while (row < r.height) : (row += 1) {
            const line_off = @as(u64, r.y + row) * stride + @as(u64, r.x) * Resource2D.BYTES_PER_PIXEL;
            // Per spec the source offset is cmd.offset plus the rect's
            // position within the resource for the transferred region.
            const src_off = cmd.offset + @as(u64, row) * stride;
            const dst = res.host_data[@intCast(line_off)..][0..row_bytes];
            if (!copyFromBacking(res.entries.items, src_off, dst, get_mem)) {
                return .resp_err_unspec;
            }
        }

        return .resp_ok_nodata;
    }

    /// Copy `dst.len` bytes starting at linear `offset` out of the
    /// scattered guest backing into `dst`.
    fn copyFromBacking(
        entries: []const MemEntry,
        offset: u64,
        dst: []u8,
        get_mem: ring.GetMemFn,
    ) bool {
        var remaining = dst;
        var skip = offset;
        for (entries) |entry| {
            if (remaining.len == 0) return true;
            if (skip >= entry.length) {
                skip -= entry.length;
                continue;
            }
            const avail = entry.length - @as(u32, @intCast(skip));
            const n: usize = @min(remaining.len, avail);
            const src = get_mem(entry.addr + skip, n) orelse return false;
            @memcpy(remaining[0..n], src[0..n]);
            remaining = remaining[n..];
            skip = 0;
        }
        return remaining.len == 0;
    }

    fn cmdResourceAttachBacking(
        self: *Gpu,
        req: []const u8,
        chain: *const ring.Chain,
        get_mem: ring.GetMemFn,
    ) CmdType {
        if (req.len < @sizeOf(ResourceAttachBacking)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(
            ResourceAttachBacking,
            req[0..@sizeOf(ResourceAttachBacking)],
        );

        const res = self.resources.getPtr(cmd.resource_id) orelse
            return .resp_err_invalid_resource_id;
        if (cmd.nr_entries == 0 or cmd.nr_entries > MAX_BACKING_ENTRIES) {
            return .resp_err_invalid_parameter;
        }

        // The entry array either follows the command in the same buffer
        // or arrives as a second device-readable descriptor (Linux).
        const entries_bytes = @as(usize, cmd.nr_entries) * @sizeOf(MemEntry);
        const inline_entries = req[@sizeOf(ResourceAttachBacking)..];
        const entries_mem: []const u8 = if (inline_entries.len >= entries_bytes)
            inline_entries
        else blk: {
            var readable_idx: u32 = 0;
            for (chain.slice()) |d| {
                if (d.isWrite()) continue;
                readable_idx += 1;
                if (readable_idx == 2) {
                    const mem = get_mem(d.addr, d.len) orelse
                        return .resp_err_invalid_parameter;
                    break :blk mem;
                }
            }
            return .resp_err_invalid_parameter;
        };
        if (entries_mem.len < entries_bytes) return .resp_err_invalid_parameter;

        res.entries.clearRetainingCapacity();
        res.entries.ensureTotalCapacity(self.alloc, cmd.nr_entries) catch
            return .resp_err_out_of_memory;

        var i: u32 = 0;
        while (i < cmd.nr_entries) : (i += 1) {
            const off = i * @sizeOf(MemEntry);
            const entry = std.mem.bytesToValue(MemEntry, entries_mem[off..][0..@sizeOf(MemEntry)]);
            res.entries.appendAssumeCapacity(entry);
        }

        return .resp_ok_nodata;
    }

    fn cmdGetCapsetInfo(self: *Gpu, req: []const u8, resp: []u8, resp_len: *u32) CmdType {
        if (!self.virgl_enabled) return .resp_err_unspec;
        if (req.len < @sizeOf(GetCapsetInfo)) return .resp_err_invalid_parameter;
        if (resp.len < @sizeOf(CapsetInfoResp)) return .resp_err_unspec;
        const cmd = std.mem.bytesToValue(GetCapsetInfo, req[0..@sizeOf(GetCapsetInfo)]);

        var info = CapsetInfoResp{
            .header = .{ .type = @intFromEnum(CmdType.resp_ok_capset_info) },
            .capset_id = 0,
            .capset_max_version = 0,
            .capset_max_size = 0,
        };
        switch (cmd.capset_index) {
            0 => {
                info.capset_id = CAPSET_VIRGL;
                info.capset_max_version = 1;
                info.capset_max_size = CAPS_V1_SIZE;
            },
            1 => {
                info.capset_id = CAPSET_VIRGL2;
                info.capset_max_version = 2;
                info.capset_max_size = CAPS_V2_SIZE;
            },
            else => return .resp_err_invalid_parameter,
        }
        @memcpy(resp[0..@sizeOf(CapsetInfoResp)], std.mem.asBytes(&info));
        resp_len.* = @sizeOf(CapsetInfoResp);
        return .resp_ok_capset_info;
    }

    fn cmdGetCapset(self: *Gpu, req: []const u8, resp: []u8, resp_len: *u32) CmdType {
        if (!self.virgl_enabled) return .resp_err_unspec;
        if (req.len < @sizeOf(GetCapset)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(GetCapset, req[0..@sizeOf(GetCapset)]);

        const size: u32 = switch (cmd.capset_id) {
            CAPSET_VIRGL => CAPS_V1_SIZE,
            CAPSET_VIRGL2 => CAPS_V2_SIZE,
            else => return .resp_err_invalid_parameter,
        };
        if (resp.len < @sizeOf(CtrlHeader) + size) return .resp_err_unspec;

        // Zeroed caps blob for now: honest sizes, conservative contents.
        // Real GL 4.3 capability bits land with the Metal translator.
        @memset(resp[@sizeOf(CtrlHeader)..][0..size], 0);
        resp_len.* = @sizeOf(CtrlHeader) + size;
        return .resp_ok_capset;
    }

    fn cmdCtxCreate(self: *Gpu, header: CtrlHeader) CmdType {
        if (!self.virgl_enabled) return .resp_err_unspec;
        if (header.ctx_id == 0) return .resp_err_invalid_context_id;
        self.gpu_device.createContextId(header.ctx_id) catch return .resp_err_out_of_memory;
        return .resp_ok_nodata;
    }

    fn cmdResourceCreate3D(self: *Gpu, req: []const u8) CmdType {
        if (!self.virgl_enabled) return .resp_err_unspec;
        if (req.len < @sizeOf(ResourceCreate3D)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(ResourceCreate3D, req[0..@sizeOf(ResourceCreate3D)]);
        if (cmd.resource_id == 0) return .resp_err_invalid_resource_id;

        self.gpu_device.createResourceRecord(.{
            .handle = cmd.resource_id,
            .target = @enumFromInt(@as(u8, @truncate(cmd.target))),
            .format = @enumFromInt(cmd.format),
            .width = cmd.width,
            .height = cmd.height,
            .depth = cmd.depth,
            .array_size = cmd.array_size,
            .last_level = cmd.last_level,
            .nr_samples = cmd.nr_samples,
            .flags = cmd.flags,
            .bind = cmd.bind,
        }) catch return .resp_err_out_of_memory;
        return .resp_ok_nodata;
    }

    fn cmdSubmit3D(
        self: *Gpu,
        header: CtrlHeader,
        req: []const u8,
        chain: *const ring.Chain,
        get_mem: ring.GetMemFn,
    ) CmdType {
        if (!self.virgl_enabled) return .resp_err_unspec;
        if (req.len < @sizeOf(Submit3D)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(Submit3D, req[0..@sizeOf(Submit3D)]);

        // The command stream either follows the header in the same buffer
        // or arrives as a second device-readable descriptor (Linux).
        const inline_data = req[@sizeOf(Submit3D)..];
        const cmd_data: []const u8 = if (inline_data.len >= cmd.size)
            inline_data[0..cmd.size]
        else blk: {
            var readable_idx: u32 = 0;
            for (chain.slice()) |d| {
                if (d.isWrite()) continue;
                readable_idx += 1;
                if (readable_idx == 2) {
                    const mem = get_mem(d.addr, d.len) orelse
                        return .resp_err_invalid_parameter;
                    if (mem.len < cmd.size) return .resp_err_invalid_parameter;
                    break :blk mem[0..cmd.size];
                }
            }
            return .resp_err_invalid_parameter;
        };

        self.gpu_device.submit(header.ctx_id, cmd_data) catch {
            return .resp_err_unspec;
        };
        return .resp_ok_nodata;
    }

    fn cmdResourceDetachBacking(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(ResourceDetachBacking)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(
            ResourceDetachBacking,
            req[0..@sizeOf(ResourceDetachBacking)],
        );

        const res = self.resources.getPtr(cmd.resource_id) orelse
            return .resp_err_invalid_resource_id;
        res.entries.clearAndFree(self.alloc);
        return .resp_ok_nodata;
    }

    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Gpu init" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    const magic = gpu.read(@intFromEnum(mmio.Reg.magic));
    try testing.expectEqual(mmio.MAGIC, magic);

    const device_id = gpu.read(@intFromEnum(mmio.Reg.device_id));
    try testing.expectEqual(@as(u32, 16), device_id);
}

test "Gpu config read" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    const num_scanouts = gpu.read(@intFromEnum(mmio.Reg.config) + 8);
    try testing.expectEqual(@as(u32, 1), num_scanouts);
}

test "CtrlHeader size" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(CtrlHeader));
}

test "ResourceCreate2D size" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(ResourceCreate2D));
}

test "Gpu resource lifecycle via direct command calls" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    // Create a 4x2 resource
    const create = ResourceCreate2D{
        .header = .{ .type = @intFromEnum(CmdType.resource_create_2d) },
        .resource_id = 1,
        .format = 2, // XRGB8888
        .width = 4,
        .height = 2,
    };
    var resp = gpu.cmdResourceCreate2D(std.mem.asBytes(&create));
    try testing.expectEqual(CmdType.resp_ok_nodata, resp);
    try testing.expect(gpu.resources.contains(1));
    try testing.expectEqual(@as(usize, 32), gpu.resources.get(1).?.host_data.len);

    // Scanout it
    const scan = SetScanout{
        .header = .{ .type = @intFromEnum(CmdType.set_scanout) },
        .r = .{ .width = 4, .height = 2 },
        .scanout_id = 0,
        .resource_id = 1,
    };
    resp = gpu.cmdSetScanout(std.mem.asBytes(&scan));
    try testing.expectEqual(CmdType.resp_ok_nodata, resp);
    try testing.expect(gpu.scanout() != null);

    // Unref clears scanout
    const unref = ResourceUnref{
        .header = .{ .type = @intFromEnum(CmdType.resource_unref) },
        .resource_id = 1,
    };
    resp = gpu.cmdResourceUnref(std.mem.asBytes(&unref));
    try testing.expectEqual(CmdType.resp_ok_nodata, resp);
    try testing.expect(gpu.scanout() == null);
}

test "virgl capset info and submit decode" {
    const gpu = try Gpu.init(testing.allocator, true);
    defer gpu.deinit();

    // Capset info for index 1 (virgl2)
    const info_req = GetCapsetInfo{
        .header = .{ .type = @intFromEnum(CmdType.get_capset_info) },
        .capset_index = 1,
    };
    var resp_buf: [64]u8 = undefined;
    var resp_len: u32 = 0;
    const rt = gpu.cmdGetCapsetInfo(std.mem.asBytes(&info_req), &resp_buf, &resp_len);
    try testing.expectEqual(CmdType.resp_ok_capset_info, rt);
    const info = std.mem.bytesToValue(CapsetInfoResp, resp_buf[0..@sizeOf(CapsetInfoResp)]);
    try testing.expectEqual(CAPSET_VIRGL2, info.capset_id);
    try testing.expectEqual(CAPS_V2_SIZE, info.capset_max_size);

    // Context create via header ctx_id
    const hdr = CtrlHeader{ .type = @intFromEnum(CmdType.ctx_create), .ctx_id = 7 };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdCtxCreate(hdr));
    try testing.expect(gpu.gpu_device.contexts.contains(7));

    // Synthetic virgl stream: NOP + SET_SCISSOR (skipped) decoded without error
    var stream: [5]u32 = undefined;
    stream[0] = (virgl.CommandHeader{ .opcode = .nop, .object_type = .null, .length = 0 }).encode();
    stream[1] = (virgl.CommandHeader{ .opcode = .set_stencil_ref, .object_type = .null, .length = 1 }).encode();
    stream[2] = 0x00010001;
    stream[3] = (virgl.CommandHeader{ .opcode = .set_blend_color, .object_type = .null, .length = 4 }).encode();
    stream[4] = 0; // truncated on purpose? no — keep well-formed: pad below
    // Rebuild well-formed: nop + stencil_ref(1)
    const bytes = std.mem.sliceAsBytes(stream[0..3]);
    try gpu.gpu_device.submit(7, bytes);

    // Destroy
    gpu.gpu_device.destroyContextId(7);
    try testing.expect(!gpu.gpu_device.contexts.contains(7));
}
