//! The two trees of the history panel, as flat lists of rows: the branch tree on the left
//! (Local / Remote, folders by `/`) and the changed-file tree of the selected commit. The
//! same rules as the Flutter version's `_buildTree` and `walk`, kept free of any UI so they
//! can be tested.

use std::collections::{BTreeMap, HashSet};

use super::git::{GitBranchInfo, GitChangeKind, GitChangedFile};

/// What a branch row shows in front of its name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BranchIcon {
    None,
    Folder,
    /// The checked-out branch.
    Current,
    /// `main` / `master`.
    Star,
    Branch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchRow {
    /// Identifies the row for collapsing and for list diffing.
    pub key: String,
    pub depth: usize,
    pub label: String,
    /// What a click filters the log by; `None` for groups.
    pub revision: Option<String>,
    pub icon: BranchIcon,
    pub is_current: bool,
    pub expandable: bool,
    pub expanded: bool,
}

struct Node {
    label: String,
    revision: Option<String>,
    icon: BranchIcon,
    is_current: bool,
    children: Vec<Node>,
}

impl Node {
    fn group(label: &str) -> Self {
        Self { label: label.to_string(), revision: None, icon: BranchIcon::Folder, is_current: false, children: Vec::new() }
    }

    fn is_group(&self) -> bool {
        self.revision.is_none()
    }
}

fn is_main(name: &str) -> bool {
    name == "main" || name == "master"
}

/// Put `leaf` into `root`, inside one folder per `/`-separated prefix of `parts`.
fn insert(root: &mut Node, parts: &[&str], leaf: Node) {
    let mut node = root;
    for part in &parts[..parts.len() - 1] {
        let at = node.children.iter().position(|c| c.is_group() && c.label == *part);
        let at = at.unwrap_or_else(|| {
            node.children.push(Node::group(part));
            node.children.len() - 1
        });
        node = &mut node.children[at];
    }
    node.children.push(leaf);
}

/// The rows of the branch tree. `query` narrows the branches by name (case-insensitive);
/// `collapsed` holds the keys of the groups that are folded.
pub fn branch_rows(
    local: &[GitBranchInfo],
    remote: &[GitBranchInfo],
    query: &str,
    collapsed: &HashSet<String>,
) -> Vec<BranchRow> {
    let q = query.to_lowercase();
    let keep = |name: &str| q.is_empty() || name.to_lowercase().contains(&q);

    let mut local_group = Node::group("Local");
    let mut sorted: Vec<&GitBranchInfo> = local.iter().collect();
    sorted.sort_by(|a, b| b.is_head.cmp(&a.is_head).then_with(|| a.name.cmp(&b.name)));
    for b in sorted.into_iter().filter(|b| keep(&b.name)) {
        let parts: Vec<&str> = b.name.split('/').collect();
        let icon = if b.is_head {
            BranchIcon::Current
        } else if is_main(&b.name) {
            BranchIcon::Star
        } else {
            BranchIcon::Branch
        };
        let leaf = Node {
            label: parts.last().unwrap().to_string(),
            revision: Some(b.name.clone()),
            icon,
            is_current: b.is_head,
            children: Vec::new(),
        };
        insert(&mut local_group, &parts, leaf);
    }

    let mut remote_group = Node::group("Remote");
    let mut sorted_remote: Vec<&GitBranchInfo> = remote.iter().filter(|b| keep(&b.name)).collect();
    sorted_remote.sort_by(|a, b| a.name.cmp(&b.name));
    for b in sorted_remote {
        let (remote_name, short) = b.name.split_once('/').unwrap_or((&b.name, ""));
        if short.is_empty() {
            continue;
        }
        let parts: Vec<&str> = short.split('/').collect();
        let leaf = Node {
            label: parts.last().unwrap().to_string(),
            revision: Some(b.name.clone()),
            icon: if is_main(short) { BranchIcon::Star } else { BranchIcon::Branch },
            is_current: false,
            children: Vec::new(),
        };
        let at = remote_group.children.iter().position(|c| c.label == remote_name).unwrap_or_else(|| {
            remote_group.children.push(Node::group(remote_name));
            remote_group.children.len() - 1
        });
        insert(&mut remote_group.children[at], &parts, leaf);
    }

    let head = Node {
        label: "HEAD (Current Branch)".to_string(),
        revision: Some("HEAD".to_string()),
        icon: BranchIcon::None,
        is_current: false,
        children: Vec::new(),
    };
    let mut roots = vec![head];
    if !local_group.children.is_empty() || q.is_empty() {
        roots.push(local_group);
    }
    if !remote_group.children.is_empty() {
        roots.push(remote_group);
    }

    let mut rows = Vec::new();
    fn walk(node: &Node, depth: usize, path: &str, collapsed: &HashSet<String>, rows: &mut Vec<BranchRow>) {
        let key = format!("{path}/{}", node.label);
        let is_collapsed = collapsed.contains(&key);
        let expandable = node.is_group() && !node.children.is_empty();
        rows.push(BranchRow {
            key: key.clone(),
            depth,
            label: node.label.clone(),
            revision: node.revision.clone(),
            icon: node.icon,
            is_current: node.is_current,
            expandable,
            expanded: !is_collapsed,
        });
        if node.is_group() && !is_collapsed {
            for child in &node.children {
                walk(child, depth + 1, &key, collapsed, rows);
            }
        }
    }
    for root in &roots {
        walk(root, 0, "", collapsed, &mut rows);
    }
    rows
}

