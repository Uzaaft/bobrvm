//! Virtual Machine abstraction.
//!
//! Ties together:
//! - Hypervisor VM and vCPUs
//! - Memory layout
//! - Virtio devices
//! - Boot loader
//!
//! This is the core "machine" that runs guest code.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const callback_binding = @import("../callback.zig");
const config_policy = @import("../config.zig");
const console_session = @import("../console/Session.zig");
const global = @import("../global.zig");
const GuestMemory = @import("../guest_memory.zig").GuestMemory;
const thread_compat = @import("../compat/thread.zig");

const hypervisor = @import("../hypervisor/main.zig");
const virtio = @import("../virtio/main.zig");
const gic = @import("../gic/main.zig");
const icc = @import("../gic/icc.zig");
const mininat = @import("../net/mininat.zig");
const pci = @import("../pci/main.zig");
const dtb = @import("dtb.zig");
const agent = @import("../agent/main.zig");
pub const snapshot = @import("snapshot.zig");
pub const GuestToolsStatus = agent.native.Status;

const log = std.log.scoped(.machine);
const ID_AA64PFR0_GIC_SHIFT: u6 = 24;
const ID_AA64PFR0_GIC_MASK: u64 = 0xF << ID_AA64PFR0_GIC_SHIFT;

// Darwin copy-on-write file clone (instant on APFS; snapshot substrate).
extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;
const enable_debug_logs = builtin.mode == .Debug;

/// Thread-local machine pointer for guest memory access.
/// Set before vCPU threads start, used by getGuestMemoryWrapper.
// Single VM per process (a Hypervisor.framework restriction), shared by
// all vCPU threads for guest memory access.
var current_machine: ?*Machine = null;

fn withGicSystemRegisters(pfr0: u64) u64 {
    return (pfr0 & ~ID_AA64PFR0_GIC_MASK) | (@as(u64, 1) << ID_AA64PFR0_GIC_SHIFT);
}

/// Memory layout for ARM64 Linux VM.
/// Based on QEMU virt machine layout for UEFI compatibility.
pub const MemoryLayout = struct {
    /// Pflash CODE region (UEFI firmware, read-only)
    /// QEMU virt uses 0x0000_0000 for first pflash
    pub const PFLASH_CODE_BASE: u64 = 0x0000_0000;
    pub const PFLASH_CODE_SIZE: u64 = 64 * 1024 * 1024; // 64MB

    /// Pflash VARS region (UEFI variables, read-write)
    /// QEMU virt uses 0x0400_0000 for second pflash
    pub const PFLASH_VARS_BASE: u64 = 0x0400_0000;
    pub const PFLASH_VARS_SIZE: u64 = 64 * 1024 * 1024; // 64MB

    /// Legacy alias for compatibility
    pub const FLASH_BASE: u64 = PFLASH_CODE_BASE;
    pub const FLASH_SIZE: u64 = PFLASH_CODE_SIZE;

    /// GIC (interrupt controller) - not used directly but reserved
    pub const GIC_DIST_BASE: u64 = 0x0800_0000;
    pub const GIC_REDIST_BASE: u64 = 0x080A_0000;

    /// UART (PL011 compatible)
    pub const UART_BASE: u64 = 0x0900_0000;
    pub const UART_SIZE: u64 = 0x1000;

    /// RTC
    pub const RTC_BASE: u64 = 0x0901_0000;
    pub const RTC_SIZE: u64 = 0x1000;

    /// Virtio MMIO devices (16 slots)
    pub const VIRTIO_BASE: u64 = 0x0A00_0000;
    pub const VIRTIO_SIZE: u64 = 0x200; // Per device
    pub const VIRTIO_COUNT: u64 = 16;

    /// PCIe ECAM base (QEMU virt compatible)
    pub const ECAM_BASE: u64 = 0x3c00_0000;
    pub const ECAM_SIZE: u64 = 64 * 1024 * 1024; // 64MB

    /// PCIe MMIO region
    pub const PCI_MMIO_BASE: u64 = 0x1000_0000;
    pub const PCI_MMIO_SIZE: u64 = 0x2c00_0000; // 768MB

    /// RAM starts at 1GB
    pub const RAM_BASE: u64 = 0x4000_0000;

    /// Kernel load address (RAM + 2MB, must be 2MB aligned for ARM64)
    pub const KERNEL_BASE: u64 = RAM_BASE + 0x0020_0000;

    /// Initrd load address (after kernel, aligned to 1MB)
    pub const INITRD_BASE: u64 = RAM_BASE + 0x0800_0000; // RAM + 128MB

    /// DTB load address (end of the low 1GB boot window - 2MB).
    pub fn dtbBase(ram_size: u64) u64 {
        const dtb_reserve_bytes: u64 = 2 * 1024 * 1024;
        const boot_window_bytes: u64 = @min(ram_size, 1024 * 1024 * 1024);
        assert(ram_size >= dtb_reserve_bytes);
        assert(boot_window_bytes >= dtb_reserve_bytes);
        return RAM_BASE + boot_window_bytes - dtb_reserve_bytes;
    }

    /// Get virtio device MMIO base for a given slot.
    pub fn virtioBase(slot: u32) u64 {
        assert(slot < VIRTIO_COUNT);
        return VIRTIO_BASE + @as(u64, slot) * VIRTIO_SIZE;
    }
};

/// Machine configuration.
pub const MachineConfig = struct {
    /// RAM size in bytes.
    ram_size: u64 = 512 * 1024 * 1024, // 512MB default

    /// Number of vCPUs.
    vcpu_count: u8 = 1,

    /// Initial guest-visible terminal dimensions in character cells.
    console_size: console_session.Size = .{},

    /// Path to UEFI firmware (e.g., QEMU_EFI.fd). If set, boots via firmware.
    firmware_path: ?[]const u8 = null,

    /// Path to UEFI variables file. Created if doesn't exist.
    vars_path: ?[]const u8 = null,

    /// Path to kernel (Image file). Used for direct boot (no firmware).
    kernel_path: ?[]const u8 = null,

    /// Path to initrd.
    initrd_path: ?[]const u8 = null,

    /// Kernel command line.
    cmdline: []const u8 = "console=hvc0 earlycon=pl011,0x09000000",

    /// Path to primary disk image (virtio slot 1).
    disk_path: ?[]const u8 = null,

    /// Whether the primary disk image is read-only.
    disk_read_only: bool = false,

    /// Path to secondary disk image (virtio slot 2, typically ISO).
    disk2_path: ?[]const u8 = null,

    /// Whether the secondary disk is read-only (typically true for ISO).
    disk2_read_only: bool = true,

    /// Enable the virtio-gpu display device.
    enable_gpu: bool = false,

    /// Advertise virgl 3D acceleration (experimental translator).
    enable_virgl: bool = false,

    /// Enable the virtio-net device (built-in NAT backend).
    enable_net: bool = false,

    /// Enable the virtio-snd (sound) device. Opt-in: audio is not always
    /// present, so both the DTB virtio count and the slot assignment gate
    /// on this flag.
    enable_snd: bool = false,

    /// Host→guest TCP port forwards (implies enable_net). The slice must
    /// stay valid until startSync() has initialized the devices.
    forwards: []const mininat.Forward = &.{},

    /// Host directory exported to the guest via 9p (mount tag "host").
    /// The slice must stay valid until startSync() has initialized devices.
    shared_dir: ?[]const u8 = null,
    share_read_only: bool = false,

    /// Restore machine state from this suspend image instead of booting.
    /// The rest of the config (RAM size, devices) must match the config
    /// the image was taken with.
    restore_path: ?[]const u8 = null,

    /// Display size for the virtio-gpu scanout.
    display_width: u32 = 1280,
    display_height: u32 = 800,

    /// Host graphics-memory budget for 2D resources and the Venus window.
    gpu_memory_bytes: u64 = config_policy.gpu_memory_bytes_default,

    /// Count how many block devices are configured.
    pub fn blockDeviceCount(self: MachineConfig) u8 {
        var count: u8 = 0;
        if (self.disk_path != null) count += 1;
        if (self.disk2_path != null) count += 1;
        return count;
    }

    /// Check if firmware boot mode is enabled.
    pub fn isFirmwareBoot(self: MachineConfig) bool {
        if (self.firmware_path) |path| {
            return path.len > 0;
        }
        return false;
    }
};

/// Virtual Machine instance.
/// Number of addressable virtio-mmio slots (console, 2 disks, gpu, spare).
// Routable virtio-mmio slots. Matches MemoryLayout.VIRTIO_COUNT (the
// reserved address space + DTB node count): a maximal device set
// (2 disks + gpu/kbd/mouse + net + rng + p9 + balloon + snd) needs more
// than 8, so the dispatch bound must cover the full reservation.
const VIRTIO_SLOT_COUNT: u64 = 16;

/// Closed set of devices routable through the virtio-mmio aperture. The
/// `inline else` calls are monomorphized and make the shared device contract a
/// compile-time requirement without introducing a vtable.
const VirtioMmioDevice = union(enum) {
    console: *virtio.Console,
    block: *virtio.Block,
    gpu: *virtio.Gpu,
    input: *virtio.Input,
    net: *virtio.Net,
    rng: *virtio.Rng,
    balloon: *virtio.Balloon,
    snd: *virtio.Snd,
    p9: *virtio.P9,

    fn setGuestMemory(
        self: VirtioMmioDevice,
        comptime accessor: *const fn (u64, usize) ?[]u8,
    ) void {
        const memory = GuestMemory.bindGlobal(accessor);
        switch (self) {
            .balloon => |device| device.setGuestMemory(accessor),
            inline else => |device| device.setGuestMemory(memory),
        }
    }

    fn setIrqCallback(self: VirtioMmioDevice, irq: virtio.mmio.Irq) void {
        switch (self) {
            inline else => |device| device.setIrqCallback(irq),
        }
    }

    fn read(self: VirtioMmioDevice, offset: u12) u32 {
        return switch (self) {
            inline else => |device| device.read(offset),
        };
    }

    fn write(self: VirtioMmioDevice, offset: u12, value: u32) void {
        switch (self) {
            inline else => |device| device.write(offset, value),
        }
    }
};

fn SnapshotSection(
    comptime section_name: []const u8,
    comptime field_name: []const u8,
    comptime Codec: type,
) type {
    return struct {
        fn capture(machine: anytype, alloc: Allocator, builder: *snapshot.Builder) !void {
            const device: *const Codec.Device = @field(machine, field_name) orelse return;
            try Codec.append(builder, alloc, section_name, device);
        }

        fn restore(machine: anytype, alloc: Allocator, reader: *const snapshot.Reader) !void {
            const data = reader.section(section_name) orelse return;
            const device: *Codec.Device = @field(machine, field_name) orelse return;
            try Codec.decode(alloc, device, data);
        }
    };
}

/// The single source of truth for machine components persisted in snapshots.
/// Balloon and sound state intentionally reset on restore and therefore have no
/// descriptor here.
const snapshot_sections = .{
    SnapshotSection("gic", "gic_device", snapshot.GicCodec),
    SnapshotSection("icc", "icc_handler", snapshot.IccCodec),
    SnapshotSection("console", "console", snapshot.ConsoleCodec),
    SnapshotSection("blk1", "block", snapshot.BlockCodec),
    SnapshotSection("blk2", "block2", snapshot.BlockCodec),
    SnapshotSection("rng", "rng", snapshot.RngCodec),
    SnapshotSection("net", "net", snapshot.NetCodec),
    SnapshotSection("kbd", "keyboard", snapshot.InputCodec),
    SnapshotSection("mouse", "mouse", snapshot.InputCodec),
    SnapshotSection("p9", "p9", snapshot.P9Codec),
    SnapshotSection("gpu", "gpu", snapshot.GpuCodec),
};

/// Console multiport ids for the agent ports (order matches the names
/// passed to Console.init in initVirtioDevices).
const SPICE_PORT: u32 = 1; // com.redhat.spice.0
const QGA_PORT: u32 = 2; // org.qemu.guest_agent.0
const BOBRVM_AGENT_PORT: u32 = 3; // org.bobrvm.agent.0
const BOBRVM_CLIPBOARD_PORT: u32 = 4; // org.bobrvm.clipboard.0

