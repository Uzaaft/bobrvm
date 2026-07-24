//! Venus host-backend smoke test (Zig). Proves the Zig↔virglrenderer FFI:
//! initializes the Venus path and confirms the Venus capset is present.
//!
//! Build+sign: `zig build venus-smoke`. Run needs the brew GPU stack on
//! DYLD_LIBRARY_PATH + VK_ICD_FILENAMES (the build step sets these). NOTE: in a
//! sandboxed shell the process may be SIGKILLed before main by the sandbox when
//! virglrenderer's initializers run; run it under lldb there
//! (`lldb -b -o run -o quit zig-out/bin/venus_smoke`). On a normal (codesigned)
//! macOS session it runs directly.

const std = @import("std");
const venus = @import("venus");

pub fn main() !void {
    var host = venus.Host.init() catch |e| {
        std.debug.print("venus init FAILED: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer host.deinit();

    const v = host.getCapset(venus.CAPSET_VENUS);
    const v1 = host.getCapset(venus.CAPSET_VIRGL);
    const v2 = host.getCapset(venus.CAPSET_VIRGL2);
    std.debug.print("venus init OK\n", .{});
    std.debug.print("  VIRGL  capset: max_ver={d} max_size={d} -> {s}\n", .{ v1.max_ver, v1.max_size, if (v1.present()) "PRESENT" else "absent" });
    std.debug.print("  VIRGL2 capset: max_ver={d} max_size={d} -> {s}\n", .{ v2.max_ver, v2.max_size, if (v2.present()) "PRESENT" else "absent" });
    std.debug.print("  VENUS  capset: max_ver={d} max_size={d} -> {s}\n", .{ v.max_ver, v.max_size, if (v.present()) "PRESENT" else "absent" });

    if (!v.present()) {
        std.debug.print("venus-smoke: VENUS capset absent — venus not enabled in this virglrenderer\n", .{});
        std.process.exit(2);
    }
    std.debug.print("venus-smoke ok\n", .{});
}
