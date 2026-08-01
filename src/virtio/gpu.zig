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
const global = @import("../global.zig");
const mmio = @import("mmio.zig");
const ring = @import("ring.zig");
const virgl = @import("../gpu/virgl/main.zig");
const gpu_module = @import("../gpu/main.zig");
const iosurface = @import("../gpu/iosurface.zig");

/// Venus (KosmicKrisp) GPU backend, opt-in via `-Dgpu-venus`. When disabled the
/// import resolves to a stub so nothing links virglrenderer and the default
/// build is unchanged; all venus code below sits behind `if (comptime gpu_venus)`.
const gpu_venus = @import("build_options").gpu_venus;
const venus = if (gpu_venus) @import("../gpu/venus.zig") else struct {
    pub const Host = struct { initialized: bool = false };
    pub const CAPSET_VENUS: u32 = 4;
    pub const iovec = extern struct { base: ?[*]u8, len: usize };
    pub const BLOB_MEM_GUEST: u32 = 1;
};

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
    resource_assign_uuid = 0x010b,
    // Blob resources (VIRTIO_GPU_F_RESOURCE_BLOB) — required by Venus. Note the
    // create/set-scanout blob commands live in the 2D opcode range.
    resource_create_blob = 0x010c,
    set_scanout_blob = 0x010d,

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
    // MUST be 0x1106: the spec inserts OK_RESOURCE_UUID at 0x1105 between EDID
    // and MAP_INFO. Getting this wrong makes the guest's RESOURCE_MAP_BLOB
    // callback set map_state=STATE_ERR → virtio_gpu_vram_mmap returns -EINVAL →
    // Venus "failed to allocate/map ring shmem". (The long-hunted mmap bug.)
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

pub const CursorPos = extern struct {
    scanout_id: u32,
    x: u32,
    y: u32,
    _padding: u32 = 0,
};

/// Shared layout for both UPDATE_CURSOR and MOVE_CURSOR (arrives on the
/// cursor virtqueue, not the control queue). MOVE_CURSOR sends resource_id=0
/// to mean "keep the current cursor image, just reposition it".
pub const UpdateCursor = extern struct {
    header: CtrlHeader,
    pos: CursorPos,
    resource_id: u32,
    hot_x: u32,
    hot_y: u32,
    _padding: u32 = 0,
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

/// virtio_gpu_resource_create_blob (followed by nr_entries × MemEntry).
pub const ResourceCreateBlob = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    blob_mem: u32,
    blob_flags: u32,
    nr_entries: u32,
    blob_id: u64,
    size: u64,
};

/// virtio_gpu_set_scanout_blob: a compositor page-flipping a blob resource
/// (what niri/wlroots do once GBM allocates scanout buffers as blobs).
pub const SetScanoutBlob = extern struct {
    header: CtrlHeader,
    r: Rect,
    scanout_id: u32,
    resource_id: u32,
    width: u32,
    height: u32,
    format: u32,
    _padding: u32 = 0,
    strides: [4]u32,
    offsets: [4]u32,
};

/// What we know about a live blob resource, recorded at create time so the
/// scanout path can tell where its pixels actually live.
pub const BlobMeta = struct {
    /// VIRTIO_GPU_BLOB_MEM_*: 1 = guest RAM (presentable by gathering the
    /// backing iovecs), 2 = host3d (pixels inside the host Vulkan driver),
    /// 3 = host3d with guest backing.
    blob_mem: u32,
    blob_flags: u32,
    size: u64,
};

/// virtio_gpu_resource_map_blob.
pub const ResourceMapBlob = extern struct {
    header: CtrlHeader,
    resource_id: u32,
    _padding: u32 = 0,
    offset: u64,
};

/// virtio_gpu_resp_map_info.
pub const MapInfoResp = extern struct {
    header: CtrlHeader,
    map_info: u32,
    _padding: u32 = 0,
};

/// A live blob→guest-PA mapping in the host-visible window.
pub const MapRecord = struct { pa: u64, size: usize };

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

/// virtio_gpu_box: a 3D region (for buffers, x/w are the byte offset/length).
pub const Box = extern struct {
    x: u32,
    y: u32,
    z: u32,
    w: u32,
    h: u32,
    d: u32,
};