/// A register capture/restore request executed ON the vCPU's owning
/// thread (HVF rejects cross-thread register access). The requester
/// parks the machine, posts the request, kicks the vCPU, and polls
/// `done`; the pause gate in runVcpuLoop performs the operation.
const VcpuSnapRequest = struct {
    kind: enum { capture, restore },
    state: *snapshot.VcpuState,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Per-vCPU run state for the synchronous multi-threaded loop.
const VcpuRunState = struct {
    pending_irq: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    vtimer_unmask: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by a restored secondary once its vCPU exists and its
    /// registers are applied; the restore path serializes on this so
    /// HVF's creation-index-derived MPIDR matches our CPU numbering.
    restore_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entry_point: u64 = 0,
    context_id: u64 = 0,
    thread: ?std.Thread = null,
    vcpu: ?*hypervisor.Vcpu = null,
    /// Pending snapshot register operation (see VcpuSnapRequest).
    snap_request: std.atomic.Value(?*VcpuSnapRequest) = std.atomic.Value(?*VcpuSnapRequest).init(null),

    /// WFI wait: the vCPU thread blocks here when the guest halts with no
    /// deliverable interrupt; kickCpu signals it so device IRQs from
    /// other threads wake it immediately instead of after the poll tick.
    wake_mutex: std.Io.Mutex = .init,
    wake_cond: std.Io.Condition = .init,
};

pub const Machine = struct {
    alloc: Allocator,
    config: MachineConfig,

    /// Hypervisor VM.
    hv_vm: ?*hypervisor.VM = null,

    /// VM runner (manages vCPU threads).
    runner: ?hypervisor.VMRunner = null,

    /// Guest RAM (host-mapped).
    ram: ?[]align(4096) u8 = null,

    /// Pflash CODE region (UEFI firmware, host-mapped).
    pflash_code: ?[]align(4096) u8 = null,

    /// Pflash VARS region (UEFI variables, host-mapped).
    pflash_vars: ?[]align(4096) u8 = null,

    /// CNTVOFF applied to every vCPU (guest CNTVCT_EL0 =
    /// mach_absolute_time() - vtimer_offset). Zero on a fresh boot;
    /// set by restore so the guest's monotonic clock continues from
    /// the capture point instead of jumping by the suspend gap.
    vtimer_offset: u64 = 0,

    /// Virtio console device.
    console: ?*virtio.Console = null,

    /// Typed bus registration for every active virtio-mmio slot.
    mmio_devices: [VIRTIO_SLOT_COUNT]?VirtioMmioDevice =
        .{null} ** VIRTIO_SLOT_COUNT,

    /// Virtio block device (primary, slot 1).
    block: ?*virtio.Block = null,

    /// Virtio block device (secondary, slot 2, typically ISO).
    block2: ?*virtio.Block = null,

    /// Virtio GPU device (assigned the slot after the block devices).
    gpu: ?*virtio.Gpu = null,
    gpu_slot: u8 = 0,

    /// Virtio input devices (slots after the GPU, present with it).
    keyboard: ?*virtio.Input = null,
    keyboard_slot: u8 = 0,
    mouse: ?*virtio.Input = null,
    mouse_slot: u8 = 0,

    /// Virtio network device + built-in NAT backend.
    net: ?*virtio.Net = null,
    net_slot: u8 = 0,
    nat: mininat.MiniNat = undefined,

    /// Virtio entropy device (always present; instant guest RNG seeding).
    rng: ?*virtio.Rng = null,
    rng_slot: u8 = 0,

    /// Virtio memory balloon device (always present; reclaim via MADV_FREE).
    balloon: ?*virtio.Balloon = null,
    balloon_slot: u8 = 0,

    /// Virtio sound device (opt-in, in the slot after the balloon).
    snd: ?*virtio.Snd = null,
    snd_slot: u8 = 0,

    /// Virtio 9p shared folder (present with config.shared_dir).
    p9: ?*virtio.P9 = null,
    p9_slot: u8 = 0,

    /// qemu-guest-agent channel on console port QGA_PORT
    /// ("org.qemu.guest_agent.0"). Talks to the stock distro agent.
    qga: ?*agent.Qga = null,

    /// spice-vdagent clipboard channel on console port SPICE_PORT
    /// ("com.redhat.spice.0"). Talks to the stock spice-vdagent daemon.
    vdagent: ?agent.Vdagent = null,

    /// bobrvm-native desktop integration channel on BOBRVM_AGENT_PORT.
    native_agent: ?*agent.Native = null,

    /// Per-user Wayland clipboard integration on BOBRVM_CLIPBOARD_PORT.
    wayland_agent: ?*agent.Native = null,

    /// UART device (PL011 for earlycon).
    uart: virtio.Uart = .{},

    /// Wall clock (PL031 for UEFI and Linux).
    rtc: virtio.Rtc = .{},

    /// GIC (interrupt controller).
    gic_device: ?*gic.Gic = null,

    /// ICC (CPU interface) handler.
    icc_handler: ?*icc.IccHandler = null,

    /// PCIe ECAM host bridge (for UEFI boot).
    ecam_host: ?*pci.EcamHost = null,

    /// Virtio PCI block device (for UEFI boot).
    pci_block: ?*pci.VirtioPciDevice = null,

    /// Secondary virtio PCI block device (typically the installer ISO).
    pci_block2: ?*pci.VirtioPciDevice = null,

    /// Virtio PCI GPU device (UEFI does not discover virtio-mmio displays).
    pci_gpu: ?*pci.VirtioPciDevice = null,

    /// Console output callback.
    console_output: ?*const fn ([]const u8, ?*anyopaque) void = null,
    console_userdata: ?*anyopaque = null,

    /// Frame ready callback (applied to the GPU at device init).
    frame_callback: ?*const fn (?*anyopaque) void = null,
    frame_userdata: ?*anyopaque = null,

    /// Initrd tracking (for DTB generation).
    initrd_start: u64 = 0,
    initrd_end: u64 = 0,

    /// Running state.
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Set before or during startup to prevent the vCPU loop from beginning.
    /// Embedded runtimes prepare this token before spawning the owning thread,
    /// so an immediate Stop cannot be lost before startSyncPrepared enters.
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Paused: vCPU threads park on their wake condvars instead of
    /// entering hv_vcpu_run. All guest state (RAM, registers, devices)
    /// is preserved, unlike stop.
    paused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Pending IRQ flag (set by GIC when interrupt should be injected).
    /// Per-CPU run state (allocated for vcpu_count at init).
    cpu_states: []VcpuRunState = &.{},

    /// Machine-wide lock ("big machine lock"): serializes device and GIC
    /// state across vCPU threads and host input threads.
    machine_lock: std.Io.Mutex = .init,

    pub const Error = hypervisor.Error ||
        Allocator.Error ||
        std.posix.MMapError ||
        std.Io.File.OpenError ||
        std.Io.File.ReadPositionalError ||
        std.Io.File.StatError ||
        std.Thread.SpawnError ||
        error{
            KernelTooLarge,
            InitrdTooLarge,
            FirmwareTooLarge,
            EmptyBootImage,
            RestoreFailed,
            StartCancelled,
        };

    pub fn init(alloc: Allocator, config: MachineConfig) Error!*Machine {
        log.info("initializing machine: {}MB RAM, {} vCPUs", .{
            config.ram_size / (1024 * 1024),
            config.vcpu_count,
        });

        comptime assert(@alignOf(Machine) >= @alignOf(VcpuRunState));
        const cpu_states_bytes = std.math.mul(
            usize,
            config.vcpu_count,
            @sizeOf(VcpuRunState),
        ) catch return error.OutOfMemory;
        const allocation_bytes = std.math.add(usize, @sizeOf(Machine), cpu_states_bytes) catch
            return error.OutOfMemory;
        const allocation = try alloc.alignedAlloc(u8, .of(Machine), allocation_bytes);
        errdefer alloc.free(allocation);
        const machine: *Machine = @ptrCast(allocation.ptr);
        const cpu_states_ptr: [*]VcpuRunState = @ptrCast(@alignCast(
            allocation.ptr + @sizeOf(Machine),
        ));
        const cpu_states = cpu_states_ptr[0..config.vcpu_count];

        machine.* = .{
            .alloc = alloc,
            .config = config,
            .cpu_states = cpu_states,
        };
        for (machine.cpu_states) |*state| state.* = .{};

        return machine;
    }

    pub fn deinit(self: *Machine) void {
        self.stop();
        self.mmio_devices = .{null} ** VIRTIO_SLOT_COUNT;

        if (self.console) |console| {
            console.deinit();
        }

        if (self.block) |block| {
            block.deinit();
        }

        if (self.block2) |block2| {
            block2.deinit();
        }

        if (self.gpu) |gpu_dev| {
            gpu_dev.deinit();
            self.gpu = null;
        }

        if (self.keyboard) |kbd| {
            kbd.deinit();
            self.keyboard = null;
        }

        if (self.mouse) |mouse| {
            mouse.deinit();
            self.mouse = null;
        }

        if (self.net) |net| {
            self.nat.stop();
            net.deinit();
            self.net = null;
        }

        if (self.rng) |rng_dev| {
            rng_dev.deinit();
            self.rng = null;
        }

        if (self.p9) |p9_dev| {
            p9_dev.deinit();
            self.p9 = null;
        }

        if (self.balloon) |balloon_dev| {
            balloon_dev.deinit();
            self.balloon = null;
        }

        if (self.snd) |snd_dev| {
            snd_dev.deinit();
            self.snd = null;
        }

        if (self.qga) |q| {
            q.deinit();
            self.alloc.destroy(q);
            self.qga = null;
        }

        if (self.vdagent) |*v| {
            v.deinit();
            self.vdagent = null;
        }

        if (self.native_agent) |native| {
            native.deinit();
            self.alloc.destroy(native);
            self.native_agent = null;
        }

        if (self.wayland_agent) |native| {
            native.deinit();
            self.alloc.destroy(native);
            self.wayland_agent = null;
        }

        if (self.icc_handler) |handler| {
            handler.deinit(self.alloc);
            self.icc_handler = null;
        }

        if (self.gic_device) |gic_dev| {
            gic_dev.deinit();
            self.gic_device = null;
        }

        if (self.pci_block) |pci_blk| {
            pci_blk.deinit();
            self.pci_block = null;
        }

        if (self.pci_block2) |pci_blk| {
            pci_blk.deinit();
            self.pci_block2 = null;
        }

        if (self.pci_gpu) |pci_gpu| {
            pci_gpu.deinit();
            self.pci_gpu = null;
        }

        if (self.ecam_host) |ecam| {
            ecam.deinit();
            self.ecam_host = null;
        }

        if (self.runner) |*runner| {
            runner.deinit();
        }

        // Clean up hypervisor (vCPUs then VM)
        self.cleanupHypervisor();
        const allocation_bytes = @sizeOf(Machine) + self.cpu_states.len * @sizeOf(VcpuRunState);
        self.cpu_states = &.{};

        const allocation_ptr: [*]align(@alignOf(Machine)) u8 = @ptrCast(self);
        self.alloc.free(allocation_ptr[0..allocation_bytes]);
    }

    /// Set frame ready callback (must be called before start).
    pub fn setFrameCallback(
        self: *Machine,
        callback: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.frame_callback = callback;
        self.frame_userdata = userdata;
    }

    /// Inject host input into the guest consoles. Thread-safe: buffers
    /// are drained on the vCPU thread.
    pub fn injectConsoleInput(self: *Machine, data: []const u8) void {
        self.machine_lock.lockUncancelable(global.io());
        self.uart.queueInput(data);
        self.machine_lock.unlock(global.io());
        if (self.console) |console| console.queueInput(data) catch {};
        self.kickCpu(0);
    }

    /// Update the guest-visible character-cell dimensions. PL011 has no size
    /// protocol; virtio-console reports this through its configuration space.
    pub fn resizeConsole(self: *Machine, size: console_session.Size) void {
        assert(size.columns > 0);
        assert(size.rows > 0);
        self.machine_lock.lockUncancelable(global.io());
        self.config.console_size = size;
        if (self.console) |console| console.resize(size.columns, size.rows);
        self.machine_lock.unlock(global.io());
        self.kickCpu(0);
    }

    /// Inject a keyboard event (evdev keycode). Thread-safe.
    pub fn injectKey(self: *Machine, keycode: u16, pressed: bool) void {
        const kbd = self.keyboard orelse return;
        kbd.injectKey(keycode, pressed) catch {};
        self.kickCpu(0);
    }

    /// Inject a mouse button event (evdev BTN_*). Thread-safe.
    pub fn injectMouseButton(self: *Machine, button: u16, pressed: bool) void {
        const mouse = self.mouse orelse return;
        mouse.injectButton(button, pressed) catch {};
        self.kickCpu(0);
    }

    /// Inject an absolute pointer position. Thread-safe.
    pub fn injectMousePosition(self: *Machine, x: i32, y: i32) void {
        const mouse = self.mouse orelse return;
        mouse.injectAbsolute(x, y) catch {};
        self.kickCpu(0);
    }

    /// Inject scroll wheel motion. Thread-safe.
    pub fn injectScroll(self: *Machine, dx: i32, dy: i32) void {
        const mouse = self.mouse orelse return;
        mouse.injectScroll(dx, dy) catch {};
        self.kickCpu(0);
    }

    fn vdagentSend(self: *Machine, data: []const u8) void {
        const console = self.console orelse return;
        console.queuePortInput(SPICE_PORT, data) catch {};
        self.kickCpu(0);
    }

    fn vdagentFeed(self: *Machine, data: []const u8) void {
        if (self.vdagent) |*v| v.feed(data);
    }

    /// Wire host-clipboard integration: `on_guest_clipboard` fires (on the
    /// vCPU thread) when the guest copies text; `request_host_clipboard`
    /// fires when the guest wants to paste — answer with
    /// sendHostClipboard().
    pub fn setClipboardHandlers(
        self: *Machine,
        on_guest_clipboard: *const fn ([]const u8, ?*anyopaque) void,
        request_host_clipboard: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        if (self.vdagent) |*v| {
            v.setClipboardHandlers(
                agent.vdagent.GuestClipboard.initRaw(on_guest_clipboard, userdata),
                agent.vdagent.HostClipboardRequest.initRaw(request_host_clipboard, userdata),
            );
        }
        if (self.wayland_agent) |native| {
            native.setClipboardHandlers(
                agent.native.GuestClipboard.initRaw(on_guest_clipboard, userdata),
                agent.native.HostClipboardRequest.initRaw(request_host_clipboard, userdata),
            );
        }
    }

    /// Announce a host clipboard change to the guest. Thread-safe.
    pub fn hostClipboardGrab(self: *Machine) void {
        if (self.vdagent) |*v| v.hostClipboardGrab();
        if (self.wayland_agent) |native| native.hostClipboardGrab();
    }

    /// Deliver host clipboard text (answers the guest's request).
    pub fn sendHostClipboard(self: *Machine, text: []const u8) void {
        if (self.vdagent) |*v| v.sendClipboard(text);
        if (self.wayland_agent) |native| native.sendClipboard(text);
    }

    /// Send bytes to the guest agent port (host→guest). Thread-safe.
    fn qgaSend(self: *Machine, data: []const u8) void {
        const console = self.console orelse return;
        console.queuePortInput(QGA_PORT, data) catch {};
        self.kickCpu(0);
    }

    /// Guest agent port output (guest→host); runs on the vCPU thread.
    fn qgaFeed(self: *Machine, data: []const u8) void {
        if (self.qga) |q| q.feed(data);
    }

    fn nativeAgentSend(self: *Machine, data: []const u8) void {
        const console = self.console orelse return;
        console.queuePortInput(BOBRVM_AGENT_PORT, data) catch {};
        self.kickCpu(0);
    }

    fn nativeAgentFeed(self: *Machine, data: []const u8) void {
        if (self.native_agent) |native| native.feed(data);
    }

    fn waylandAgentSend(self: *Machine, data: []const u8) void {
        const console = self.console orelse return;
        console.queuePortInput(BOBRVM_CLIPBOARD_PORT, data) catch {};
        self.kickCpu(0);
    }

    fn waylandAgentFeed(self: *Machine, data: []const u8) void {
        if (self.wayland_agent) |native| native.feed(data);
    }

    pub fn guestToolsStatus(self: *const Machine) agent.native.Status {
        if (self.native_agent) |native| {
            if (native.status() == .protocol_error) return .protocol_error;
            if (native.status() == .ready) return .ready;
        }
        if (self.wayland_agent) |native| {
            if (native.status() == .protocol_error) return .protocol_error;
            if (native.status() == .ready) return .ready;
        }
        if (self.qga) |q| if (q.isConnected()) return .ready;
        if (self.vdagent) |*v| if (v.isConnected()) return .ready;
        if (self.native_agent) |native| return native.status();
        if (self.wayland_agent) |native| return native.status();
        return .disconnected;
    }

    pub fn guestToolsCapabilities(self: *const Machine) u64 {
        var capabilities: u64 = 0;
        if (self.native_agent) |native| capabilities |= native.capabilities();
        if (self.wayland_agent) |native| capabilities |= native.capabilities();
        if (self.qga) |q| {
            if (q.isConnected()) capabilities |= agent.native.HostCapability.management;
        }
        if (self.vdagent) |*v| {
            if (v.isConnected()) capabilities |= agent.native.HostCapability.clipboard;
        }
        return capabilities;
    }

    pub fn sendFileToGuest(self: *Machine, path: []const u8) !void {
        const native = self.native_agent orelse return error.AgentUnavailable;
        if (native.capabilities() & agent.native.HostCapability.file_transfer == 0) {
            return error.AgentUnavailable;
        }
        try native.offerFile(path);
    }

    /// Ask the guest to shut down gracefully via qemu-guest-agent
    /// (requires the agent running in the guest). The guest then powers
    /// off through the normal PSCI SYSTEM_OFF path. Thread-safe.
    pub fn requestGuestShutdown(self: *Machine) void {
        if (self.qga) |q| q.shutdown("powerdown");
    }

    pub fn requestGuestReboot(self: *Machine) void {
        if (self.qga) |q| q.shutdown("reboot");
    }

    pub fn trimGuestFilesystems(self: *Machine) void {
        if (self.qga) |q| q.trimFilesystems();
    }

    pub fn guestManagementReady(self: *const Machine) bool {
        if (self.qga) |q| return q.isConnected();
        return false;
    }

    /// Host wall clock in nanoseconds (zig 0.16 moved timestamps into Io).
    fn hostRealNs() i64 {
        return @intCast(std.Io.Clock.real.now(global.io()).nanoseconds);
    }

    /// Probe guest-agent liveness (response visible via qga state/logs).
    pub fn pingGuestAgent(self: *Machine) void {
        if (self.qga) |q| {
            q.sync(@divTrunc(hostRealNs(), std.time.ns_per_ms));
            q.ping();
        }
    }

    /// Set the guest wall clock to the host's (for restore-from-disk).
    pub fn syncGuestTime(self: *Machine) void {
        if (self.qga) |q| q.setTime(hostRealNs());
    }

    /// Ask the agent for guest interface IPs (lands in qga.guest_ips).
    pub fn queryGuestIps(self: *Machine) void {
        if (self.qga) |q| q.queryNetworkInterfaces();
    }

    pub const GuestExecResult = struct {
        exit_code: i64,
        signal: ?i64,
        stdout: []u8,
        stderr: []u8,
        out_truncated: bool,
        err_truncated: bool,

        pub fn deinit(self: *GuestExecResult, alloc: Allocator) void {
            alloc.free(self.stdout);
            alloc.free(self.stderr);
        }
    };

    /// Run a program in the guest via qemu-guest-agent and wait for it
    /// to exit. Output is capped by the agent (16 MiB per stream by
    /// default) and the returned buffers are owned by the caller. The
    /// guest must allow guest-exec (automation.enable in the guest
    /// module). Watched qga requests are single-slot, so callers must
    /// not interleave this with other watched operations (snapshots).
    pub fn guestExec(
        self: *Machine,
        argv: []const []const u8,
        timeout_ms: u32,
    ) !GuestExecResult {
        const qga = self.qga orelse return error.AgentUnavailable;
        if (!qga.isConnected()) return error.AgentUnavailable;

        const spawn = try qga.exec(argv);
        try self.waitForQgaResponse(qga, spawn);
        const pid = qga.execPid() orelse return error.AgentRejected;

        var waited_ms: u32 = 0;
        while (true) {
            const poll = qga.execStatusRequest(pid);
            try self.waitForQgaResponse(qga, poll);
            const result = qga.execResult();
            if (result.status.exited) {
                const stdout_copy = try self.alloc.dupe(u8, result.out);
                errdefer self.alloc.free(stdout_copy);
                const stderr_copy = try self.alloc.dupe(u8, result.err);
                return .{
                    .exit_code = result.status.exit_code orelse -1,
                    .signal = result.status.signal,
                    .stdout = stdout_copy,
                    .stderr = stderr_copy,
                    .out_truncated = result.status.out_truncated,
                    .err_truncated = result.status.err_truncated,
                };
            }
            if (waited_ms >= timeout_ms) return error.ExecTimeout;
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = 20 * std.time.ns_per_ms },
                .clock = .awake,
            }, global.io()) catch {};
            waited_ms += 20;
        }
    }

    /// Request a live guest display resolution change (host window resized).
    /// Thread-safe: takes the machine lock, which serializes against all GPU
    /// MMIO/queue processing on the vCPU thread. Lock order (machine_lock ->
    /// scanout_mutex -> GIC via the irq callback) matches handleMmio's.
    pub fn requestDisplayResize(self: *Machine, width: u32, height: u32) void {
        const gpu = self.gpu orelse return;
        log.info("display resize requested: {}x{}", .{ width, height });
        self.machine_lock.lockUncancelable(global.io());
        gpu.resizeDisplay(width, height);
        self.machine_lock.unlock(global.io());
        // Wake the guest from WFI so the config-change IRQ lands promptly.
        self.kickCpu(0);
    }

    /// Set console output callback.
    pub fn setConsoleOutput(
        self: *Machine,
        callback: *const fn ([]const u8, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        self.console_output = callback;
        self.console_userdata = userdata;
    }

    /// Start the machine.
    pub fn start(self: *Machine) Error!void {
        if (self.running.load(.acquire)) return;

        log.info("starting machine", .{});

        // Create hypervisor VM
        self.hv_vm = try hypervisor.VM.create(self.alloc);
        errdefer self.cleanupHypervisor();

        const vm = self.hv_vm.?;

        // Map pflash regions if firmware boot
        if (self.config.isFirmwareBoot()) {
            try self.mapPflashRegions(vm);
            try self.loadFirmware();
        }

        // Map guest RAM
        try self.mapGuestRam(vm);
        log.debug("mapped RAM: 0x{x} - 0x{x}", .{
            MemoryLayout.RAM_BASE,
            MemoryLayout.RAM_BASE + self.config.ram_size,
        });

        // Load kernel/initrd/DTB only when booting fresh — a restore
        // overwrites all of RAM from the suspend image anyway.
        if (self.config.restore_path == null) {
            // Generate and load DTB
            try self.generateDtb();
        }

        // Initialize GIC (interrupt controller)
        try self.initGic();

        // Initialize virtio devices
        try self.initVirtioDevices();

        // Set current machine for guest memory access (used by vCPU threads)
        current_machine = self;

        // Create runner
        self.runner = hypervisor.VMRunner.init(self.alloc, vm);

        // Register MMIO handlers
        try self.registerMmioHandlers();

        // Add vCPU slots - vCPUs will be created on their own threads
        // (Apple Hypervisor requires hv_vcpu_create on the same thread as hv_vcpu_run)
        for (0..self.config.vcpu_count) |_| {
            try self.runner.?.addVcpuSlot(vcpuSetupCallback, self);
        }

        // Start execution (vCPUs created on their threads)
        try self.runner.?.start();

        self.running.store(true, .release);
        log.info("machine started", .{});
    }

    /// Callback to set up vCPU initial state.
    /// Called on each vCPU's thread after creation.
    fn vcpuSetupCallback(vcpu: *hypervisor.Vcpu, id: u32, userdata: ?*anyopaque) hypervisor.Vcpu.Error!void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        try self.setupVcpuState(vcpu, id);
    }

    /// Clean up hypervisor resources.
    /// VM.destroy() handles vCPU cleanup internally.
    fn cleanupHypervisor(self: *Machine) void {
        // Destroy the VM (this also destroys vCPUs and unmaps memory)
        if (self.hv_vm) |vm| {
            vm.destroy();
            self.hv_vm = null;
        }

        self.ram = null;
    }

    /// Stop the machine.
    /// Async-signal-safe stop request: only an atomic store and the
    /// hv_vcpus_exit syscall — no locks, no allocation. Safe to call from
    /// a signal handler; the vCPU loops observe running=false and unwind
    /// (WFI-halted CPUs wake within their 1ms condvar timeout).
    pub fn requestStop(self: *Machine) void {
        self.stop_requested.store(true, .release);
        self.running.store(false, .release);
        for (self.cpu_states) |*state| {
            if (state.vcpu) |v| v.forceExit() catch {};
        }
    }

    /// True once startup (including any restore) has finished and the
    /// vCPUs are entering the run loop. Used to time warm restore.
    pub fn isRunning(self: *const Machine) bool {
        return self.running.load(.acquire);
    }

    pub fn stop(self: *Machine) void {
        self.stop_requested.store(true, .release);
        if (!self.running.load(.acquire)) return;

        log.info("stopping machine", .{});

        if (self.runner) |*runner| {
            runner.stop();
        }

        self.running.store(false, .release);

        // Kick every sync-loop vCPU out of hv_vcpu_run and wake any that
        // are WFI-halted on the condvar so they observe running=false.
        for (self.cpu_states) |*state| {
            state.wake_mutex.lockUncancelable(global.io());
            state.wake_cond.signal(global.io());
            state.wake_mutex.unlock(global.io());
            if (state.vcpu) |v| v.forceExit() catch {};
        }

        log.info("machine stop requested", .{});
    }

    /// Freeze the guest in place: vCPUs are kicked out of hv_vcpu_run and
    /// park on their wake condvars; RAM, registers and device state stay
    /// intact. Thread-safe (atomics + syscalls only). Guest wall-clock
    /// time keeps advancing while paused (CNTVCT is host-time based), so
    /// the guest sees a time jump on resume.
    pub fn pause(self: *Machine) void {
        if (!self.running.load(.acquire)) return;
        if (self.paused.swap(true, .acq_rel)) return;
        log.info("pausing machine", .{});
        for (self.cpu_states) |*state| {
            if (state.vcpu) |v| v.forceExit() catch {};
        }
    }

    /// Resume a paused guest exactly where it stopped. Thread-safe.
    pub fn unpause(self: *Machine) void {
        if (!self.paused.swap(false, .acq_rel)) return;
        log.info("resuming machine", .{});
        for (self.cpu_states) |*state| {
            state.wake_mutex.lockUncancelable(global.io());
            state.wake_cond.signal(global.io());
            state.wake_mutex.unlock(global.io());
        }
    }

    /// Run one register capture/restore on a vCPU's owning thread (the
    /// machine must be paused so the thread is parked at the gate).
    fn runVcpuSnapOp(self: *Machine, cpu_id: u8, req: *VcpuSnapRequest) !void {
        const state = &self.cpu_states[cpu_id];
        if (state.vcpu == null) return error.VcpuNotRunning;
        state.snap_request.store(req, .release);
        state.wake_mutex.lockUncancelable(global.io());
        state.wake_cond.signal(global.io());
        state.wake_mutex.unlock(global.io());
        // Poll for completion (bounded: the gate services within 50ms).
        var waited_ms: u32 = 0;
        while (!req.done.load(.acquire)) {
            if (waited_ms > 2000) return error.Timeout;
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms },
                .clock = .awake,
            }, global.io()) catch {};
            waited_ms += 2;
        }
        if (req.failed.load(.acquire)) return error.SnapshotOpFailed;
    }

    /// Serialize all machine state except guest RAM. The machine must be
    /// paused. Caller owns the returned bytes.
    pub fn captureState(self: *Machine, alloc: Allocator) ![]u8 {
        if (!self.paused.load(.acquire)) return error.NotPaused;

        var builder = try snapshot.Builder.init(alloc);
        defer builder.deinit();

        // vCPUs (only started ones; secondary CPUs may be offline).
        for (self.cpu_states, 0..) |*state, i| {
            if (state.vcpu == null or !state.started.load(.acquire)) continue;
            var vstate = snapshot.VcpuState{};
            var req = VcpuSnapRequest{ .kind = .capture, .state = &vstate };
            try self.runVcpuSnapOp(@intCast(i), &req);
            var name_buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "vcpu{d}", .{i}) catch unreachable;
            try builder.section(name, std.mem.asBytes(&vstate));
        }

        inline for (snapshot_sections) |Section| {
            try Section.capture(self, alloc, &builder);
        }

        // Guest virtual counter at capture, so restore can resume the
        // guest's monotonic clock exactly where it stopped.
        var vtimer_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &vtimer_bytes, machTicks() -% self.vtimer_offset, .little);
        try builder.section("vtimer", &vtimer_bytes);

        // UEFI variable store (firmware boots): the mapping is not part
        // of guest RAM, so vars written since boot would otherwise be
        // lost on restore. Trailing erased flash (0xFF) is trimmed.
        if (self.pflash_vars) |vars| {
            try builder.section("pflash_vars", vars[0..trimErasedFlash(vars)]);
        }

        return try builder.finish();
    }

    extern "c" fn mach_absolute_time() u64;

    /// Host tick counter in CNTVCT units (Apple Silicon's
    /// mach_absolute_time is the physical counter).
    fn machTicks() u64 {
        return mach_absolute_time();
    }

    /// Length of the flash content up to the last programmed byte;
    /// everything after reads back as erased (0xFF).
    fn trimErasedFlash(flash: []const u8) usize {
        var len = flash.len;
        while (len > 0 and flash[len - 1] == 0xFF) len -= 1;
        return len;
    }

    /// Apply a captured state to a freshly-initialized, paused machine
    /// whose vCPU threads are parked at the gate (RAM is restored
    /// separately by the suspend layer before this).
    pub fn applyState(self: *Machine, alloc: Allocator, bytes: []const u8) !void {
        if (!self.paused.load(.acquire)) return error.NotPaused;
        const reader = try snapshot.Reader.init(bytes);

        for (self.cpu_states, 0..) |*state, i| {
            var name_buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "vcpu{d}", .{i}) catch unreachable;
            const data = reader.section(name) orelse continue;
            if (data.len != @sizeOf(snapshot.VcpuState)) return error.Corrupt;
            if (state.vcpu == null) return error.VcpuNotRunning;
            var vstate: snapshot.VcpuState = undefined;
            @memcpy(std.mem.asBytes(&vstate), data);
            var req = VcpuSnapRequest{ .kind = .restore, .state = &vstate };
            try self.runVcpuSnapOp(@intCast(i), &req);
        }

        inline for (snapshot_sections) |Section| {
            try Section.restore(self, self.alloc, &reader);
        }
        _ = alloc;
    }

    /// Take a live snapshot: freeze, write the suspend image plus
    /// copy-on-write clones of every writable disk into `dir` (instant
    /// on APFS via clonefile), then RESUME — the VM keeps running.
    /// Revert later with --restore <dir>.
    pub fn snapshotTo(self: *Machine, dir: []const u8) !void {
        const io = global.io();
        std.Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        self.pause();
        defer self.unpause();

        var path_buf: [1024]u8 = undefined;
        const state_path = try std.fmt.bufPrint(&path_buf, "{s}/state.img", .{dir});
        try self.suspendToDisk(state_path);

        // Clone writable disks (quiescent: the machine is paused and all
        // blk writes are synchronous on the parked vCPU thread).
        var meta = std.ArrayListUnmanaged(u8).empty;
        defer meta.deinit(self.alloc);
        try meta.appendSlice(self.alloc, "{\"disks\":[");
        var disk_idx: u32 = 0;
        const candidates = [_]struct { path: ?[]const u8, writable: bool }{
            .{ .path = self.config.disk_path, .writable = !self.config.disk_read_only },
            .{ .path = self.config.disk2_path, .writable = !self.config.disk2_read_only },
        };
        for (candidates) |cand| {
            const disk_path = cand.path orelse continue;
            if (!cand.writable) continue;
            var name_buf: [64]u8 = undefined;
            const copy_name = std.fmt.bufPrint(&name_buf, "disk{d}.raw", .{disk_idx}) catch unreachable;
            var copy_buf: [1024]u8 = undefined;
            const copy_path = try std.fmt.bufPrint(&copy_buf, "{s}/{s}", .{ dir, copy_name });
            try cloneFile(self.alloc, disk_path, copy_path);
            if (disk_idx > 0) try meta.append(self.alloc, ',');
            try meta.appendSlice(self.alloc, "{\"orig\":\"");
            try meta.appendSlice(self.alloc, disk_path);
            try meta.appendSlice(self.alloc, "\",\"copy\":\"");
            try meta.appendSlice(self.alloc, copy_name);
            try meta.appendSlice(self.alloc, "\"}");
            disk_idx += 1;
        }
        try meta.appendSlice(self.alloc, "]}");

        const meta_path = try std.fmt.bufPrint(&path_buf, "{s}/meta.json", .{dir});
        const meta_file = try std.Io.Dir.cwd().createFile(io, meta_path, .{});
        defer meta_file.close(io);
        try meta_file.writePositionalAll(io, meta.items, 0);

        log.info("snapshot written to {s} ({} disk clones)", .{ dir, disk_idx });
    }

    /// Capture a filesystem-consistent snapshot using qemu-guest-agent.
    /// Thaw is attempted after every capture outcome once vCPUs are running.
    pub fn snapshotToQuiesced(self: *Machine, dir: []const u8) !void {
        const qga = self.qga orelse return error.AgentUnavailable;
        if (!qga.isConnected()) return error.AgentUnavailable;

        const freeze_request = qga.freezeFilesystems();
        defer self.thawAfterSnapshot(qga);
        try self.waitForQgaResponse(qga, freeze_request);
        try self.snapshotTo(dir);
    }

    fn thawAfterSnapshot(self: *Machine, qga: *agent.Qga) void {
        const thaw_request = qga.thawFilesystems();
        self.waitForQgaResponse(qga, thaw_request) catch |err| {
            log.err("failed to thaw guest filesystems after snapshot: {}", .{err});
        };
    }

    fn waitForQgaResponse(
        self: *Machine,
        qga: *agent.Qga,
        request: agent.Qga.WatchedRequest,
    ) !void {
        var waited_ms: u32 = 0;
        while (!qga.watchedResponseReady(request)) {
            if (waited_ms >= 5000) return error.AgentTimeout;
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = 2 * std.time.ns_per_ms },
                .clock = .awake,
            }, global.io()) catch {};
            waited_ms += 2;
        }
        _ = self;
        if (qga.watchedResponseFailed(request)) return error.AgentRejected;
    }

    /// Copy-on-write file clone (instant on APFS); replaces dst.
    pub fn cloneFile(alloc: Allocator, src: []const u8, dst: []const u8) !void {
        const src_z = try alloc.dupeZ(u8, src);
        defer alloc.free(src_z);
        const dst_z = try alloc.dupeZ(u8, dst);
        defer alloc.free(dst_z);
        _ = std.c.unlink(dst_z.ptr);
        if (clonefile(src_z.ptr, dst_z.ptr, 0) != 0) return error.CloneFailed;
    }

    /// Suspend-to-disk image magic.
    const SUSPEND_MAGIC = "BBRVSUSP";
    const SUSPEND_VERSION: u32 = 1;
    const RAM_CHUNK: usize = 64 * 1024;

    /// Write the paused machine (device/vCPU state + RAM) to a file.
    /// Pauses the machine if it isn't already; caller decides whether to
    /// unpause or shut down afterwards. Zero RAM chunks become file
    /// holes, so the image is roughly the guest's working set on APFS.
    pub fn suspendToDisk(self: *Machine, path: []const u8) !void {
        const was_paused = self.paused.load(.acquire);
        if (!was_paused) self.pause();
        errdefer if (!was_paused) self.unpause();

        const state = try self.captureState(self.alloc);
        defer self.alloc.free(state);
        const ram = self.ram orelse return error.NoRam;

        const io = global.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var header: [8 + 4 + 8 + 8]u8 = undefined;
        @memcpy(header[0..8], SUSPEND_MAGIC);
        std.mem.writeInt(u32, header[8..12], SUSPEND_VERSION, .little);
        std.mem.writeInt(u64, header[12..20], state.len, .little);
        std.mem.writeInt(u64, header[20..28], ram.len, .little);
        try file.writePositionalAll(io, &header, 0);
        try file.writePositionalAll(io, state, header.len);

        // RAM: skip all-zero chunks (they read back as zeros from holes).
        const ram_base: u64 = header.len + state.len;
        var off: usize = 0;
        var written_bytes: usize = 0;
        while (off < ram.len) : (off += RAM_CHUNK) {
            const chunk = ram[off..@min(off + RAM_CHUNK, ram.len)];
            if (std.mem.allEqual(u8, chunk, 0)) continue;
            try file.writePositionalAll(io, chunk, ram_base + off);
            written_bytes += chunk.len;
        }
        // Pin the file's logical size even if the tail was a hole.
        if (std.c.ftruncate(file.handle, @intCast(ram_base + ram.len)) != 0) {
            return error.Truncate;
        }
        log.info("suspended to {s} ({} KiB state, {} MiB RAM written)", .{
            path, state.len / 1024, written_bytes / (1024 * 1024),
        });
    }

    /// Restore state from a suspend image. Runs on vCPU 0's owning
    /// thread (called from startSync before the run loop), so its
    /// registers apply directly; captured secondaries are spawned onto
    /// their own threads.
    fn restoreFromFile(self: *Machine, path: []const u8, vcpu: *hypervisor.Vcpu) Error!void {
        const io = global.io();
        const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch {
            log.err("cannot open suspend image {s}", .{path});
            return Error.RestoreFailed;
        };
        defer file.close(io);

        self.restoreFromFileInner(file, vcpu) catch |err| {
            log.err("restore from {s} failed: {}", .{ path, err });
            return Error.RestoreFailed;
        };
        log.info("restored machine state from {s}", .{path});
    }

    fn restoreFromFileInner(self: *Machine, file: std.Io.File, vcpu: *hypervisor.Vcpu) !void {
        const io = global.io();
        var header: [28]u8 = undefined;
        const got = try file.readPositionalAll(io, &header, 0);
        if (got != header.len or !std.mem.eql(u8, header[0..8], SUSPEND_MAGIC)) {
            return error.BadImage;
        }
        if (std.mem.readInt(u32, header[8..12], .little) != SUSPEND_VERSION) {
            return error.BadVersion;
        }
        const state_len = std.mem.readInt(u64, header[12..20], .little);
        const ram_len = std.mem.readInt(u64, header[20..28], .little);
        const ram = self.ram orelse return error.NoRam;
        if (ram_len != ram.len) return error.RamSizeMismatch;

        const state = try self.alloc.alloc(u8, @intCast(state_len));
        defer self.alloc.free(state);
        if (try file.readPositionalAll(io, state, header.len) != state.len) {
            return error.BadImage;
        }

        // RAM. The guest mapping is freshly created (all zeros) and
        // suspendToDisk writes zero chunks as file holes, so only the
        // image's data regions need to be read: restore cost then scales
        // with the guest's written working set, not with configured RAM.
        // Fall back to reading the full logical size when the filesystem
        // can't enumerate holes.
        const ram_base: u64 = header.len + state_len;
        if (!readRamDataRegions(file, ram, ram_base)) {
            var off: usize = 0;
            while (off < ram.len) : (off += RAM_CHUNK) {
                const chunk = ram[off..@min(off + RAM_CHUNK, ram.len)];
                const n = try file.readPositionalAll(io, chunk, ram_base + off);
                if (n < chunk.len) @memset(chunk[n..], 0);
            }
        }

        // Devices + GIC.
        const reader = try snapshot.Reader.init(state);

        // Guest clock: resume CNTVCT from the capture point so the
        // guest's monotonic time never jumps (or runs backward after a
        // host reboot). Must be computed before secondaries spawn —
        // they apply the same offset on their own threads.
        if (reader.section("vtimer")) |data| {
            if (data.len != 8) return error.BadImage;
            const guest_counter = std.mem.readInt(u64, data[0..8], .little);
            self.vtimer_offset = machTicks() -% guest_counter;
            try vcpu.setVTimerOffset(self.vtimer_offset);
        }

        // UEFI variable store: what the guest programmed since boot,
        // with the trimmed tail reading back as erased flash.
        if (reader.section("pflash_vars")) |data| {
            const vars = self.pflash_vars orelse return error.BadImage;
            if (data.len > vars.len) return error.BadImage;
            @memcpy(vars[0..data.len], data);
            @memset(vars[data.len..], 0xFF);
        }

        // Secondary vCPUs: each captured CPU gets its own thread (HVF
        // requires create+run on the owning thread) which applies its
        // registers and then waits for the machine to start. CPUs the
        // image doesn't carry stay offline, matching the captured
        // guest. An image with MORE CPUs than this machine cannot
        // restore faithfully.
        for (1..self.cpu_states.len) |i| {
            var name_buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "vcpu{d}", .{i}) catch unreachable;
            const data = reader.section(name) orelse continue;
            if (data.len != @sizeOf(snapshot.VcpuState)) return error.BadImage;
            try self.spawnRestoredSecondary(@intCast(i), data);
        }
        {
            var name_buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "vcpu{d}", .{self.cpu_states.len}) catch unreachable;
            if (reader.section(name)) |_| return error.VcpuCountMismatch;
        }

        inline for (snapshot_sections) |Section| {
            try Section.restore(self, self.alloc, &reader);
        }

        // vCPU 0 registers — we are its owning thread.
        const vdata = reader.section("vcpu0") orelse return error.BadImage;
        if (vdata.len != @sizeOf(snapshot.VcpuState)) return error.BadImage;
        var vstate: snapshot.VcpuState = undefined;
        @memcpy(std.mem.asBytes(&vstate), vdata);
        try snapshot.restoreVcpu(vcpu, &vstate);
    }

    /// Register state handed to a restored secondary's thread; the
    /// thread owns and frees it (the suspend-image buffer it was
    /// copied from dies with restoreFromFileInner).
    const SecondaryRestore = struct {
        vstate: snapshot.VcpuState,
    };

    /// Spawn one restored secondary vCPU and wait until its vCPU
    /// exists with registers applied. The wait serializes creations so
    /// HVF's creation-index-derived MPIDR matches our CPU numbering.
    fn spawnRestoredSecondary(self: *Machine, cpu_id: u8, data: []const u8) !void {
        const state = &self.cpu_states[cpu_id];
        assert(!state.started.load(.acquire));
        assert(data.len == @sizeOf(snapshot.VcpuState));

        const boot = try self.alloc.create(SecondaryRestore);
        @memcpy(std.mem.asBytes(&boot.vstate), data);

        state.restore_ready.store(false, .release);
        state.started.store(true, .release);
        state.thread = std.Thread.spawn(
            .{},
            restoredSecondaryVcpuMain,
            .{ self, cpu_id, boot },
        ) catch {
            state.started.store(false, .release);
            self.alloc.destroy(boot);
            return error.RestoreFailed;
        };

        var waited_ms: u32 = 0;
        while (!state.restore_ready.load(.acquire)) {
            if (!state.started.load(.acquire)) return error.RestoreFailed;
            if (waited_ms >= 2000) return error.RestoreFailed;
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = std.time.ns_per_ms },
                .clock = .awake,
            }, global.io()) catch {};
            waited_ms += 1;
        }
    }

    /// Entry point for a restored secondary vCPU thread: create the
    /// vCPU here (owning thread), apply the captured registers, then
    /// hold until the machine starts and enter the normal run loop.
    fn restoredSecondaryVcpuMain(self: *Machine, cpu_id: u8, boot: *SecondaryRestore) void {
        const state = &self.cpu_states[cpu_id];
        defer self.alloc.destroy(boot);
        const vm = self.hv_vm orelse {
            state.started.store(false, .release);
            return;
        };

        const vcpu = vm.createVcpu() catch |err| {
            log.err("cpu {}: restored vCPU creation failed: {}", .{ cpu_id, err });
            state.started.store(false, .release);
            return;
        };
        setupVcpuFeatures(vcpu) catch |err| {
            log.err("cpu {}: restored vCPU feature setup failed: {}", .{ cpu_id, err });
            state.started.store(false, .release);
            return;
        };
        snapshot.restoreVcpu(vcpu, &boot.vstate) catch |err| {
            log.err("cpu {}: register restore failed: {}", .{ cpu_id, err });
            state.started.store(false, .release);
            return;
        };
        // The clock offset was computed before this thread spawned.
        if (self.vtimer_offset != 0) {
            vcpu.setVTimerOffset(self.vtimer_offset) catch |err| {
                log.err("cpu {}: vtimer offset failed: {}", .{ cpu_id, err });
                state.started.store(false, .release);
                return;
            };
        }
        state.vcpu = vcpu;
        state.restore_ready.store(true, .release);

        // The machine starts running after restoreFromFile returns; a
        // failed startup sets stop_requested so this never leaks.
        while (!self.running.load(.acquire)) {
            if (self.stop_requested.load(.acquire)) {
                state.started.store(false, .release);
                return;
            }
            std.Io.Clock.Duration.sleep(.{
                .raw = .{ .nanoseconds = 200 * std.time.ns_per_us },
                .clock = .awake,
            }, global.io()) catch {};
        }

        self.runVcpuLoop(vcpu, cpu_id) catch |err| {
            log.warn("cpu {}: restored vCPU loop failed: {}", .{ cpu_id, err });
        };
        state.started.store(false, .release);
    }

    /// Darwin lseek whence values for sparse-file traversal. This file
    /// is Hypervisor.framework-only, so Darwin's numbering applies —
    /// note Linux numbers the same pair the other way around.
    const SEEK_HOLE: c_int = 3;
    const SEEK_DATA: c_int = 4;

    /// Read only the data regions of a sparse suspend image into `ram`.
    /// Requires `ram` to be all zeros (a fresh guest mapping): skipped
    /// holes are never written. Returns false when the filesystem cannot
    /// enumerate holes or a read fails mid-walk; the caller's full-read
    /// fallback overwrites everything, so a partial walk is harmless.
    fn readRamDataRegions(file: std.Io.File, ram: []u8, ram_base: u64) bool {
        if (std.c.getenv("BOBRVM_NO_SPARSE_RESTORE") != null) return false;
        const io = global.io();
        const ram_end: u64 = ram_base + ram.len;
        var pos: u64 = ram_base;
        while (pos < ram_end) {
            const data_rc = std.c.lseek(file.handle, @intCast(pos), SEEK_DATA);
            if (data_rc < 0) {
                // ENXIO: no data at or after pos — the tail is one hole.
                return std.c.errno(@as(c_int, -1)) == .NXIO;
            }
            const data_start: u64 = @intCast(data_rc);
            if (data_start >= ram_end) return true;
            const hole_rc = std.c.lseek(file.handle, @intCast(data_start), SEEK_HOLE);
            if (hole_rc < 0) return false;
            const data_end: u64 = @min(@as(u64, @intCast(hole_rc)), ram_end);
            assert(data_end > data_start);
            const dst = ram[@intCast(data_start - ram_base)..@intCast(data_end - ram_base)];
            const n = file.readPositionalAll(io, dst, data_start) catch return false;
            if (n != dst.len) return false;
            pos = data_end;
        }
        return true;
    }

    /// Kick a specific vCPU to wake it from WFI/sleep.
    /// Injects an IRQ and forces an exit from hv_vcpu_run.
    pub fn kickVcpu(self: *Machine, vcpu_id: u32) void {
        if (self.runner) |*runner| {
            runner.kickVcpu(vcpu_id);
        }
    }

    /// Force all vCPUs to exit from hv_vcpu_run (for debugging).
    pub fn forceExitAllVcpus(self: *Machine) void {
        if (self.runner) |*runner| {
            runner.forceExitAll();
        }
    }

    /// Start and run the machine synchronously on the current thread.
    /// vCPU is created and run on the same thread (required by Apple Hypervisor).
    pub fn startSync(self: *Machine) Error!void {
        self.prepareStart();
        return self.startSyncPrepared();
    }

    /// Perform every startup step through primary vCPU register setup, then return.
    pub fn benchmarkStartupSync(self: *Machine) Error!void {
        self.prepareStart();
        return self.startSyncPreparedMode(.setup_only);
    }

    pub fn prepareStart(self: *Machine) void {
        assert(!self.running.load(.acquire));
        assert(self.hv_vm == null);
        self.stop_requested.store(false, .release);
        self.paused.store(false, .release);
    }

    pub fn startSyncPrepared(self: *Machine) Error!void {
        return self.startSyncPreparedMode(.run);
    }

    const SyncStartMode = enum { run, setup_only };

    fn startSyncPreparedMode(self: *Machine, mode: SyncStartMode) Error!void {
        assert(!self.running.load(.acquire));
        assert(self.hv_vm == null);
        try self.checkStartupCancelled();
        log.info("starting machine (sync)", .{});

        // Create hypervisor VM
        self.hv_vm = try hypervisor.VM.create(self.alloc);
        errdefer self.cleanupHypervisor();
        try self.checkStartupCancelled();

        const vm = self.hv_vm.?;

        // Map pflash regions if firmware boot
        log.debug("isFirmwareBoot={}, firmware_path={?s}", .{
            self.config.isFirmwareBoot(),
            self.config.firmware_path,
        });
        if (self.config.isFirmwareBoot()) {
            try self.mapPflashRegions(vm);
            try self.loadFirmware();
            try self.checkStartupCancelled();
        }

        // Map guest RAM
        try self.mapGuestRam(vm);
        try self.checkStartupCancelled();
        log.debug("mapped RAM: 0x{x} - 0x{x}", .{
            MemoryLayout.RAM_BASE,
            MemoryLayout.RAM_BASE + self.config.ram_size,
        });

        // Load kernel/initrd/DTB only when booting fresh — a restore
        // overwrites all of RAM from the suspend image anyway.
        if (self.config.restore_path == null) {
            // Generate and load DTB
            try self.generateDtb();
            try self.checkStartupCancelled();
        }

        // Initialize GIC (interrupt controller)
        try self.initGic();
        try self.checkStartupCancelled();

        // Initialize virtio devices
        try self.initVirtioDevices();
        try self.checkStartupCancelled();

        // Set current machine for guest memory access
        current_machine = self;

        // Create vCPU on THIS thread (required by Apple Hypervisor)
        const vcpu = try vm.createVcpu();
        log.debug("created vCPU on main thread", .{});

        // Set up initial vCPU state (as vCPU 0 - the boot CPU)
        try self.setupVcpuState(vcpu, 0);
        self.cpu_states[0].vcpu = vcpu;
        self.cpu_states[0].started.store(true, .release);

        // Restoring: we ARE vCPU 0's owning thread here, so registers,
        // RAM, and device state can be applied directly before running.
        // Restored secondaries wait on running/stop_requested, so a
        // failed restore must raise stop and reap them before erroring.
        if (self.config.restore_path) |path| {
            self.restoreFromFile(path, vcpu) catch |err| {
                self.stop_requested.store(true, .release);
                self.joinSecondaryVcpus();
                return err;
            };
        }
        try self.checkStartupCancelled();

        self.running.store(true, .release);
        log.info("machine started, running vCPU loop", .{});

        if (mode == .setup_only) {
            self.running.store(false, .release);
            current_machine = null;
            return;
        }

        // Run vCPU loop on this thread
        self.runVcpuLoop(vcpu, 0) catch |err| {
            log.err("vCPU loop error: {}", .{err});
        };

        self.running.store(false, .release);
        self.joinSecondaryVcpus();
        current_machine = null;
        log.info("machine stopped", .{});
    }

    fn checkStartupCancelled(self: *const Machine) error{StartCancelled}!void {
        assert(!self.running.load(.acquire));
        assert(self.cpu_states.len == self.config.vcpu_count);
        if (self.stop_requested.load(.acquire)) return error.StartCancelled;
    }

    fn runVcpuLoop(self: *Machine, vcpu: *hypervisor.Vcpu, cpu_id: u8) !void {
        var exit_count: u64 = 0;
        const state = &self.cpu_states[cpu_id];

        while (self.running.load(.acquire)) {
            // Pause gate: park until unpaused (or stopping). The 50ms
            // timeout is only a missed-wakeup backstop — unpause()/stop()
            // signal the condvar for prompt wakeups. Snapshot register
            // ops are serviced here: this is the vCPU's owning thread.
            while (self.paused.load(.acquire) and self.running.load(.acquire)) {
                if (state.snap_request.swap(null, .acq_rel)) |req| {
                    const result = switch (req.kind) {
                        .capture => snapshot.captureVcpu(vcpu, req.state),
                        .restore => snapshot.restoreVcpu(vcpu, req.state),
                    };
                    if (result) |_| {} else |err| {
                        log.err("vCPU {} snapshot op failed: {}", .{ cpu_id, err });
                        req.failed.store(true, .release);
                    }
                    req.done.store(true, .release);
                    continue;
                }
                state.wake_mutex.lockUncancelable(global.io());
                thread_compat.waitTimeout(&state.wake_cond, global.io(), &state.wake_mutex, .{
                    .duration = .{ .raw = .{ .nanoseconds = 50_000_000 }, .clock = .awake },
                }) catch {};
                state.wake_mutex.unlock(global.io());
            }
            if (!self.running.load(.acquire)) break;

            // Check for pending IRQ before running
            // Drive the IRQ line from GIC state on every iteration: HVF
            // clears the pending interrupt at each hv_vcpu_run entry, so a
            // one-shot assert loses interrupts the guest had masked.
            _ = state.pending_irq.swap(false, .acq_rel);
            self.machine_lock.lockUncancelable(global.io());
            const irq_line = if (self.gic_device) |g| g.hasDeliverableIrq(cpu_id) else false;
            self.machine_lock.unlock(global.io());
            try vcpu.setPendingInterrupt(.irq, irq_line);

            // Unmask the HVF vtimer once the guest has EOI'd PPI 27.
            if (state.vtimer_unmask.swap(false, .acq_rel)) {
                try vcpu.setVTimerMask(false);
            }

            // Poll host-input-fed queues (vCPU 0 only; MMIO kicks from any
            // CPU are processed inline under the machine lock).
            if (cpu_id == 0) {
                self.machine_lock.lockUncancelable(global.io());
                if (self.console) |console| {
                    console.pollTransmit();
                    console.pollReceive();
                }
                if (self.keyboard) |kbd| kbd.pollEvents();
                if (self.mouse) |mouse| mouse.pollEvents();
                if (self.net) |net| net.poll();
                self.machine_lock.unlock(global.io());
            }

            const exit_info = try vcpu.run();
            exit_count += 1;

            switch (exit_info.reason) {
                .canceled => {
                    // hv_vcpus_exit kick: either a cross-thread IRQ kick
                    // (handled by the flag checks at the top of the loop)
                    // or shutdown (running=false ends the loop).
                    continue;
                },
                .exception => {
                    const ec = exit_info.exceptionClass();
                    switch (ec) {
                        .data_abort_lower, .data_abort_same => {
                            self.machine_lock.lockUncancelable(global.io());
                            defer self.machine_lock.unlock(global.io());
                            try self.handleMmio(vcpu, exit_info);
                        },
                        .wf_trapped => {
                            // Poll console/input queues while halted
                            if (cpu_id == 0) {
                                self.machine_lock.lockUncancelable(global.io());
                                if (self.console) |console| {
                                    console.pollTransmit();
                                    console.pollReceive();
                                }
                                if (self.keyboard) |kbd| kbd.pollEvents();
                                if (self.mouse) |mouse| mouse.pollEvents();
                                self.machine_lock.unlock(global.io());
                            }
                            try vcpu.advancePC(exit_info);
                            // Wait for an interrupt instead of busy-spinning.
                            // Skip the wait entirely if one is already
                            // deliverable; otherwise block until kickCpu
                            // signals or the 1ms timer-poll cap elapses.
                            self.machine_lock.lockUncancelable(global.io());
                            const has_irq = if (self.gic_device) |g| g.hasDeliverableIrq(cpu_id) else false;
                            self.machine_lock.unlock(global.io());
                            if (!has_irq and !state.pending_irq.load(.acquire)) {
                                state.wake_mutex.lockUncancelable(global.io());
                                thread_compat.waitTimeout(&state.wake_cond, global.io(), &state.wake_mutex, .{
                                    .duration = .{ .raw = .{ .nanoseconds = 1_000_000 }, .clock = .awake },
                                }) catch {};
                                state.wake_mutex.unlock(global.io());
                            }
                        },
                        .hvc_aarch64, .smc_aarch64 => {
                            self.machine_lock.lockUncancelable(global.io());
                            defer self.machine_lock.unlock(global.io());
                            try self.handlePsci(vcpu, exit_info);
                        },
                        .msr_mrs_system => {
                            self.machine_lock.lockUncancelable(global.io());
                            defer self.machine_lock.unlock(global.io());
                            try self.handleSysReg(vcpu, cpu_id, exit_info);
                        },
                        else => {
                            log.warn("unhandled exception class: 0x{x}", .{@intFromEnum(ec)});
                            log.warn("syndrome: 0x{x}, VA: 0x{x}, PA: 0x{x}", .{
                                exit_info.syndrome,
                                exit_info.virtual_address,
                                exit_info.physical_address,
                            });
                            break;
                        },
                    }
                },
                .vtimer_activated => {
                    // Pend the virtual timer PPI (intid 27). HVF masks the
                    // vtimer on this exit; we unmask when the guest EOIs.
                    self.machine_lock.lockUncancelable(global.io());
                    if (self.gic_device) |gic_dev| {
                        gic_dev.setPpiPending(cpu_id, 27, true);
                    }
                    self.machine_lock.unlock(global.io());
                },
                .unknown => {
                    log.warn("unknown exit reason", .{});
                    break;
                },
            }
        }

        log.info("vCPU loop finished after {} exits", .{exit_count});
    }

    fn handleMmio(self: *Machine, vcpu: *hypervisor.Vcpu, info: hypervisor.ExitInfo) !void {
        const access = try self.decodeMmioAccess(vcpu, info) orelse {
            try vcpu.advancePC(info);
            return;
        };
        const is_write = access.is_write;
        const size = access.size;
        const srt = access.srt;
        const addr = info.physical_address;

        // Note: ECAM-range logging disabled to reduce noise during UEFI boot

        // GIC Distributor (GICD)
        const gic_dist_end = MemoryLayout.GIC_DIST_BASE + 0x10000;
        if (addr >= MemoryLayout.GIC_DIST_BASE and addr < gic_dist_end) {
            if (self.gic_device) |gic_dev| {
                const offset = addr - MemoryLayout.GIC_DIST_BASE;
                if (is_write) {
                    const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                    gic_dev.distWrite(offset, size, value);
                } else {
                    const value = gic_dev.distRead(offset, size);
                    if (srt != 31) {
                        try vcpu.setReg(@enumFromInt(srt), value);
                    }
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // GIC Redistributor (GICR) - 128KB per CPU
        const gicr_size = @as(u64, gic.GICR_FRAME_SIZE) * self.config.vcpu_count;
        const gic_redist_end = MemoryLayout.GIC_REDIST_BASE + gicr_size;
        if (addr >= MemoryLayout.GIC_REDIST_BASE and addr < gic_redist_end) {
            if (self.gic_device) |gic_dev| {
                const offset = addr - MemoryLayout.GIC_REDIST_BASE;
                if (is_write) {
                    const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                    gic_dev.redistWrite(offset, size, value);
                } else {
                    const value = gic_dev.redistRead(offset, size);
                    if (srt != 31) {
                        try vcpu.setReg(@enumFromInt(srt), value);
                    }
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // UART (PL011)
        if (addr >= MemoryLayout.UART_BASE and addr < MemoryLayout.UART_BASE + MemoryLayout.UART_SIZE) {
            const offset: u12 = @truncate(addr - MemoryLayout.UART_BASE);
            if (is_write) {
                const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                self.uart.write(offset, @truncate(value));
            } else {
                const value = self.uart.read(offset);
                if (srt != 31) {
                    try vcpu.setReg(@enumFromInt(srt), value);
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // RTC (PL031)
        if (addr >= MemoryLayout.RTC_BASE and addr < MemoryLayout.RTC_BASE + MemoryLayout.RTC_SIZE) {
            const offset: u12 = @truncate(addr - MemoryLayout.RTC_BASE);
            if (is_write) {
                const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                self.rtc.write(offset, @truncate(value));
            } else {
                const value = self.rtc.read(offset);
                if (srt != 31) {
                    try vcpu.setReg(@enumFromInt(srt), value);
                }
            }
            try vcpu.advancePC(info);
            return;
        }

        // Virtio MMIO devices (console/blk/gpu, slot-addressed)
        const virtio_end = MemoryLayout.VIRTIO_BASE + MemoryLayout.VIRTIO_SIZE * VIRTIO_SLOT_COUNT;
        if (addr >= MemoryLayout.VIRTIO_BASE and addr < virtio_end) {
            const slot: u8 = @intCast((addr - MemoryLayout.VIRTIO_BASE) / MemoryLayout.VIRTIO_SIZE);
            const offset: u12 = @truncate(addr - MemoryLayout.virtioBase(slot));
            const value: u32 = if (is_write)
                @truncate(if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt)))
            else
                0;
            var result: u32 = 0;

            if (self.mmio_devices[slot]) |device| {
                if (is_write) device.write(offset, value) else result = device.read(offset);
            }

            if (!is_write and srt != 31) {
                try vcpu.setReg(@enumFromInt(srt), result);
            }
            try vcpu.advancePC(info);
            return;
        }

        // PCIe ECAM (configuration space)
        if (addr >= MemoryLayout.ECAM_BASE and addr < MemoryLayout.ECAM_BASE + MemoryLayout.ECAM_SIZE) {
            const offset = addr - MemoryLayout.ECAM_BASE;
            if (is_write) {
                const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                ecamMmioWrite(self, offset, size, value);
            } else if (srt != 31) {
                try vcpu.setReg(@enumFromInt(srt), ecamMmioRead(self, offset, size));
            }
            try vcpu.advancePC(info);
            return;
        }

        // PCI MMIO region (BAR space) - virtio-pci devices
        if (addr >= MemoryLayout.PCI_MMIO_BASE and addr < MemoryLayout.PCI_MMIO_BASE + MemoryLayout.PCI_MMIO_SIZE) {
            if (is_write) {
                const value = if (srt == 31) 0 else try vcpu.getReg(@enumFromInt(srt));
                _ = self.pciBarWriteAt(addr, size, @truncate(value));
            } else if (srt != 31) {
                const value = self.pciBarReadAt(addr, size) orelse 0xFFFFFFFF;
                try vcpu.setReg(@enumFromInt(srt), value);
            }
            try vcpu.advancePC(info);
            return;
        }

        if (enable_debug_logs) {
            log.debug("unhandled MMIO {s} at 0x{x}", .{ if (is_write) "write" else "read", addr });
        }
        try vcpu.advancePC(info);
    }

    const MmioAccess = struct {
        is_write: bool,
        size: u8,
        srt: u5,
    };

    fn decodeMmioAccess(
        self: *Machine,
        vcpu: *hypervisor.Vcpu,
        info: hypervisor.ExitInfo,
    ) !?MmioAccess {
        assert(info.isDataAbort());
        assert(self.hv_vm != null);

        const iss = info.iss();
        if ((iss >> 24) & 1 != 0) {
            return .{
                .is_write = info.isWrite(),
                .size = @as(u8, 1) << info.accessSize(),
                .srt = @truncate(iss >> 16),
            };
        }

        const pc = try vcpu.getReg(.pc);
        const instr_ptr = self.hv_vm.?.guestToHost(pc) orelse return error.InvalidAddress;
        const instr = @as(*align(1) const u32, @ptrCast(instr_ptr)).*;
        return switch (hypervisor.runner.decodeLoadStore(instr)) {
            .load_store => |load_store| access: {
                if (load_store.writeback_rn) |rn| {
                    try hypervisor.runner.applyLoadStoreWriteback(
                        vcpu,
                        rn,
                        load_store.writeback_imm,
                    );
                }
                break :access .{
                    .is_write = load_store.is_write,
                    .size = load_store.size,
                    .srt = load_store.rt,
                };
            },
            .cache_op => null,
            .unknown => {
                log.err("unsupported MMIO instruction at pc=0x{x}: 0x{x}", .{ pc, instr });
                return error.UnsupportedMmioInstruction;
            },
        };
    }

    fn handlePsci(self: *Machine, vcpu: *hypervisor.Vcpu, _: hypervisor.ExitInfo) !void {
        const fn_id = try vcpu.getReg(.x0);

        const result: u64 = switch (fn_id) {
            // PSCI_VERSION - return v1.0
            0x84000000 => 0x00010000,

            // PSCI_FEATURES
            0x8400000A => blk: {
                const feature = try vcpu.getReg(.x1);
                break :blk switch (feature) {
                    0x84000000,
                    0x84000008,
                    0x84000009,
                    0x8400000A,
                    0x84000003,
                    0xC4000003,
                    0x84000004,
                    0xC4000004,
                    => 0,
                    else => 0xFFFFFFFF,
                };
            },

            // PSCI_CPU_ON (32- and 64-bit calling conventions)
            0x84000003, 0xC4000003 => blk: {
                const target_mpidr = try vcpu.getReg(.x1);
                const entry_point = try vcpu.getReg(.x2);
                const context_id = try vcpu.getReg(.x3);
                break :blk self.psciCpuOn(target_mpidr, entry_point, context_id);
            },

            // PSCI_AFFINITY_INFO
            0x84000004, 0xC4000004 => blk: {
                const target_mpidr = try vcpu.getReg(.x1);
                const cpu_id = target_mpidr & 0xFF;
                if (cpu_id >= self.cpu_states.len) break :blk PSCI_INVALID_PARAMETERS;
                break :blk if (self.cpu_states[cpu_id].started.load(.acquire)) 0 else 1;
            },

            // PSCI_SYSTEM_OFF
            0x84000008 => blk: {
                log.info("PSCI SYSTEM_OFF", .{});
                self.running.store(false, .release);
                break :blk 0;
            },

            // PSCI_SYSTEM_RESET
            0x84000009 => blk: {
                log.info("PSCI SYSTEM_RESET", .{});
                self.running.store(false, .release);
                break :blk 0;
            },

            else => blk: {
                log.debug("unknown PSCI fn=0x{x}", .{fn_id});
                break :blk 0xFFFFFFFF;
            },
        };

        try vcpu.setReg(.x0, result);
        // NOTE: Do NOT advance PC - for HVC/SMC, PC already points past the instruction
    }

    const PSCI_INVALID_PARAMETERS: u64 = @bitCast(@as(i64, -2));
    const PSCI_ALREADY_ON: u64 = @bitCast(@as(i64, -4));
    const PSCI_INTERNAL_FAILURE: u64 = @bitCast(@as(i64, -6));

    /// PSCI CPU_ON: bring a secondary vCPU online on its own thread.
    fn psciCpuOn(self: *Machine, target_mpidr: u64, entry_point: u64, context_id: u64) u64 {
        const cpu_id = target_mpidr & 0xFF;
        if (cpu_id == 0 or cpu_id >= self.cpu_states.len) return PSCI_INVALID_PARAMETERS;

        const state = &self.cpu_states[cpu_id];
        if (state.started.load(.acquire)) return PSCI_ALREADY_ON;

        state.entry_point = entry_point;
        state.context_id = context_id;
        state.started.store(true, .release);

        state.thread = std.Thread.spawn(.{}, secondaryVcpuMain, .{ self, @as(u8, @intCast(cpu_id)) }) catch {
            state.started.store(false, .release);
            return PSCI_INTERNAL_FAILURE;
        };

        log.info("PSCI CPU_ON: cpu {} entry=0x{x}", .{ cpu_id, entry_point });
        return 0;
    }

    /// Entry point for secondary vCPU threads (HVF requires create+run
    /// on the same thread).
    fn secondaryVcpuMain(self: *Machine, cpu_id: u8) void {
        const state = &self.cpu_states[cpu_id];
        const vm = self.hv_vm orelse return;

        const vcpu = vm.createVcpu() catch |err| {
            log.err("cpu {}: vCPU creation failed: {}", .{ cpu_id, err });
            state.started.store(false, .release);
            return;
        };

        self.setupSecondaryState(vcpu, cpu_id, state.entry_point, state.context_id) catch |err| {
            log.err("cpu {}: state setup failed: {}", .{ cpu_id, err });
            state.started.store(false, .release);
            return;
        };
        state.vcpu = vcpu;

        self.runVcpuLoop(vcpu, cpu_id) catch |err| {
            log.warn("cpu {}: vCPU loop failed: {}", .{ cpu_id, err });
        };
        state.started.store(false, .release);
    }

    /// EL1 boot state for a CPU_ON'd secondary: like the primary but with
    /// the PSCI-provided entry point and context id.
    fn setupSecondaryState(
        self: *Machine,
        vcpu: *hypervisor.Vcpu,
        cpu_id: u8,
        entry_point: u64,
        context_id: u64,
    ) !void {
        _ = self;
        try setupVcpuFeatures(vcpu);
        try vcpu.setSysReg(.vbar_el1, MemoryLayout.RAM_BASE);
        try vcpu.setSysReg(.sctlr_el1, 0);
        // Best-effort: HVF may treat MPIDR as read-only (its default is
        // the vCPU creation index, which matches our numbering).
        vcpu.setSysReg(.mpidr_el1, @as(u64, cpu_id)) catch |err| {
            log.warn("cpu {}: MPIDR not settable: {}", .{ cpu_id, err });
        };
        try vcpu.setReg(.cpsr, 0x3c5);
        try vcpu.setPC(entry_point);
        try vcpu.setReg(.x0, context_id);
    }

    /// Join all secondary vCPU threads (after running=false).
    fn joinSecondaryVcpus(self: *Machine) void {
        for (self.cpu_states, 0..) |*state, i| {
            if (i == 0) continue;
            if (state.vcpu) |v| v.forceExit() catch {};
            if (state.thread) |thread| {
                thread.join();
                state.thread = null;
            }
        }
    }

    fn handleSysReg(self: *Machine, vcpu: *hypervisor.Vcpu, cpu_id: u8, info: hypervisor.ExitInfo) !void {
        const iss = info.iss();
        const decoded = icc.IccHandler.decodeIss(iss);

        // Check if this is an ICC register
        if (self.icc_handler) |handler| {
            if (decoded.is_read) {
                const value = handler.read(cpu_id, decoded.reg);
                if (decoded.rt != 31) {
                    try vcpu.setReg(@enumFromInt(decoded.rt), value);
                }
            } else {
                const value = if (decoded.rt == 31) 0 else try vcpu.getReg(@enumFromInt(decoded.rt));
                handler.write(cpu_id, decoded.reg, value);
            }
        }

        try vcpu.advancePC(info);
    }

    // =========================================================================
    // Private Methods
    // =========================================================================

    fn mapGuestRam(self: *Machine, vm: *hypervisor.VM) !void {
        var files: [2]std.Io.File = undefined;
        var files_len: u8 = 0;
        defer for (files[0..files_len]) |file| file.close(global.io());

        var overlays: [2]hypervisor.FileOverlay = undefined;
        var overlays_len: u8 = 0;
        if (self.config.restore_path == null and !self.config.isFirmwareBoot()) {
            if (self.config.kernel_path) |path| {
                overlays[overlays_len] = try self.openBootOverlay(
                    path,
                    MemoryLayout.KERNEL_BASE,
                    .kernel,
                    &files,
                    &files_len,
                );
                overlays_len += 1;
            }
            if (self.config.initrd_path) |path| {
                overlays[overlays_len] = try self.openBootOverlay(
                    path,
                    MemoryLayout.INITRD_BASE,
                    .initrd,
                    &files,
                    &files_len,
                );
                overlays_len += 1;
            }
        }

        self.ram = try vm.mapWithFileOverlays(
            MemoryLayout.RAM_BASE,
            self.config.ram_size,
            hypervisor.MEM_READ_WRITE_EXEC,
            overlays[0..overlays_len],
        );
    }

    const BootOverlayKind = enum { kernel, initrd };

    fn openBootOverlay(
        self: *Machine,
        path: []const u8,
        guest_addr: u64,
        kind: BootOverlayKind,
        files: *[2]std.Io.File,
        files_len: *u8,
    ) !hypervisor.FileOverlay {
        assert(files_len.* < files.len);
        assert(guest_addr >= MemoryLayout.RAM_BASE);

        const file = try std.Io.Dir.cwd().openFile(global.io(), path, .{});
        files[files_len.*] = file;
        files_len.* += 1;
        const size_u64 = (try file.stat(global.io())).size;
        const offset_u64 = guest_addr - MemoryLayout.RAM_BASE;
        if (size_u64 == 0) return error.EmptyBootImage;
        if (kind == .kernel and size_u64 > self.config.ram_size / 2) {
            return error.KernelTooLarge;
        }
        if (offset_u64 > self.config.ram_size or
            size_u64 > self.config.ram_size - offset_u64)
        {
            return error.InitrdTooLarge;
        }
        const size: usize = @intCast(size_u64);
        const offset: usize = @intCast(offset_u64);

        if (kind == .initrd) {
            self.initrd_start = guest_addr;
            self.initrd_end = guest_addr + size;
        }
        log.info("mapped {s}: {} bytes at 0x{x}", .{ @tagName(kind), size, guest_addr });
        return .{ .fd = file.handle, .memory_offset = offset, .size = size };
    }

    fn mapPflashRegions(self: *Machine, vm: *hypervisor.VM) !void {
        // Map CODE region (read-execute for firmware)
        self.pflash_code = try vm.map(
            MemoryLayout.PFLASH_CODE_BASE,
            MemoryLayout.PFLASH_CODE_SIZE,
            hypervisor.MEM_READ_EXEC,
        );
        log.debug("mapped pflash CODE: 0x{x} - 0x{x}", .{
            MemoryLayout.PFLASH_CODE_BASE,
            MemoryLayout.PFLASH_CODE_BASE + MemoryLayout.PFLASH_CODE_SIZE,
        });

        // Map VARS region (read-write for UEFI variables)
        self.pflash_vars = try vm.map(
            MemoryLayout.PFLASH_VARS_BASE,
            MemoryLayout.PFLASH_VARS_SIZE,
            hypervisor.MEM_READ_WRITE,
        );
        log.debug("mapped pflash VARS: 0x{x} - 0x{x}", .{
            MemoryLayout.PFLASH_VARS_BASE,
            MemoryLayout.PFLASH_VARS_BASE + MemoryLayout.PFLASH_VARS_SIZE,
        });
    }

    fn loadFirmware(self: *Machine) !void {
        const firmware_path = self.config.firmware_path orelse return;
        log.info("loading firmware: {s}", .{firmware_path});

        const file = try std.Io.Dir.cwd().openFile(global.io(), firmware_path, .{});
        defer file.close(global.io());

        const stat = try file.stat(global.io());
        const firmware_size = stat.size;

        if (firmware_size > MemoryLayout.PFLASH_CODE_SIZE) {
            log.err("firmware too large: {} bytes (max {})", .{ firmware_size, MemoryLayout.PFLASH_CODE_SIZE });
            return error.FirmwareTooLarge;
        }

        const pflash = self.pflash_code.?;

        // Zero-fill the pflash region first (firmware may be smaller than region)
        @memset(pflash, 0xFF); // Flash is typically 0xFF when erased

        // Read firmware into pflash CODE region (bounded to the file's own
        // size — see loadKernel for why we don't pass the whole region).
        const bytes_read = try file.readPositionalAll(global.io(), pflash[0..firmware_size], 0);
        log.info("loaded firmware: {} bytes at 0x{x}", .{ bytes_read, MemoryLayout.PFLASH_CODE_BASE });

        // Load or create VARS file
        try self.loadOrCreateVars();
    }

    fn loadOrCreateVars(self: *Machine) !void {
        const pflash_vars = self.pflash_vars.?;

        // Initialize VARS region to 0xFF (erased flash)
        @memset(pflash_vars, 0xFF);

        // If vars_path is specified, try to load existing vars
        if (self.config.vars_path) |vars_path| {
            const file = std.Io.Dir.cwd().openFile(global.io(), vars_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    if (try self.loadBundledVarsTemplate(pflash_vars)) {
                        log.info("initialized UEFI vars from bundled template", .{});
                    } else {
                        log.info("UEFI vars file not found, starting erased: {s}", .{vars_path});
                    }
                    return;
                }
                return err;
            };
            defer file.close(global.io());

            const stat = try file.stat(global.io());
            const vars_size = @min(stat.size, pflash_vars.len);
            const bytes_read = try file.readPositionalAll(global.io(), pflash_vars[0..vars_size], 0);
            log.info("loaded UEFI vars: {} bytes from {s}", .{ bytes_read, vars_path });
        }
    }

    fn loadBundledVarsTemplate(self: *Machine, pflash_vars: []u8) !bool {
        assert(pflash_vars.len == MemoryLayout.PFLASH_VARS_SIZE);
        assert(self.config.isFirmwareBoot());

        const firmware_path = self.config.firmware_path orelse return false;
        const firmware_dir = std.fs.path.dirname(firmware_path) orelse return false;
        const template_path = try std.fs.path.join(self.alloc, &.{ firmware_dir, "QEMU_VARS.fd" });
        defer self.alloc.free(template_path);

        const file = std.Io.Dir.cwd().openFile(global.io(), template_path, .{}) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        defer file.close(global.io());

        const stat = try file.stat(global.io());
        const template_size = @min(stat.size, pflash_vars.len);
        _ = try file.readPositionalAll(global.io(), pflash_vars[0..template_size], 0);
        return true;
    }

    fn generateDtb(self: *Machine) !void {
        var stack_allocator = std.heap.stackFallback(dtb.DtbBuilder.scratch_bytes, self.alloc);
        var builder = dtb.DtbBuilder.init(stack_allocator.get());
        defer builder.deinit();

        // Count virtio devices: console (slot 0) + block devices + gpu
        // + keyboard + mouse (input accompanies the display) + net + rng
        // (always present) + 9p (with shared_dir) + balloon (always present)
        const virtio_count: u8 = 1 + self.config.blockDeviceCount() +
            (if (self.config.enable_gpu) @as(u8, 3) else 0) +
            @intFromBool(self.config.enable_net) + 1 +
            @intFromBool(self.config.shared_dir != null) + 1 +
            @intFromBool(self.config.enable_snd);

        const config = dtb.DtbConfig{
            .ram_base = MemoryLayout.RAM_BASE,
            .ram_size = self.config.ram_size,
            .vcpu_count = self.config.vcpu_count,
            .cmdline = self.config.cmdline,
            .initrd_start = self.initrd_start,
            .initrd_end = self.initrd_end,
            .virtio_count = virtio_count,
            .virtio_base = MemoryLayout.VIRTIO_BASE,
            .virtio_size = MemoryLayout.VIRTIO_SIZE,
            .uart_base = MemoryLayout.UART_BASE,
            .rtc_base = MemoryLayout.RTC_BASE,
            .gic_dist_base = MemoryLayout.GIC_DIST_BASE,
            .gic_redist_base = MemoryLayout.GIC_REDIST_BASE,
            .flash_enabled = self.config.isFirmwareBoot(),
            .flash_base = MemoryLayout.PFLASH_CODE_BASE,
            .flash_bank_size = MemoryLayout.PFLASH_CODE_SIZE,
            .pcie_enabled = self.config.isFirmwareBoot(),
            .pcie_ecam_base = MemoryLayout.ECAM_BASE,
            .pcie_ecam_size = MemoryLayout.ECAM_SIZE,
            .pcie_mmio_base = MemoryLayout.PCI_MMIO_BASE,
            .pcie_mmio_size = MemoryLayout.PCI_MMIO_SIZE,
        };

        const dtb_addr = self.dtbGuestAddress();
        const ram_offset = dtb_addr - MemoryLayout.RAM_BASE;
        const ram = self.ram.?;

        if (ram_offset >= ram.len) {
            log.err("DTB too large or wrong offset", .{});
            return error.InitrdTooLarge; // Reuse error
        }

        const dtb_data = builder.generateInto(config, ram[ram_offset..]) catch |err| switch (err) {
            error.NoSpaceLeft => {
                log.err("DTB too large or wrong offset", .{});
                return error.InitrdTooLarge;
            },
            else => return err,
        };
        log.info("loaded DTB: {} bytes at 0x{x}", .{ dtb_data.len, dtb_addr });
    }

    fn dtbGuestAddress(self: *const Machine) u64 {
        // ArmVirtQemu firmware has PcdDeviceTreeInitialBaseAddress fixed at
        // the first byte of RAM. Direct Linux boot keeps the DTB near the top
        // of the low-memory window to avoid the kernel and initrd.
        return if (self.config.isFirmwareBoot())
            MemoryLayout.RAM_BASE
        else
            MemoryLayout.dtbBase(self.config.ram_size);
    }

    fn initGic(self: *Machine) !void {
        // Initialize GIC
        self.gic_device = try gic.Gic.init(self.alloc, self.config.vcpu_count);
        // Set up IRQ injection callback
        self.gic_device.?.setInjectCallback(gicInjectIrqCallback, self);
        self.gic_device.?.setEoiCallback(gicEoiCallback, self);
        log.debug("initialized GIC at 0x{x}", .{MemoryLayout.GIC_DIST_BASE});

        // Initialize ICC handler
        self.icc_handler = try icc.IccHandler.init(self.alloc, self.gic_device.?, self.config.vcpu_count);
        log.debug("initialized ICC handler", .{});
    }

    fn initVirtioDevices(self: *Machine) !void {
        // Initialize UART (PL011 for earlycon)
        self.uart = virtio.Uart.init();
        if (self.console_output) |cb| {
            self.uart.setOutputCallback(
                virtio.uart.Output.initRaw(cb, self.console_userdata),
            );
        }
        self.uart.setIrqCallback(
            callback_binding.Handler1(Machine, bool, void, uartIrqCallback).bind(self),
        );
        log.debug("initialized UART at 0x{x}", .{MemoryLayout.UART_BASE});

        self.rtc = virtio.Rtc.init();
        log.debug("initialized RTC at 0x{x}", .{MemoryLayout.RTC_BASE});

        // Initialize console (slot 0). The extra multiport ports are the
        // guest-agent substrate: stock spice-vdagent and qemu-guest-agent
        // attach to these names; host-side protocol handlers arrive with
        // the clipboard/agent features (ports are inert until then).
        self.console = try virtio.Console.init(self.alloc, &.{
            "com.redhat.spice.0",
            "org.qemu.guest_agent.0",
            "org.bobrvm.agent.0",
            "org.bobrvm.clipboard.0",
        });
        self.console.?.setInitialSize(
            self.config.console_size.columns,
            self.config.console_size.rows,
        );
        if (self.console_output) |cb| {
            self.console.?.setOutputCallback(
                virtio.console.Output.initRaw(cb, self.console_userdata),
            );
        }
        // Set up IRQ callback - virtio console is SPI 32 (intid 32)
        self.registerVirtioMmioDevice(
            0,
            .{ .console = self.console.? },
            consoleIrqCallback,
        );
        log.debug("initialized virtio-console at 0x{x}", .{MemoryLayout.virtioBase(0)});

        // qemu-guest-agent channel on the second named port.
        self.qga = try self.alloc.create(agent.Qga);
        self.qga.?.* = agent.Qga.init(
            self.alloc,
            callback_binding.Handler1(Machine, []const u8, void, qgaSend).bind(self),
        );
        self.console.?.setPortOutput(
            QGA_PORT,
            callback_binding.Handler1(Machine, []const u8, void, qgaFeed).bind(self),
        );
        self.qga.?.sync(@divTrunc(hostRealNs(), std.time.ns_per_ms));
        self.qga.?.ping();

        // spice-vdagent clipboard channel on the first named port.
        self.vdagent = agent.Vdagent.init(
            self.alloc,
            callback_binding.Handler1(Machine, []const u8, void, vdagentSend).bind(self),
        );
        self.console.?.setPortOutput(
            SPICE_PORT,
            callback_binding.Handler1(Machine, []const u8, void, vdagentFeed).bind(self),
        );

        self.native_agent = try self.alloc.create(agent.Native);
        self.native_agent.?.* = agent.Native.init(
            self.alloc,
            callback_binding.Handler1(Machine, []const u8, void, nativeAgentSend).bind(self),
            .{ .capabilities = agent.native.Capability.file_transfer },
        );
        self.console.?.setPortOutput(
            BOBRVM_AGENT_PORT,
            callback_binding.Handler1(Machine, []const u8, void, nativeAgentFeed).bind(self),
        );
        self.native_agent.?.begin();

        self.wayland_agent = try self.alloc.create(agent.Native);
        self.wayland_agent.?.* = agent.Native.init(
            self.alloc,
            callback_binding.Handler1(Machine, []const u8, void, waylandAgentSend).bind(self),
            .{ .capabilities = agent.native.Capability.clipboard },
        );
        self.console.?.setPortOutput(
            BOBRVM_CLIPBOARD_PORT,
            callback_binding.Handler1(Machine, []const u8, void, waylandAgentFeed).bind(self),
        );
        self.wayland_agent.?.begin();

        // Initialize primary block device (slot 1) if disk_path is set
        if (self.config.disk_path) |disk_path| {
            self.block = try virtio.Block.init(self.alloc);
            try self.block.?.attachDisk(disk_path, self.config.disk_read_only);
            self.registerVirtioMmioDevice(1, .{ .block = self.block.? }, blk1IrqCallback);
            log.debug("initialized virtio-blk at 0x{x} with disk: {s}", .{
                MemoryLayout.virtioBase(1),
                disk_path,
            });
        }

        // Initialize secondary block device (slot 2) if disk2_path is set (typically ISO)
        if (self.config.disk2_path) |disk2_path| {
            log.debug("attaching disk2: {s} (len={})", .{ disk2_path, disk2_path.len });
            self.block2 = try virtio.Block.init(self.alloc);
            self.block2.?.attachDisk(disk2_path, self.config.disk2_read_only) catch |err| {
                log.err("failed to attach disk2 '{s}': {}", .{ disk2_path, err });
                return err;
            };
            self.registerVirtioMmioDevice(2, .{ .block = self.block2.? }, blk2IrqCallback);
            log.debug("initialized virtio-blk2 at 0x{x} with disk: {s} (read-only: {})", .{
                MemoryLayout.virtioBase(2),
                disk2_path,
                self.config.disk2_read_only,
            });
        }

        // Initialize GPU (slot after the block devices) if enabled
        if (self.config.enable_gpu) {
            self.gpu_slot = 1 + self.config.blockDeviceCount();
            self.gpu = try virtio.Gpu.initWithMemoryLimit(
                self.alloc,
                self.config.enable_virgl,
                self.config.gpu_memory_bytes,
            );
            // Venus host-visible memory window: a guest-PA range above RAM that
            // host blob memory is hv_vm_map'd into on RESOURCE_MAP_BLOB. Its
            // presence makes the guest kernel set VIRTGPU_PARAM_HOST_VISIBLE.
            if (self.config.enable_virgl) {
                if (self.hv_vm) |vm| {
                    const gb: u64 = 1 << 30;
                    const hv_base = std.mem.alignForward(u64, MemoryLayout.RAM_BASE + self.config.ram_size + gb, gb);
                    self.gpu.?.setHostVisible(
                        hv_base,
                        self.config.gpu_memory_bytes,
                        hostVisibleMapFn,
                        hostVisibleUnmapFn,
                        vm,
                    );
                    log.debug("virtio-gpu host-visible window: 0x{x} + {}MB", .{
                        hv_base,
                        self.config.gpu_memory_bytes / (1024 * 1024),
                    });
                }
            }
            self.gpu.?.setDisplaySize(self.config.display_width, self.config.display_height);
            self.registerVirtioMmioDevice(
                self.gpu_slot,
                .{ .gpu = self.gpu.? },
                gpuIrqCallback,
            );
            if (self.frame_callback) |cb| {
                self.gpu.?.setFrameCallback(
                    virtio.gpu.FrameReady.initRaw(cb, self.frame_userdata),
                );
            }
            log.debug("initialized virtio-gpu at 0x{x} (slot {}, {}x{})", .{
                MemoryLayout.virtioBase(self.gpu_slot),
                self.gpu_slot,
                self.config.display_width,
                self.config.display_height,
            });

            // Input devices accompany the display.
            self.keyboard_slot = self.gpu_slot + 1;
            self.keyboard = try virtio.Input.init(self.alloc, .keyboard);
            self.registerVirtioMmioDevice(
                self.keyboard_slot,
                .{ .input = self.keyboard.? },
                keyboardIrqCallback,
            );

            self.mouse_slot = self.gpu_slot + 2;
            self.mouse = try virtio.Input.init(self.alloc, .tablet);
            self.registerVirtioMmioDevice(
                self.mouse_slot,
                .{ .input = self.mouse.? },
                mouseIrqCallback,
            );

            log.debug("initialized virtio-input at slots {} (kbd), {} (mouse)", .{
                self.keyboard_slot,
                self.mouse_slot,
            });
        }

        // Initialize network (slot after everything else) if enabled
        if (self.config.enable_net) {
            self.net_slot = 1 + self.config.blockDeviceCount() +
                (if (self.config.enable_gpu) @as(u8, 3) else 0);
            self.net = try virtio.Net.init(self.alloc);
            self.registerVirtioMmioDevice(
                self.net_slot,
                .{ .net = self.net.? },
                netIrqCallback,
            );
            self.nat = mininat.MiniNat.init(
                self.alloc,
                callback_binding.Handler1(
                    Machine,
                    []const u8,
                    void,
                    natReplyCallback,
                ).bind(self),
            );
            self.nat.setReplyLease(
                callback_binding.Handler1(
                    Machine,
                    usize,
                    ?mininat.ReplyLease,
                    natReplyReserveCallback,
                ).bind(self),
                callback_binding.Handler1(
                    Machine,
                    mininat.ReplyLease,
                    void,
                    natReplyCommitCallback,
                ).bind(self),
            );
            self.nat.setRxReady(
                callback_binding.Handler0(Machine, bool, natRxReadyCallback).bind(self),
            );
            for (self.config.forwards) |fwd| {
                self.nat.addForward(fwd) catch |err| {
                    log.err("port forward {}->{} failed: {} (port in use?)", .{
                        fwd.host_port, fwd.guest_port, err,
                    });
                };
            }
            try self.nat.start();
            self.net.?.setTxCallback(
                callback_binding.Handler1(Machine, []const u8, void, netTxCallback).bind(self),
            );
            log.debug("initialized virtio-net at slot {} (built-in NAT)", .{self.net_slot});
        }

        // Entropy device: always present, in the slot after everything else.
        self.rng_slot = 1 + self.config.blockDeviceCount() +
            (if (self.config.enable_gpu) @as(u8, 3) else 0) +
            @intFromBool(self.config.enable_net);
        self.rng = try virtio.Rng.init(self.alloc);
        self.registerVirtioMmioDevice(
            self.rng_slot,
            .{ .rng = self.rng.? },
            rngIrqCallback,
        );
        log.debug("initialized virtio-rng at slot {}", .{self.rng_slot});

        // 9p shared folder (slot after the rng) if configured.
        if (self.config.shared_dir) |dir| {
            self.p9_slot = self.rng_slot + 1;
            self.p9 = try virtio.P9.init(self.alloc, "host", dir, self.config.share_read_only);
            self.registerVirtioMmioDevice(
                self.p9_slot,
                .{ .p9 = self.p9.? },
                p9IrqCallback,
            );
            log.debug("initialized virtio-9p at slot {} sharing {s}", .{ self.p9_slot, dir });
        }

        // Memory balloon: always present, in the slot after the rng (and
        // after the 9p device when a shared folder is configured).
        self.balloon_slot = self.rng_slot + 1 + @intFromBool(self.config.shared_dir != null);
        self.balloon = try virtio.Balloon.init(self.alloc);
        self.registerVirtioMmioDevice(
            self.balloon_slot,
            .{ .balloon = self.balloon.? },
            balloonIrqCallback,
        );
        log.debug("initialized virtio-balloon at slot {}", .{self.balloon_slot});

        // Sound device (opt-in), in the slot after the balloon.
        if (self.config.enable_snd) {
            self.snd_slot = self.balloon_slot + 1;
            self.snd = try virtio.Snd.init(self.alloc);
            self.registerVirtioMmioDevice(
                self.snd_slot,
                .{ .snd = self.snd.? },
                sndIrqCallback,
            );
            log.debug("initialized virtio-snd at slot {}", .{self.snd_slot});
        }

        // Initialize PCIe ECAM host bridge for UEFI boot
        if (self.config.isFirmwareBoot()) {
            try self.initEcam();
        }
    }

    fn registerVirtioMmioDevice(
        self: *Machine,
        slot: u8,
        device: VirtioMmioDevice,
        comptime irq_handler: fn (*Machine, bool) void,
    ) void {
        assert(slot < self.mmio_devices.len);
        assert(self.mmio_devices[slot] == null);
        device.setGuestMemory(getGuestMemoryWrapper);
        device.setIrqCallback(
            callback_binding.Handler1(Machine, bool, void, irq_handler).bind(self),
        );
        self.mmio_devices[slot] = device;
    }

    fn initEcam(self: *Machine) !void {
        assert(self.config.isFirmwareBoot());
        assert(self.ecam_host == null);

        self.ecam_host = try pci.EcamHost.init(self.alloc, self.config.disk_path != null);
        log.debug("initialized PCIe ECAM at 0x{x}-0x{x}", .{
            MemoryLayout.ECAM_BASE,
            MemoryLayout.ECAM_BASE + MemoryLayout.ECAM_SIZE,
        });

        if (self.block) |blk| try self.initPciBlock(blk);
        if (self.block2) |blk| try self.initPciBlock2(blk);
        if (self.gpu) |gpu_dev| try self.initPciGpu(gpu_dev);
    }

    fn initPciBlock(self: *Machine, blk: *virtio.Block) !void {
        assert(self.ecam_host != null);
        assert(self.pci_block == null);
        self.pci_block = try self.createPciBlock(blk, 0, pciBlockNotify, pciBlockBackendIrq);
    }

    fn initPciBlock2(self: *Machine, blk: *virtio.Block) !void {
        assert(self.ecam_host != null);
        assert(self.pci_block2 == null);

        self.pci_block2 = try self.createPciBlock(blk, 1, pciBlock2Notify, pciBlock2BackendIrq);
    }

    fn createPciBlock(
        self: *Machine,
        blk: *virtio.Block,
        slot: u5,
        notify: *const fn (u32, ?*anyopaque) void,
        irq: *const fn (bool, ?*anyopaque) void,
    ) !*pci.VirtioPciDevice {
        assert(self.ecam_host != null);
        assert(slot < 2);
        const blk_features = virtio.blk.Features.SIZE_MAX |
            virtio.blk.Features.SEG_MAX |
            virtio.blk.Features.BLK_SIZE |
            virtio.blk.Features.FLUSH;
        const device = try pci.VirtioPciDevice.init(
            self.alloc,
            2,
            0x0002,
            blk_features,
            1,
            @sizeOf(virtio.blk.Config),
        );
        errdefer device.deinit();
        const bar0_addr: u32 = @truncate(
            MemoryLayout.PCI_MMIO_BASE + @as(u64, slot) * pci.virtio_pci.BAR0_SIZE,
        );
        device.bar0_addr = bar0_addr;
        device.transport.setDeviceConfig(std.mem.asBytes(&blk.config));
        device.transport.setNotifyCallback(notify, self);
        blk.transport.setIrqCallback(virtio.mmio.Irq.initRaw(irq, self));

        const ecam_device = pci.PciDevice{ .config = device.config, .present = true };
        try self.ecam_host.?.addDevice(slot, 0, ecam_device);
        log.info("initialized virtio-pci-blk at PCI 00:0{}.0, BAR0=0x{x}", .{ slot, bar0_addr });
        return device;
    }

    fn initPciGpu(self: *Machine, gpu_dev: *virtio.Gpu) !void {
        assert(self.ecam_host != null);
        assert(self.pci_gpu == null);

        self.pci_gpu = try pci.VirtioPciDevice.init(
            self.alloc,
            16,
            0x0010,
            gpu_dev.transport.device_features,
            2,
            @sizeOf(virtio.gpu.Config),
        );
        const bar0_addr: u32 = @truncate(
            MemoryLayout.PCI_MMIO_BASE + 2 * pci.virtio_pci.BAR0_SIZE,
        );
        self.pci_gpu.?.bar0_addr = bar0_addr;
        self.pci_gpu.?.transport.setDeviceConfig(std.mem.asBytes(&gpu_dev.config));
        self.pci_gpu.?.transport.setNotifyCallback(pciGpuNotify, self);
        gpu_dev.transport.setIrqCallback(
            virtio.mmio.Irq.initRaw(pciGpuBackendIrq, self),
        );

        const ecam_dev = pci.PciDevice{ .config = self.pci_gpu.?.config, .present = true };
        try self.ecam_host.?.addDevice(2, 0, ecam_dev);
        log.info("initialized virtio-pci-gpu at PCI 00:02.0, BAR0=0x{x}", .{bar0_addr});
    }

    fn pciBlockNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        syncPciBlockQueue(self.pci_block, self.block, queue_idx);
    }

    fn pciBlockBackendIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        self.setPciBlockIrq(self.pci_block, self.block, 80, level);
    }

    fn pciBlock2Notify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        syncPciBlockQueue(self.pci_block2, self.block2, queue_idx);
    }

    fn pciBlock2BackendIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        self.setPciBlockIrq(self.pci_block2, self.block2, 81, level);
    }

    fn syncPciBlockQueue(
        pci_block: ?*pci.VirtioPciDevice,
        block: ?*virtio.Block,
        queue_idx: u32,
    ) void {
        if (queue_idx != 0) return;
        const device = pci_block orelse return;
        const blk = block orelse return;
        assert(device.transport.queues.len == 1);
        assert(blk.transport.queues.len == 1);
        const source = device.transport.queues[queue_idx];
        const target = &blk.transport.queues[queue_idx];
        target.num = source.size;
        target.ready = source.enable;
        target.desc_addr = source.desc_addr;
        target.driver_addr = source.driver_addr;
        target.device_addr = source.device_addr;
        blk.pollRequests();
        assert(target.num == source.size);
    }

    fn setPciBlockIrq(
        self: *Machine,
        pci_block: ?*pci.VirtioPciDevice,
        block: ?*virtio.Block,
        intid: u32,
        level: bool,
    ) void {
        assert(intid == 80 or intid == 81);
        if (pci_block) |device| {
            if (block) |blk| {
                device.transport.isr_status.queue_interrupt =
                    blk.transport.interrupt_status.used_buffer;
                device.transport.isr_status.config_change =
                    blk.transport.interrupt_status.config_change;
            }
        }
        if (self.gic_device) |gic_dev| gic_dev.setSpiPending(intid, level);
    }

    fn pciGpuNotify(queue_idx: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        const gpu_dev = self.gpu orelse return;
        const pci_gpu = self.pci_gpu orelse return;
        if (queue_idx >= pci_gpu.transport.queues.len) return;
        if (queue_idx >= gpu_dev.transport.queues.len) return;

        const source = pci_gpu.transport.queues[queue_idx];
        const target = &gpu_dev.transport.queues[queue_idx];
        target.num = source.size;
        target.ready = source.enable;
        target.desc_addr = source.desc_addr;
        target.driver_addr = source.driver_addr;
        target.device_addr = source.device_addr;
        gpu_dev.poll();
    }

    fn pciGpuBackendIrq(level: bool, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        if (self.pci_gpu) |pci_gpu| {
            if (self.gpu) |gpu_dev| {
                pci_gpu.transport.isr_status.queue_interrupt =
                    gpu_dev.transport.interrupt_status.used_buffer;
                pci_gpu.transport.isr_status.config_change =
                    gpu_dev.transport.interrupt_status.config_change;
            }
        }
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(82, level);
        }
    }

    fn pciGpuBarRead(
        self: *Machine,
        pci_gpu: *pci.VirtioPciDevice,
        offset: u32,
        size: u8,
    ) u32 {
        assert(self.gpu != null);
        assert(offset < pci.virtio_pci.BAR0_SIZE);
        const gpu_dev = self.gpu.?;

        if (offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET) {
            pci_gpu.transport.setDeviceConfig(std.mem.asBytes(&gpu_dev.config));
        }
        const value = pci_gpu.readBar0(offset, size);
        if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
            offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE)
        {
            gpu_dev.transport.write(@intFromEnum(virtio.mmio.Reg.interrupt_ack), value);
        }
        return value;
    }

    fn pciGpuBarWrite(
        self: *Machine,
        pci_gpu: *pci.VirtioPciDevice,
        offset: u32,
        size: u8,
        value: u32,
    ) void {
        assert(self.gpu != null);
        assert(offset < pci.virtio_pci.BAR0_SIZE);
        const gpu_dev = self.gpu.?;

        if (offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET) {
            pci_gpu.transport.setDeviceConfig(std.mem.asBytes(&gpu_dev.config));
        }
        pci_gpu.writeBar0(offset, size, value);
        if (offset >= pci.virtio_pci.BAR_DEVICE_CFG_OFFSET) {
            const config_size = @sizeOf(virtio.gpu.Config);
            @memcpy(
                std.mem.asBytes(&gpu_dev.config),
                pci_gpu.transport.device_config[0..config_size],
            );
        }
    }

    fn pciBlockBarRead(
        self: *Machine,
        pci_block: *pci.VirtioPciDevice,
        block: *virtio.Block,
        offset: u32,
        size: u8,
    ) u32 {
        assert(self.hv_vm != null);
        assert(block.transport.device_id == 2);
        assert(offset < pci.virtio_pci.BAR0_SIZE);
        const value = pci_block.readBar0(offset, size);
        if (offset >= pci.virtio_pci.BAR_ISR_OFFSET and
            offset < pci.virtio_pci.BAR_ISR_OFFSET + pci.virtio_pci.BAR_ISR_SIZE)
        {
            block.transport.write(@intFromEnum(virtio.mmio.Reg.interrupt_ack), value);
        }
        return value;
    }

    fn pciBarOffset(device: *pci.VirtioPciDevice, addr: u64) ?u32 {
        assert(addr >= MemoryLayout.PCI_MMIO_BASE);
        assert(addr < MemoryLayout.PCI_MMIO_BASE + MemoryLayout.PCI_MMIO_SIZE);

        const bar_addr: u64 = device.getBar0Addr();
        if (bar_addr == 0) return null;
        if (addr < bar_addr or addr >= bar_addr + pci.virtio_pci.BAR0_SIZE) return null;
        return @truncate(addr - bar_addr);
    }

    fn pciBarReadAt(self: *Machine, addr: u64, size: u8) ?u32 {
        assert(size == 1 or size == 2 or size == 4 or size == 8);
        assert(addr >= MemoryLayout.PCI_MMIO_BASE);

        if (self.pci_block) |device| {
            if (pciBarOffset(device, addr)) |offset| {
                return self.pciBlockBarRead(device, self.block.?, offset, size);
            }
        }
        if (self.pci_block2) |device| {
            if (pciBarOffset(device, addr)) |offset| {
                return self.pciBlockBarRead(device, self.block2.?, offset, size);
            }
        }
        if (self.pci_gpu) |device| {
            if (pciBarOffset(device, addr)) |offset| {
                return self.pciGpuBarRead(device, offset, size);
            }
        }
        return null;
    }

    fn pciBarWriteAt(self: *Machine, addr: u64, size: u8, value: u32) bool {
        assert(size == 1 or size == 2 or size == 4 or size == 8);
        assert(addr >= MemoryLayout.PCI_MMIO_BASE);

        if (self.pci_block) |device| {
            if (pciBarOffset(device, addr)) |offset| {
                device.writeBar0(offset, size, value);
                return true;
            }
        }
        if (self.pci_block2) |device| {
            if (pciBarOffset(device, addr)) |offset| {
                device.writeBar0(offset, size, value);
                return true;
            }
        }
        if (self.pci_gpu) |device| {
            if (pciBarOffset(device, addr)) |offset| {
                self.pciGpuBarWrite(device, offset, size, value);
                return true;
            }
        }
        return false;
    }

    fn registerMmioHandlers(self: *Machine) !void {
        var runner = &self.runner.?;
        // Two GIC regions, UART, RTC, three virtio slots, ECAM, and the PCI BAR.
        try runner.reserveMmioHandlers(9);

        // Register GIC Distributor MMIO handler
        if (self.gic_device) |gic_dev| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(gic_dev),
                .base = MemoryLayout.GIC_DIST_BASE,
                .size = 0x10000, // 64KB for distributor
                .read = gic.distMmioRead,
                .write = gic.distMmioWrite,
            });

            // Register GIC Redistributor MMIO handler
            // Size depends on number of CPUs: 2 * 64KB per CPU
            const redist_size = @as(u64, self.config.vcpu_count) * 2 * 0x10000;
            try runner.registerMmioHandler(.{
                .context = @ptrCast(gic_dev),
                .base = MemoryLayout.GIC_REDIST_BASE,
                .size = redist_size,
                .read = gic.redistMmioRead,
                .write = gic.redistMmioWrite,
            });
        }

        // Register UART MMIO handler (PL011)
        try runner.registerMmioHandler(.{
            .context = @ptrCast(&self.uart),
            .base = MemoryLayout.UART_BASE,
            .size = MemoryLayout.UART_SIZE,
            .read = virtio.uart.mmioRead,
            .write = virtio.uart.mmioWrite,
        });

        // Register RTC MMIO handler (PL031)
        try runner.registerMmioHandler(.{
            .context = @ptrCast(&self.rtc),
            .base = MemoryLayout.RTC_BASE,
            .size = MemoryLayout.RTC_SIZE,
            .read = virtio.rtc.mmioRead,
            .write = virtio.rtc.mmioWrite,
        });

        // Register console MMIO handler (slot 0)
        if (self.console) |console| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(console),
                .base = MemoryLayout.virtioBase(0),
                .size = MemoryLayout.VIRTIO_SIZE,
                .read = consoleMmioRead,
                .write = consoleMmioWrite,
            });
        }

        // Register block MMIO handler (slot 1)
        if (self.block) |block| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(block),
                .base = MemoryLayout.virtioBase(1),
                .size = MemoryLayout.VIRTIO_SIZE,
                .read = blockMmioRead,
                .write = blockMmioWrite,
            });
        }

        // Register block2 MMIO handler (slot 2)
        if (self.block2) |block2| {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(block2),
                .base = MemoryLayout.virtioBase(2),
                .size = MemoryLayout.VIRTIO_SIZE,
                .read = blockMmioRead,
                .write = blockMmioWrite,
            });
        }

        // Register PCIe ECAM MMIO handler
        if (self.ecam_host != null or self.pci_block != null or
            self.pci_block2 != null or self.pci_gpu != null)
        {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(self),
                .base = MemoryLayout.ECAM_BASE,
                .size = MemoryLayout.ECAM_SIZE,
                .read = ecamMmioRead,
                .write = ecamMmioWrite,
            });
        }

        // Register PCI BAR0 MMIO handler (virtio-pci devices)
        if (self.pci_block != null or self.pci_block2 != null or self.pci_gpu != null) {
            try runner.registerMmioHandler(.{
                .context = @ptrCast(self),
                .base = MemoryLayout.PCI_MMIO_BASE,
                .size = MemoryLayout.PCI_MMIO_SIZE,
                .read = pciBarMmioRead,
                .write = pciBarMmioWrite,
            });
        }
    }

    fn ecamMmioRead(ctx: *anyopaque, offset: u64, size: u8) u64 {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        const addr = MemoryLayout.ECAM_BASE + offset;
        const ecam_addr = pci.EcamAddr.decode(addr);

        // PCI config space only supports 1/2/4 byte accesses
        // For 8-byte reads, do two 4-byte reads (if within bounds)
        if (size == 8) {
            const reg_offset: u16 = ecam_addr.reg;
            var result: u64 = 0xFFFFFFFF_FFFFFFFF;
            if (reg_offset + 4 <= 4096) {
                result = (result & 0xFFFFFFFF_00000000) | ecamMmioRead(ctx, offset, 4);
            }
            if (reg_offset + 8 <= 4096 and offset + 4 < MemoryLayout.ECAM_SIZE) {
                result = (result & 0x00000000_FFFFFFFF) | (ecamMmioRead(ctx, offset + 4, 4) << 32);
            }
            return result;
        }

        if (self.pciDeviceAt(ecam_addr)) |entry| {
            return entry.device.readConfig(ecam_addr.reg, size);
        }

        if (self.ecam_host) |ecam| {
            return ecam.read(addr, size);
        }

        return 0xFFFFFFFF;
    }

    fn ecamMmioWrite(ctx: *anyopaque, offset: u64, size: u8, value: u64) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        const addr = MemoryLayout.ECAM_BASE + offset;
        const ecam_addr = pci.EcamAddr.decode(addr);

        // PCI config space only supports 1/2/4 byte accesses
        // For 8-byte writes, do two 4-byte writes (if within bounds)
        if (size == 8) {
            // Check if second half would be out of bounds for this function's config space
            const reg_offset: u16 = ecam_addr.reg;
            if (reg_offset + 4 <= 4096) {
                ecamMmioWrite(ctx, offset, 4, value & 0xFFFFFFFF);
            }
            if (reg_offset + 8 <= 4096 and offset + 4 < MemoryLayout.ECAM_SIZE) {
                ecamMmioWrite(ctx, offset + 4, 4, value >> 32);
            }
            return;
        }

        if (self.pciDeviceAt(ecam_addr)) |entry| {
            entry.device.writeConfig(ecam_addr.reg, size, value);
            if (self.ecam_host) |ecam| {
                ecam.updateConfig(entry.slot, 0, &entry.device.config);
            }
            return;
        }

        if (self.ecam_host) |ecam| {
            ecam.write(addr, size, value);
        }
    }

    const PciDeviceAt = struct {
        device: *pci.VirtioPciDevice,
        slot: u5,
    };

    fn pciDeviceAt(self: *Machine, address: pci.EcamAddr) ?PciDeviceAt {
        if (address.bus != 0) return null;
        if (address.function != 0) return null;

        return switch (address.device) {
            0 => if (self.pci_block) |device| .{ .device = device, .slot = 0 } else null,
            1 => if (self.pci_block2) |device| .{ .device = device, .slot = 1 } else null,
            2 => if (self.pci_gpu) |device| .{ .device = device, .slot = 2 } else null,
            else => null,
        };
    }

    fn pciBarMmioRead(ctx: *anyopaque, offset: u64, size: u8) u64 {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        return self.pciBarReadAt(MemoryLayout.PCI_MMIO_BASE + offset, size) orelse 0xFFFFFFFF;
    }

    fn pciBarMmioWrite(ctx: *anyopaque, offset: u64, size: u8, value: u64) void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        _ = self.pciBarWriteAt(MemoryLayout.PCI_MMIO_BASE + offset, size, @truncate(value));
    }

    /// Set up initial state for a single vCPU.
    /// Only vCPU 0 gets the boot configuration; others wait for IPI.
    fn setupVcpuState(self: *Machine, vcpu: *hypervisor.Vcpu, id: u32) !void {
        try setupVcpuFeatures(vcpu);

        // Set up SP_EL0 and SP_EL1 to valid addresses (per-vCPU)
        const stack_base = MemoryLayout.RAM_BASE + 0x10000 + @as(u64, id) * 0x20000;
        try vcpu.setSysReg(.sp_el0, stack_base);
        try vcpu.setSysReg(.sp_el1, stack_base + 0x10000);

        // VBAR_EL1 - Vector Base Address
        try vcpu.setSysReg(.vbar_el1, MemoryLayout.RAM_BASE);

        // Set up SCTLR_EL1 (MMU off, caches off)
        try vcpu.setSysReg(.sctlr_el1, 0);

        // Start in EL1h so firmware and Linux use the initialized SP_EL1.
        try vcpu.setReg(.cpsr, 0x3c5);

        if (id == 0) {
            // Primary vCPU boot configuration
            const boot_pc = if (self.config.isFirmwareBoot())
                MemoryLayout.PFLASH_CODE_BASE // UEFI firmware entry
            else
                MemoryLayout.KERNEL_BASE; // Direct kernel boot

            try vcpu.setPC(boot_pc);

            // x0 = DTB address (used by both firmware and kernel)
            try vcpu.setReg(.x0, self.dtbGuestAddress());

            // x1, x2, x3 = 0 (reserved)
            try vcpu.setReg(.x1, 0);
            try vcpu.setReg(.x2, 0);
            try vcpu.setReg(.x3, 0);

            if (self.config.isFirmwareBoot()) {
                log.debug("vCPU 0: firmware boot PC=0x{x}", .{boot_pc});
            } else {
                log.debug("vCPU 0: direct boot PC=0x{x}", .{boot_pc});
            }
        } else {
            // Secondary vCPUs: start halted, waiting for PSCI CPU_ON
            // Write a WFI loop at a per-vCPU location in RAM
            const wfi_offset = 0x1000 * @as(u64, id);
            const wfi_addr = MemoryLayout.RAM_BASE + wfi_offset;

            // Write WFI loop: wfi; b -4 (loop back to wfi)
            // WFI = 0xD503207F, B #-4 = 0x17FFFFFF
            const ram = self.ram.?;
            const wfi_code = [_]u8{
                0x7F, 0x20, 0x03, 0xD5, // wfi
                0xFF, 0xFF, 0xFF, 0x17, // b #-4
            };
            @memcpy(ram[wfi_offset..][0..wfi_code.len], &wfi_code);

            try vcpu.setPC(wfi_addr);
            try vcpu.setReg(.x0, 0);

            log.debug("vCPU {}: secondary state at 0x{x} (waiting for PSCI CPU_ON)", .{ id, wfi_addr });
        }
    }

    fn setupVcpuFeatures(vcpu: *hypervisor.Vcpu) !void {
        // Apple CPUs do not expose a host GIC, but every guest vCPU uses
        // bobrvm's emulated GICv3 system-register interface.
        const pfr0 = try vcpu.getSysReg(.id_aa64pfr0_el1);
        try vcpu.setSysReg(.id_aa64pfr0_el1, withGicSystemRegisters(pfr0));
        try vcpu.setSysReg(.cpacr_el1, 3 << 20);
    }

    // =========================================================================
    // MMIO Callbacks
    // =========================================================================

    fn consoleMmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
        const console: *virtio.Console = @ptrCast(@alignCast(context));
        _ = size;
        return console.read(@truncate(offset));
    }

    fn consoleMmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
        const console: *virtio.Console = @ptrCast(@alignCast(context));
        _ = size;
        console.write(@truncate(offset), @truncate(value));
    }

    fn blockMmioRead(context: *anyopaque, offset: u64, size: u8) u64 {
        const block: *virtio.Block = @ptrCast(@alignCast(context));
        _ = size;
        return block.read(@truncate(offset));
    }

    fn blockMmioWrite(context: *anyopaque, offset: u64, size: u8, value: u64) void {
        const block: *virtio.Block = @ptrCast(@alignCast(context));
        _ = size;
        block.write(@truncate(offset), @truncate(value));
    }

    fn getGuestMemoryWrapper(addr: u64, len: usize) ?[]u8 {
        const machine = current_machine orelse return null;
        const ram = machine.ram orelse return null;

        // Check if address is within RAM region
        if (addr < MemoryLayout.RAM_BASE) return null;
        const ram_offset = addr - MemoryLayout.RAM_BASE;
        if (ram_offset + len > ram.len) {
            log.warn("get_mem: OOB addr=0x{x} len={} ram_len=0x{x}", .{ addr, len, ram.len });
            return null;
        }

        return ram[ram_offset..][0..len];
    }

    fn consoleIrqCallback(self: *Machine, level: bool) void {
        // DTB declares virtio slot 0 as GIC_SPI 32 → intid 32 + 32 = 64.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64, level);
        }
    }

    fn blk1IrqCallback(self: *Machine, level: bool) void {
        // DTB declares virtio slot 1 as GIC_SPI 33 → intid 32 + 33 = 65.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(65, level);
        }
    }

    fn blk2IrqCallback(self: *Machine, level: bool) void {
        // DTB declares virtio slot 2 as GIC_SPI 34 → intid 32 + 34 = 66.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(66, level);
        }
    }

    fn gpuIrqCallback(self: *Machine, level: bool) void {
        // Virtio slot N is GIC_SPI 32+N → intid 64 + N.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.gpu_slot), level);
        }
    }

    /// Map host blob memory into the guest host-visible window (Venus). Returns
    /// false on any alignment/HVF error so the guest gets a clean map failure.
    fn hostVisibleMapFn(userdata: ?*anyopaque, host_ptr: [*]u8, guest_pa: u64, size: usize) bool {
        const vm: *hypervisor.VM = @ptrCast(@alignCast(userdata orelse return false));
        const PS: usize = 0x4000; // Apple Silicon host page (16 KiB); hv_vm_map needs this alignment.
        if (@intFromPtr(host_ptr) % PS != 0 or guest_pa % PS != 0 or size % PS != 0) {
            log.warn("host-visible map unaligned: ptr=0x{x} pa=0x{x} size=0x{x}", .{ @intFromPtr(host_ptr), guest_pa, size });
            return false;
        }
        const aligned: []align(4096) u8 = @alignCast(host_ptr[0..size]);
        vm.mapExisting(aligned, guest_pa, .{ .read = true, .write = true }) catch |e| {
            log.warn("host-visible hv_vm_map failed (pa=0x{x} size=0x{x}): {}", .{ guest_pa, size, e });
            return false;
        };
        return true;
    }

    fn hostVisibleUnmapFn(userdata: ?*anyopaque, guest_pa: u64, size: usize) void {
        const vm: *hypervisor.VM = @ptrCast(@alignCast(userdata orelse return));
        vm.unmap(guest_pa, size) catch {};
    }

    fn rngIrqCallback(self: *Machine, level: bool) void {
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.rng_slot), level);
        }
    }

    fn p9IrqCallback(self: *Machine, level: bool) void {
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.p9_slot), level);
        }
    }

    fn balloonIrqCallback(self: *Machine, level: bool) void {
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.balloon_slot), level);
        }
    }

    fn sndIrqCallback(self: *Machine, level: bool) void {
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.snd_slot), level);
        }
    }

    fn keyboardIrqCallback(self: *Machine, level: bool) void {
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.keyboard_slot), level);
        }
    }

    fn mouseIrqCallback(self: *Machine, level: bool) void {
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.mouse_slot), level);
        }
    }

    fn netIrqCallback(self: *Machine, level: bool) void {
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(64 + @as(u32, self.net_slot), level);
        }
    }

    /// Guest → host frame: hand to the NAT responder (vCPU thread,
    /// machine lock held).
    fn netTxCallback(self: *Machine, frame: []const u8) void {
        self.nat.handleFrame(frame);
    }

    /// NAT responder → guest frame.
    fn natReplyCallback(self: *Machine, frame: []const u8) void {
        if (self.net) |net| net.queueRxFrame(frame);
    }

    fn natReplyReserveCallback(self: *Machine, frame_len: usize) ?mininat.ReplyLease {
        assert(frame_len > 0);
        assert(frame_len <= virtio.Net.MAX_FRAME);
        const net = self.net orelse return null;
        const reservation = net.reserveRxFrame(frame_len) orelse return null;
        return .{
            .frame = reservation.bytes,
            .token = reservation.storage_index,
        };
    }

    fn natReplyCommitCallback(self: *Machine, lease: mininat.ReplyLease) void {
        assert(lease.frame.len > 0);
        assert(lease.token <= std.math.maxInt(u16));
        const net = self.net orelse unreachable;
        net.commitRxFrame(.{
            .bytes = lease.frame,
            .storage_index = @intCast(lease.token),
        });
    }

    /// NAT back-pressure: true while the guest RX queue has headroom.
    fn natRxReadyCallback(self: *Machine) bool {
        if (self.net) |net| return net.rxReady();
        return true;
    }

    fn uartIrqCallback(self: *Machine, level: bool) void {
        // DTB declares the PL011 as GIC_SPI 1 → intid 32 + 1 = 33.
        if (self.gic_device) |gic_dev| {
            gic_dev.setSpiPending(33, level);
        }
    }

    fn gicEoiCallback(cpu_id: u8, intid: u32, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        if (intid == 27) {
            // vtimer PPI: drop the (level) pending state and unmask HVF's
            // vtimer. If the timer condition still holds, HVF exits again
            // with vtimer_activated and we re-pend.
            if (self.gic_device) |gic_dev| {
                gic_dev.setPpiPending(cpu_id, 27, false);
            }
            if (cpu_id < self.cpu_states.len) {
                self.cpu_states[cpu_id].vtimer_unmask.store(true, .release);
            }
        }
    }

    fn gicInjectIrqCallback(cpu_id: u8, userdata: ?*anyopaque) void {
        const self: *Machine = @ptrCast(@alignCast(userdata));
        self.kickCpu(cpu_id);
    }

    /// Mark an IRQ pending for a vCPU and force it out of hv_vcpu_run so
    /// cross-CPU interrupts (SGIs, device IRQs) are delivered promptly.
    fn kickCpu(self: *Machine, cpu_id: u8) void {
        if (cpu_id >= self.cpu_states.len) return;
        const state = &self.cpu_states[cpu_id];
        state.pending_irq.store(true, .release);
        // Wake a WFI-halted vCPU (blocked on the condvar) and force a
        // running one out of hv_vcpu_run.
        state.wake_mutex.lockUncancelable(global.io());
        state.wake_cond.signal(global.io());
        state.wake_mutex.unlock(global.io());
        if (state.vcpu) |v| v.forceExit() catch {};
    }
};

