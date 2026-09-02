//! Guest-agent protocol module rooted at `src` for shared authentication imports.

pub const protocol = @import("agent/protocol.zig");

pub const protocol_version = protocol.protocol_version;
pub const payload_bytes_max = protocol.payload_bytes_max;
pub const clipboard_text_bytes_max = protocol.clipboard_text_bytes_max;
pub const authentication_principal_bytes_max = protocol.authentication_principal_bytes_max;
pub const Header = protocol.Header;
pub const MessageKind = protocol.MessageKind;
pub const Frame = protocol.Frame;
pub const CodecError = protocol.CodecError;
pub const Capability = protocol.Capability;
pub const AuthenticationCapability = protocol.AuthenticationCapability;
pub const AuthenticationOperation = protocol.AuthenticationOperation;
pub const AuthenticationRequest = protocol.AuthenticationRequest;
pub const AuthenticationResponse = protocol.AuthenticationResponse;
pub const AuthenticationResult = protocol.AuthenticationResult;
pub const AuthenticationFrontendSession = protocol.AuthenticationFrontendSession;
pub const authenticationCapabilities = protocol.authenticationCapabilities;
pub const Clipboard = protocol.Clipboard;
pub const FileChunk = protocol.FileChunk;
pub const FileOffer = protocol.FileOffer;
pub const encode = protocol.encode;
pub const encodeHeader = protocol.encodeHeader;
pub const Decoder = protocol.Decoder;

test {
    _ = protocol;
}