/// virtio_gpu_transfer_host_3d.
pub const TransferHost3D = extern struct {
    header: CtrlHeader,
    box: Box,
    offset: u64,
    resource_id: u32,
    level: u32,
    stride: u32,
    layer_stride: u32,
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

pub const GetEdid = extern struct {
    header: CtrlHeader,
    scanout: u32,
    _padding: u32 = 0,
};

pub const RespEdid = extern struct {
    header: CtrlHeader,
    size: u32,
    _padding: u32 = 0,
    edid: [1024]u8 = [_]u8{0} ** 1024,
};

/// Synthesize a minimal EDID 1.4 base block whose preferred (detailed)
/// timing is `width`x`height` @ 60 Hz with CVT-reduced-blanking-style
/// intervals. The DTD's active-pixel fields are 12-bit and its pixel clock
/// is a u16 in 10 kHz units, so oversized modes are clamped there — the
/// guest still learns the true size from GET_DISPLAY_INFO, which the Linux
/// driver prefers for its added mode.
pub fn buildEdid(width: u32, height: u32, out: *[128]u8) void {
    @memset(out, 0);

    // Header + vendor/product. Manufacturer id "BBR" (5 bits/letter, A=1).
    out[0..8].* = .{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    const mfg: u16 = (2 << 10) | (2 << 5) | 18; // B, B, R
    out[8] = @truncate(mfg >> 8);
    out[9] = @truncate(mfg);
    out[10] = 0x01; // product code 1 (LE)
    out[17] = 34; // model year 2024 (deterministic; year = 1990 + n)
    out[18] = 1; // EDID version
    out[19] = 4; // EDID revision
    out[20] = 0xA5; // digital input, 8 bits per color
    // Physical size in cm assuming ~96 DPI (px * 25.4 / 96 / 10).
    const w_mm: u32 = width * 254 / 960;
    const h_mm: u32 = height * 254 / 960;
    out[21] = @truncate(@min(w_mm / 10, 255));
    out[22] = @truncate(@min(h_mm / 10, 255));
    out[23] = 120; // gamma 2.2 (x100 - 100)
    out[24] = 0x06; // features: preferred timing is native, sRGB default
    // sRGB chromaticity coordinates (same block QEMU emits).
    out[25..35].* = .{ 0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54 };
    // Standard timings: all unused.
    @memset(out[38..54], 0x01);

    // Detailed timing descriptor (bytes 54-71): the preferred mode.
    const ha: u32 = @min(width, 4095);
    const va: u32 = @min(height, 4095);
    const hblank: u32 = 160; // CVT-RB horizontal blanking
    const vblank: u32 = 30;
    const clock_10khz: u32 = @min(
        (ha + hblank) * (va + vblank) * 60 / 10_000,
        std.math.maxInt(u16),
    );
    const dtd = out[54..72];
    dtd[0] = @truncate(clock_10khz);
    dtd[1] = @truncate(clock_10khz >> 8);
    dtd[2] = @truncate(ha);
    dtd[3] = @truncate(hblank);
    dtd[4] = @truncate(((ha >> 8) << 4) | (hblank >> 8));
    dtd[5] = @truncate(va);
    dtd[6] = @truncate(vblank);
    dtd[7] = @truncate(((va >> 8) << 4) | (vblank >> 8));
    dtd[8] = 48; // hsync offset
    dtd[9] = 32; // hsync width
    dtd[10] = (3 << 4) | 5; // vsync offset 3, width 5
    dtd[11] = 0; // no high bits for the sync values above
    dtd[12] = @truncate(@min(w_mm, 4095));
    dtd[13] = @truncate(@min(h_mm, 4095));
    dtd[14] = @truncate(((@min(w_mm, 4095) >> 8) << 4) | (@min(h_mm, 4095) >> 8));
    dtd[17] = 0x1E; // digital separate sync, +hsync +vsync

    // Descriptor 2 (bytes 72-89): display name. 3 + 4: dummy descriptors.
    out[72..77].* = .{ 0x00, 0x00, 0x00, 0xFC, 0x00 };
    out[77..90].* = "bobrvm\n      ".*;
    out[90..94].* = .{ 0x00, 0x00, 0x00, 0x10 };
    out[108..112].* = .{ 0x00, 0x00, 0x00, 0x10 };

    // No extension blocks; checksum makes the block sum to 0 mod 256.
    var sum: u8 = 0;
    for (out[0..127]) |b| sum +%= b;
    out[127] = 0 -% sum;
}

/// Capset ids (VIRTIO_GPU_CAPSET_*).
pub const CAPSET_VIRGL: u32 = 1;
pub const CAPSET_VENUS: u32 = 4;
pub const CAPSET_VIRGL2: u32 = 2;

/// Capset blob sizes (virgl_caps_v1/v2 from virglrenderer). The kernel
/// transports these opaquely to mesa; sizes must be honest, contents
/// grow as the translator does.
pub const CAPS_V1_SIZE: u32 = 308;
pub const CAPS_V2_SIZE: u32 = 1408;

/// Display-changed event bit for config.events_read
/// (VIRTIO_GPU_EVENT_DISPLAY): tells the guest to re-query display info.
pub const EVENT_DISPLAY: u32 = 1 << 0;

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
    /// Host copy of the pixels (width * height * 4). When `surface` is set this
    /// slice aliases the IOSurface's memory rather than a heap allocation.
    host_data: []u8,
    /// IOSurface backing `host_data`, if the zero-copy scanout path is active.
    /// Present means the render thread can wrap an MTLTexture over these pixels
    /// directly, skipping the per-frame CPU->GPU upload.
    surface: ?iosurface.IOSurface = null,
    /// Guest backing pages (scatter-gather).
    entries: std.ArrayListUnmanaged(MemEntry),

    pub const BYTES_PER_PIXEL: u32 = 4;

    pub fn stride(self: *const Resource2D) u32 {
        return self.width * BYTES_PER_PIXEL;
    }

    /// Release the pixel storage — either the IOSurface or the heap buffer.
    pub fn freePixels(self: *const Resource2D, alloc: Allocator) void {
        if (self.surface) |surf| surf.release() else alloc.free(self.host_data);
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
    scanout_mutex: std.Io.Mutex,

    /// Current scanout.
    scanout_resource_id: u32,

    /// Scanout sub-rectangle within the scanout resource. Linux fbdev
    /// re-modesets to a smaller mode by scanning a sub-rect of the SAME
    /// framebuffer resource (the fb buffer can never grow), so honoring
    /// r is what makes resize-to-fit real for console guests. Zero
    /// width/height = present the whole resource.
    scanout_rect: Rect = .{},

    /// Bumped each time the scanout content changes (flush of the scanout
    /// resource). The renderer compares this to skip re-presenting an
    /// unchanged frame — no upload, no blit, no drawable for idle vsyncs.
    frame_generation: u64,

    /// Display dimensions.
    display_width: u32,
    display_height: u32,

    /// Boot-time display dimensions = the guest fbdev framebuffer's size,
    /// which can never grow. Hotplug resizes are clamped to this so the
    /// advertised mode always fits (see setDisplaySize/resizeDisplay).
    boot_display_width: u32 = 1280,
    boot_display_height: u32 = 800,

    /// Guest memory accessor.
    guest_memory: ?ring.GetMemFn,

    /// Frame ready callback (scanout resource was flushed).
    frame_callback: ?*const fn (userdata: ?*anyopaque) void,
    frame_userdata: ?*anyopaque,

    /// 3D (virgl) support: guest contexts + resources + command decode.
    virgl_enabled: bool,
    gpu_device: gpu_module.GpuDevice,
    /// Guest backing pages for 3D resources (buffers/textures), keyed by
    /// resource id. 3D resources live in gpu_device, not self.resources, so
    /// their backing is tracked here rather than on a Resource2D.
    backing3d: std.AutoHashMap(u32, std.ArrayListUnmanaged(MemEntry)),
    /// Readback of a 3D-rendered scanout resource's MTLTexture, so the
    /// present path (which serves BGRA host pixels) can display GPU output.
    scanout3d_data: []u8 = &.{},
    scanout3d_w: u32 = 0,
    scanout3d_h: u32 = 0,
    /// True once a flush found the 3D scanout target IOSurface-backed, so the
    /// readback into scanout3d_data is skipped. The surface ref itself is NOT
    /// cached — scanout() re-derives it live from the (mutex-guarded) target so
    /// a destroyed/recreated target can never leave a dangling ref behind.
    scanout3d_direct: bool = false,
    /// Count of submit_3d commands seen (used to log the first few for
    /// bring-up diagnostics without flooding the log).
    submit3d_seen: u32 = 0,

    /// Venus backend (opt-in, `-Dgpu-venus`). `venus_host` is the process
    /// virglrenderer(venus) instance (null if unavailable); `venus_contexts`
    /// tracks which guest ctx_ids were created as Venus contexts so their
    /// submit_3d streams route to venus rather than the legacy translator.
    venus_host: ?venus.Host = null,
    venus_contexts: std.AutoHashMap(u32, void),
    /// Guest-backing iovec arrays for Venus blob resources, keyed by resource
    /// id. virglrenderer holds the pointer for the resource's lifetime, so the
    /// array must outlive create_blob and is freed on unref.
    venus_blobs: std.AutoHashMap(u32, []venus.iovec),
    /// Per-blob metadata (blob_mem etc.), recorded at create time so the
    /// scanout-blob path knows where a flipped buffer's pixels live.
    blob_meta: std.AutoHashMap(u32, BlobMeta),
    /// Most recent SET_SCANOUT_BLOB, for the venus present path.
    scanout_blob: ?SetScanoutBlob = null,

    /// Host-visible memory window (VIRTIO_GPU_SHM_ID_HOST_VISIBLE). Guest maps
    /// host blob memory into [base, base+size) at driver-chosen offsets via
    /// RESOURCE_MAP_BLOB; the machine wires map_fn/unmap_fn to HVF hv_vm_map.
    host_visible_base: u64 = 0,
    host_visible_size: u64 = 0,
    host_visible_map: ?*const fn (userdata: ?*anyopaque, host_ptr: [*]u8, guest_pa: u64, size: usize) bool = null,
    host_visible_unmap: ?*const fn (userdata: ?*anyopaque, guest_pa: u64, size: usize) void = null,
    host_visible_userdata: ?*anyopaque = null,
    /// Active blob→guest-PA mappings (for unmap), keyed by resource id.
    venus_mappings: std.AutoHashMap(u32, MapRecord),

    /// Hardware cursor state, set via the cursor virtqueue (UPDATE_CURSOR/
    /// MOVE_CURSOR) — separate from the main scanout entirely. The guest
    /// compositor draws the mouse pointer as a cursor plane, not into the
    /// framebuffer, so without this the pointer never appears even though
    /// input events (motion/clicks) are delivered and processed correctly.
    cursor_resource_id: u32 = 0,
    cursor_hot_x: u32 = 0,
    cursor_hot_y: u32 = 0,
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_visible: bool = false,
    /// Bumped on every cursor command so the renderer can redraw on
    /// cursor-only movement even when frame_generation is unchanged.
    cursor_generation: u64 = 0,

    pub const Error = Allocator.Error;
    pub const QUEUE_SIZE: u16 = 256;
    pub const MAX_RESOURCE_DIM: u32 = 8192;
    pub const MAX_BACKING_ENTRIES: u32 = 16384;

    pub fn init(alloc: Allocator, enable_virgl: bool) Error!*Gpu {
        // VIRTIO_F_VERSION_1 (bit 32) is required for modern virtio-mmio
        const virtio_version_1: u64 = 1 << 32;
        var features = virtio_version_1 | Features.EDID;
        if (enable_virgl) features |= Features.VIRGL;
        // Venus contexts are selected via the context_init capset id, which
        // needs VIRTIO_GPU_F_CONTEXT_INIT; venus also *requires* blob resources
        // (guest kernel VIRTGPU_PARAM_RESOURCE_BLOB — "kernel param 3").
        if (gpu_venus and enable_virgl) features |= Features.CONTEXT_INIT | Features.RESOURCE_BLOB;
        const transport = try mmio.Transport.init(alloc, 16, features, 2); // 16 = GPU device ID
        errdefer transport.deinit();

        const gpu = try alloc.create(Gpu);
        errdefer alloc.destroy(gpu);

        // Advertise the Venus capset (index 2, id 4) in addition to VIRGL/VIRGL2
        // when the venus host is available.
        const num_capsets: u32 = if (!enable_virgl) 0 else if (gpu_venus) 3 else 2;

        gpu.* = .{
            .alloc = alloc,
            .transport = transport,
            .config = .{ .num_capsets = num_capsets },
            .ctrl_last_avail = 0,
            .cursor_last_avail = 0,
            .resources = std.AutoHashMap(u32, Resource2D).init(alloc),
            .scanout_mutex = .init,
            .scanout_resource_id = 0,
            .frame_generation = 0,
            .display_width = 1280,
            .display_height = 800,
            .guest_memory = null,
            .frame_callback = null,
            .frame_userdata = null,
            .virgl_enabled = enable_virgl,
            .gpu_device = gpu_module.GpuDevice.init(alloc),
            .backing3d = std.AutoHashMap(u32, std.ArrayListUnmanaged(MemEntry)).init(alloc),
            .scanout3d_data = &.{},
            .scanout3d_w = 0,
            .scanout3d_h = 0,
            .submit3d_seen = 0,
            .venus_host = null,
            .venus_contexts = std.AutoHashMap(u32, void).init(alloc),
            .venus_blobs = std.AutoHashMap(u32, []venus.iovec).init(alloc),
            .blob_meta = std.AutoHashMap(u32, BlobMeta).init(alloc),
            .venus_mappings = std.AutoHashMap(u32, MapRecord).init(alloc),
        };

        transport.setNotifyCallback(handleNotify, gpu);

        assert(gpu.transport.device_id == 16);

        // Bring up the Venus host (once) if the backend is compiled in. On
        // failure we simply don't advertise a usable venus capset — the guest
        // falls back to the legacy virgl path.
        if (comptime gpu_venus) {
            if (enable_virgl) {
                if (venus.ensureHost()) |h| {
                    gpu.venus_host = h.*;
                    log.info("venus GPU backend active (capset {d})", .{CAPSET_VENUS});
                } else {
                    gpu.config.num_capsets = 2; // venus unavailable; VIRGL/VIRGL2 only
                    log.warn("venus backend compiled in but host unavailable; using legacy virgl", .{});
                }
            }
        }

        return gpu;
    }

    pub fn deinit(self: *Gpu) void {
        var iter = self.resources.valueIterator();
        while (iter.next()) |res| {
            res.freePixels(self.alloc);
            res.entries.deinit(self.alloc);
        }
        self.resources.deinit();
        var b3d = self.backing3d.valueIterator();
        while (b3d.next()) |list| list.deinit(self.alloc);
        self.backing3d.deinit();
        if (self.scanout3d_data.len > 0) self.alloc.free(self.scanout3d_data);
        self.venus_contexts.deinit();
        {
            var it = self.venus_blobs.valueIterator();
            while (it.next()) |iov| self.alloc.free(iov.*);
            self.venus_blobs.deinit();
            self.blob_meta.deinit();
        }
        self.venus_mappings.deinit();
        if (comptime gpu_venus) venus.deinitHost();
        self.gpu_device.deinit();
        self.transport.deinit();
        self.alloc.destroy(self);
    }

    /// Set display dimensions (before guest probes). Also records the boot
    /// ceiling: the guest's fbdev framebuffer is allocated at this size and
    /// can never grow, so later hotplug resizes are clamped to it — a mode
    /// that can't fit the fb leaves the fbdev client with NO usable mode
    /// and it turns the display off (black screen) until a fitting hotplug
    /// arrives.
    pub fn setDisplaySize(self: *Gpu, width: u32, height: u32) void {
        assert(width > 0 and height > 0);
        assert(width <= MAX_RESOURCE_DIM and height <= MAX_RESOURCE_DIM);
        self.display_width = width;
        self.display_height = height;
        self.boot_display_width = width;
        self.boot_display_height = height;
    }

    /// Recreate a 2D resource from snapshot state: a heap-backed pixel copy
    /// (no IOSurface — the renderer re-wraps on the next present) with no
    /// guest backing entries (the guest re-attaches after restore). Replaces
    /// any existing resource with the same id. Used by snapshot restore.
    pub fn restore2dResource(
        self: *Gpu,
        id: u32,
        format: u32,
        width: u32,
        height: u32,
        pixels: []const u8,
    ) Error!void {
        const host = try self.alloc.alloc(u8, pixels.len);
        errdefer self.alloc.free(host);
        @memcpy(host, pixels);
        if (self.resources.fetchRemove(id)) |old| {
            old.value.freePixels(self.alloc);
            var entries = old.value.entries;
            entries.deinit(self.alloc);
        }
        self.resources.put(id, .{
            .id = id,
            .format = format,
            .width = width,
            .height = height,
            .host_data = host,
            .surface = null,
            .entries = .empty,
        }) catch |err| {
            self.alloc.free(host);
            return err;
        };
    }

    /// Minimum live-resize dimension: below this guests produce unusable
    /// modes and some fbcon setups wedge.
    pub const MIN_DISPLAY_DIM: u32 = 320;

    /// Live guest resolution change (host window resized). Updates the
    /// advertised display info, flags VIRTIO_GPU_EVENT_DISPLAY, and raises
    /// the config-change interrupt; the guest re-queries display info and
    /// modesets via DRM hotplug. Caller must hold the machine lock — that
    /// serializes this against the vCPU thread's MMIO/queue processing.
    pub fn resizeDisplay(self: *Gpu, width: u32, height: u32) void {
        // Host-UI input: clamp rather than assert. The upper bound is the
        // BOOT display size — the guest fbdev fb is allocated once at that
        // size and a mode that can't fit it makes the fbdev client disable
        // the display entirely (black screen), so never advertise one.
        const w = std.math.clamp(width, MIN_DISPLAY_DIM, self.boot_display_width);
        const h = std.math.clamp(height, MIN_DISPLAY_DIM, self.boot_display_height);
        if (w != width or h != height) {
            log.info("display resize {}x{} clamped to {}x{} (boot fb ceiling)", .{ width, height, w, h });
        }
        if (w == self.display_width and h == self.display_height) return;

        // Serialize against the renderer thread reading display state.
        self.scanout_mutex.lockUncancelable(global.io());
        self.display_width = w;
        self.display_height = h;
        self.scanout_mutex.unlock(global.io());

        self.config.events_read |= EVENT_DISPLAY;
        self.transport.signalConfigChange();
    }

    /// Set guest memory accessor.
    pub fn setGuestMemory(self: *Gpu, accessor: ring.GetMemFn) void {
        self.guest_memory = accessor;
    }

    /// Wire the host-visible memory window (Venus). `map`/`unmap` bridge host
    /// blob memory into the guest window via HVF; this also advertises the
    /// virtio shm region so the guest kernel sets VIRTGPU_PARAM_HOST_VISIBLE.
    pub fn setHostVisible(
        self: *Gpu,
        base: u64,
        size: u64,
        map_fn: *const fn (userdata: ?*anyopaque, host_ptr: [*]u8, guest_pa: u64, size: usize) bool,
        unmap_fn: *const fn (userdata: ?*anyopaque, guest_pa: u64, size: usize) void,
        userdata: ?*anyopaque,
    ) void {
        self.host_visible_base = base;
        self.host_visible_size = size;
        self.host_visible_map = map_fn;
        self.host_visible_unmap = unmap_fn;
        self.host_visible_userdata = userdata;
        // VIRTIO_GPU_SHM_ID_HOST_VISIBLE = 1 (shmid 0 is "undefined").
        self.transport.setShmRegion(1, base, size);
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

    pub const CursorView = struct {
        /// Cursor sprite pixels (BGRA, same layout as the framebuffer).
        data: []const u8,
        width: u32,
        height: u32,
        hot_x: u32,
        hot_y: u32,
        /// Top-left position in screen coordinates (already includes the
        /// guest's own placement — the renderer just subtracts the hotspot).
        x: i32,
        y: i32,
        /// Bumped on every cursor command; lets the renderer redraw on
        /// cursor-only movement even when the framebuffer hasn't changed.
        generation: u64,
    };

    pub const ScanoutView = struct {
        data: []const u8,
        /// Visible (scanned-out) dimensions — the scanout rect, not
        /// necessarily the full resource.
        width: u32,
        height: u32,
        /// Origin of the scanout rect within the resource.
        src_x: u32 = 0,
        src_y: u32 = 0,
        /// Full resource dimensions (`data`/`surface` layout). Rows are
        /// full_width*4 bytes; the visible rect starts at (src_x, src_y).
        full_width: u32,
        full_height: u32,
        /// Content generation; unchanged means the renderer can skip.
        generation: u64,
        /// IOSurfaceRef backing `data` when the zero-copy path is active; the
        /// renderer wraps a texture over it instead of uploading `data`.
        surface: ?*anyopaque = null,
        cursor: ?CursorView = null,
    };

    fn cursorView(self: *Gpu) ?CursorView {
        if (!self.cursor_visible or self.cursor_resource_id == 0) return null;
        const res = self.resources.get(self.cursor_resource_id) orelse return null;
        return .{
            .data = res.host_data,
            .width = res.width,
            .height = res.height,
            .hot_x = self.cursor_hot_x,
            .hot_y = self.cursor_hot_y,
            .x = self.cursor_x,
            .y = self.cursor_y,
            .generation = self.cursor_generation,
        };
    }

    /// Current scanout pixels (BGRA/XRGB 4 bytes per pixel), or null.
    /// Caller must be on the vCPU thread (unsynchronized).
    pub fn scanout(self: *Gpu) ?ScanoutView {
        if (self.scanout_resource_id == 0) return null;
        // 2D scanout: served directly from the resource's host pixels,
        // honoring the scanout rect (fbdev re-modesets to a smaller mode by
        // scanning a sub-rect of the same resource). A zero-sized or
        // out-of-bounds rect falls back to the full resource.
        if (self.resources.get(self.scanout_resource_id)) |res| {
            var r = self.scanout_rect;
            if (r.width == 0 or r.height == 0 or
                r.x +| r.width > res.width or r.y +| r.height > res.height)
            {
                r = .{ .x = 0, .y = 0, .width = res.width, .height = res.height };
            }
            return .{
                .data = res.host_data,
                .width = r.width,
                .height = r.height,
                .src_x = r.x,
                .src_y = r.y,
                .full_width = res.width,
                .full_height = res.height,
                .generation = self.frame_generation,
                .surface = if (res.surface) |surf| surf.ref else null,
                .cursor = self.cursorView(),
            };
        }
        // 3D scanout: present the render target's IOSurface directly when the
        // target is still live and IOSurface-backed, otherwise the readback
        // buffer. Re-derive the ref live (guarded by scanout_mutex) so a
        // destroyed/recreated target yields null here instead of a dangling ref.
        const surf = if (self.scanout3d_direct)
            self.gpu_device.scanoutSurfaceRef(self.scanout_resource_id)
        else
            null;
        if (self.scanout3d_w > 0 and (surf != null or self.scanout3d_data.len > 0)) {
            // 3D scanouts present the full render target (desktop stacks
            // allocate a correctly-sized fb per mode, so rect == full).
            return .{
                .data = self.scanout3d_data,
                .width = self.scanout3d_w,
                .height = self.scanout3d_h,
                .full_width = self.scanout3d_w,
                .full_height = self.scanout3d_h,
                .generation = self.frame_generation,
                .surface = surf,
                .cursor = self.cursorView(),
            };
        }
        return null;
    }

    /// Acquire the scanout for reading from another thread (renderer).
    /// Must be paired with unlockScanout; the view is only valid while
    /// the lock is held.
    pub fn lockScanout(self: *Gpu) ?ScanoutView {
        self.scanout_mutex.lockUncancelable(global.io());
        const view = self.scanout() orelse {
            self.scanout_mutex.unlock(global.io());
            return null;
        };
        return view;
    }

    pub fn unlockScanout(self: *Gpu) void {
        self.scanout_mutex.unlock(global.io());
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
            self.processCursorCommand(qc, head, get_mem);
            ring.pushUsed(qc, head, 0, get_mem);
            self.cursor_last_avail +%= 1;
        }

        if (processed > 0) {
            self.transport.signalUsedBuffer();
        }
    }

    fn processCursorCommand(self: *Gpu, qc: mmio.QueueConfig, head: u16, get_mem: ring.GetMemFn) void {
        const chain = ring.Chain.collect(qc, head, get_mem);
        const req = chain.request(get_mem) orelse return;
        self.handleCursorCommand(req);
    }

    /// Decode + apply one UPDATE_CURSOR/MOVE_CURSOR command. Split out from
    /// processCursorCommand so it's directly unit-testable with a synthetic
    /// buffer, matching the cmdXxx(req) pattern used for the control queue.
    fn handleCursorCommand(self: *Gpu, req: []const u8) void {
        if (req.len < @sizeOf(UpdateCursor)) return;
        const cmd = std.mem.bytesToValue(UpdateCursor, req[0..@sizeOf(UpdateCursor)]);
        const cmd_type: CmdType = @enumFromInt(cmd.header.type);

        self.scanout_mutex.lockUncancelable(global.io());
        defer self.scanout_mutex.unlock(global.io());

        switch (cmd_type) {
            .update_cursor => {
                self.cursor_resource_id = cmd.resource_id;
                self.cursor_hot_x = cmd.hot_x;
                self.cursor_hot_y = cmd.hot_y;
                // Untrusted guest input: a plain @intCast would panic (and
                // take the whole VM down) if the driver ever sends a
                // position that doesn't fit i32 — clamp instead.
                self.cursor_x = std.math.cast(i32, cmd.pos.x) orelse std.math.maxInt(i32);
                self.cursor_y = std.math.cast(i32, cmd.pos.y) orelse std.math.maxInt(i32);
                self.cursor_visible = cmd.resource_id != 0;
                self.cursor_generation +%= 1;
            },
            .move_cursor => {
                self.cursor_x = std.math.cast(i32, cmd.pos.x) orelse std.math.maxInt(i32);
                self.cursor_y = std.math.cast(i32, cmd.pos.y) orelse std.math.maxInt(i32);
                self.cursor_generation +%= 1;
            },
            else => {},
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
        self.scanout_mutex.lockUncancelable(global.io());
        defer self.scanout_mutex.unlock(global.io());

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
            .set_scanout_blob => {
                resp_type = self.cmdSetScanoutBlob(req);
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
            .get_edid => {
                resp_type = self.cmdGetEdid(req, resp, &resp_len);
            },
            .ctx_create => {
                resp_type = self.cmdCtxCreate(header, req);
            },
            .ctx_destroy => {
                if (self.virgl_enabled) {
                    var handled = false;
                    if (comptime gpu_venus) {
                        if (self.venus_contexts.remove(header.ctx_id)) {
                            if (self.venus_host) |*h| h.destroyContext(header.ctx_id);
                            handled = true;
                        }
                    }
                    if (!handled) self.gpu_device.destroyContextId(header.ctx_id);
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
            .transfer_to_host_3d => {
                resp_type = self.cmdTransferToHost3D(req, get_mem);
            },
            .transfer_from_host_3d => {
                // Host→guest readback lands with the present/readback path.
                resp_type = if (self.virgl_enabled) .resp_ok_nodata else .resp_err_unspec;
            },
            .submit_3d => {
                resp_type = self.cmdSubmit3D(header, req, &chain, get_mem);
            },
            .resource_create_blob => {
                resp_type = self.cmdResourceCreateBlob(header, req, &chain, get_mem);
            },
            .resource_map_blob => {
                resp_type = self.cmdResourceMapBlob(req, resp, &resp_len);
            },
            .resource_unmap_blob => {
                resp_type = self.cmdResourceUnmapBlob(req);
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

    fn cmdGetEdid(self: *Gpu, req: []const u8, resp: []u8, resp_len: *u32) CmdType {
        if (req.len < @sizeOf(GetEdid)) return .resp_err_invalid_parameter;
        if (resp.len < @sizeOf(RespEdid)) return .resp_err_unspec;
        const cmd = std.mem.bytesToValue(GetEdid, req[0..@sizeOf(GetEdid)]);
        if (cmd.scanout != 0) return .resp_err_invalid_scanout_id;

        var edid_resp = RespEdid{
            .header = .{ .type = @intFromEnum(CmdType.resp_ok_edid) },
            .size = 128,
        };
        buildEdid(self.display_width, self.display_height, edid_resp.edid[0..128]);
        @memcpy(resp[0..@sizeOf(RespEdid)], std.mem.asBytes(&edid_resp));
        resp_len.* = @sizeOf(RespEdid);
        return .resp_ok_edid;
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

        // Prefer an IOSurface so the render thread can present these pixels with
        // no upload (zero-copy). Fall back to a heap buffer when IOSurface is
        // unavailable or would pad the row stride (e.g. headless CI, odd width).
        const surface = iosurface.IOSurface.createBGRA(cmd.width, cmd.height);
        const host_data = if (surface) |surf|
            surf.pixels(size)
        else
            self.alloc.alloc(u8, size) catch return .resp_err_out_of_memory;
        @memset(host_data, 0);

        // Replace any existing resource with this id.
        if (self.resources.fetchRemove(cmd.resource_id)) |old| {
            old.value.freePixels(self.alloc);
            var entries = old.value.entries;
            entries.deinit(self.alloc);
        }

        log.info("resource_create_2d id={} {}x{}", .{ cmd.resource_id, cmd.width, cmd.height });
        self.resources.put(cmd.resource_id, .{
            .id = cmd.resource_id,
            .format = cmd.format,
            .width = cmd.width,
            .height = cmd.height,
            .host_data = host_data,
            .surface = surface,
            .entries = .empty,
        }) catch {
            if (surface) |surf| surf.release() else self.alloc.free(host_data);
            return .resp_err_out_of_memory;
        };

        return .resp_ok_nodata;
    }

    fn cmdResourceUnref(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(ResourceUnref)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(ResourceUnref, req[0..@sizeOf(ResourceUnref)]);

        if (self.resources.fetchRemove(cmd.resource_id)) |entry| {
            entry.value.freePixels(self.alloc);
            var entries = entry.value.entries;
            entries.deinit(self.alloc);
            if (self.scanout_resource_id == cmd.resource_id) {
                self.scanout_resource_id = 0;
            }
            log.info("resource_unref id={}", .{cmd.resource_id});
            return .resp_ok_nodata;
        }

        // Venus blob resources live inside virglrenderer, not the 2D table; the
        // guest unrefs them (e.g. tearing down a ring/shmem). Route to the venus
        // host so we don't wrongly answer RESP_ERR_INVALID_RESOURCE_ID.
        if (comptime gpu_venus) {
            if (self.venus_host) |*h| {
                if (self.venus_blobs.fetchRemove(cmd.resource_id)) |kv| {
                    if (self.venus_mappings.fetchRemove(cmd.resource_id)) |m| {
                        if (self.host_visible_unmap) |unmap_fn|
                            unmap_fn(self.host_visible_userdata, m.value.pa, m.value.size);
                        h.unmapResource(cmd.resource_id);
                    }
                    if (kv.value.len > 0) self.alloc.free(kv.value);
                    h.unrefResource(cmd.resource_id);
                    return .resp_ok_nodata;
                }
            }
        }

        return .resp_err_invalid_resource_id;
    }

    fn cmdSetScanout(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(SetScanout)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(SetScanout, req[0..@sizeOf(SetScanout)]);

        if (cmd.scanout_id != 0) {
            log.warn("set_scanout REJECTED: bad scanout_id={}", .{cmd.scanout_id});
            return .resp_err_invalid_scanout_id;
        }
        // resource_id 0 disables the scanout. Accept both a 2D resource and a
        // 3D (virgl-rendered) resource.
        if (cmd.resource_id != 0 and
            !self.resources.contains(cmd.resource_id) and
            self.gpu_device.getResource(cmd.resource_id) == null)
        {
            log.warn("set_scanout REJECTED: unknown resource id={} rect={}x{}", .{
                cmd.resource_id, cmd.r.width, cmd.r.height,
            });
            return .resp_err_invalid_resource_id;
        }
        self.scanout_resource_id = cmd.resource_id;
        self.scanout_rect = cmd.r;
        self.frame_generation +%= 1; // new scanout target: force a present
        // A page flip IS a new frame. Compositors that drive KMS (niri and
        // every other Wayland compositor) flip between buffers with
        // SET_SCANOUT and never call RESOURCE_FLUSH, so without this the
        // frame callback only ever fired for the boot console.
        if (cmd.resource_id != 0) {
            if (self.frame_callback) |cb| cb(self.frame_userdata);
        }
        log.info("set_scanout res={} rect={}x{}+{}+{}", .{
            cmd.resource_id, cmd.r.width, cmd.r.height, cmd.r.x, cmd.r.y,
        });
        return .resp_ok_nodata;
    }

    /// SET_SCANOUT_BLOB: a compositor page-flipping a blob-backed buffer.
    /// Decoded and recorded; presenting the pixels is the venus present path
    /// (guest-backed blobs can be gathered from their iovecs, host3d blobs
    /// live inside the host Vulkan driver and need an export). Accepting the
    /// command rather than erroring keeps the compositor's flip loop alive so
    /// the modeset path can be observed.
    fn cmdSetScanoutBlob(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(SetScanoutBlob)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(SetScanoutBlob, req[0..@sizeOf(SetScanoutBlob)]);

        if (cmd.scanout_id != 0) {
            log.warn("set_scanout_blob REJECTED: bad scanout_id={}", .{cmd.scanout_id});
            return .resp_err_invalid_scanout_id;
        }
        // resource_id 0 disables the scanout.
        if (cmd.resource_id == 0) {
            self.scanout_blob = null;
            self.scanout_resource_id = 0;
            self.frame_generation +%= 1;
            log.info("set_scanout_blob: disable", .{});
            return .resp_ok_nodata;
        }

        const meta = self.blob_meta.get(cmd.resource_id);
        const backing_iovs: usize = if (self.venus_blobs.get(cmd.resource_id)) |v| v.len else 0;
        log.info(
            "set_scanout_blob res={} {}x{} rect={}x{}+{}+{} fmt=0x{x} stride0={} offset0={} blob_mem={?} flags=0x{x} size={?} iovs={}",
            .{
                cmd.resource_id,       cmd.width,
                cmd.height,            cmd.r.width,
                cmd.r.height,          cmd.r.x,
                cmd.r.y,               cmd.format,
                cmd.strides[0],        cmd.offsets[0],
                if (meta) |m| m.blob_mem else null,
                if (meta) |m| m.blob_flags else 0,
                if (meta) |m| m.size else null,
                backing_iovs,
            },
        );

        self.scanout_blob = cmd;
        self.scanout_resource_id = cmd.resource_id;
        self.scanout_rect = .{ .x = cmd.r.x, .y = cmd.r.y, .width = cmd.r.width, .height = cmd.r.height };
        self.frame_generation +%= 1;
        return .resp_ok_nodata;
    }

    fn cmdResourceFlush(self: *Gpu, req: []const u8) CmdType {
        if (req.len < @sizeOf(ResourceFlush)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(ResourceFlush, req[0..@sizeOf(ResourceFlush)]);

        if (cmd.resource_id == self.scanout_resource_id and self.scanout_resource_id != 0) {
            // If the scanout is a 3D-rendered resource, pull its pixels out of
            // the GPU texture into the host present buffer.
            self.refresh3dScanout();
            self.frame_generation +%= 1; // content changed: renderer should present
            if (self.frame_callback) |cb| {
                cb(self.frame_userdata);
            }
        }
        return .resp_ok_nodata;
    }

    /// Read the current 3D scanout resource's MTLTexture into the host
    /// present buffer. No-op for 2D scanouts (served from Resource2D) or when
    /// there is no GPU-backed texture.
    fn refresh3dScanout(self: *Gpu) void {
        const id = self.scanout_resource_id;
        if (id == 0) return;
        if (self.resources.contains(id)) return; // 2D path
        const res = self.gpu_device.getResource(id) orelse return;
        if (res.width == 0 or res.height == 0) return;

        // Zero-copy path: the target renders straight into an IOSurface, so
        // just mark direct-present — scanout() re-derives the live ref itself.
        if (self.gpu_device.scanoutSurfaceRef(id) != null) {
            self.scanout3d_direct = true;
            self.scanout3d_w = res.width;
            self.scanout3d_h = res.height;
            return;
        }

        // Fallback: read the rendered pixels back into a host buffer.
        self.scanout3d_direct = false;
        const needed = @as(usize, res.width) * res.height * 4;
        if (self.scanout3d_data.len != needed) {
            const nb = if (self.scanout3d_data.len == 0)
                self.alloc.alloc(u8, needed) catch return
            else
                self.alloc.realloc(self.scanout3d_data, needed) catch return;
            self.scanout3d_data = nb;
        }
        if (!self.gpu_device.readbackResource(id, self.scanout3d_data)) return;
        self.scanout3d_w = res.width;
        self.scanout3d_h = res.height;
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

        const stride = res.stride();

        // Fast path: a full-width rect is contiguous in both the guest
        // backing and host_data, so the whole region is one copy instead
        // of a per-row scatter walk (the common fbcon/scanout case).
        if (r.x == 0 and r.width == res.width) {
            const block_off = @as(u64, r.y) * stride;
            const block_len = @as(usize, r.height) * stride;
            const dst = res.host_data[@intCast(block_off)..][0..block_len];
            if (!copyFromBacking(res.entries.items, cmd.offset, dst, get_mem)) {
                return .resp_err_unspec;
            }
            return .resp_ok_nodata;
        }

        // General case: partial-width rect, copy row by row.
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

    /// Transfer guest data into a 3D (virgl) resource. Only buffer resources
    /// are handled here — vertex/index/constant uploads — which is what
    /// draw_vbo needs. The scattered guest backing is copied straight into
    /// the resource's shared-storage MTLBuffer (zero staging copy).
    fn cmdTransferToHost3D(self: *Gpu, req: []const u8, get_mem: ring.GetMemFn) CmdType {
        if (!self.virgl_enabled) return .resp_err_unspec;
        if (req.len < @sizeOf(TransferHost3D)) return .resp_err_invalid_parameter;
        const cmd = std.mem.bytesToValue(TransferHost3D, req[0..@sizeOf(TransferHost3D)]);

        const res = self.gpu_device.getResource(cmd.resource_id) orelse
            return .resp_err_invalid_resource_id;
        if (res.target != .buffer) {
            // Texture upload: gather the box rect from the scattered guest
            // backing into staging, then a region replaceRegion. 32-bit
            // formats only so far (everything mesa uses for scanout/simple
            // texturing); stride 0 means tightly packed.
            const list = self.backing3d.getPtr(cmd.resource_id) orelse return .resp_err_unspec;
            if (list.items.len == 0) return .resp_err_unspec;
            const bpp: u64 = 4;
            const row_bytes: u64 = @as(u64, cmd.box.w) * bpp;
            if (row_bytes == 0 or cmd.box.h == 0) return .resp_ok_nodata;
            const stride: u64 = if (cmd.stride != 0) cmd.stride else row_bytes;
            const total_u64 = row_bytes * cmd.box.h;
            if (total_u64 > 512 * 1024 * 1024) return .resp_err_invalid_parameter;
            const total: usize = @intCast(total_u64);
            const staging = self.alloc.alloc(u8, total) catch return .resp_err_out_of_memory;
            defer self.alloc.free(staging);
            var y: u32 = 0;
            while (y < cmd.box.h) : (y += 1) {
                const src_off = cmd.offset + @as(u64, y) * stride;
                const dst_row = staging[@intCast(@as(u64, y) * row_bytes)..][0..@intCast(row_bytes)];
                if (!copyFromBacking(list.items, src_off, dst_row, get_mem)) {
                    return .resp_err_unspec;
                }
            }
            // No Metal backing (decode-only CI) is not an error, but the
            // outcome is worth counting: a texture that never lands is why a
            // guest's textured draws come out blank.
            const up_ok = self.gpu_device.uploadToTextureRegion(
                cmd.resource_id,
                cmd.box.x,
                cmd.box.y,
                cmd.box.w,
                cmd.box.h,
                staging,
                @intCast(row_bytes),
            );
            if (gpu_module.stats.on()) {
                if (up_ok) gpu_module.stats.tex_uploads_ok += 1 else gpu_module.stats.tex_uploads_fail += 1;
            }
            return .resp_ok_nodata;
        }

        const list = self.backing3d.getPtr(cmd.resource_id) orelse return .resp_err_unspec;
        if (list.items.len == 0) return .resp_err_unspec;

        const dst_all = self.gpu_device.bufferContents(cmd.resource_id) orelse
            return .resp_err_unspec;

        // For buffers the box is 1D: x = byte offset into the resource,
        // w = byte length.
        const start: usize = cmd.box.x;
        const len: usize = cmd.box.w;
        if (start + len > dst_all.len) return .resp_err_invalid_parameter;

        if (!copyFromBacking(list.items, cmd.offset, dst_all[start .. start + len], get_mem)) {
            return .resp_err_unspec;
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

        if (cmd.nr_entries == 0 or cmd.nr_entries > MAX_BACKING_ENTRIES) {
            return .resp_err_invalid_parameter;
        }

        // Resolve where the backing entries belong: a 2D resource keeps them
        // on its Resource2D; a 3D (virgl) resource lives in gpu_device, so its
        // backing is tracked in backing3d.
        const dest: *std.ArrayListUnmanaged(MemEntry) = blk: {
            if (self.resources.getPtr(cmd.resource_id)) |res| break :blk &res.entries;
            if (self.virgl_enabled and self.gpu_device.getResource(cmd.resource_id) != null) {
                const gop = self.backing3d.getOrPut(cmd.resource_id) catch
                    return .resp_err_out_of_memory;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                break :blk gop.value_ptr;
            }
            return .resp_err_invalid_resource_id;
        };

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

        dest.clearRetainingCapacity();
        dest.ensureTotalCapacity(self.alloc, cmd.nr_entries) catch
            return .resp_err_out_of_memory;

        var i: u32 = 0;
        while (i < cmd.nr_entries) : (i += 1) {
            const off = i * @sizeOf(MemEntry);
            const entry = std.mem.bytesToValue(MemEntry, entries_mem[off..][0..@sizeOf(MemEntry)]);
            dest.appendAssumeCapacity(entry);
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
            2 => {
                // Venus capset — advertised only when compiled in and the host is up.
                if (comptime gpu_venus) {
                    if (self.venus_host) |*h| {
                        const cs = h.getCapset(CAPSET_VENUS);
                        info.capset_id = CAPSET_VENUS;
                        info.capset_max_version = cs.max_ver;
                        info.capset_max_size = cs.max_size;
                    } else return .resp_err_invalid_parameter;
                } else return .resp_err_invalid_parameter;
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

        // Venus caps come from virglrenderer itself (its size is host-defined).
        var venus_ver: u32 = 0;
        const size: u32 = switch (cmd.capset_id) {
            CAPSET_VIRGL => CAPS_V1_SIZE,
            CAPSET_VIRGL2 => CAPS_V2_SIZE,
            CAPSET_VENUS => blk: {
                if (comptime gpu_venus) {
                    if (self.venus_host) |*h| {
                        const cs = h.getCapset(CAPSET_VENUS);
                        venus_ver = cmd.capset_version;
                        break :blk cs.max_size;
                    }
                }
                return .resp_err_invalid_parameter;
            },
            else => return .resp_err_invalid_parameter,
        };
        if (resp.len < @sizeOf(CtrlHeader) + size) return .resp_err_unspec;

        // virgl2 gets a real GL 4.3 caps blob (glsl_level 430 + limits); v1 stays
        // zeroed; venus is filled by virglrenderer. Format masks await the translator.
        const blob = resp[@sizeOf(CtrlHeader)..][0..size];
        if (cmd.capset_id == CAPSET_VIRGL2) {
            virgl.caps.writeV2(blob);
        } else if (comptime gpu_venus) {
            if (cmd.capset_id == CAPSET_VENUS) {
                if (self.venus_host) |*h| h.fillCaps(CAPSET_VENUS, venus_ver, blob);
            } else @memset(blob, 0);
        } else {
            @memset(blob, 0);
        }
        resp_len.* = @sizeOf(CtrlHeader) + size;
        log.info("virgl get_capset id={} size={}", .{ cmd.capset_id, size });
        return .resp_ok_capset;
    }

    fn cmdResourceCreateBlob(
        self: *Gpu,
        header: CtrlHeader,
        req: []const u8,
        chain: *const ring.Chain,
        get_mem: ring.GetMemFn,
    ) CmdType {
        if (comptime gpu_venus) {
            const vh = if (self.venus_host) |*h| h else return .resp_err_unspec;
            if (req.len < @sizeOf(ResourceCreateBlob)) return .resp_err_invalid_parameter;
            const cmd = std.mem.bytesToValue(ResourceCreateBlob, req[0..@sizeOf(ResourceCreateBlob)]);
            if (cmd.resource_id == 0) return .resp_err_invalid_resource_id;
            if (cmd.nr_entries > MAX_BACKING_ENTRIES) return .resp_err_invalid_parameter;

            // Gather guest backing pages into iovecs (host pointers into guest
            // RAM). Host-only blobs (nr_entries == 0) carry no guest backing.
            var iovs: []venus.iovec = &.{};
            if (cmd.nr_entries > 0) {
                const entries_bytes = @as(usize, cmd.nr_entries) * @sizeOf(MemEntry);
                const inline_entries = req[@sizeOf(ResourceCreateBlob)..];
                const entries_mem: []const u8 = if (inline_entries.len >= entries_bytes)
                    inline_entries
                else blk: {
                    var readable_idx: u32 = 0;
                    for (chain.slice()) |d| {
                        if (d.isWrite()) continue;
                        readable_idx += 1;
                        if (readable_idx == 2) break :blk get_mem(d.addr, d.len) orelse
                            return .resp_err_invalid_parameter;
                    }
                    return .resp_err_invalid_parameter;
                };
                if (entries_mem.len < entries_bytes) return .resp_err_invalid_parameter;

                iovs = self.alloc.alloc(venus.iovec, cmd.nr_entries) catch return .resp_err_out_of_memory;
                var i: u32 = 0;
                while (i < cmd.nr_entries) : (i += 1) {
                    const e = std.mem.bytesToValue(MemEntry, entries_mem[i * @sizeOf(MemEntry) ..][0..@sizeOf(MemEntry)]);
                    const host = get_mem(e.addr, e.length) orelse {
                        self.alloc.free(iovs);
                        return .resp_err_invalid_parameter;
                    };
                    iovs[i] = .{ .base = host.ptr, .len = e.length };
                }
            }

            var args = venus.BlobArgs{
                .res_handle = cmd.resource_id,
                .ctx_id = header.ctx_id,
                .blob_mem = cmd.blob_mem,
                .blob_flags = cmd.blob_flags,
                .blob_id = cmd.blob_id,
                .size = cmd.size,
                .iovecs = if (iovs.len > 0) iovs.ptr else null,
                .num_iovs = cmd.nr_entries,
            };
            log.info("create_blob res={} ctx={} mem={} flags=0x{x} id={} size={} nr_ent={}", .{ cmd.resource_id, header.ctx_id, cmd.blob_mem, cmd.blob_flags, cmd.blob_id, cmd.size, cmd.nr_entries });
            vh.createBlob(&args) catch {
                log.warn("create_blob FAILED res={} mem={} size={}", .{ cmd.resource_id, cmd.blob_mem, cmd.size });
                if (iovs.len > 0) self.alloc.free(iovs);
                return .resp_err_unspec;
            };
            self.venus_blobs.put(cmd.resource_id, iovs) catch {};
            self.blob_meta.put(cmd.resource_id, .{
                .blob_mem = cmd.blob_mem,
                .blob_flags = cmd.blob_flags,
                .size = cmd.size,
            }) catch {};
            return .resp_ok_nodata;
        }
        return .resp_err_unspec;
    }

    fn cmdResourceMapBlob(self: *Gpu, req: []const u8, resp: []u8, resp_len: *u32) CmdType {
        if (comptime gpu_venus) {
            const vh = if (self.venus_host) |*h| h else return .resp_err_unspec;
            if (req.len < @sizeOf(ResourceMapBlob)) return .resp_err_invalid_parameter;
            if (resp.len < @sizeOf(MapInfoResp)) return .resp_err_unspec;
            const map_fn = self.host_visible_map orelse return .resp_err_unspec;
            const cmd = std.mem.bytesToValue(ResourceMapBlob, req[0..@sizeOf(ResourceMapBlob)]);

            // Ask virglrenderer for the host pointer + size of the resource's
            // (device) memory, then map it into the guest host-visible window at
            // the driver-chosen offset.
            const mapping = vh.mapResource(cmd.resource_id) catch {
                log.warn("map_blob res={} mapResource FAILED (offset=0x{x})", .{ cmd.resource_id, cmd.offset });
                return .resp_err_unspec;
            };
            log.info("map_blob res={} ptr=0x{x} size={} -> guest_pa offset=0x{x}", .{ cmd.resource_id, @intFromPtr(mapping.ptr), mapping.size, cmd.offset });
            const guest_pa = self.host_visible_base +% cmd.offset;
            // hv_vm_map needs a host-page (16 KiB on Apple Silicon) multiple;
            // blob sizes are only 4 KiB-aligned. Round up — virgl backs blobs
            // with mmap'd (host-page) memory, so the rounded tail is in-bounds.
            const HOST_PAGE: usize = 0x4000;
            const map_size = std.mem.alignForward(usize, @intCast(mapping.size), HOST_PAGE);
            if (cmd.offset +% map_size > self.host_visible_size) return .resp_err_invalid_parameter;
            if (!map_fn(self.host_visible_userdata, mapping.ptr, guest_pa, map_size)) {
                vh.unmapResource(cmd.resource_id);
                return .resp_err_unspec;
            }
            self.venus_mappings.put(cmd.resource_id, .{ .pa = guest_pa, .size = map_size }) catch {};

            var info = MapInfoResp{ .header = .{ .type = @intFromEnum(CmdType.resp_ok_map_info) }, .map_info = 1 }; // 1 = VIRTIO_GPU_MAP_CACHE_CACHED
            @memcpy(resp[0..@sizeOf(MapInfoResp)], std.mem.asBytes(&info));
            resp_len.* = @sizeOf(MapInfoResp);
            return .resp_ok_map_info;
        }
        return .resp_err_unspec;
    }

    fn cmdResourceUnmapBlob(self: *Gpu, req: []const u8) CmdType {
        if (comptime gpu_venus) {
            const vh = if (self.venus_host) |*h| h else return .resp_err_unspec;
            // virtio_gpu_resource_unmap_blob = { header, resource_id, padding }.
            if (req.len < @sizeOf(ResourceUnref)) return .resp_err_invalid_parameter;
            const cmd = std.mem.bytesToValue(ResourceUnref, req[0..@sizeOf(ResourceUnref)]);
            if (self.venus_mappings.fetchRemove(cmd.resource_id)) |kv| {
                if (self.host_visible_unmap) |unmap_fn| {
                    unmap_fn(self.host_visible_userdata, kv.value.pa, kv.value.size);
                }
                vh.unmapResource(cmd.resource_id);
            }
            return .resp_ok_nodata;
        }
        return .resp_err_unspec;
    }

    fn cmdCtxCreate(self: *Gpu, header: CtrlHeader, req: []const u8) CmdType {
        if (!self.virgl_enabled) return .resp_err_unspec;
        if (header.ctx_id == 0) return .resp_err_invalid_context_id;

        // The capset id lives in the low byte of context_init (when the guest
        // negotiated VIRTIO_GPU_F_CONTEXT_INIT). A Venus context routes to the
        // venus host; everything else uses the legacy virgl translator.
        if (comptime gpu_venus) {
            if (self.venus_host) |*h| {
                if (req.len >= @sizeOf(CtxCreate)) {
                    const cc = std.mem.bytesToValue(CtxCreate, req[0..@sizeOf(CtxCreate)]);
                    const capset: u32 = cc.context_init & 0xff;
                    if (capset == CAPSET_VENUS) {
                        h.createVenusContext(header.ctx_id) catch return .resp_err_unspec;
                        self.venus_contexts.put(header.ctx_id, {}) catch return .resp_err_out_of_memory;
                        log.info("venus ctx_create ctx_id={}", .{header.ctx_id});
                        return .resp_ok_nodata;
                    }
                }
            }
        }

        self.gpu_device.createContextId(header.ctx_id) catch return .resp_err_out_of_memory;
        log.info("virgl ctx_create ctx_id={}", .{header.ctx_id});
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

        // Bring-up diagnostic: log the first few submits' leading opcode so we
        // can see whether the guest reaches real 3D command submission.
        if (self.submit3d_seen < 12) {
            self.submit3d_seen += 1;
            const op0: u8 = if (cmd_data.len >= 4) @truncate(std.mem.readInt(u32, cmd_data[0..4], .little)) else 0xff;
            log.info("virgl submit_3d #{} ctx={} bytes={} first_op={}", .{ self.submit3d_seen, header.ctx_id, cmd_data.len, op0 });
        }

        // Route Venus contexts' command streams to virglrenderer(venus); all
        // others go to the legacy translator.
        if (comptime gpu_venus) {
            if (self.venus_contexts.contains(header.ctx_id)) {
                if (self.venus_host) |*h| {
                    h.submit(header.ctx_id, cmd_data) catch return .resp_err_unspec;
                    return .resp_ok_nodata;
                }
            }
        }

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

    // Context create via header ctx_id (no request body = legacy virgl path)
    const hdr = CtrlHeader{ .type = @intFromEnum(CmdType.ctx_create), .ctx_id = 7 };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdCtxCreate(hdr, &.{}));
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

test "transfer_to_host_2d full-width fast path matches guest backing" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    // A 64x8 XRGB resource backed by a single contiguous region in our
    // fake guest memory at 0x1000.
    const w: u32 = 64;
    const h: u32 = 8;
    const bytes = @as(usize, w) * h * 4;

    const guest = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(guest);
    for (guest, 0..) |*b, i| b.* = @truncate(i * 7 + 3);

    const Ctx = struct {
        var mem: []u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr < 0x1000) return null;
            const off = addr - 0x1000;
            if (off + len > mem.len) return null;
            return mem[off..][0..len];
        }
    };
    Ctx.mem = guest;
    gpu.setGuestMemory(Ctx.get);

    // create_2d
    const create = ResourceCreate2D{
        .header = .{ .type = @intFromEnum(CmdType.resource_create_2d) },
        .resource_id = 1,
        .format = 2,
        .width = w,
        .height = h,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdResourceCreate2D(std.mem.asBytes(&create)));

    // attach a single contiguous backing entry
    const AttachMsg = extern struct { hdr: ResourceAttachBacking, entry: MemEntry };
    const attach = AttachMsg{
        .hdr = .{
            .header = .{ .type = @intFromEnum(CmdType.resource_attach_backing) },
            .resource_id = 1,
            .nr_entries = 1,
        },
        .entry = .{ .addr = 0x1000, .length = @intCast(bytes) },
    };
    var empty_chain = ring.Chain{};
    try testing.expectEqual(
        CmdType.resp_ok_nodata,
        gpu.cmdResourceAttachBacking(std.mem.asBytes(&attach), &empty_chain, Ctx.get),
    );

    // full-surface transfer (hits the fast path)
    const xfer = TransferToHost2D{
        .header = .{ .type = @intFromEnum(CmdType.transfer_to_host_2d) },
        .r = .{ .width = w, .height = h },
        .offset = 0,
        .resource_id = 1,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdTransferToHost2D(std.mem.asBytes(&xfer), Ctx.get));

    // host copy must match the guest backing byte-for-byte
    const res = gpu.resources.get(1).?;
    try testing.expect(std.mem.eql(u8, res.host_data, guest));
}

test "transfer_to_host_3d uploads guest TEXTURE data via replaceRegion" {
    const gpu = try Gpu.init(testing.allocator, true);
    defer gpu.deinit();

    // A 2x2 BGRA texture: 4 distinct pixels.
    const nbytes: u32 = 2 * 2 * 4;
    const guest = try testing.allocator.alloc(u8, nbytes);
    defer testing.allocator.free(guest);
    for (guest, 0..) |*b, i| b.* = @truncate(i * 11 + 5);

    const Ctx = struct {
        var mem: []u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr < 0x1000) return null;
            const off = addr - 0x1000;
            if (off + len > mem.len) return null;
            return mem[off..][0..len];
        }
    };
    Ctx.mem = guest;
    gpu.setGuestMemory(Ctx.get);

    // texture_2d (2) with sampler_view bind (1<<3).
    const create = ResourceCreate3D{
        .header = .{ .type = @intFromEnum(CmdType.resource_create_3d) },
        .resource_id = 1,
        .target = 2,
        .format = @intFromEnum(@import("../gpu/virgl/protocol.zig").Format.b8g8r8a8_unorm),
        .bind = 1 << 3,
        .width = 2,
        .height = 2,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdResourceCreate3D(std.mem.asBytes(&create)));
    if (gpu.gpu_device.renderer == null) return error.SkipZigTest;

    const AttachMsg = extern struct { hdr: ResourceAttachBacking, entry: MemEntry };
    const attach = AttachMsg{
        .hdr = .{
            .header = .{ .type = @intFromEnum(CmdType.resource_attach_backing) },
            .resource_id = 1,
            .nr_entries = 1,
        },
        .entry = .{ .addr = 0x1000, .length = nbytes },
    };
    var empty_chain = ring.Chain{};
    try testing.expectEqual(
        CmdType.resp_ok_nodata,
        gpu.cmdResourceAttachBacking(std.mem.asBytes(&attach), &empty_chain, Ctx.get),
    );

    // Full-rect transfer (tight stride via stride=0).
    const xfer = TransferHost3D{
        .header = .{ .type = @intFromEnum(CmdType.transfer_to_host_3d) },
        .box = .{ .x = 0, .y = 0, .z = 0, .w = 2, .h = 2, .d = 1 },
        .offset = 0,
        .resource_id = 1,
        .level = 0,
        .stride = 0,
        .layer_stride = 0,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdTransferToHost3D(std.mem.asBytes(&xfer), Ctx.get));

    // Read the texture back from the GPU: must match the guest bytes.
    var out: [nbytes]u8 = undefined;
    try testing.expect(gpu.gpu_device.readbackResource(1, &out));
    try testing.expectEqualSlices(u8, guest, &out);
}

test "transfer_to_host_3d uploads guest vertex data into the resource's MTLBuffer" {
    const gpu = try Gpu.init(testing.allocator, true);
    defer gpu.deinit();

    const nbytes: u32 = 24; // 3 vertices * float2

    const guest = try testing.allocator.alloc(u8, nbytes);
    defer testing.allocator.free(guest);
    for (guest, 0..) |*b, i| b.* = @truncate(i + 1);

    const Ctx = struct {
        var mem: []u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr < 0x1000) return null;
            const off = addr - 0x1000;
            if (off + len > mem.len) return null;
            return mem[off..][0..len];
        }
    };
    Ctx.mem = guest;
    gpu.setGuestMemory(Ctx.get);

    // Create a 3D buffer resource (target=buffer(0), bind=vertex_buffer).
    const create = ResourceCreate3D{
        .header = .{ .type = @intFromEnum(CmdType.resource_create_3d) },
        .resource_id = 1,
        .target = 0,
        .format = 0,
        .bind = 1 << 4, // PIPE_BIND_VERTEX_BUFFER
        .width = nbytes, // buffers encode byte size in width
        .height = 0,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdResourceCreate3D(std.mem.asBytes(&create)));

    if (gpu.gpu_device.renderer == null) return error.SkipZigTest;

    // Attach a single contiguous backing region.
    const AttachMsg = extern struct { hdr: ResourceAttachBacking, entry: MemEntry };
    const attach = AttachMsg{
        .hdr = .{
            .header = .{ .type = @intFromEnum(CmdType.resource_attach_backing) },
            .resource_id = 1,
            .nr_entries = 1,
        },
        .entry = .{ .addr = 0x1000, .length = nbytes },
    };
    var empty_chain = ring.Chain{};
    try testing.expectEqual(
        CmdType.resp_ok_nodata,
        gpu.cmdResourceAttachBacking(std.mem.asBytes(&attach), &empty_chain, Ctx.get),
    );

    // Transfer the whole buffer to the host.
    const xfer = TransferHost3D{
        .header = .{ .type = @intFromEnum(CmdType.transfer_to_host_3d) },
        .box = .{ .x = 0, .y = 0, .z = 0, .w = nbytes, .h = 1, .d = 1 },
        .offset = 0,
        .resource_id = 1,
        .level = 0,
        .stride = 0,
        .layer_stride = 0,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdTransferToHost3D(std.mem.asBytes(&xfer), Ctx.get));

    // The MTLBuffer must now hold the guest vertex bytes exactly.
    const contents = gpu.gpu_device.bufferContents(1).?;
    try testing.expect(std.mem.eql(u8, contents[0..nbytes], guest));
}

test "3D scanout presents rendered GPU pixels" {
    const gpu = try Gpu.init(testing.allocator, true);
    defer gpu.deinit();

    // A 3D render-target resource that will also be the scanout.
    try gpu.gpu_device.createResourceRecord(.{
        .handle = 10,
        .target = .texture_2d,
        .format = .b8g8r8a8_unorm,
        .width = 32,
        .height = 32,
        .depth = 1,
        .array_size = 1,
        .last_level = 0,
        .nr_samples = 0,
        .flags = 0,
        .bind = 1 << 1, // PIPE_BIND_RENDER_TARGET
    });
    if (gpu.gpu_device.renderer == null) return error.SkipZigTest;

    const scan = SetScanout{
        .header = .{ .type = @intFromEnum(CmdType.set_scanout) },
        .r = .{ .width = 32, .height = 32 },
        .scanout_id = 0,
        .resource_id = 10,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdSetScanout(std.mem.asBytes(&scan)));

    // Render RED into it via a clear command stream.
    try gpu.gpu_device.createContextId(1);
    var w: [17]u32 = undefined;
    var i: usize = 0;
    w[i] = 1 | (8 << 8) | (3 << 16); // create SURFACE
    i += 1;
    w[i] = 60;
    i += 1;
    w[i] = 10;
    i += 1;
    w[i] = 1; // format bgra8
    i += 1;
    w[i] = 5 | (3 << 16); // set_framebuffer
    i += 1;
    w[i] = 1;
    i += 1;
    w[i] = 0;
    i += 1;
    w[i] = 60;
    i += 1;
    w[i] = 7 | (8 << 16); // clear
    i += 1;
    w[i] = 4;
    i += 1;
    w[i] = @bitCast(@as(f32, 1.0)); // r
    i += 1;
    w[i] = @bitCast(@as(f32, 0.0)); // g
    i += 1;
    w[i] = @bitCast(@as(f32, 0.0)); // b
    i += 1;
    w[i] = @bitCast(@as(f32, 1.0)); // a
    i += 1;
    w[i] = 0;
    i += 1;
    w[i] = 0;
    i += 1;
    w[i] = 0;
    i += 1;
    try gpu.gpu_device.submit(1, std.mem.sliceAsBytes(w[0..i]));

    const flush = ResourceFlush{
        .header = .{ .type = @intFromEnum(CmdType.resource_flush) },
        .r = .{ .width = 32, .height = 32 },
        .resource_id = 10,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdResourceFlush(std.mem.asBytes(&flush)));

    const view = gpu.scanout() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 32), view.width);
    // Pixels come from the render target's IOSurface directly (zero-copy 3D
    // present) when available, otherwise from the readback buffer.
    const pixels = if (view.surface) |surf|
        (iosurface.baseAddressOf(surf) orelse return error.TestUnexpectedResult)[0 .. @as(usize, view.width) * view.height * 4]
    else
        view.data;
    const c = ((16 * 32) + 16) * 4;
    // Red in BGRA host memory: B<40, G<40, R>200.
    try testing.expect(pixels[c + 2] > 200 and pixels[c + 1] < 40 and pixels[c + 0] < 40);
}

test "scanout frame generation advances only on flush of the scanout" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    const Ctx = struct {
        var mem: [4096]u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr < 0x1000) return null;
            const off = addr - 0x1000;
            if (off + len > mem.len) return null;
            return mem[off..][0..len];
        }
    };
    gpu.setGuestMemory(Ctx.get);

    // 8x8 resource, scanned out.
    const create = ResourceCreate2D{
        .header = .{ .type = @intFromEnum(CmdType.resource_create_2d) },
        .resource_id = 1,
        .format = 2,
        .width = 8,
        .height = 8,
    };
    _ = gpu.cmdResourceCreate2D(std.mem.asBytes(&create));

    const gen0 = gpu.scanout(); // no scanout yet
    try testing.expect(gen0 == null);

    const scan = SetScanout{
        .header = .{ .type = @intFromEnum(CmdType.set_scanout) },
        .r = .{ .width = 8, .height = 8 },
        .scanout_id = 0,
        .resource_id = 1,
    };
    _ = gpu.cmdSetScanout(std.mem.asBytes(&scan));
    const g_after_scanout = gpu.scanout().?.generation;

    // Flushing the scanout resource advances the generation.
    const flush = ResourceFlush{
        .header = .{ .type = @intFromEnum(CmdType.resource_flush) },
        .r = .{ .width = 8, .height = 8 },
        .resource_id = 1,
    };
    _ = gpu.cmdResourceFlush(std.mem.asBytes(&flush));
    try testing.expectEqual(g_after_scanout + 1, gpu.scanout().?.generation);

    // Flushing a non-scanout resource does not.
    const g = gpu.scanout().?.generation;
    const flush_other = ResourceFlush{
        .header = .{ .type = @intFromEnum(CmdType.resource_flush) },
        .r = .{ .width = 8, .height = 8 },
        .resource_id = 999,
    };
    _ = gpu.cmdResourceFlush(std.mem.asBytes(&flush_other));
    try testing.expectEqual(g, gpu.scanout().?.generation);
}

test "hardware cursor: update_cursor sets image+position, move_cursor repositions only" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    const Ctx = struct {
        var mem: [4096]u8 = undefined;
        fn get(addr: u64, len: usize) ?[]u8 {
            if (addr < 0x1000) return null;
            const off = addr - 0x1000;
            if (off + len > mem.len) return null;
            return mem[off..][0..len];
        }
    };
    gpu.setGuestMemory(Ctx.get);

    // No cursor yet.
    try testing.expect(gpu.cursorView() == null);

    // Create the 4x4 cursor sprite resource the guest would've uploaded.
    const create = ResourceCreate2D{
        .header = .{ .type = @intFromEnum(CmdType.resource_create_2d) },
        .resource_id = 7,
        .format = 2,
        .width = 4,
        .height = 4,
    };
    _ = gpu.cmdResourceCreate2D(std.mem.asBytes(&create));

    const update = UpdateCursor{
        .header = .{ .type = @intFromEnum(CmdType.update_cursor) },
        .pos = .{ .scanout_id = 0, .x = 100, .y = 50 },
        .resource_id = 7,
        .hot_x = 1,
        .hot_y = 2,
    };
    gpu.handleCursorCommand(std.mem.asBytes(&update));

    const view1 = gpu.cursorView() orelse return error.TestExpectedCursor;
    try testing.expectEqual(@as(u32, 4), view1.width);
    try testing.expectEqual(@as(u32, 4), view1.height);
    try testing.expectEqual(@as(u32, 1), view1.hot_x);
    try testing.expectEqual(@as(u32, 2), view1.hot_y);
    try testing.expectEqual(@as(i32, 100), view1.x);
    try testing.expectEqual(@as(i32, 50), view1.y);
    const gen1 = view1.generation;

    // MOVE_CURSOR (resource_id=0): repositions only, keeps the same image
    // and hotspot, and still bumps the generation (redraw on motion alone).
    const move = UpdateCursor{
        .header = .{ .type = @intFromEnum(CmdType.move_cursor) },
        .pos = .{ .scanout_id = 0, .x = 200, .y = 150 },
        .resource_id = 0,
        .hot_x = 0,
        .hot_y = 0,
    };
    gpu.handleCursorCommand(std.mem.asBytes(&move));

    const view2 = gpu.cursorView() orelse return error.TestExpectedCursor;
    try testing.expectEqual(@as(i32, 200), view2.x);
    try testing.expectEqual(@as(i32, 150), view2.y);
    try testing.expectEqual(@as(u32, 1), view2.hot_x); // unchanged by move_cursor
    try testing.expectEqual(@as(u32, 2), view2.hot_y);
    try testing.expect(view2.generation != gen1);

    // resource_id=0 on UPDATE_CURSOR hides the cursor.
    const hide = UpdateCursor{
        .header = .{ .type = @intFromEnum(CmdType.update_cursor) },
        .pos = .{ .scanout_id = 0, .x = 200, .y = 150 },
        .resource_id = 0,
        .hot_x = 0,
        .hot_y = 0,
    };
    gpu.handleCursorCommand(std.mem.asBytes(&hide));
    try testing.expect(gpu.cursorView() == null);
}

test "EDID feature advertised" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    try testing.expect(gpu.transport.device_features & Features.EDID != 0);
    // Low 32 bits via the MMIO register path (sel defaults to 0).
    const low = gpu.read(@intFromEnum(mmio.Reg.device_features));
    try testing.expect(low & @as(u32, @truncate(Features.EDID)) != 0);
}

