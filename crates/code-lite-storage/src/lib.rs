//! # code-lite-storage
//!
//! SQLite-backed persistence for CodeLiteX.
//!
//! Manages CodeGraph persistence (symbols, call graphs, import graphs,
//! resumable index jobs) and LSP diagnostics.

pub mod db;
pub mod diagnostic_store;
pub mod error;
pub mod graph_store;
pub mod models;
pub mod schema;

pub use db::Database;
pub use diagnostic_store::DiagnosticStore;
pub use error::StorageError;
pub use graph_store::GraphStore;
pub use models::*;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
