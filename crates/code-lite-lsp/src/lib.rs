//! # code-lite-lsp
//!
//! Language Server Protocol (LSP 3.17) cognitive infrastructure for CodeLiteX.
//!
//! Exposes 6 core capabilities ordered by AI Agent closed loop & core editor requirements:
//! 1. Diagnostics (Agent verify & real-time syntax checking)
//! 2. Definition (Go to definition)
//! 3. References (Find all callers/usages)
//! 4. Hover (Type annotations & Markdown docs)
//! 5. Completion (Intelligent code completion)
//! 6. Rename (Workspace-wide atomic refactoring)

pub mod client;
pub mod protocol;
pub mod transport;
pub mod virtual_server;

pub use client::{DiagnosticsCallback, LspClient};
pub use protocol::*;
pub use transport::{FramedReader, FramedWriter};
pub use virtual_server::VirtualLspServer;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
