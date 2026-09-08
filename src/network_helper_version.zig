//! Source identity shared by the helper and its clients. Keep the input list
//! complete when adding helper dependencies. This identifies source, not age.
const std = @import("std");

pub const value = blk: {
    @setEvalBranchQuota(20_000_000);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (.{
        @embedFile("network_helper_main.zig"),
        @embedFile("network_helper_version.zig"),
        @embedFile("net/shared_protocol.zig"),
        @embedFile("net/shared.zig"),
        @embedFile("net/vmnet.zig"),
        @embedFile("net/packet_batch.zig"),
        @embedFile("compat/net.zig"),
        @embedFile("callback.zig"),
    }) |source| {
        hash.update(source);
        hash.update("\x00");
    }
    break :blk std.fmt.bytesToHex(hash.finalResult(), .lower);
};
