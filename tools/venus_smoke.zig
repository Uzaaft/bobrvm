//! Smoke test for the Zig↔virglrenderer Venus bindings.
//!
//! `zig build venus-smoke` configures the required renderer and Vulkan paths.
//! Sandboxed shells may need LLDB because the sandbox can kill virglrenderer's
//! initializer before `main`.

const std = @import("std");
const venus = @import("venus");

pub fn main() !void {
    const host = venus.ensureHost() orelse {
        std.debug.print("venus init FAILED (host unavailable)\n", .{});
        std.process.exit(1);
    };
    defer venus.deinitHost();

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

    // These are the first two operations issued by a guest.
    var caps: [4096]u8 = undefined;
    host.fillCaps(venus.CAPSET_VENUS, v.max_ver, caps[0..v.max_size]);
    std.debug.print("  fill_caps(VENUS, ver={d}) wrote {d} bytes; head={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ v.max_ver, v.max_size, caps[0], caps[1], caps[2], caps[3] });

    host.createVenusContext(1) catch |e| {
        std.debug.print("createVenusContext FAILED: {s}\n", .{@errorName(e)});
        std.process.exit(3);
    };
    std.debug.print("  createVenusContext(1) OK\n", .{});
    host.destroyContext(1);
    std.debug.print("  destroyContext(1) OK\n", .{});

    std.debug.print("venus-smoke ok\n", .{});
}