test "get_edid returns a valid preferred-mode EDID" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();
    gpu.setDisplaySize(1440, 900);

    const req = GetEdid{
        .header = .{ .type = @intFromEnum(CmdType.get_edid) },
        .scanout = 0,
    };
    var resp_buf: [@sizeOf(RespEdid)]u8 = undefined;
    var resp_len: u32 = 0;
    const rt = gpu.cmdGetEdid(std.mem.asBytes(&req), &resp_buf, &resp_len);
    try testing.expectEqual(CmdType.resp_ok_edid, rt);
    try testing.expectEqual(@as(u32, @sizeOf(RespEdid)), resp_len);

    const resp = std.mem.bytesToValue(RespEdid, resp_buf[0..@sizeOf(RespEdid)]);
    try testing.expectEqual(@as(u32, 128), resp.size);
    const edid = resp.edid[0..128];
    // Magic header
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 }, edid[0..8]);
    // Block checksums to 0 mod 256
    var sum: u8 = 0;
    for (edid) |b| sum +%= b;
    try testing.expectEqual(@as(u8, 0), sum);
    // DTD carries the preferred mode's active pixels
    const ha = @as(u32, edid[56]) | (@as(u32, edid[58] >> 4) << 8);
    const va = @as(u32, edid[59]) | (@as(u32, edid[61] >> 4) << 8);
    try testing.expectEqual(@as(u32, 1440), ha);
    try testing.expectEqual(@as(u32, 900), va);

    // Non-zero scanout is rejected.
    const bad = GetEdid{
        .header = .{ .type = @intFromEnum(CmdType.get_edid) },
        .scanout = 1,
    };
    try testing.expectEqual(
        CmdType.resp_err_invalid_scanout_id,
        gpu.cmdGetEdid(std.mem.asBytes(&bad), &resp_buf, &resp_len),
    );
}