// Custom errors
const MachineError = error{
    KernelTooLarge,
    InitrdTooLarge,
    RestoreFailed,
};

test {
    _ = MemoryLayout;
    _ = gic;
    _ = icc;
    _ = mininat;
    _ = dtb;
    _ = snapshot;
}

test "MemoryLayout constants" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0x4000_0000), MemoryLayout.RAM_BASE);
    try testing.expectEqual(@as(u64, 0x4020_0000), MemoryLayout.KERNEL_BASE); // 2MB aligned
    try testing.expectEqual(@as(u64, 0x5fe0_0000), MemoryLayout.dtbBase(512 * 1024 * 1024));
    try testing.expectEqual(@as(u64, 0x7fe0_0000), MemoryLayout.dtbBase(16 * 1024 * 1024 * 1024));
    try testing.expectEqual(@as(u64, 0x0A00_0000), MemoryLayout.virtioBase(0));
    try testing.expectEqual(@as(u64, 0x0A00_0200), MemoryLayout.virtioBase(1));
}

test "withGicSystemRegisters advertises GICv3 without changing other features" {
    const pfr0: u64 = 0xA501_0000_5F00_1234;
    const updated = withGicSystemRegisters(pfr0);

    try std.testing.expectEqual(@as(u64, 1), (updated & ID_AA64PFR0_GIC_MASK) >> 24);
    try std.testing.expectEqual(pfr0 & ~ID_AA64PFR0_GIC_MASK, updated & ~ID_AA64PFR0_GIC_MASK);
}

