//! Common machine configuration for CLI execution paths.

const Config = @import("Config.zig");
const machine = @import("../machine/main.zig");

/// Borrows paths from config; callers add execution-specific devices and policy.
pub fn base(config: *const Config) machine.MachineConfig {
    return .{
        .ram_size = config.memory_mb * 1024 * 1024,
        .vcpu_count = config.vcpu_count,
        .firmware_path = config.firmware_path,
        .vars_path = config.vars_path,
        .kernel_path = config.kernel_path,
        .initrd_path = config.initrd_path,
        .cmdline = config.cmdline,
        .disk_path = config.disk_path,
        .disk_read_only = config.disk_read_only,
        .disk2_path = config.disk2_path,
        .disk2_read_only = config.disk2_read_only,
        .enable_net = config.enable_net,
        .network_shared = config.network_shared,
        .network_mac = config.network_mac,
        .shared_dir = config.shared_dir,
        .share_read_only = config.share_read_only,
        .restore_path = config.restore_path,
    };
}
