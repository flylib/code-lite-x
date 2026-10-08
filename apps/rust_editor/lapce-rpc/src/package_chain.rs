// CodeLiteX: IntelliJ-style package chains in the file explorer.
//
// A directory below a Maven/Gradle source root (`src/<set>/java|kotlin|scala|groovy`)
// whose only child is another directory is shown on one row, `com.example.app`.
// Only the layout of the path is inspected here; nothing touches the file system.

use std::path::Path;

/// Directory names that hold packages under `src/<set>/`.
pub const SOURCE_ROOT_NAMES: [&str; 4] = ["java", "kotlin", "scala", "groovy"];

/// `…/src/main/java`, `…/src/test/kotlin`, … — the layout, not just the folder
/// name: a project that merely lives under a directory called `java` has no source roots.
pub fn is_source_root(path: &Path) -> bool {
    let named_like_root = path
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| SOURCE_ROOT_NAMES.contains(&n));
    named_like_root
        && path
            .parent()
            .and_then(|set| set.parent())
            .and_then(|src| src.file_name())
            .is_some_and(|n| n == "src")
}

/// Strictly below a source root, where package chains are folded.
pub fn in_package_dir(path: &Path) -> bool {
    path.ancestors().skip(1).any(is_source_root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_roots_follow_the_maven_gradle_layout() {
        assert!(is_source_root(Path::new("/p/src/main/java")));
        assert!(is_source_root(Path::new("/p/mod/src/test/kotlin")));
        assert!(!is_source_root(Path::new("/p/src/main/resources")));
        assert!(!is_source_root(Path::new("/p/java")));
        assert!(!is_source_root(Path::new("/Users/dev/Worker/java")));
        assert!(!is_source_root(Path::new("/p/main/java")), "needs src/ above the source set");
    }

    #[test]
    fn a_project_inside_a_folder_named_java_has_no_package_dirs() {
        assert!(!in_package_dir(Path::new("/Users/dev/Worker/java/bcpoker/docs/a/b")));
        assert!(in_package_dir(Path::new("/p/src/main/java/com")));
        assert!(in_package_dir(Path::new("/p/src/main/java/com/example/App.java")));
        assert!(!in_package_dir(Path::new("/p/src/main/java")), "the source root itself is not folded");
    }
}
