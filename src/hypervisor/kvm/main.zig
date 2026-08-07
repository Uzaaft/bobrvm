//! Linux KVM host backend.
//!
//! KVM file descriptors are owned by their wrapper and closed by `deinit`.
//! A VM may own multiple vCPUs; each vCPU owns its shared `kvm_run` mapping.

const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;

pub const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("linux/kvm.h");
    @cInclude("sys/eventfd.h");
    @cInclude("sys/ioctl.h");
});

pub const API_VERSION: c_int = 12;

const kick_signal = std.posix.SIG.USR1;
var kick_handler_state = std.atomic.Value(u8).init(0);

pub const Error = OpenError || CreateError || FastPathError || InterruptError || RunError;

pub const OpenError = error{
    AccessDenied,
    DeviceUnavailable,
    UnsupportedApiVersion,
    MissingUserMemory,
    IoctlFailed,
};

pub const CreateError = error{
    ConfigureVcpuFailed,
    CreateIrqChipFailed,
    CreatePitFailed,
    CreateVmFailed,
    CreateVcpuFailed,
    GetCpuidFailed,
    InvalidMemoryRegion,
    MapRunFailed,
    MapMemoryFailed,
    MemoryAlreadyMapped,
    RegisterMemoryFailed,
    SetCpuidFailed,
    SetMpStateFailed,
};

pub const Cpuid = extern struct {
    nent: u32 = entries_max,
    padding: u32 = 0,
    entries: [entries_max]c.struct_kvm_cpuid_entry2 =
        std.mem.zeroes([entries_max]c.struct_kvm_cpuid_entry2),

    const entries_max = 256;

    pub fn setTopology(self: *Cpuid, cpu_id: u8, cpu_count: u8) void {
        assert(cpu_count > 0);
        assert(cpu_id < cpu_count);
        for (self.entries[0..self.nent]) |*entry| switch (entry.function) {
            0x0000_0001 => {
                entry.ebx &= 0x0000_ffff;
                entry.ebx |= @as(u32, cpu_count) << 16;
                entry.ebx |= @as(u32, cpu_id) << 24;
                if (cpu_count > 1) entry.edx |= @as(u32, 1) << 28;
            },
            0x0000_000b, 0x0000_001f => entry.edx = cpu_id,
            0x8000_001e => {
                entry.eax = cpu_id;
                entry.ebx = (entry.ebx & 0xffff_ff00) | cpu_id;
            },
            else => {},
        };
    }
};

pub const RunError = error{
    Interrupted,
    InvalidVcpuState,
    RunFailed,
    VcpuUninitialized,
    WouldBlock,
};

pub const InterruptError = error{SetIrqFailed};

pub const FastPathError = error{
    CreateEventFdFailed,
    RegisterIoEventFailed,
    RegisterIrqFdFailed,
};

pub const Capability = enum(c_int) {
    user_memory = c.KVM_CAP_USER_MEMORY,
    irqfd = c.KVM_CAP_IRQFD,
    irqfd_resample = c.KVM_CAP_IRQFD_RESAMPLE,
    ioeventfd = c.KVM_CAP_IOEVENTFD,
    immediate_exit = c.KVM_CAP_IMMEDIATE_EXIT,
    x86_user_space_msr = c.KVM_CAP_X86_USER_SPACE_MSR,
};

pub const VcpuLimits = struct {
    recommended: u32,
    maximum: u32,
    id_max: u32,
};

pub const Capabilities = struct {
    user_memory: bool,
    irqfd: bool,
    irqfd_resample: bool,
    ioeventfd: bool,
    immediate_exit: bool,
    x86_user_space_msr: bool,

    pub fn supportsFastDevicePath(self: Capabilities) bool {
        return self.irqfd and self.irqfd_resample and self.ioeventfd;
    }

    pub fn validate(self: Capabilities) OpenError!void {
        if (!self.user_memory) return error.MissingUserMemory;
    }
};

