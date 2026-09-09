use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Represents a node in the project file tree.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileSystemEntry {
    pub path: PathBuf,
    pub name: String,
    pub is_dir: bool,
    pub size_bytes: u64,
    pub modified_ms: u64,
    pub children: Option<Vec<FileSystemEntry>>,
}

impl FileSystemEntry {
    pub fn new_file(path: PathBuf, size_bytes: u64, modified_ms: u64) -> Self {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        Self {
            path,
            name,
            is_dir: false,
            size_bytes,
            modified_ms,
            children: None,
        }
    }

    pub fn new_dir(path: PathBuf, children: Vec<FileSystemEntry>) -> Self {
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        Self {
            path,
            name,
            is_dir: true,
            size_bytes: 0,
            modified_ms: 0,
            children: Some(children),
        }
    }
}
