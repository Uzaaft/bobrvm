//! Linux KVM host backend.
//!
//! KVM file descriptors are owned by their wrapper and closed by `deinit`.
//! A VM may own multiple vCPUs; each vCPU owns its shared `kvm_run` mapping.

const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;

pub const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("linux/kvm.h");
    @cInclude("sys/ioctl.h");
});

pub const API_VERSION: c_int = 12;

pub const Error = OpenError || CreateError || RunError;

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
};

pub const Cpuid = extern struct {
    nent: u32 = entries_max,
    padding: u32 = 0,
    entries: [entries_max]c.struct_kvm_cpuid_entry2 =
        std.mem.zeroes([entries_max]c.struct_kvm_cpuid_entry2),

    const entries_max = 256;
};

pub const RunError = error{
    Interrupted,
    RunFailed,
};

pub const Capability = enum(c_int) {
    user_memory = c.KVM_CAP_USER_MEMORY,
    irqfd = c.KVM_CAP_IRQFD,
    ioeventfd = c.KVM_CAP_IOEVENTFD,
    immediate_exit = c.KVM_CAP_IMMEDIATE_EXIT,
    x86_user_space_msr = c.KVM_CAP_X86_USER_SPACE_MSR,
};

pub const Capabilities = struct {
    user_memory: bool,
    irqfd: bool,
    ioeventfd: bool,
    immediate_exit: bool,
    x86_user_space_msr: bool,

    pub fn supportsFastDevicePath(self: Capabilities) bool {
        return self.irqfd and self.ioeventfd;
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
            .memory_region = null,
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

    fn checkExtension(fd: std.posix.fd_t, capability: Capability) bool {
        return c.ioctl(fd, c.KVM_CHECK_EXTENSION, @intFromEnum(capability)) > 0;
    }

    fn openError() OpenError {
        return switch (std.c.errno(@as(c_int, -1))) {
            .ACCES, .PERM => error.AccessDenied,
            .NOENT, .NODEV => error.DeviceUnavailable,
            else => error.IoctlFailed,
        };
    }
};

pub const VM = struct {
    fd: std.posix.fd_t,
    vcpu_run_size: usize,
    memory_region: ?MemoryRegion,

    const page_size: u64 = 4096;

    const MemoryRegion = struct {
        memory: []align(std.heap.page_size_min) u8,
    };

    pub fn deinit(self: *VM) void {
        assert(self.fd >= 0);
        if (self.memory_region) |region| std.posix.munmap(region.memory);
        _ = std.c.close(self.fd);
        self.memory_region = null;
        self.fd = -1;
    }

    pub fn mapMemory(
        self: *VM,
        slot: u32,
        guest_address: u64,
        size: usize,
    ) CreateError![]align(std.heap.page_size_min) u8 {
        try validateMemoryRegion(guest_address, size);
        if (self.memory_region != null) return error.MemoryAlreadyMapped;

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

        self.memory_region = .{ .memory = memory };
        return memory;
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
};

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

    pub fn runOnce(self: *Vcpu) RunError!ExitReason {
        self.run.immediate_exit = 0;
        if (c.ioctl(self.fd, c.KVM_RUN, @as(c_ulong, 0)) < 0) {
            return switch (std.c.errno(@as(c_int, -1))) {
                .INTR => error.Interrupted,
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

test "KVM requires userspace guest memory" {
    const caps = Capabilities{
        .user_memory = false,
        .irqfd = true,
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
        .ioeventfd = false,
        .immediate_exit = true,
        .x86_user_space_msr = true,
    };
    try std.testing.expect(!caps.supportsFastDevicePath());
    caps.ioeventfd = true;
    try std.testing.expect(caps.supportsFastDevicePath());
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