test "MachineConfig.isFirmwareBoot" {
    const testing = std.testing;

    // Direct kernel boot: no firmware_path
    const direct_boot = MachineConfig{
        .kernel_path = "/path/to/Image",
        .initrd_path = "/path/to/initrd",
    };
    try testing.expect(!direct_boot.isFirmwareBoot());

    // Firmware boot: firmware_path set
    const firmware_boot = MachineConfig{
        .firmware_path = "/path/to/QEMU_EFI.fd",
    };
    try testing.expect(firmware_boot.isFirmwareBoot());

    // Empty firmware_path is not firmware boot
    const empty_firmware = MachineConfig{
        .firmware_path = "",
    };
    try testing.expect(!empty_firmware.isFirmwareBoot());
}

test "MachineConfig.blockDeviceCount" {
    const testing = std.testing;

    const no_disks = MachineConfig{};
    try testing.expectEqual(@as(u8, 0), no_disks.blockDeviceCount());

    const one_disk = MachineConfig{ .disk_path = "/disk1" };
    try testing.expectEqual(@as(u8, 1), one_disk.blockDeviceCount());

    const two_disks = MachineConfig{
        .disk_path = "/disk1",
        .disk2_path = "/disk2",
    };
    try testing.expectEqual(@as(u8, 2), two_disks.blockDeviceCount());
}

