//! Apple Hypervisor.framework bindings for ARM64.
//!
//! Provides Zig wrappers around the C API for:
//! - VM creation/destruction (hv_vm_create, hv_vm_destroy)
//! - vCPU management (hv_vcpu_create, hv_vcpu_run, hv_vcpu_destroy)
//! - Memory mapping (hv_vm_map, hv_vm_unmap)
//! - Register access (general-purpose, system, SIMD/FP)
//!
//! Requirements:
//! - macOS 11.0+ (Big Sur or later)
//! - Apple Silicon (ARM64)
//! - `com.apple.security.hypervisor` entitlement
//!
//! Note: Only one VM can exist per process.

const std = @import("std");

pub const c = @import("c.zig");
pub const vm = @import("vm.zig");
pub const vcpu = @import("vcpu.zig");
pub const runner = @import("runner.zig");

// Re-export main types
pub const VM = vm.VM;
pub const Vcpu = vcpu.Vcpu;
pub const MemoryFlags = vm.MemoryFlags;
pub const FileOverlay = vm.FileOverlay;
pub const VMRunner = runner.VMRunner;
pub const VcpuRunner = runner.VcpuRunner;
pub const MmioHandler = runner.MmioHandler;
pub const MmioAccess = runner.MmioAccess;

// Memory flag presets
pub const MEM_READ = vm.MEM_READ;
pub const MEM_READ_WRITE = vm.MEM_READ_WRITE;
pub const MEM_READ_EXEC = vm.MEM_READ_EXEC;
pub const MEM_READ_WRITE_EXEC = vm.MEM_READ_WRITE_EXEC;

// Register types
pub const Register = vcpu.Register;
pub const SystemRegister = vcpu.SystemRegister;
pub const SimdFpRegister = vcpu.SimdFpRegister;

// Exit information
pub const ExitReason = vcpu.ExitReason;
pub const ExitInfo = vcpu.ExitInfo;
pub const ExceptionClass = vcpu.ExceptionClass;
pub const InterruptType = vcpu.InterruptType;

// Error type
pub const Error = c.Error;

test {
    _ = c;
    _ = vm;
    _ = vcpu;
    _ = runner;
}
