//! # code-lite-storage
//!
//! SQLite-backed state and memory engine for CodeLiteX.
//!
//! Manages CodeGraph persistence (symbols, call graphs, import graphs),
//! agent session memory, atomic operation history with undo/rollback,
//! and the global event stream.

pub mod approval_store;
pub mod db;
pub mod diagnostic_store;
pub mod error;
pub mod event_store;
pub mod graph_store;
pub mod memory_store;
pub mod models;
pub mod op_store;
pub mod schema;
pub mod session_store;

pub use approval_store::ApprovalStore;
pub use db::Database;
pub use diagnostic_store::DiagnosticStore;
pub use error::StorageError;
pub use event_store::EventStore;
pub use graph_store::GraphStore;
pub use memory_store::{DecisionMemory, ErrorMemory, MemoryStore, NewDecisionMemory, NewErrorMemory};
pub use models::*;
pub use op_store::OperationStore;
pub use session_store::SessionStore;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