pub const Kvm = struct {
    fd: std.posix.fd_t,
    vcpu_run_size: usize,
    capabilities: Capabilities,

    pub fn open() OpenError!Kvm {
        installKickHandler();
        const fd = c.open("/dev/kvm", c.O_RDWR | c.O_CLOEXEC);
        if (fd < 0) return openError();
        errdefer _ = std.c.close(fd);

        const api_version = c.ioctl(fd, c.KVM_GET_API_VERSION, @as(c_ulong, 0));
        if (api_version < 0) return error.IoctlFailed;
        if (api_version != API_VERSION) return error.UnsupportedApiVersion;

        const run_size = c.ioctl(fd, c.KVM_GET_VCPU_MMAP_SIZE, @as(c_ulong, 0));
        if (run_size <= 0) return error.IoctlFailed;

        const capabilities = Capabilities{
            .user_memory = checkExtension(fd, .user_memory),
            .irqfd = checkExtension(fd, .irqfd),
            .irqfd_resample = checkExtension(fd, .irqfd_resample),
            .ioeventfd = checkExtension(fd, .ioeventfd),
            .immediate_exit = checkExtension(fd, .immediate_exit),
            .x86_user_space_msr = checkExtension(fd, .x86_user_space_msr),
        };
        try capabilities.validate();

        return .{
            .fd = fd,
            .vcpu_run_size = @intCast(run_size),
            .capabilities = capabilities,
        };
    }

    pub fn deinit(self: *Kvm) void {
        assert(self.fd >= 0);
        _ = std.c.close(self.fd);
        self.fd = -1;
    }

    pub fn createVm(self: *const Kvm) CreateError!VM {
        const fd = c.ioctl(self.fd, c.KVM_CREATE_VM, @as(c_ulong, 0));
        if (fd < 0) return error.CreateVmFailed;
        return .{
            .fd = fd,
            .vcpu_run_size = self.vcpu_run_size,
            .memory_regions = @splat(null),
        };
    }

    pub fn supportedCpuid(self: *const Kvm) CreateError!Cpuid {
        var cpuid = Cpuid{};
        const header: *c.struct_kvm_cpuid2 = @ptrCast(&cpuid);
        if (c.ioctl(self.fd, c.KVM_GET_SUPPORTED_CPUID, header) < 0) {
            return error.GetCpuidFailed;
        }
        return cpuid;
    }

    pub fn vcpuLimits(self: *const Kvm) VcpuLimits {
        const recommended = checkExtensionValue(self.fd, c.KVM_CAP_NR_VCPUS, 4);
        const maximum = checkExtensionValue(self.fd, c.KVM_CAP_MAX_VCPUS, recommended);
        const id_max = checkExtensionValue(self.fd, c.KVM_CAP_MAX_VCPU_ID, maximum);
        return .{ .recommended = recommended, .maximum = maximum, .id_max = id_max };
    }

    fn checkExtension(fd: std.posix.fd_t, capability: Capability) bool {
        return c.ioctl(fd, c.KVM_CHECK_EXTENSION, @intFromEnum(capability)) > 0;
    }

    fn checkExtensionValue(fd: std.posix.fd_t, capability: c_int, fallback: u32) u32 {
        const value = c.ioctl(fd, c.KVM_CHECK_EXTENSION, capability);
        return if (value > 0) @intCast(value) else fallback;
    }

    fn openError() OpenError {
        return switch (std.c.errno(@as(c_int, -1))) {
            .ACCES, .PERM => error.AccessDenied,
            .NOENT, .NODEV => error.DeviceUnavailable,
            else => error.IoctlFailed,
        };
    }
};

/// Interrupt the KVM_RUN ioctl owned by a Linux thread after setting immediate_exit.
pub fn interruptThread(thread_id: u32) void {
    _ = std.os.linux.tgkill(std.os.linux.getpid(), @intCast(thread_id), kick_signal);
}