// ----- changed files ----------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRow {
    pub key: String,
    pub depth: usize,
    pub label: String,
    /// Directories: `Some(number of files below)`; files: `None`.
    pub dir_count: Option<usize>,
    pub expanded: bool,
    /// Files only.
    pub kind: Option<GitChangeKind>,
    pub path: Option<String>,
    /// File name before a rename.
    pub renamed_from: Option<String>,
}

#[derive(Default)]
struct DirNode {
    dirs: BTreeMap<String, DirNode>,
    files: Vec<(String, GitChangedFile)>,
}

impl DirNode {
    fn count(&self) -> usize {
        self.files.len() + self.dirs.values().map(DirNode::count).sum::<usize>()
    }
}

fn file_tree(files: &[GitChangedFile]) -> DirNode {
    let mut root = DirNode::default();
    for f in files {
        let parts: Vec<&str> = f.path.split('/').collect();
        let mut node = &mut root;
        for dir in &parts[..parts.len() - 1] {
            node = node.dirs.entry(dir.to_string()).or_default();
        }
        node.files.push((parts.last().unwrap().to_string(), f.clone()));
    }
    root
}

/// The rows of the file tree, rooted at `repo_name`. `collapsed` holds folded folder keys.
pub fn file_rows(repo_name: &str, files: &[GitChangedFile], collapsed: &HashSet<String>) -> Vec<FileRow> {
    let root = file_tree(files);
    let root_name = if repo_name.is_empty() { "repository" } else { repo_name };
    let mut rows = Vec::new();

    fn walk(name: &str, node: &DirNode, depth: usize, path: &str, collapsed: &HashSet<String>, rows: &mut Vec<FileRow>) {
        let key = format!("{path}/{name}");
        let is_collapsed = collapsed.contains(&key);
        rows.push(FileRow {
            key: key.clone(),
            depth,
            label: name.to_string(),
            dir_count: Some(node.count()),
            expanded: !is_collapsed,
            kind: None,
            path: None,
            renamed_from: None,
        });
        if is_collapsed {
            return;
        }
        for (dir_name, dir) in &node.dirs {
            walk(dir_name, dir, depth + 1, &key, collapsed, rows);
        }
        let mut files: Vec<&(String, GitChangedFile)> = node.files.iter().collect();
        files.sort_by(|a, b| a.0.cmp(&b.0));
        for (file_name, change) in files {
            rows.push(FileRow {
                key: format!("{key}/{file_name}"),
                depth: depth + 1,
                label: file_name.clone(),
                dir_count: None,
                expanded: false,
                kind: Some(change.kind),
                path: Some(change.path.clone()),
                renamed_from: change
                    .old_path
                    .as_ref()
                    .filter(|_| change.kind == GitChangeKind::Renamed)
                    .map(|old| old.rsplit('/').next().unwrap_or(old).to_string()),
            });
        }
    }
    walk(root_name, &root, 0, "", collapsed, &mut rows);
    rows
}

