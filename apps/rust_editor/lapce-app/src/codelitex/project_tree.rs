//! CodeLiteX Project Tree & Java Package Compaction
//!
//! Provides intelligent package tree compaction for IntelliJ IDEA style
//! display of single-child directory chains under source roots (e.g. `src/main/java`).

use std::path::{Path, PathBuf};

/// Known source root folder names where package chain compaction is enabled.
pub const SOURCE_ROOTS: &[&str] = &["java", "kotlin", "scala", "groovy"];

/// Checks if a path is inside a source root directory (e.g., `src/main/java`).
pub fn is_in_source_root(path: &Path) -> bool {
    let mut current = path.parent();
    while let Some(parent) = current {
        if let Some(name) = parent.file_name().and_then(|n| n.to_str()) {
            if SOURCE_ROOTS.contains(&name) {
                return true;
            }
        }
        current = parent.parent();
    }
    false
}

/// Compact a package directory chain into a dotted display string (e.g. `com.bcpoker.game`)
/// and return the deepest directory in the chain.
pub fn compact_package_name(path: &Path) -> (String, PathBuf) {
    let base_name = path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_default();

    if !is_in_source_root(path) || !path.is_dir() {
        return (base_name, path.to_path_buf());
    }

    let mut current = path.to_path_buf();
    let mut parts = vec![base_name];

    // Follow single-child directory chains
    while let Ok(entries) = std::fs::read_dir(&current) {
        let valid_entries: Vec<_> = entries.filter_map(|e| e.ok()).collect();
        if valid_entries.len() == 1 && valid_entries[0].path().is_dir() {
            let child_path = valid_entries[0].path();
            if let Some(child_name) = child_path.file_name().and_then(|n| n.to_str()) {
                parts.push(child_name.to_string());
                current = child_path;
                continue;
            }
        }
        break;
    }

    (parts.join("."), current)
}

/// Returns the formatted display name for a file explorer tree node.
pub fn file_node_display_name(path: &Path, is_dir: bool) -> String {
    if is_dir && is_in_source_root(path) {
        let (compact_name, _) = compact_package_name(path);
        compact_name
    } else {
        path.file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_in_source_root() {
        assert!(is_in_source_root(Path::new("/project/src/main/java/com/example")));
        assert!(is_in_source_root(Path::new("/project/src/main/kotlin/app")));
        assert!(!is_in_source_root(Path::new("/project/src/main/resources/config")));
        assert!(!is_in_source_root(Path::new("/project/target/classes")));
    }

    #[test]
    fn test_compact_package_name_non_dir() {
        let file_path = Path::new("/project/src/main/java/com/example/App.java");
        let (name, target) = compact_package_name(file_path);
        assert_eq!(name, "App.java");
        assert_eq!(target, file_path);
    }
}
