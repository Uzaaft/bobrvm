//! Virtio GPU Device.
//!
//! Implements virtio-gpu per virtio 1.2 spec section 5.7.
//! Provides 2D framebuffer and 3D (virgl) acceleration.
//!
//! Queues:
//!   0: controlq (commands and responses)
//!   1: cursorq (cursor updates)
//!
//! Supports both 2D (simple framebuffer) and 3D (virgl/venus) modes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const mmio = @import("mmio.zig");
const Queue = @import("queue.zig");
const gpu_module = @import("../gpu/main.zig");

/// GPU feature bits.
pub const Features = struct {
    /// 3D (virgl) support.
    pub const VIRGL: u64 = 1 << 0;
    /// EDID support.
    pub const EDID: u64 = 1 << 1;
    /// Resource UUID support.
    pub const RESOURCE_UUID: u64 = 1 << 2;
    /// Resource blob support.
    pub const RESOURCE_BLOB: u64 = 1 << 3;
    /// Context init support.
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
    resource_map_blob = 0x0208,
    resource_unmap_blob = 0x0209,

    // Cursor commands
    update_cursor = 0x0300,
    move_cursor = 0x0301,

    // Response types (success)
    resp_ok_nodata = 0x1100,
    resp_ok_display_info = 0x1101,
    resp_ok_capset_info = 0x1102,
    resp_ok_capset = 0x1103,
    resp_ok_edid = 0x1104,
    resp_ok_resource_uuid = 0x1105,
    resp_ok_map_info = 0x1106,

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

/// Display info (per scanout).
pub const DisplayOne = extern struct {
    r: Rect = .{},
    enabled: u32 = 0,
    flags: u32 = 0,
};

/// Rectangle.
pub const Rect = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// Resource create 2D.
pub const ResourceCreate2D = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};

/// Resource unref.
pub const ResourceUnref = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    _padding: u32 = 0,
};

/// Set scanout.
pub const SetScanout = extern struct {
    header: CtrlHeader,
    r: Rect,
    scanout_id: u32,
    resource_id: u32,
};

/// Resource flush.
pub const ResourceFlush = extern struct {
    header: CtrlHeader,
    r: Rect,
    resource_id: u32,
    _padding: u32 = 0,
};

/// Transfer to host 2D.
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

/// Resource attach backing.
pub const ResourceAttachBacking = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    nr_entries: u32,
};

/// Context create.
pub const CtxCreate = extern struct {
    header: CtrlHeader,
    nlen: u32,
    context_init: u32,
    debug_name: [64]u8 = .{0} ** 64,
};

/// Submit 3D.
pub const Submit3D = extern struct {
    header: CtrlHeader,
    size: u32,
    _padding: u32 = 0,
};

/// Capset info response.
pub const CapsetInfoResp = extern struct {
    header: CtrlHeader,
    capset_id: u32,
    capset_max_version: u32,
    capset_max_size: u32,
    _padding: u32 = 0,
};

/// Display info response.
pub const DisplayInfoResp = extern struct {
    header: CtrlHeader,
    pmodes: [16]DisplayOne = .{.{}} ** 16,
};

/// GPU config space.
pub const Config = extern struct {
    events_read: u32 = 0,
    events_clear: u32 = 0,
    num_scanouts: u32 = 1,
    num_capsets: u32 = 1, // virgl
};

/// 2D resource.
pub const Resource2D = struct {
    id: u32,
    format: u32,
    width: u32,
    height: u32,
    backing: ?[]u8,
};