test "buildEdid clamps oversized modes to DTD field limits" {
    var edid: [128]u8 = undefined;
    buildEdid(7680, 4320, &edid);

    var sum: u8 = 0;
    for (edid) |b| sum +%= b;
    try testing.expectEqual(@as(u8, 0), sum);

    const ha = @as(u32, edid[56]) | (@as(u32, edid[58] >> 4) << 8);
    const va = @as(u32, edid[59]) | (@as(u32, edid[61] >> 4) << 8);
    try testing.expectEqual(@as(u32, 4095), ha);
    try testing.expectEqual(@as(u32, 4095), va);
    // Pixel clock clamped to u16
    const clock = @as(u32, edid[54]) | (@as(u32, edid[55]) << 8);
    try testing.expect(clock <= std.math.maxInt(u16));
}

test "resizeDisplay flags the display event and raises config-change" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    const Line = struct {
        var level: bool = false;
        fn cb(l: bool, _: ?*anyopaque) void {
            level = l;
        }
    };
    Line.level = false;
    gpu.transport.setIrqCallback(Line.cb, null);

    // Boot size = fbdev framebuffer allocation = the resize ceiling.
    gpu.setDisplaySize(2560, 1440);

    const gen_before = gpu.transport.config_generation;
    gpu.resizeDisplay(1920, 1080);

    // Event bit visible through the config-space read path.
    try testing.expectEqual(EVENT_DISPLAY, gpu.read(@intFromEnum(mmio.Reg.config)));
    try testing.expect(gpu.transport.interrupt_status.config_change);
    try testing.expect(Line.level);
    try testing.expectEqual(gen_before +% 1, gpu.transport.config_generation);

    // Display info reflects the new size immediately.
    var resp_buf: [@sizeOf(DisplayInfoResp)]u8 = undefined;
    var resp_len: u32 = 0;
    try testing.expectEqual(CmdType.resp_ok_display_info, gpu.cmdGetDisplayInfo(&resp_buf, &resp_len));
    const info = std.mem.bytesToValue(DisplayInfoResp, resp_buf[0..@sizeOf(DisplayInfoResp)]);
    try testing.expectEqual(@as(u32, 1920), info.pmodes[0].r.width);
    try testing.expectEqual(@as(u32, 1080), info.pmodes[0].r.height);

    // Guest clears the event via events_clear.
    gpu.write(@intFromEnum(mmio.Reg.config) + @offsetOf(Config, "events_clear"), EVENT_DISPLAY);
    try testing.expectEqual(@as(u32, 0), gpu.read(@intFromEnum(mmio.Reg.config)));

    // Unchanged size is a no-op (no spurious generation bump).
    const gen_after = gpu.transport.config_generation;
    gpu.resizeDisplay(1920, 1080);
    try testing.expectEqual(gen_after, gpu.transport.config_generation);

    // Tiny sizes clamp to the minimum instead of wedging the guest.
    gpu.resizeDisplay(1, 1);
    try testing.expectEqual(Gpu.MIN_DISPLAY_DIM, gpu.display_width);
    try testing.expectEqual(Gpu.MIN_DISPLAY_DIM, gpu.display_height);

    // Oversized requests clamp to the BOOT size: the guest fbdev fb can
    // never grow, and advertising a mode that can't fit it makes the fbdev
    // client disable the display (black screen).
    gpu.resizeDisplay(4000, 3000);
    try testing.expectEqual(@as(u32, 2560), gpu.display_width);
    try testing.expectEqual(@as(u32, 1440), gpu.display_height);
}

test "guest modeset at new size after resizeDisplay" {
    const gpu = try Gpu.init(testing.allocator, false);
    defer gpu.deinit();

    gpu.resizeDisplay(640, 480);

    // Guest responds to the hotplug by creating a new resource at the new
    // size and scanning it out.
    const create = ResourceCreate2D{
        .header = .{ .type = @intFromEnum(CmdType.resource_create_2d) },
        .resource_id = 2,
        .format = 2,
        .width = 640,
        .height = 480,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdResourceCreate2D(std.mem.asBytes(&create)));
    const scan = SetScanout{
        .header = .{ .type = @intFromEnum(CmdType.set_scanout) },
        .r = .{ .width = 640, .height = 480 },
        .scanout_id = 0,
        .resource_id = 2,
    };
    try testing.expectEqual(CmdType.resp_ok_nodata, gpu.cmdSetScanout(std.mem.asBytes(&scan)));

    const view = gpu.scanout().?;
    try testing.expectEqual(@as(u32, 640), view.width);
    try testing.expectEqual(@as(u32, 480), view.height);
}