test "Machine and CPU states allocation profile" {
    const testing = std.testing;
    var counted = testing.FailingAllocator.init(testing.allocator, .{});
    const config = MachineConfig{ .vcpu_count = 2 };

    const machine = try Machine.init(counted.allocator(), config);
    defer machine.deinit();

    try testing.expectEqual(@as(usize, 1), counted.allocations);
    try testing.expectEqual(
        @sizeOf(Machine) + @as(usize, config.vcpu_count) * @sizeOf(VcpuRunState),
        counted.allocated_bytes,
    );
    try testing.expectEqual(@as(usize, config.vcpu_count), machine.cpu_states.len);
    try testing.expect(@sizeOf(Machine) <= 6232);
}

test "stop before synchronous thread entry cancels startup" {
    const testing = std.testing;
    const machine = try Machine.init(testing.allocator, .{ .vcpu_count = 1 });
    defer machine.deinit();

    machine.prepareStart();
    machine.requestStop();

    try testing.expectError(error.StartCancelled, machine.startSyncPrepared());
    try testing.expect(!machine.running.load(.acquire));
    try testing.expect(machine.stop_requested.load(.acquire));
}

test "trimErasedFlash keeps content up to the last programmed byte" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 0), Machine.trimErasedFlash(&.{}));
    try testing.expectEqual(@as(usize, 0), Machine.trimErasedFlash(&.{ 0xFF, 0xFF }));
    try testing.expectEqual(@as(usize, 3), Machine.trimErasedFlash(&.{ 0xFF, 0x00, 0x01, 0xFF }));
    try testing.expectEqual(@as(usize, 2), Machine.trimErasedFlash(&.{ 0x00, 0x00 }));
}

