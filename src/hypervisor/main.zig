//! Apple Hypervisor.framework bindings for ARM64.
//!
//! Hypervisor.framework permits only one VM per process and requires the
//! `com.apple.security.hypervisor` entitlement.

const std = @import("std");

pub const c = @import("c.zig");
pub const vm = @import("vm.zig");
pub const vcpu = @import("vcpu.zig");
pub const runner = @import("runner.zig");

pub const VM = vm.VM;
pub const Vcpu = vcpu.Vcpu;
pub const MemoryFlags = vm.MemoryFlags;
pub const FileOverlay = vm.FileOverlay;
pub const VMRunner = runner.VMRunner;
pub const VcpuRunner = runner.VcpuRunner;
pub const MmioHandler = runner.MmioHandler;
pub const MmioAccess = runner.MmioAccess;

pub const MEM_READ = vm.MEM_READ;
pub const MEM_READ_WRITE = vm.MEM_READ_WRITE;
pub const MEM_READ_EXEC = vm.MEM_READ_EXEC;
pub const MEM_READ_WRITE_EXEC = vm.MEM_READ_WRITE_EXEC;

pub const Register = vcpu.Register;
pub const SystemRegister = vcpu.SystemRegister;
pub const SimdFpRegister = vcpu.SimdFpRegister;

pub const ExitReason = vcpu.ExitReason;
pub const ExitInfo = vcpu.ExitInfo;
pub const ExceptionClass = vcpu.ExceptionClass;
pub const InterruptType = vcpu.InterruptType;

pub const Error = c.Error;

test {
    _ = c;
    _ = vm;
    _ = vcpu;
    _ = runner;
}
