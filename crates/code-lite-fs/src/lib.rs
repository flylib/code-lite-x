//! # code-lite-fs
//!
//! File system operations, directory tree traversal, and file scanning for CodeLiteX.

pub mod entry;
pub mod file_index;
pub mod line_diff;
pub mod project_search;
pub mod search;
pub mod tree;
pub mod watcher;

pub use entry::FileSystemEntry;
pub use search::{SearchOptions, SearchResult, WorkspaceSearcher};
pub use tree::WorkspaceTree;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