test "readRamDataRegions reads only the data regions of a sparse image" {
    const testing = std.testing;
    const io = global.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Layout mirrors a suspend image: header+state bytes, then a RAM
    // span whose zero chunks are file holes. The filesystem may round
    // data extents up to block granularity; the walk tolerates that
    // because the surrounding file bytes are zeros.
    const ram_base: u64 = 100;
    const ram_len: usize = 512 * 1024;
    const header_bytes = [_]u8{0xEE} ** 100;
    var region_a: [16 * 1024]u8 = @splat(0xA5);
    var region_b: [4 * 1024]u8 = @splat(0x5A);

    {
        const out = try tmp.dir.createFile(io, "state.img", .{});
        defer out.close(io);
        try out.writePositionalAll(io, &header_bytes, 0);
        try out.writePositionalAll(io, &region_a, ram_base + 64 * 1024);
        try out.writePositionalAll(io, &region_b, ram_base + ram_len - region_b.len);
        if (std.c.ftruncate(out.handle, @intCast(ram_base + ram_len)) != 0) {
            return error.Truncate;
        }
    }

    const file = try tmp.dir.openFile(io, "state.img", .{ .mode = .read_only });
    defer file.close(io);

    const ram = try testing.allocator.alloc(u8, ram_len);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    try testing.expect(Machine.readRamDataRegions(file, ram, ram_base));
    try testing.expect(std.mem.allEqual(u8, ram[64 * 1024 .. 80 * 1024], 0xA5));
    try testing.expect(std.mem.allEqual(u8, ram[ram_len - region_b.len ..], 0x5A));
    try testing.expect(std.mem.allEqual(u8, ram[0 .. 64 * 1024], 0));
    try testing.expect(std.mem.allEqual(u8, ram[80 * 1024 .. ram_len - region_b.len], 0));
}

