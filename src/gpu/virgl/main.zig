//! Virgl GPU Translation Layer.
//!
//! Parses OpenGL 4.3 commands from guest Mesa driver (via virgl protocol)
//! and translates them to Metal API calls.
//!
//! Architecture:
//! 1. Guest Mesa driver → virgl command stream via virtio-gpu
//! 2. Decoder parses command stream
//! 3. Context manages OpenGL state machine
//! 4. Metal backend issues actual GPU commands

const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const decoder = @import("decoder.zig");
pub const state = @import("state.zig");
pub const context = @import("context.zig");

// Re-export commonly used types
pub const Command = protocol.Command;
pub const ObjectType = protocol.ObjectType;
pub const CommandHeader = protocol.CommandHeader;
pub const Decoder = decoder.Decoder;
pub const Context = context.Context;

test {
    _ = protocol;
    _ = decoder;
    _ = state;
    _ = context;
}