/// Keys of every folder below the root, to fold them all at once.
pub fn folder_keys(repo_name: &str, files: &[GitChangedFile]) -> HashSet<String> {
    file_rows(repo_name, files, &HashSet::new())
        .into_iter()
        .filter(|r| r.dir_count.is_some() && r.depth > 0)
        .map(|r| r.key)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn branch(name: &str, is_head: bool, is_remote: bool) -> GitBranchInfo {
        GitBranchInfo { name: name.to_string(), is_head, is_remote }
    }

    fn labels(rows: &[BranchRow]) -> Vec<String> {
        rows.iter().map(|r| format!("{}{}", "  ".repeat(r.depth), r.label)).collect()
    }

    fn change(path: &str, kind: GitChangeKind, old: Option<&str>) -> GitChangedFile {
        GitChangedFile { path: path.to_string(), old_path: old.map(str::to_string), kind }
    }

    #[test]
    fn local_branches_are_grouped_by_slash_with_the_current_one_first() {
        let local = [
            branch("main", false, false),
            branch("feat/login", false, false),
            branch("feat/pay/refund", false, false),
            branch("dev", true, false),
        ];
        let rows = branch_rows(&local, &[], "", &HashSet::new());
        assert_eq!(
            labels(&rows),
            ["HEAD (Current Branch)", "Local", "  dev", "  feat", "    login", "    pay", "      refund", "  main"]
        );
        let by = |l: &str| rows.iter().find(|r| r.label == l).unwrap();
        assert_eq!(by("dev").icon, BranchIcon::Current);
        assert!(by("dev").is_current);
        assert_eq!(by("main").icon, BranchIcon::Star);
        assert_eq!(by("login").icon, BranchIcon::Branch);
        assert_eq!(by("login").revision.as_deref(), Some("feat/login"), "a click filters by the full name");
        assert_eq!(by("feat").revision, None);
        assert!(by("feat").expandable);
        assert!(!by("dev").expandable);
    }

    #[test]
    fn remote_branches_are_grouped_by_remote_then_by_slash() {
        let remote = [branch("origin/main", false, true), branch("origin/feat/x", false, true), branch("up/dev", false, true)];
        let rows = branch_rows(&[branch("main", true, false)], &remote, "", &HashSet::new());
        let text = labels(&rows);
        let at = text.iter().position(|l| l == "Remote").unwrap();
        assert_eq!(&text[at..], ["Remote", "  origin", "    feat", "      x", "    main", "  up", "    dev"]);
        let x = rows.iter().find(|r| r.label == "x").unwrap();
        assert_eq!(x.revision.as_deref(), Some("origin/feat/x"));
        assert_eq!(rows.iter().find(|r| r.label == "main" && r.depth == 2).unwrap().icon, BranchIcon::Star);
    }

    #[test]
    fn collapsing_a_group_hides_what_is_inside() {
        let local = [branch("a", false, false), branch("feat/b", false, false)];
        let collapsed: HashSet<String> = ["/Local/feat".to_string()].into();
        let rows = branch_rows(&local, &[], "", &collapsed);
        assert_eq!(labels(&rows), ["HEAD (Current Branch)", "Local", "  a", "  feat"]);
        let feat = rows.iter().find(|r| r.label == "feat").unwrap();
        assert!(feat.expandable && !feat.expanded);
        let rows = branch_rows(&local, &[], "", &["/Local".to_string()].into());
        assert_eq!(labels(&rows), ["HEAD (Current Branch)", "Local"]);
    }

    #[test]
    fn the_branch_search_keeps_matching_branches_and_drops_empty_groups() {
        let local = [branch("main", true, false), branch("feat/login", false, false)];
        let remote = [branch("origin/main", false, true)];
        let rows = branch_rows(&local, &remote, "LOG", &HashSet::new());
        assert_eq!(labels(&rows), ["HEAD (Current Branch)", "Local", "  feat", "    login"]);
        // nothing matches: no Local group either, only the HEAD row
        assert_eq!(labels(&branch_rows(&local, &remote, "zzz", &HashSet::new())), ["HEAD (Current Branch)"]);
        // no query and no branches: the empty Local group is still shown
        assert_eq!(labels(&branch_rows(&[], &[], "", &HashSet::new())), ["HEAD (Current Branch)", "Local"]);
    }

    #[test]
    fn changed_files_form_a_tree_with_counts_dirs_first() {
        let files = [
            change("src/b.rs", GitChangeKind::Modified, None),
            change("src/a.rs", GitChangeKind::Added, None),
            change("src/util/x.rs", GitChangeKind::Deleted, None),
            change("README.md", GitChangeKind::Modified, None),
        ];
        let rows = file_rows("proj", &files, &HashSet::new());
        let text: Vec<String> = rows.iter().map(|r| format!("{}{}", "  ".repeat(r.depth), r.label)).collect();
        assert_eq!(text, ["proj", "  src", "    util", "      x.rs", "    a.rs", "    b.rs", "  README.md"]);
        assert_eq!(rows[0].dir_count, Some(4));
        assert_eq!(rows[1].dir_count, Some(3));
        assert_eq!(rows[3].kind, Some(GitChangeKind::Deleted));
        assert_eq!(rows[3].path.as_deref(), Some("src/util/x.rs"));
    }

    #[test]
    fn folding_folders_and_a_rename_label() {
        let files = [change("src/new.rs", GitChangeKind::Renamed, Some("old/dir/old.rs")), change("src/keep.rs", GitChangeKind::Modified, None)];
        let rows = file_rows("", &files, &HashSet::new());
        assert_eq!(rows[0].label, "repository", "an unnamed root gets a default name");
        assert_eq!(rows.iter().find(|r| r.label == "new.rs").unwrap().renamed_from.as_deref(), Some("old.rs"));
        assert_eq!(rows.iter().find(|r| r.label == "keep.rs").unwrap().renamed_from, None);

        let folded = file_rows("proj", &files, &["/proj/src".to_string()].into());
        assert_eq!(folded.iter().map(|r| r.label.as_str()).collect::<Vec<_>>(), ["proj", "src"]);
        assert!(!folded[1].expanded);
        assert_eq!(folder_keys("proj", &files), ["/proj/src".to_string()].into());
    }

    #[test]
    fn a_commit_without_files_still_has_its_root() {
        let rows = file_rows("proj", &[], &HashSet::new());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].dir_count, Some(0));
    }
}