test "readRamDataRegions handles an image whose RAM span is one hole" {
    const testing = std.testing;
    const io = global.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const ram_base: u64 = 64 * 1024;
    const ram_len: usize = 256 * 1024;
    const header_bytes = [_]u8{0xEE} ** 128;

    {
        const out = try tmp.dir.createFile(io, "hole.img", .{});
        defer out.close(io);
        try out.writePositionalAll(io, &header_bytes, 0);
        if (std.c.ftruncate(out.handle, @intCast(ram_base + ram_len)) != 0) {
            return error.Truncate;
        }
    }

    const file = try tmp.dir.openFile(io, "hole.img", .{ .mode = .read_only });
    defer file.close(io);

    const ram = try testing.allocator.alloc(u8, ram_len);
    defer testing.allocator.free(ram);
    @memset(ram, 0);

    // The SEEK_DATA walk must terminate cleanly via ENXIO (or an
    // extent that ends before ram_base) and leave RAM untouched.
    try testing.expect(Machine.readRamDataRegions(file, ram, ram_base));
    try testing.expect(std.mem.allEqual(u8, ram, 0));
}

test "snapshot section registry stays analyzable" {
    // Mirrors the x86 machine's registry test: force analysis of every
    // section codec so codec rot is a compile error on all hosts. The
    // comptime gate keeps Hypervisor.framework analysis out of Linux
    // test builds.
    if (builtin.os.tag == .macos) {
        inline for (snapshot_sections) |Section| {
            _ = &Section.capture;
            _ = &Section.restore;
        }
    }
}