/// GPU device.
pub const Gpu = struct {
    alloc: Allocator,
    transport: *mmio.Transport,
    config: Config,

    /// Control queue.
    control_queue: Queue.VirtQueue,
    /// Cursor queue.
    cursor_queue: Queue.VirtQueue,

    /// 2D resources.
    resources: std.AutoHashMap(u32, Resource2D),

    /// 3D GPU device (virgl contexts).
    gpu_device: gpu_module.GpuDevice,

    /// Current scanout.
    scanout_resource_id: u32,
    scanout_rect: Rect,

    /// Display dimensions.
    display_width: u32,
    display_height: u32,

    /// Guest memory accessor.
    guest_memory: ?*const fn (addr: u64, len: usize) ?[]u8,

    /// Frame ready callback.
    frame_callback: ?*const fn (userdata: ?*anyopaque) void,
    frame_userdata: ?*anyopaque,

    /// Interrupt callback.
    interrupt_callback: ?*const fn (userdata: ?*anyopaque) void,
    interrupt_userdata: ?*anyopaque,

    pub const Error = Allocator.Error;
    pub const QUEUE_SIZE: u16 = 256;

    pub fn init(alloc: Allocator) Error!*Gpu {
        const features = Features.VIRGL;
        const transport = try mmio.Transport.init(alloc, 16, features, 2); // 16 = GPU device ID
        errdefer transport.deinit();

        var control_queue = try Queue.VirtQueue.init(alloc, QUEUE_SIZE);
        errdefer control_queue.deinit();

        var cursor_queue = try Queue.VirtQueue.init(alloc, QUEUE_SIZE);
        errdefer cursor_queue.deinit();

        const gpu = try alloc.create(Gpu);
        errdefer alloc.destroy(gpu);

        gpu.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = .{},
            .control_queue = control_queue,
            .cursor_queue = cursor_queue,
            .resources = std.AutoHashMap(u32, Resource2D).init(alloc),
            .gpu_device = gpu_module.GpuDevice.init(alloc),
            .scanout_resource_id = 0,
            .scanout_rect = .{},
            .display_width = 1920,
            .display_height = 1080,
            .guest_memory = null,
            .frame_callback = null,
            .frame_userdata = null,
            .interrupt_callback = null,
            .interrupt_userdata = null,
        };

        transport.setNotifyCallback(handleNotify, gpu);

        assert(gpu.transport.device_id == 16);

        return gpu;
    }

    pub fn deinit(self: *Gpu) void {
        var iter = self.resources.valueIterator();
        while (iter.next()) |res| {
            if (res.backing) |b| self.alloc.free(b);
        }
        self.resources.deinit();
        self.gpu_device.deinit();
        self.cursor_queue.deinit();
        self.control_queue.deinit();
        self.transport.deinit();
        self.alloc.destroy(self);
    }

    /// Set display dimensions.
    pub fn setDisplaySize(self: *Gpu, width: u32, height: u32) void {
        self.display_width = width;
        self.display_height = height;
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(
        self: *Gpu,
        accessor: *const fn (u64, usize) ?[]u8,
    ) void {
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

    /// Set interrupt callback.
    pub fn setInterruptCallback(
        self: *Gpu,
        callback: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.interrupt_callback = callback;
        self.interrupt_userdata = userdata;
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
        if (queue_idx == 0) {
            self.processControlQueue();
        }
    }

    // =========================================================================
    // Command Processing
    // =========================================================================

    fn processControlQueue(self: *Gpu) void {
        const queue = &self.control_queue;

        while (queue.pop()) |head| {
            self.processCommand(head);
        }

        if (self.interrupt_callback) |cb| {
            cb(self.interrupt_userdata);
        }
    }

    fn processCommand(self: *Gpu, head: u16) void {
        const queue = &self.control_queue;
        const desc = &queue.desc[head];
        const get_mem = self.guest_memory orelse return;

        if (desc.len < @sizeOf(CtrlHeader)) return;
        const header_mem = get_mem(desc.addr, @sizeOf(CtrlHeader)) orelse return;
        const header = std.mem.bytesToValue(CtrlHeader, header_mem[0..@sizeOf(CtrlHeader)]);

        const cmd_type: CmdType = @enumFromInt(header.type);
        var resp_type: CmdType = .resp_ok_nodata;

        switch (cmd_type) {
            .get_display_info => {
                resp_type = self.cmdGetDisplayInfo(head, desc);
            },
            .resource_create_2d => {
                self.cmdResourceCreate2D(desc, get_mem) catch {
                    resp_type = .resp_err_out_of_memory;
                };
            },
            .resource_unref => {
                self.cmdResourceUnref(desc, get_mem);
            },
            .set_scanout => {
                self.cmdSetScanout(desc, get_mem);
            },
            .resource_flush => {
                self.cmdResourceFlush(desc, get_mem);
            },
            .transfer_to_host_2d => {
                self.cmdTransferToHost2D(desc, get_mem);
            },
            .resource_attach_backing => {
                self.cmdResourceAttachBacking(desc, get_mem) catch {
                    resp_type = .resp_err_out_of_memory;
                };
            },
            .get_capset_info => {
                resp_type = self.cmdGetCapsetInfo(head, desc, header);
            },
            .ctx_create => {
                self.gpu_device.processCommand(.ctx_create, &.{}) catch {};
            },
            .ctx_destroy => {
                const data_mem = get_mem(desc.addr, desc.len) orelse return;
                self.gpu_device.processCommand(.ctx_destroy, data_mem[@sizeOf(CtrlHeader)..]) catch {};
            },
            .submit_3d => {
                self.cmdSubmit3D(desc, get_mem, header) catch {};
            },
            else => {
                resp_type = .resp_err_unspec;
            },
        }

        // Write response
        self.writeResponse(head, resp_type);
    }

    fn cmdGetDisplayInfo(self: *Gpu, head: u16, desc: *const Queue.Desc) CmdType {
        _ = head;
        _ = desc;

        // Response is written in next descriptor
        // For now, just return success
        _ = self;
        return .resp_ok_display_info;
    }

    fn cmdResourceCreate2D(self: *Gpu, desc: *const Queue.Desc, get_mem: anytype) !void {
        if (desc.len < @sizeOf(ResourceCreate2D)) return;
        const mem = get_mem(desc.addr, @sizeOf(ResourceCreate2D)) orelse return;
        const cmd = std.mem.bytesToValue(ResourceCreate2D, mem[0..@sizeOf(ResourceCreate2D)]);

        try self.resources.put(cmd.resource_id, .{
            .id = cmd.resource_id,
            .format = cmd.format,
            .width = cmd.width,
            .height = cmd.height,
            .backing = null,
        });
    }

    fn cmdResourceUnref(self: *Gpu, desc: *const Queue.Desc, get_mem: anytype) void {
        if (desc.len < @sizeOf(ResourceUnref)) return;
        const mem = get_mem(desc.addr, @sizeOf(ResourceUnref)) orelse return;
        const cmd = std.mem.bytesToValue(ResourceUnref, mem[0..@sizeOf(ResourceUnref)]);

        if (self.resources.fetchRemove(cmd.resource_id)) |entry| {
            if (entry.value.backing) |b| self.alloc.free(b);
        }
    }

    fn cmdSetScanout(self: *Gpu, desc: *const Queue.Desc, get_mem: anytype) void {
        if (desc.len < @sizeOf(SetScanout)) return;
        const mem = get_mem(desc.addr, @sizeOf(SetScanout)) orelse return;
        const cmd = std.mem.bytesToValue(SetScanout, mem[0..@sizeOf(SetScanout)]);

        self.scanout_resource_id = cmd.resource_id;
        self.scanout_rect = cmd.r;
    }

    fn cmdResourceFlush(self: *Gpu, desc: *const Queue.Desc, get_mem: anytype) void {
        if (desc.len < @sizeOf(ResourceFlush)) return;
        const mem = get_mem(desc.addr, @sizeOf(ResourceFlush)) orelse return;
        const cmd = std.mem.bytesToValue(ResourceFlush, mem[0..@sizeOf(ResourceFlush)]);

        // If flushing the scanout resource, signal frame ready
        if (cmd.resource_id == self.scanout_resource_id) {
            if (self.frame_callback) |cb| {
                cb(self.frame_userdata);
            }
        }
    }

    fn cmdTransferToHost2D(self: *Gpu, desc: *const Queue.Desc, get_mem: anytype) void {
        if (desc.len < @sizeOf(TransferToHost2D)) return;
        const mem = get_mem(desc.addr, @sizeOf(TransferToHost2D)) orelse return;
        const cmd = std.mem.bytesToValue(TransferToHost2D, mem[0..@sizeOf(TransferToHost2D)]);

        // Get the resource backing and copy pixel data
        const res = self.resources.getPtr(cmd.resource_id) orelse return;
        _ = res;
        // TODO: Implement actual transfer from guest memory to backing
    }

    fn cmdResourceAttachBacking(self: *Gpu, desc: *const Queue.Desc, get_mem: anytype) !void {
        if (desc.len < @sizeOf(ResourceAttachBacking)) return;
        const mem = get_mem(desc.addr, desc.len) orelse return;
        const cmd = std.mem.bytesToValue(ResourceAttachBacking, mem[0..@sizeOf(ResourceAttachBacking)]);

        const res = self.resources.getPtr(cmd.resource_id) orelse return;

        // Calculate total size from entries
        var total_size: usize = 0;
        const entries_start = @sizeOf(ResourceAttachBacking);
        var i: u32 = 0;
        while (i < cmd.nr_entries and entries_start + (i + 1) * @sizeOf(MemEntry) <= desc.len) : (i += 1) {
            const entry_offset = entries_start + i * @sizeOf(MemEntry);
            const entry = std.mem.bytesToValue(MemEntry, mem[entry_offset..][0..@sizeOf(MemEntry)]);
            total_size += entry.length;
        }

        // Allocate backing store
        if (total_size > 0) {
            if (res.backing) |old| self.alloc.free(old);
            res.backing = try self.alloc.alloc(u8, total_size);
        }
    }

    fn cmdGetCapsetInfo(self: *Gpu, head: u16, desc: *const Queue.Desc, header: CtrlHeader) CmdType {
        _ = head;
        _ = desc;
        _ = header;
        _ = self;
        // Return virgl capset info
        return .resp_ok_capset_info;
    }

    fn cmdSubmit3D(self: *Gpu, desc: *const Queue.Desc, get_mem: anytype, header: CtrlHeader) !void {
        if (desc.len < @sizeOf(Submit3D)) return;
        const mem = get_mem(desc.addr, desc.len) orelse return;

        const cmd_data = mem[@sizeOf(Submit3D)..];
        var data_with_ctx: [8 + 4096]u8 = undefined;

        // Prepend ctx_id
        std.mem.writeInt(u32, data_with_ctx[0..4], header.ctx_id, .little);
        const copy_len = @min(cmd_data.len, data_with_ctx.len - 8);
        @memcpy(data_with_ctx[8..][0..copy_len], cmd_data[0..copy_len]);

        try self.gpu_device.processCommand(.submit_3d, data_with_ctx[0 .. 8 + copy_len]);
    }

    fn writeResponse(self: *Gpu, head: u16, resp_type: CmdType) void {
        // Find response descriptor (next in chain)
        const queue = &self.control_queue;
        const desc = &queue.desc[head];

        if (!desc.flags.next) {
            queue.pushUsed(head, @sizeOf(CtrlHeader));
            return;
        }

        const resp_idx = desc.next;
        const resp_desc = &queue.desc[resp_idx];

        if (resp_desc.flags.write and resp_desc.len >= @sizeOf(CtrlHeader)) {
            const get_mem = self.guest_memory orelse {
                queue.pushUsed(head, 0);
                return;
            };
            const mem = get_mem(resp_desc.addr, @sizeOf(CtrlHeader)) orelse {
                queue.pushUsed(head, 0);
                return;
            };

            const resp = CtrlHeader{
                .type = @intFromEnum(resp_type),
            };
            @memcpy(mem[0..@sizeOf(CtrlHeader)], std.mem.asBytes(&resp));
        }

        queue.pushUsed(head, @sizeOf(CtrlHeader));
        self.transport.signalUsedBuffer();
    }

    /// Get current framebuffer data (for rendering).
    pub fn getFramebuffer(self: *Gpu) ?[]const u8 {
        if (self.scanout_resource_id == 0) return null;
        const res = self.resources.get(self.scanout_resource_id) orelse return null;
        return res.backing;
    }

    pub fn mmioSize() usize {
        return mmio.REGION_SIZE;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Gpu init" {
    const gpu = try Gpu.init(std.testing.allocator);
    defer gpu.deinit();

    const magic = gpu.read(@intFromEnum(mmio.Reg.magic));
    try std.testing.expectEqual(mmio.MAGIC, magic);

    const device_id = gpu.read(@intFromEnum(mmio.Reg.device_id));
    try std.testing.expectEqual(@as(u32, 16), device_id);
}

test "Gpu config read" {
    const gpu = try Gpu.init(std.testing.allocator);
    defer gpu.deinit();

    const num_scanouts = gpu.read(@intFromEnum(mmio.Reg.config) + 8);
    try std.testing.expectEqual(@as(u32, 1), num_scanouts);
}

test "CtrlHeader size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CtrlHeader));
}

test "ResourceCreate2D size" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ResourceCreate2D));
}