fn installKickHandler() void {
    if (kick_handler_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        const action = std.posix.Sigaction{
            .handler = .{ .handler = kickSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(kick_signal, &action, null);
        kick_handler_state.store(2, .release);
        return;
    }
    while (kick_handler_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn kickSignalHandler(_: std.posix.SIG) callconv(.c) void {}

pub const VM = struct {
    fd: std.posix.fd_t,
    vcpu_run_size: usize,
    memory_regions: [memory_regions_max]?MemoryRegion,

    const page_size: u64 = 4096;
    const memory_regions_max: usize = 8;

    const MemoryRegion = struct {
        slot: u32,
        guest_address: u64,
        memory: []align(std.heap.page_size_min) u8,
    };

    pub fn deinit(self: *VM) void {
        assert(self.fd >= 0);
        for (&self.memory_regions) |*entry| {
            if (entry.*) |region| std.posix.munmap(region.memory);
            entry.* = null;
        }
        _ = std.c.close(self.fd);
        self.fd = -1;
    }

    pub fn mapMemory(
        self: *VM,
        slot: u32,
        guest_address: u64,
        size: usize,
    ) CreateError![]align(std.heap.page_size_min) u8 {
        try validateMemoryRegion(guest_address, size);
        const entry = self.freeMemoryRegion(slot, guest_address, size) orelse
            return error.MemoryAlreadyMapped;

        const memory = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.MapMemoryFailed;
        errdefer std.posix.munmap(memory);

        var region = c.struct_kvm_userspace_memory_region{
            .slot = slot,
            .flags = 0,
            .guest_phys_addr = guest_address,
            .memory_size = size,
            .userspace_addr = @intFromPtr(memory.ptr),
        };
        if (c.ioctl(self.fd, c.KVM_SET_USER_MEMORY_REGION, &region) < 0) {
            return error.RegisterMemoryFailed;
        }

        entry.* = .{
            .slot = slot,
            .guest_address = guest_address,
            .memory = memory,
        };
        return memory;
    }

    fn freeMemoryRegion(
        self: *VM,
        slot: u32,
        guest_address: u64,
        size: usize,
    ) ?*?MemoryRegion {
        const guest_end = guest_address + @as(u64, @intCast(size));
        var free: ?*?MemoryRegion = null;
        for (&self.memory_regions) |*entry| {
            const region = entry.* orelse {
                if (free == null) free = entry;
                continue;
            };
            if (region.slot == slot) return null;
            const region_end = region.guest_address + @as(u64, @intCast(region.memory.len));
            if (guest_address < region_end and region.guest_address < guest_end) return null;
        }
        return free;
    }

    pub fn validateMemoryRegion(
        guest_address: u64,
        size: usize,
    ) error{InvalidMemoryRegion}!void {
        if (size == 0) return error.InvalidMemoryRegion;
        if (guest_address % page_size != 0) return error.InvalidMemoryRegion;
        if (size % page_size != 0) return error.InvalidMemoryRegion;
        _ = std.math.add(u64, guest_address, size) catch return error.InvalidMemoryRegion;
    }

    pub fn createVcpu(self: *const VM, id: u32) CreateError!Vcpu {
        const fd = c.ioctl(self.fd, c.KVM_CREATE_VCPU, @as(c_ulong, id));
        if (fd < 0) return error.CreateVcpuFailed;
        errdefer _ = std.c.close(fd);

        const run_memory = std.posix.mmap(
            null,
            self.vcpu_run_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.MapRunFailed;

        return .{
            .fd = fd,
            .run_memory = run_memory,
            .run = @ptrCast(run_memory.ptr),
        };
    }

    pub fn createPcInterrupts(self: *VM) CreateError!void {
        if (c.ioctl(self.fd, c.KVM_CREATE_IRQCHIP, @as(c_ulong, 0)) < 0) {
            return error.CreateIrqChipFailed;
        }
        var pit = std.mem.zeroes(c.struct_kvm_pit_config);
        if (c.ioctl(self.fd, c.KVM_CREATE_PIT2, &pit) < 0) {
            return error.CreatePitFailed;
        }
    }

    pub fn setIrqLine(self: *VM, irq: u32, level: bool) InterruptError!void {
        var irq_level = c.struct_kvm_irq_level{
            .unnamed_0 = .{ .irq = irq },
            .level = @intFromBool(level),
        };
        if (c.ioctl(self.fd, c.KVM_IRQ_LINE, &irq_level) < 0) {
            return error.SetIrqFailed;
        }
    }

    /// Register an MMIO address whose guest writes signal `event` without a VM exit.
    pub fn registerIoEvent(
        self: *VM,
        event: EventFd,
        guest_address: u64,
    ) FastPathError!void {
        var descriptor = ioEventDescriptor(event, guest_address, false);
        if (c.ioctl(self.fd, c.KVM_IOEVENTFD, &descriptor) < 0) {
            return error.RegisterIoEventFailed;
        }
    }

    pub fn unregisterIoEvent(self: *VM, event: EventFd, guest_address: u64) void {
        var descriptor = ioEventDescriptor(event, guest_address, true);
        _ = c.ioctl(self.fd, c.KVM_IOEVENTFD, &descriptor);
    }

    /// Route eventfd assertions to a level-triggered guest interrupt.
    pub fn registerIrqFd(
        self: *VM,
        event: EventFd,
        resample_event: EventFd,
        irq: u32,
    ) FastPathError!void {
        var descriptor = irqFdDescriptor(event, resample_event, irq, false);
        if (c.ioctl(self.fd, c.KVM_IRQFD, &descriptor) < 0) {
            return error.RegisterIrqFdFailed;
        }
    }

    pub fn unregisterIrqFd(
        self: *VM,
        event: EventFd,
        resample_event: EventFd,
        irq: u32,
    ) void {
        var descriptor = irqFdDescriptor(event, resample_event, irq, true);
        _ = c.ioctl(self.fd, c.KVM_IRQFD, &descriptor);
    }
};

/// A nonblocking eventfd used for KVM device notifications and interrupt routing.
pub const EventFd = struct {
    fd: std.posix.fd_t,

    pub fn init() FastPathError!EventFd {
        const fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (fd < 0) return error.CreateEventFdFailed;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *EventFd) void {
        assert(self.fd >= 0);
        _ = std.c.close(self.fd);
        self.fd = -1;
    }

    pub fn signal(self: EventFd) bool {
        var value: u64 = 1;
        return std.c.write(self.fd, std.mem.asBytes(&value).ptr, @sizeOf(u64)) ==
            @sizeOf(u64);
    }

    pub fn consume(self: EventFd) ?u64 {
        var value: u64 = 0;
        if (std.c.read(self.fd, std.mem.asBytes(&value).ptr, @sizeOf(u64)) != @sizeOf(u64)) {
            return null;
        }
        return value;
    }
};

fn ioEventDescriptor(
    event: EventFd,
    guest_address: u64,
    deassign: bool,
) c.struct_kvm_ioeventfd {
    return .{
        .datamatch = 0,
        .addr = guest_address,
        .len = 0,
        .fd = event.fd,
        .flags = if (deassign) c.KVM_IOEVENTFD_FLAG_DEASSIGN else 0,
        .pad = std.mem.zeroes([36]u8),
    };
}

fn irqFdDescriptor(
    event: EventFd,
    resample_event: EventFd,
    irq: u32,
    deassign: bool,
) c.struct_kvm_irqfd {
    return .{
        .fd = @intCast(event.fd),
        .gsi = irq,
        .flags = if (deassign) c.KVM_IRQFD_FLAG_DEASSIGN else c.KVM_IRQFD_FLAG_RESAMPLE,
        .resamplefd = @intCast(resample_event.fd),
        .pad = std.mem.zeroes([16]u8),
    };
}

pub const ExitReason = enum {
    halted,
    io,
    mmio,
    shutdown,
    interrupted,
    internal_error,
    unknown,
};

pub const IoDirection = enum {
    read,
    write,
};

pub const IoExit = struct {
    direction: IoDirection,
    port: u16,
    size: u8,
    count: u32,
    data: []u8,
};

pub const MmioExit = struct {
    direction: IoDirection,
    address: u64,
    data: []u8,
};

pub const Vcpu = struct {
    fd: std.posix.fd_t,
    run_memory: []align(std.heap.page_size_min) u8,
    run: *c.struct_kvm_run,

    pub fn deinit(self: *Vcpu) void {
        assert(self.fd >= 0);
        std.posix.munmap(self.run_memory);
        _ = std.c.close(self.fd);
        self.fd = -1;
    }

    pub fn requestExit(self: *Vcpu) void {
        @atomicStore(u8, &self.run.immediate_exit, 1, .release);
    }

    pub fn clearExitRequest(self: *Vcpu) void {
        @atomicStore(u8, &self.run.immediate_exit, 0, .release);
    }

    pub fn setRealModeEntry(
        self: *Vcpu,
        instruction_pointer: u64,
        stack_pointer: u64,
    ) CreateError!void {
        var special: c.struct_kvm_sregs = undefined;
        if (c.ioctl(self.fd, c.KVM_GET_SREGS, &special) < 0) {
            return error.ConfigureVcpuFailed;
        }
        special.cs.base = 0;
        special.cs.selector = 0;
        if (c.ioctl(self.fd, c.KVM_SET_SREGS, &special) < 0) {
            return error.ConfigureVcpuFailed;
        }

        var registers = std.mem.zeroes(c.struct_kvm_regs);
        registers.rip = instruction_pointer;
        registers.rsp = stack_pointer;
        registers.rflags = 2;
        if (c.ioctl(self.fd, c.KVM_SET_REGS, &registers) < 0) {
            return error.ConfigureVcpuFailed;
        }
    }

    /// Configure the architectural x86 reset vector used by PC firmware.
    pub fn setFirmwareReset(self: *Vcpu) CreateError!void {
        var special: c.struct_kvm_sregs = undefined;
        if (c.ioctl(self.fd, c.KVM_GET_SREGS, &special) < 0) {
            return error.ConfigureVcpuFailed;
        }
        special.cs.base = 0xffff_0000;
        special.cs.selector = 0xf000;
        special.cr0 = 0x6000_0010;
        special.cr4 = 0;
        special.efer = 0;
        if (c.ioctl(self.fd, c.KVM_SET_SREGS, &special) < 0) {
            return error.ConfigureVcpuFailed;
        }

        var registers = std.mem.zeroes(c.struct_kvm_regs);
        registers.rip = 0xfff0;
        registers.rflags = 2;
        registers.rdx = 0x600;
        if (c.ioctl(self.fd, c.KVM_SET_REGS, &registers) < 0) {
            return error.ConfigureVcpuFailed;
        }
    }

    pub fn setProtectedModeEntry(
        self: *Vcpu,
        instruction_pointer: u64,
        boot_params_address: u64,
        gdt_address: u64,
    ) CreateError!void {
        var special: c.struct_kvm_sregs = undefined;
        if (c.ioctl(self.fd, c.KVM_GET_SREGS, &special) < 0) {
            return error.ConfigureVcpuFailed;
        }
        special.cs = protectedSegment(0x8, true);
        const data = protectedSegment(0x10, false);
        special.ds = data;
        special.es = data;
        special.fs = data;
        special.gs = data;
        special.ss = data;
        special.gdt.base = gdt_address;
        special.gdt.limit = 3 * 8 - 1;
        special.cr0 |= 1;
        special.efer = 0;
        if (c.ioctl(self.fd, c.KVM_SET_SREGS, &special) < 0) {
            return error.ConfigureVcpuFailed;
        }

        var registers = std.mem.zeroes(c.struct_kvm_regs);
        registers.rip = instruction_pointer;
        registers.rsi = boot_params_address;
        registers.rflags = 2;
        if (c.ioctl(self.fd, c.KVM_SET_REGS, &registers) < 0) {
            return error.ConfigureVcpuFailed;
        }
    }

    pub fn setCpuid(self: *Vcpu, cpuid: *Cpuid) CreateError!void {
        const header: *c.struct_kvm_cpuid2 = @ptrCast(cpuid);
        if (c.ioctl(self.fd, c.KVM_SET_CPUID2, header) < 0) {
            return error.SetCpuidFailed;
        }
    }

    pub fn setApplicationProcessorState(self: *Vcpu) CreateError!void {
        var state = c.struct_kvm_mp_state{ .mp_state = c.KVM_MP_STATE_UNINITIALIZED };
        if (c.ioctl(self.fd, c.KVM_SET_MP_STATE, &state) < 0) {
            return error.SetMpStateFailed;
        }
    }

    pub fn runOnce(self: *Vcpu) RunError!ExitReason {
        if (c.ioctl(self.fd, c.KVM_RUN, @as(c_ulong, 0)) < 0) {
            return switch (std.c.errno(@as(c_int, -1))) {
                .INTR => error.Interrupted,
                .AGAIN => error.WouldBlock,
                .INVAL => error.InvalidVcpuState,
                .NOEXEC => error.VcpuUninitialized,
                else => error.RunFailed,
            };
        }
        return exitReason(self.run.exit_reason);
    }

    pub fn ioExit(self: *Vcpu) ?IoExit {
        if (self.run.exit_reason != c.KVM_EXIT_IO) return null;
        const io = self.run.unnamed_0.io;
        const length = std.math.mul(usize, io.size, io.count) catch return null;
        if (io.data_offset > self.run_memory.len) return null;
        const offset: usize = @intCast(io.data_offset);
        if (length > self.run_memory.len - offset) return null;
        const direction: IoDirection = switch (io.direction) {
            c.KVM_EXIT_IO_IN => .read,
            c.KVM_EXIT_IO_OUT => .write,
            else => return null,
        };
        return .{
            .direction = direction,
            .port = io.port,
            .size = io.size,
            .count = io.count,
            .data = self.run_memory[offset..][0..length],
        };
    }

    pub fn mmioExit(self: *Vcpu) ?MmioExit {
        if (self.run.exit_reason != c.KVM_EXIT_MMIO) return null;
        const mmio = &self.run.unnamed_0.mmio;
        if (mmio.len == 0 or mmio.len > mmio.data.len) return null;
        const direction: IoDirection = switch (mmio.is_write) {
            0 => .read,
            1 => .write,
            else => return null,
        };
        return .{
            .direction = direction,
            .address = mmio.phys_addr,
            .data = mmio.data[0..mmio.len],
        };
    }

    fn exitReason(reason: u32) ExitReason {
        return switch (reason) {
            c.KVM_EXIT_HLT => .halted,
            c.KVM_EXIT_IO => .io,
            c.KVM_EXIT_MMIO => .mmio,
            c.KVM_EXIT_SHUTDOWN => .shutdown,
            c.KVM_EXIT_INTR => .interrupted,
            c.KVM_EXIT_INTERNAL_ERROR => .internal_error,
            else => .unknown,
        };
    }

    fn protectedSegment(selector: u16, executable: bool) c.struct_kvm_segment {
        return .{
            .base = 0,
            .limit = std.math.maxInt(u32),
            .selector = selector,
            .type = if (executable) 11 else 3,
            .present = 1,
            .dpl = 0,
            .db = 1,
            .s = 1,
            .l = 0,
            .g = 1,
            .avl = 0,
            .unusable = 0,
            .padding = 0,
        };
    }
};

pub const smoke_payload = [_]u8{
    0xba, 0xf8, 0x03, // mov dx, 0x3f8
    0xb0, 'B', // mov al, 'B'
    0xee, // out dx, al
    0xf4, // hlt
};

pub fn runSmoke() (Error || error{ UnexpectedExit, UnexpectedIo })!void {
    var host = try Kvm.open();
    defer host.deinit();

    var vm = try host.createVm();
    defer vm.deinit();
    const memory = try vm.mapMemory(0, 0, 64 * 1024);
    @memcpy(memory[0x1000..][0..smoke_payload.len], &smoke_payload);

    var vcpu = try vm.createVcpu(0);
    defer vcpu.deinit();
    try vcpu.setRealModeEntry(0x1000, 0x8000);

    if (try vcpu.runOnce() != .io) return error.UnexpectedExit;
    const io = vcpu.ioExit() orelse return error.UnexpectedIo;
    if (io.direction != .write or io.port != 0x3f8 or io.size != 1 or
        io.count != 1 or io.data[0] != 'B')
    {
        return error.UnexpectedIo;
    }
    if (try vcpu.runOnce() != .halted) return error.UnexpectedExit;
}

test "KVM API version matches the stable userspace contract" {
    try std.testing.expectEqual(API_VERSION, c.KVM_API_VERSION);
}

test "CPUID topology gives every vCPU a distinct APIC identity" {
    var cpuid = Cpuid{ .nent = 4 };
    cpuid.entries[0].function = 1;
    cpuid.entries[1].function = 0xb;
    cpuid.entries[2].function = 0x1f;
    cpuid.entries[3].function = 0x8000_001e;
    cpuid.setTopology(1, 2);

    try std.testing.expectEqual(@as(u32, 1), cpuid.entries[0].ebx >> 24);
    try std.testing.expectEqual(@as(u32, 2), (cpuid.entries[0].ebx >> 16) & 0xff);
    try std.testing.expectEqual(@as(u32, 1), cpuid.entries[1].edx);
    try std.testing.expectEqual(@as(u32, 1), cpuid.entries[2].edx);
    try std.testing.expectEqual(@as(u32, 1), cpuid.entries[3].eax);
}

test "KVM requires userspace guest memory" {
    const caps = Capabilities{
        .user_memory = false,
        .irqfd = true,
        .irqfd_resample = true,
        .ioeventfd = true,
        .immediate_exit = true,
        .x86_user_space_msr = true,
    };
    try std.testing.expectError(error.MissingUserMemory, caps.validate());
}

test "KVM fast device path needs ioeventfd and irqfd" {
    var caps = Capabilities{
        .user_memory = true,
        .irqfd = true,
        .irqfd_resample = true,
        .ioeventfd = false,
        .immediate_exit = true,
        .x86_user_space_msr = true,
    };
    try std.testing.expect(!caps.supportsFastDevicePath());
    caps.ioeventfd = true;
    try std.testing.expect(caps.supportsFastDevicePath());
    caps.irqfd_resample = false;
    try std.testing.expect(!caps.supportsFastDevicePath());
}

test "KVM fast path descriptors preserve registration identity" {
    const event = EventFd{ .fd = 7 };
    const resample = EventFd{ .fd = 8 };
    const address: u64 = 0xd000_0044;

    const ioevent = ioEventDescriptor(event, address, false);
    try std.testing.expectEqual(address, ioevent.addr);
    try std.testing.expectEqual(@as(u32, 0), ioevent.len);
    try std.testing.expectEqual(@as(i32, 7), ioevent.fd);
    try std.testing.expectEqual(@as(u32, 0), ioevent.flags);

    const irqfd = irqFdDescriptor(event, resample, 11, false);
    try std.testing.expectEqual(@as(u32, 7), irqfd.fd);
    try std.testing.expectEqual(@as(u32, 8), irqfd.resamplefd);
    try std.testing.expectEqual(@as(u32, 11), irqfd.gsi);
    try std.testing.expectEqual(@as(u32, c.KVM_IRQFD_FLAG_RESAMPLE), irqfd.flags);
}

test "eventfd coalesces notifications without blocking" {
    var event = try EventFd.init();
    defer event.deinit();

    try std.testing.expect(event.signal());
    try std.testing.expect(event.signal());
    try std.testing.expectEqual(@as(u64, 2), event.consume().?);
    try std.testing.expectEqual(@as(?u64, null), event.consume());
}

test "KVM guest memory regions are page aligned and nonempty" {
    try std.testing.expectError(error.InvalidMemoryRegion, VM.validateMemoryRegion(0, 0));
    try std.testing.expectError(error.InvalidMemoryRegion, VM.validateMemoryRegion(1, 4096));
    try std.testing.expectError(error.InvalidMemoryRegion, VM.validateMemoryRegion(0, 4095));
    try VM.validateMemoryRegion(0x4000_0000, 4096);
}

test "KVM smoke payload writes a marker then halts" {
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xba, 0xf8, 0x03, 0xb0, 'B', 0xee, 0xf4 },
        &smoke_payload,
    );
}
