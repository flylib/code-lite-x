use std::{
    cmp::{Ord, Ordering, PartialOrd},
    collections::HashMap,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

use crate::package_chain;

/// UTF8 line and column-offset
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize,
)]
pub struct LineCol {
    pub line: usize,
    pub column: usize,
}

#[derive(
    Default, Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize,
)]
pub struct PathObject {
    pub path: PathBuf,
    pub linecol: Option<LineCol>,
    pub is_dir: bool,
}

impl PathObject {
    pub fn new(
        path: PathBuf,
        is_dir: bool,
        line: usize,
        column: usize,
    ) -> PathObject {
        PathObject {
            path,
            is_dir,
            linecol: Some(LineCol { line, column }),
        }
    }

    pub fn from_path(path: PathBuf, is_dir: bool) -> PathObject {
        PathObject {
            path,
            is_dir,
            linecol: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FileNodeViewKind {
    /// An actual file/directory
    Path(PathBuf),
    /// We are renaming the file at this path
    Renaming { path: PathBuf, err: Option<String> },
    /// We are naming a new file/directory
    Naming { err: Option<String> },
    Duplicating {
        /// The path that is being duplicated
        source: PathBuf,
        err: Option<String>,
    },
}
impl FileNodeViewKind {
    pub fn path(&self) -> Option<&Path> {
        match self {
            Self::Path(path) => Some(path),
            Self::Renaming { path, .. } => Some(path),
            Self::Naming { .. } => None,
            Self::Duplicating { source, .. } => Some(source),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NamingState {
    /// Actively naming
    Naming,
    /// Application of the naming is pending
    Pending,
    /// There's an active error with the typed name
    Err { err: String },
}
impl NamingState {
    pub fn is_accepting_input(&self) -> bool {
        match self {
            Self::Naming | Self::Err { .. } => true,
            Self::Pending => false,
        }
    }

    pub fn is_err(&self) -> bool {
        match self {
            Self::Naming | Self::Pending => false,
            Self::Err { .. } => true,
        }
    }

    pub fn err(&self) -> Option<&str> {
        match self {
            Self::Err { err } => Some(err.as_str()),
            _ => None,
        }
    }

    pub fn set_ok(&mut self) {
        *self = Self::Naming;
    }

    pub fn set_pending(&mut self) {
        *self = Self::Pending;
    }

    pub fn set_err(&mut self, err: String) {
        *self = Self::Err { err };
    }
}

/// Stores the state of any in progress rename of a path.
///
/// The `editor_needs_reset` field is `true` if the rename editor should have its contents reset
/// when the view function next runs.
#[derive(Debug, Clone)]
pub struct Renaming {
    pub state: NamingState,
    /// Original file's path
    pub path: PathBuf,
    pub editor_needs_reset: bool,
}

#[derive(Debug, Clone)]
pub struct NewNode {
    pub state: NamingState,
    /// If true, then we are creating a directory
    pub is_dir: bool,
    /// The folder that the file/directory is being created within
    pub base_path: PathBuf,
    pub editor_needs_reset: bool,
}

#[derive(Debug, Clone)]
pub struct Duplicating {
    pub state: NamingState,
    /// Path to the item being duplicated
    pub path: PathBuf,
    pub editor_needs_reset: bool,
}

#[derive(Debug, Clone)]
pub enum Naming {
    None,
    Renaming(Renaming),
    NewNode(NewNode),
    Duplicating(Duplicating),
}
impl Naming {
    pub fn state(&self) -> Option<&NamingState> {
        match self {
            Self::None => None,
            Self::Renaming(rename) => Some(&rename.state),
            Self::NewNode(state) => Some(&state.state),
            Self::Duplicating(state) => Some(&state.state),
        }
    }

    pub fn state_mut(&mut self) -> Option<&mut NamingState> {
        match self {
            Self::None => None,
            Self::Renaming(rename) => Some(&mut rename.state),
            Self::NewNode(state) => Some(&mut state.state),
            Self::Duplicating(state) => Some(&mut state.state),
        }
    }

    pub fn is_accepting_input(&self) -> bool {
        self.state().is_some_and(NamingState::is_accepting_input)
    }

    pub fn editor_needs_reset(&self) -> bool {
        match self {
            Naming::None => false,
            Naming::Renaming(rename) => rename.editor_needs_reset,
            Naming::NewNode(state) => state.editor_needs_reset,
            Naming::Duplicating(state) => state.editor_needs_reset,
        }
    }

    pub fn set_editor_needs_reset(&mut self, needs_reset: bool) {
        match self {
            Naming::None => {}
            Naming::Renaming(rename) => rename.editor_needs_reset = needs_reset,
            Naming::NewNode(state) => state.editor_needs_reset = needs_reset,
            Naming::Duplicating(state) => state.editor_needs_reset = needs_reset,
        }
    }

    pub fn set_ok(&mut self) {
        if let Some(state) = self.state_mut() {
            state.set_ok();
        }
    }

    pub fn set_pending(&mut self) {
        if let Some(state) = self.state_mut() {
            state.set_pending();
        }
    }

    pub fn set_err(&mut self, err: String) {
        if let Some(state) = self.state_mut() {
            state.set_err(err);
        }
    }

    pub fn as_renaming(&self) -> Option<&Renaming> {
        match self {
            Naming::Renaming(rename) => Some(rename),
            _ => None,
        }
    }

    /// The extra node that should be added after the node at `path`
    pub fn extra_node(
        &self,
        is_dir: bool,
        level: usize,
        path: &Path,
    ) -> Option<FileNodeViewData> {
        match self {
            Naming::NewNode(n) if n.base_path == path => Some(FileNodeViewData {
                kind: FileNodeViewKind::Naming {
                    err: n.state.err().map(ToString::to_string),
                },
                is_dir: n.is_dir,
                is_root: false,
                open: false,
                level: level + 1,
                compact_name: None,
            }),
            Naming::Duplicating(d) if d.path == path => Some(FileNodeViewData {
                kind: FileNodeViewKind::Duplicating {
                    source: d.path.to_path_buf(),
                    err: d.state.err().map(ToString::to_string),
                },
                is_dir,
                is_root: false,
                open: false,
                level: level + 1,
                compact_name: None,
            }),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct FileNodeViewData {
    pub kind: FileNodeViewKind,
    pub is_dir: bool,
    pub is_root: bool,
    pub open: bool,
    pub level: usize,
    /// CodeLiteX: dotted name (`com.example.app`) when this row stands for a folded
    /// package chain; `kind` then holds the path of the deepest directory.
    pub compact_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileNodeItem {
    pub path: PathBuf,
    pub is_dir: bool,
    /// Whether the directory's children have been read.
    /// Does nothing if not a directory.
    pub read: bool,
    /// Whether the directory is open in the explorer view.
    pub open: bool,
    pub children: HashMap<PathBuf, FileNodeItem>,
    /// The number of child (directories) that are open themselves
    /// Used for sizing of the explorer list
    pub children_open_count: usize,
}

impl PartialOrd for FileNodeItem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for FileNodeItem {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self.is_dir, other.is_dir) {
            (true, false) => Ordering::Less,
            (false, true) => Ordering::Greater,
            _ => {
                let [self_file_name, other_file_name] = [&self.path, &other.path]
                    .map(|path| {
                        path.file_name()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .to_lowercase()
                    });
                human_sort::compare(&self_file_name, &other_file_name)
            }
        }
    }
}

impl FileNodeItem {
    /// CodeLiteX: the only child, when this directory folds into it (see
    /// [`crate::package_chain`]). Needs the directory to have been read.
    fn chain_child(&self) -> Option<&FileNodeItem> {
        if !(self.is_dir && self.read && self.children.len() == 1)
            || !package_chain::in_package_dir(&self.path)
        {
            return None;
        }
        self.children.values().next().filter(|child| child.is_dir)
    }

    /// CodeLiteX: the deepest directory of the chain starting here and its dotted name;
    /// the name is `None` when nothing folds into this directory.
    fn fold_chain(&self) -> (&FileNodeItem, Option<String>) {
        let name_of = |node: &FileNodeItem| {
            node.path.file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default()
        };
        let mut end = self;
        let mut name: Option<String> = None;
        while let Some(child) = end.chain_child() {
            let name = name.get_or_insert_with(|| name_of(self));
            name.push('.');
            name.push_str(&name_of(child));
            end = child;
        }
        (end, name)
    }

    /// CodeLiteX: the directories to read right away so that package chains can fold before
    /// the user opens them: every package directly under a source root, and the only child of
    /// a package directory. A chain that grows below an open directory inherits its open
    /// state, so a folder the user just expanded does not collapse when its row starts
    /// standing for a deeper directory.
    pub fn package_dirs_to_preread(&mut self) -> Vec<PathBuf> {
        if !self.is_dir {
            return Vec::new();
        }
        if package_chain::is_source_root(&self.path) {
            return self
                .children
                .values()
                .filter(|child| child.is_dir && !child.read)
                .map(|child| child.path.clone())
                .collect();
        }
        if self.children.len() == 1 && package_chain::in_package_dir(&self.path) {
            let open = self.open;
            if let Some(child) = self.children.values_mut().next() {
                if child.is_dir && !child.read {
                    child.open = open;
                    return vec![child.path.clone()];
                }
            }
        }
        Vec::new()
    }

    /// Collect the children, sorted by name.
    /// Note: this will be empty if the directory has not been read.
    pub fn sorted_children(&self) -> Vec<&FileNodeItem> {
        let mut children = self.children.values().collect::<Vec<&FileNodeItem>>();
        children.sort();
        children
    }

    /// Collect the children, sorted by name.
    /// Note: this will be empty if the directory has not been read.
    pub fn sorted_children_mut(&mut self) -> Vec<&mut FileNodeItem> {
        let mut children = self
            .children
            .values_mut()
            .collect::<Vec<&mut FileNodeItem>>();
        children.sort();
        children
    }

    /// Returns an iterator over the ancestors of `path`, starting with the first descendant of `prefix`.
    ///
    /// # Example:
    /// (ignored because the function is private but I promise this passes)
    /// ```rust,ignore
    /// # use lapce_rpc::file::FileNodeItem;
    /// # use std::path::{Path, PathBuf};
    /// # use std::collections::HashMap;
    /// #
    /// let node_item = FileNodeItem {
    ///     path_buf: PathBuf::from("/pre/fix"),
    ///     // ...
    /// #    is_dir: true,
    /// #    read: false,
    /// #    open: false,
    /// #    children: HashMap::new(),
    /// #    children_open_count: 0,
    ///};
    /// let mut iter = node_item.ancestors_rev(Path::new("/pre/fix/foo/bar")).unwrap();
    /// assert_eq!(Some(Path::new("/pre/fix/foo")), iter.next());
    /// assert_eq!(Some(Path::new("/pre/fix/foo/bar")), iter.next());
    /// ```
    fn ancestors_rev<'a>(
        &self,
        path: &'a Path,
    ) -> Option<impl Iterator<Item = &'a Path> + use<'a>> {
        let take = if let Ok(suffix) = path.strip_prefix(&self.path) {
            suffix.components().count()
        } else {
            return None;
        };

        #[allow(clippy::needless_collect)] // Ancestors is not reversible
        let ancestors = path.ancestors().take(take).collect::<Vec<&Path>>();
        Some(ancestors.into_iter().rev())
    }

    /// Recursively get the node at `path`.
    pub fn get_file_node(&self, path: &Path) -> Option<&FileNodeItem> {
        self.ancestors_rev(path)?
            .try_fold(self, |node, path| node.children.get(path))
    }

    /// Recursively get the (mutable) node at `path`.
    pub fn get_file_node_mut(&mut self, path: &Path) -> Option<&mut FileNodeItem> {
        self.ancestors_rev(path)?
            .try_fold(self, |node, path| node.children.get_mut(path))
    }

    /// Remove a specific child from the node.
    /// The path is recursive and will remove the child from parent indicated by the path.
    pub fn remove_child(&mut self, path: &Path) -> Option<FileNodeItem> {
        let parent = path.parent()?;
        let node = self.get_file_node_mut(parent)?;
        let node = node.children.remove(path)?;
        for p in path.ancestors() {
            self.update_node_count(p);
        }

        Some(node)
    }

    /// Add a new (unread & unopened) child to the node.
    pub fn add_child(&mut self, path: &Path, is_dir: bool) -> Option<()> {
        let parent = path.parent()?;
        let node = self.get_file_node_mut(parent)?;
        node.children.insert(
            PathBuf::from(path),
            FileNodeItem {
                path: PathBuf::from(path),
                is_dir,
                read: false,
                open: false,
                children: HashMap::new(),
                children_open_count: 0,
            },
        );
        for p in path.ancestors() {
            self.update_node_count(p);
        }

        Some(())
    }

    /// Set the children of the node.
    /// Note: this opens the node.
    pub fn set_item_children(
        &mut self,
        path: &Path,
        children: HashMap<PathBuf, FileNodeItem>,
    ) {
        if let Some(node) = self.get_file_node_mut(path) {
            node.open = true;
            node.read = true;
            node.children = children;
        }

        for p in path.ancestors() {
            self.update_node_count(p);
        }
    }

    pub fn update_node_count_recursive(&mut self, path: &Path) {
        for current_path in path.ancestors() {
            self.update_node_count(current_path);
        }
    }

    pub fn update_node_count(&mut self, path: &Path) -> Option<()> {
        let is_root = path == self.path;
        let node = self.get_file_node_mut(path)?;
        if node.is_dir {
            // CodeLiteX: a directory that folds into its only child shares that child's row,
            // so the rows below it are the rows below the child, whether or not it is open.
            let folded = if is_root {
                None
            } else {
                node.chain_child().map(|child| child.children_open_count)
            };
            node.children_open_count = match folded {
                Some(count) => count,
                None if node.open => node
                    .children
                    .values()
                    .map(|item| item.children_open_count + 1)
                    .sum::<usize>(),
                None => 0,
            };
        }
        None
    }

    pub fn append_view_slice(
        &self,
        view_items: &mut Vec<FileNodeViewData>,
        naming: &Naming,
        min: usize,
        max: usize,
        current: usize,
        level: usize,
    ) -> usize {
        if current > max {
            return current;
        }
        if current + self.children_open_count < min {
            return current + self.children_open_count;
        }

        // CodeLiteX: a package chain is one row that stands for its deepest directory.
        // The workspace root is never folded.
        let (row, compact_name) = if level == 1 {
            (self, None)
        } else {
            self.fold_chain()
        };

        if current >= min {
            let kind = if let Naming::Renaming(r) = &naming {
                if r.path == row.path {
                    FileNodeViewKind::Renaming {
                        path: row.path.clone(),
                        err: r.state.err().map(ToString::to_string),
                    }
                } else {
                    FileNodeViewKind::Path(row.path.clone())
                }
            } else {
                FileNodeViewKind::Path(row.path.clone())
            };
            view_items.push(FileNodeViewData {
                kind,
                is_dir: row.is_dir,
                is_root: level == 1,
                open: row.open,
                level,
                compact_name,
            });
        }

        row.append_children_view_slice(view_items, naming, min, max, current, level)
    }

    /// Calculate the row where the file resides
    pub fn find_file_at_line(&self, file_path: &Path) -> (bool, f64) {
        let mut line = 0.0;
        if !self.open {
            return (false, line);
        }
        for item in self.sorted_children() {
            line += 1.0;
            // CodeLiteX: a folded chain is one row; `file_path` is on it when it lies
            // between the first and the deepest directory of the chain.
            let (row, _) = item.fold_chain();
            let on_row = file_path.starts_with(&item.path) && row.path.starts_with(file_path);
            match (row.is_dir, row.open, on_row) {
                (_, _, true) => {
                    return (true, line);
                }
                (true, true, _) => {
                    let (found, item_position) = row.find_file_at_line(file_path);
                    line += item_position;
                    if found {
                        return (true, line);
                    }
                }
                _ => {}
            }
        }
        (false, line)
    }

    /// Append the children of this item with the given level
    pub fn append_children_view_slice(
        &self,
        view_items: &mut Vec<FileNodeViewData>,
        naming: &Naming,
        min: usize,
        max: usize,
        mut i: usize,
        level: usize,
    ) -> usize {
        let mut naming_extra = naming.extra_node(self.is_dir, level, &self.path);

        if !self.open {
            // If the folder isn't open, then we just put it right at the top
            if i >= min {
                if let Some(naming_extra) = naming_extra {
                    view_items.push(naming_extra);
                    i += 1;
                }
            }
            return i;
        }

        let naming_is_dir = naming_extra.as_ref().map(|n| n.is_dir).unwrap_or(false);
        // Immediately put the naming entry first if it's a directory
        if naming_is_dir {
            if let Some(node) = naming_extra.take() {
                // Actually add the node if it's within the range
                if i >= min {
                    view_items.push(node);
                    i += 1;
                }
            }
        }

        let mut after_dirs = false;

        for item in self.sorted_children() {
            // If we're naming a file at the root, then wait until we've added the directories
            // before adding the input node
            if naming_extra.is_some()
                && !naming_is_dir
                && !item.is_dir
                && !after_dirs
            {
                after_dirs = true;

                // If we're creating a new file node, then we show it after the directories
                // TODO(minor): should this be i >= min or i + 1 >= min?
                if i >= min {
                    if let Some(node) = naming_extra.take() {
                        view_items.push(node);
                        i += 1;
                    }
                }
            }
            i = item.append_view_slice(
                view_items,
                naming,
                min,
                max,
                i + 1,
                level + 1,
            );
            if i > max {
                return i;
            }
        }

        // If it has not been added yet, add it now.
        if i >= min {
            if let Some(node) = naming_extra {
                view_items.push(node);
                i += 1;
            }
        }

        i
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(path: &str, is_dir: bool) -> FileNodeItem {
        FileNodeItem {
            path: PathBuf::from(path),
            is_dir,
            read: false,
            open: false,
            children: HashMap::new(),
            children_open_count: 0,
        }
    }

    /// Fill `dir` with `names` (a trailing `/` marks a directory). Like the explorer, this
    /// reads and opens `dir`.
    fn fill(root: &mut FileNodeItem, dir: &str, names: &[&str]) {
        let children = names
            .iter()
            .map(|n| {
                let is_dir = n.ends_with('/');
                let path = format!("{dir}/{}", n.trim_end_matches('/'));
                (PathBuf::from(&path), node(&path, is_dir))
            })
            .collect();
        root.set_item_children(Path::new(dir), children);
    }

    fn close(root: &mut FileNodeItem, dir: &str) {
        root.get_file_node_mut(Path::new(dir)).unwrap().open = false;
        root.update_node_count_recursive(Path::new(dir));
    }

    /// `/p/src/main/java/com/bcpoker/game` holding two files, everything expanded.
    fn java_project() -> FileNodeItem {
        let mut root = node("/p", true);
        fill(&mut root, "/p", &["src/"]);
        fill(&mut root, "/p/src", &["main/"]);
        fill(&mut root, "/p/src/main", &["java/"]);
        fill(&mut root, "/p/src/main/java", &["com/"]);
        fill(&mut root, "/p/src/main/java/com", &["bcpoker/"]);
        fill(&mut root, "/p/src/main/java/com/bcpoker", &["game/"]);
        fill(&mut root, "/p/src/main/java/com/bcpoker/game", &["App.java", "Util.java"]);
        root
    }

    fn rows(root: &FileNodeItem, min: usize, max: usize) -> Vec<FileNodeViewData> {
        let mut out = vec![];
        root.append_view_slice(&mut out, &Naming::None, min, max, 0, 1);
        out
    }

    fn describe(rows: &[FileNodeViewData]) -> Vec<String> {
        rows.iter()
            .map(|r| match (&r.compact_name, r.kind.path()) {
                (Some(name), _) => format!("{}{name}", "  ".repeat(r.level)),
                (None, Some(p)) => format!(
                    "{}{}",
                    "  ".repeat(r.level),
                    p.file_name().map(|f| f.to_string_lossy().to_string()).unwrap_or_default()
                ),
                (None, None) => String::new(),
            })
            .collect()
    }

    #[test]
    fn a_single_child_package_chain_is_one_row() {
        let root = java_project();
        let all = rows(&root, 0, usize::MAX);
        assert_eq!(
            describe(&all),
            ["  p", "    src", "      main", "        java", "          com.bcpoker.game", "            App.java", "            Util.java"]
        );
        // the row stands for the deepest directory
        assert_eq!(all[4].kind.path(), Some(Path::new("/p/src/main/java/com/bcpoker/game")));
        assert!(all[4].open);
    }

    #[test]
    fn row_count_matches_the_rows_that_are_built() {
        let mut root = java_project();
        assert_eq!(root.children_open_count + 1, rows(&root, 0, usize::MAX).len());
        close(&mut root, "/p/src/main/java/com/bcpoker/game");
        let all = rows(&root, 0, usize::MAX);
        assert_eq!(root.children_open_count + 1, all.len());
        assert_eq!(describe(&all).last().unwrap().trim(), "com.bcpoker.game");
        assert!(!all.last().unwrap().open, "a collapsed chain shows the collapsed state of its deepest directory");
    }

    #[test]
    fn windows_into_the_list_agree_with_the_full_list() {
        let root = java_project();
        let all = describe(&rows(&root, 0, usize::MAX));
        for min in 0..all.len() {
            for max in min..all.len() {
                let part = describe(&rows(&root, min, max));
                // the explorer asks for a window and may get a few extra rows; the rows it
                // does get must be the right ones, in order
                let expected: Vec<_> = all.iter().skip(min).take(max - min + 1).cloned().collect();
                assert!(
                    part.windows(expected.len()).any(|w| w == &expected[..]),
                    "window {min}..={max}: got {part:?}, wanted {expected:?}"
                );
            }
        }
    }

    #[test]
    fn a_folder_that_branches_stops_the_chain() {
        let mut root = node("/p", true);
        fill(&mut root, "/p", &["src/"]);
        fill(&mut root, "/p/src", &["main/"]);
        fill(&mut root, "/p/src/main", &["java/"]);
        fill(&mut root, "/p/src/main/java", &["com/"]);
        fill(&mut root, "/p/src/main/java/com", &["a/", "b/"]);
        let all = describe(&rows(&root, 0, usize::MAX));
        assert!(all.iter().any(|l| l.trim() == "com"), "{all:?}");
        assert_eq!(root.children_open_count + 1, all.len());
    }

    #[test]
    fn a_lone_file_does_not_fold() {
        let mut root = node("/p", true);
        fill(&mut root, "/p", &["src/"]);
        fill(&mut root, "/p/src", &["main/"]);
        fill(&mut root, "/p/src/main", &["java/"]);
        fill(&mut root, "/p/src/main/java", &["com/"]);
        fill(&mut root, "/p/src/main/java/com", &["Only.java"]);
        let all = describe(&rows(&root, 0, usize::MAX));
        assert_eq!(all.last().unwrap().trim(), "Only.java");
        assert!(all.iter().any(|l| l.trim() == "com"));
    }

    #[test]
    fn a_project_inside_a_folder_called_java_is_left_alone() {
        let mut root = node("/Users/dev/Worker/java/proj", true);
        fill(&mut root, "/Users/dev/Worker/java/proj", &["docs/"]);
        fill(&mut root, "/Users/dev/Worker/java/proj/docs", &["a/"]);
        fill(&mut root, "/Users/dev/Worker/java/proj/docs/a", &["b/"]);
        let all = rows(&root, 0, usize::MAX);
        assert_eq!(describe(&all).iter().map(|l| l.trim()).collect::<Vec<_>>(), ["proj", "docs", "a", "b"]);
        assert!(all.iter().all(|r| r.compact_name.is_none()));
    }

    #[test]
    fn the_workspace_root_is_never_folded() {
        let mut root = node("/p/src/main/java/com", true);
        fill(&mut root, "/p/src/main/java/com", &["foo/"]);
        fill(&mut root, "/p/src/main/java/com/foo", &["x/"]);
        let all = rows(&root, 0, usize::MAX);
        assert_eq!(describe(&all).iter().map(|l| l.trim()).collect::<Vec<_>>(), ["com", "foo.x"]);
        assert_eq!(root.children_open_count + 1, all.len());
    }

    #[test]
    fn find_file_at_line_counts_a_folded_chain_once() {
        let root = java_project();
        let all = rows(&root, 0, usize::MAX);
        let (found, line) = root.find_file_at_line(Path::new("/p/src/main/java/com/bcpoker/game/Util.java"));
        assert!(found);
        // row 0 is the root itself; `line` is relative to it
        assert_eq!(all[line as usize].kind.path(), Some(Path::new("/p/src/main/java/com/bcpoker/game/Util.java")));
    }

    #[test]
    fn renaming_or_naming_inside_a_chain_targets_its_deepest_directory() {
        let root = java_project();
        let naming = Naming::NewNode(NewNode {
            state: NamingState::Naming,
            is_dir: false,
            base_path: PathBuf::from("/p/src/main/java/com/bcpoker/game"),
            editor_needs_reset: false,
        });
        let mut out = vec![];
        root.append_view_slice(&mut out, &naming, 0, usize::MAX, 0, 1);
        let at = out.iter().position(|r| matches!(r.kind, FileNodeViewKind::Naming { .. })).expect("naming row");
        let chain = &out[at - 1];
        assert_eq!(chain.compact_name.as_deref(), Some("com.bcpoker.game"), "the input row follows the folded folder");
        assert_eq!(out[at].level, chain.level + 1, "and sits inside it");
        assert_eq!(out.iter().filter(|r| matches!(r.kind, FileNodeViewKind::Naming { .. })).count(), 1);
    }

    #[test]
    fn packages_under_a_source_root_are_read_ahead() {
        let mut java = node("/p/src/main/java", true);
        fill(&mut java, "/p/src/main/java", &["com/", "org/", "README.md"]);
        let mut todo = java.package_dirs_to_preread();
        todo.sort();
        assert_eq!(todo, [PathBuf::from("/p/src/main/java/com"), PathBuf::from("/p/src/main/java/org")]);
    }

    #[test]
    fn a_lone_package_child_is_read_ahead_and_inherits_the_open_state() {
        let mut com = node("/p/src/main/java/com", true);
        com.open = true;
        com.read = true;
        com.children.insert(PathBuf::from("/p/src/main/java/com/x"), node("/p/src/main/java/com/x", true));
        assert_eq!(com.package_dirs_to_preread(), [PathBuf::from("/p/src/main/java/com/x")]);
        assert!(com.children.values().next().unwrap().open, "the user had expanded com, so the folded row stays expanded");

        // collapsed stays collapsed
        let mut com = node("/p/src/main/java/com", true);
        com.children.insert(PathBuf::from("/p/src/main/java/com/x"), node("/p/src/main/java/com/x", true));
        com.package_dirs_to_preread();
        assert!(!com.children.values().next().unwrap().open);
    }

    #[test]
    fn nothing_is_read_ahead_outside_package_dirs_or_for_branching_folders() {
        let mut docs = node("/p/docs", true);
        docs.children.insert(PathBuf::from("/p/docs/a"), node("/p/docs/a", true));
        assert!(docs.package_dirs_to_preread().is_empty());

        let mut com = node("/p/src/main/java/com", true);
        com.children.insert(PathBuf::from("/p/src/main/java/com/a"), node("/p/src/main/java/com/a", true));
        com.children.insert(PathBuf::from("/p/src/main/java/com/b"), node("/p/src/main/java/com/b", true));
        assert!(com.package_dirs_to_preread().is_empty());

        // already read: nothing to do (and no endless re-reading)
        let mut com = node("/p/src/main/java/com", true);
        let mut x = node("/p/src/main/java/com/x", true);
        x.read = true;
        com.children.insert(x.path.clone(), x);
        assert!(com.package_dirs_to_preread().is_empty());
    }
}
