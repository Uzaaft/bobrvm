//! Focused tests for the helper boundary, runnable without root or vmnet.
test {
    _ = @import("net/shared_protocol.zig");
    _ = @import("net/shared.zig");
}
