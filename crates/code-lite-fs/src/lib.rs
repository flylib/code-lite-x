//! # code-lite-fs
//!
//! File system operations, directory tree traversal, and file scanning for CodeLiteX.

pub mod entry;
pub mod git;
pub mod search;
pub mod tree;
pub mod updater;
pub mod worktree;

pub use entry::FileSystemEntry;
pub use git::{DiffHunkKind, GitEngine, GitError, GitFileChange, GitLineDiff, GitStatusKind, GitStatusResult};
pub use search::{SearchOptions, SearchResult, WorkspaceSearcher};
pub use tree::WorkspaceTree;
pub use updater::{
    compare_semver, sha256_digest, ApplyReport, PlatformArtifact, PlatformKind, PlatformRelease,
    UpdateCheckResult, UpdateStrategy, UpdaterEngine, UpdaterError, VersionManifest,
};
pub use worktree::{WorktreeManager, WorktreeSession};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
