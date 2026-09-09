use crate::entry::FileSystemEntry;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

pub struct WorkspaceTree {
    root: PathBuf,
}

impl WorkspaceTree {
    pub fn new<P: AsRef<Path>>(root: P) -> Self {
        Self {
            root: root.as_ref().to_path_buf(),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Recursively scans and constructs the file tree.
    pub fn scan(&self, max_depth: usize) -> io::Result<FileSystemEntry> {
        Self::scan_dir(&self.root, 0, max_depth)
    }

    /// Collects all non-ignored file paths (useful for indexing).
    pub fn list_files(&self) -> io::Result<Vec<PathBuf>> {
        let mut results = Vec::new();
        Self::collect_files_recursive(&self.root, &mut results)?;
        Ok(results)
    }

    fn is_ignored(name: &str) -> bool {
        matches!(
            name,
            ".git" | "target" | "node_modules" | ".DS_Store" | ".codelite" | ".idea" | ".vscode"
        )
    }

    fn scan_dir(path: &Path, current_depth: usize, max_depth: usize) -> io::Result<FileSystemEntry> {
        let mut children = Vec::new();

        if current_depth < max_depth && path.is_dir() {
            if let Ok(entries) = fs::read_dir(path) {
                let mut dir_entries = Vec::new();
                for entry in entries.flatten() {
                    let file_name = entry.file_name().to_string_lossy().to_string();
                    if Self::is_ignored(&file_name) {
                        continue;
                    }
                    dir_entries.push(entry);
                }

                // Sort: directories first, then files alphabetically
                dir_entries.sort_by(|a, b| {
                    let a_is_dir = a.file_type().map(|t| t.is_dir()).unwrap_or(false);
                    let b_is_dir = b.file_type().map(|t| t.is_dir()).unwrap_or(false);
                    match (a_is_dir, b_is_dir) {
                        (true, false) => std::cmp::Ordering::Less,
                        (false, true) => std::cmp::Ordering::Greater,
                        _ => a.file_name().cmp(&b.file_name()),
                    }
                });

                for entry in dir_entries {
                    let child_path = entry.path();
                    let metadata = entry.metadata()?;

                    if metadata.is_dir() {
                        let child_node = Self::scan_dir(&child_path, current_depth + 1, max_depth)?;
                        children.push(child_node);
                    } else {
                        let modified_ms = metadata
                            .modified()
                            .ok()
                            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                            .map(|d| d.as_millis() as u64)
                            .unwrap_or(0);

                        children.push(FileSystemEntry::new_file(
                            child_path,
                            metadata.len(),
                            modified_ms,
                        ));
                    }
                }
            }
        }

        Ok(FileSystemEntry::new_dir(path.to_path_buf(), children))
    }

    fn collect_files_recursive(path: &Path, results: &mut Vec<PathBuf>) -> io::Result<()> {
        if path.is_dir() {
            if let Ok(entries) = fs::read_dir(path) {
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if Self::is_ignored(&name) {
                        continue;
                    }
                    let p = entry.path();
                    if p.is_dir() {
                        Self::collect_files_recursive(&p, results)?;
                    } else {
                        results.push(p);
                    }
                }
            }
        } else {
            results.push(path.to_path_buf());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_workspace() {
        let current_dir = std::env::current_dir().unwrap();
        let tree = WorkspaceTree::new(&current_dir);
        let root_entry = tree.scan(2).unwrap();

        assert!(root_entry.is_dir);
        assert!(root_entry.children.is_some());

        let files = tree.list_files().unwrap();
        assert!(!files.is_empty());
        // Verify ignored paths are not included
        assert!(!files.iter().any(|f| f.to_string_lossy().contains("/target/")));
        assert!(!files.iter().any(|f| f.to_string_lossy().contains("/.git/")));
    }
}
