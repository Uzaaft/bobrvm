//! Shared policy for virtio transports.

/// Upper bound for queues owned by one emulated device. Sixteen covers the
/// console base and control queues plus six named multiport channels.
pub const device_queues_max: u16 = 16;
