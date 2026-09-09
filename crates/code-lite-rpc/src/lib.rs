//! # CodeLite RPC
//!
//! Shared JSON-RPC 2.0 infrastructure: protocol types, transport framing, and request correlation.

pub mod correlation;
pub mod framing;
pub mod protocol;

pub use correlation::RpcTracker;
pub use framing::{FramedReader, FramedWriter};
pub use protocol::{
    error_codes, JsonRpcError, JsonRpcNotification, JsonRpcRequest, JsonRpcResponse,
};
