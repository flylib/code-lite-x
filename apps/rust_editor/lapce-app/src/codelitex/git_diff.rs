//! What a "diff of one file in one commit" is made of: two read-only history documents whose
//! `version` says where their text comes from. The strings are part of the saved workspace
//! state (open diff tabs are restored from them), so their format has to stay readable:
//!
//! * `head` — the file as of `HEAD` (the existing working-tree diff),
//! * `git:<commit>:<path>` — the file at that commit,
//! * `git-empty` — nothing: the left side of an added file, the right side of a deleted one.

use std::path::Path;

use super::git::{GitChangeKind, GitChangedFile};

pub const HEAD: &str = "head";
pub const EMPTY: &str = "git-empty";

/// Where a history document gets its text from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistorySource<'a> {
    Head,
    Empty,
    Commit { oid: &'a str, path: &'a str },
}

/// `None` for a version that is not one of the above.
pub fn parse_version(version: &str) -> Option<HistorySource<'_>> {
    match version {
        HEAD => Some(HistorySource::Head),
        EMPTY => Some(HistorySource::Empty),
        _ => {
            let rest = version.strip_prefix("git:")?;
            let (oid, path) = rest.split_once(':')?;
            (!oid.is_empty() && !path.is_empty()).then_some(HistorySource::Commit { oid, path })
        }
    }
}

pub fn commit_version(oid: &str, path: &str) -> String {
    format!("git:{oid}:{path}")
}

/// The versions of the two sides for `file` in commit `oid`, compared with its first parent
/// (`None`: a root commit). A rename reads the left side under the old path.
pub fn commit_file_versions(oid: &str, parent: Option<&str>, file: &GitChangedFile) -> (String, String) {
    let left = match (parent, file.kind) {
        (None, _) | (_, GitChangeKind::Added) => EMPTY.to_string(),
        (Some(parent), _) => commit_version(parent, file.old_path.as_deref().unwrap_or(&file.path)),
    };
    let right = match file.kind {
        GitChangeKind::Deleted => EMPTY.to_string(),
        _ => commit_version(oid, &file.path),
    };
    (left, right)
}

/// Tab title of a diff of two history documents of the same commit: `App.java (4d26280)`.
/// `None` when the two do not both come from a commit.
pub fn commit_diff_title(path: &Path, left: &str, right: &str) -> Option<String> {
    let commit_of = |version: &str| match parse_version(version)? {
        HistorySource::Commit { oid, .. } => Some(oid.chars().take(7).collect::<String>()),
        _ => None,
    };
    let short = commit_of(right).or_else(|| commit_of(left))?;
    // one side may be empty (added / deleted file); any other pairing is not a commit diff
    let ok = |v: &str| v == EMPTY || commit_of(v).is_some();
    if !(ok(left) && ok(right)) {
        return None;
    }
    let name = path.file_name()?.to_string_lossy();
    Some(format!("{name} ({short})"))
}

/// Text of a file shown in a commit diff; files that cannot be shown as text get a note.
pub const MAX_TEXT_BYTES: usize = 4 * 1024 * 1024;

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, kind: GitChangeKind, old: Option<&str>) -> GitChangedFile {
        GitChangedFile { path: path.into(), old_path: old.map(str::to_string), kind }
    }

    #[test]
    fn versions_round_trip_and_odd_ones_are_rejected() {
        assert_eq!(parse_version("head"), Some(HistorySource::Head));
        assert_eq!(parse_version("git-empty"), Some(HistorySource::Empty));
        let v = commit_version("abc123", "src/a.rs");
        assert_eq!(parse_version(&v), Some(HistorySource::Commit { oid: "abc123", path: "src/a.rs" }));
        // a path may itself contain a colon
        let v = commit_version("abc123", "weird:name.txt");
        assert_eq!(parse_version(&v), Some(HistorySource::Commit { oid: "abc123", path: "weird:name.txt" }));
        for bad in ["", "git:", "git:abc", "git::path", "git:abc:", "v1", "HEAD"] {
            assert_eq!(parse_version(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn a_modified_file_compares_with_the_parent() {
        let (l, r) = commit_file_versions("c2", Some("c1"), &file("a.rs", GitChangeKind::Modified, None));
        assert_eq!((l.as_str(), r.as_str()), ("git:c1:a.rs", "git:c2:a.rs"));
    }

    #[test]
    fn added_deleted_and_root_commit_files_have_an_empty_side() {
        let added = commit_file_versions("c2", Some("c1"), &file("a.rs", GitChangeKind::Added, None));
        assert_eq!(added, (EMPTY.to_string(), "git:c2:a.rs".to_string()));
        let deleted = commit_file_versions("c2", Some("c1"), &file("a.rs", GitChangeKind::Deleted, None));
        assert_eq!(deleted, ("git:c1:a.rs".to_string(), EMPTY.to_string()));
        let root = commit_file_versions("c1", None, &file("a.rs", GitChangeKind::Modified, None));
        assert_eq!(root, (EMPTY.to_string(), "git:c1:a.rs".to_string()));
    }

    #[test]
    fn a_rename_reads_the_left_side_under_its_old_path() {
        let (l, r) = commit_file_versions("c2", Some("c1"), &file("new/b.rs", GitChangeKind::Renamed, Some("old/a.rs")));
        assert_eq!((l.as_str(), r.as_str()), ("git:c1:old/a.rs", "git:c2:new/b.rs"));
    }

    #[test]
    fn the_tab_title_names_the_file_and_the_commit() {
        let path = Path::new("src/App.java");
        assert_eq!(commit_diff_title(path, "git:1111111aaaa:src/App.java", "git:2222222bbbb:src/App.java").as_deref(), Some("App.java (2222222)"));
        assert_eq!(commit_diff_title(path, EMPTY, "git:2222222bbbb:src/App.java").as_deref(), Some("App.java (2222222)"));
        assert_eq!(commit_diff_title(path, "git:1111111aaaa:src/App.java", EMPTY).as_deref(), Some("App.java (1111111)"));
        // not a commit diff
        assert_eq!(commit_diff_title(path, HEAD, "git:2222222bbbb:x"), None);
        assert_eq!(commit_diff_title(path, EMPTY, EMPTY), None);
    }
}
