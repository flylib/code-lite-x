//! State of the Git history panel: the commit list and its graph, the filters of the filter
//! bar, the selected commit and the folding of the two trees. Reading the repository happens
//! on a worker thread; a newer request makes the older one's result (and, where it can, its
//! work) obsolete.

use std::{
    collections::HashSet,
    path::PathBuf,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

use floem::{
    ext_event::create_ext_action,
    keyboard::Modifiers,
    reactive::{RwSignal, Scope, SignalGet, SignalUpdate, SignalWith},
};
use lapce_core::{
    command::{EditCommand, MoveCommand},
    mode::Mode,
};

use super::{
    commit_graph::{GraphRow, layout_commit_graph},
    git::{
        self, GitBranchInfo, GitChangeKind, GitCommitDetails, GitCommitInfo, GitLogPage,
        GitLogQuery,
    },
    git_log_tree,
};
use crate::{
    command::{CommandExecuted, CommandKind, LapceCommand},
    editor::EditorData,
    keypress::{KeyPressFocus, condition::Condition},
    main_split::Editors,
    window_tab::CommonData,
};

/// Commits fetched per request.
pub const PAGE_SIZE: usize = 200;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitRefLists {
    pub local: Vec<GitBranchInfo>,
    pub remote: Vec<GitBranchInfo>,
    pub tags: Vec<String>,
}

/// The Date dropdown.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DateFilter {
    #[default]
    All,
    Day,
    Week,
    Month,
    Year,
}

impl DateFilter {
    pub const CHOICES: [DateFilter; 4] = [Self::Day, Self::Week, Self::Month, Self::Year];

    pub fn label(self) -> &'static str {
        match self {
            Self::All => "All",
            Self::Day => "Last 24 Hours",
            Self::Week => "Last 7 Days",
            Self::Month => "Last 30 Days",
            Self::Year => "Last Year",
        }
    }

    /// Unix time before which commits are dropped.
    pub fn since(self, now: i64) -> Option<i64> {
        let days = match self {
            Self::All => return None,
            Self::Day => 1,
            Self::Week => 7,
            Self::Month => 30,
            Self::Year => 365,
        };
        Some(now - days * 24 * 3600)
    }
}

/// Which text box the keyboard types into while the panel has focus.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogInput {
    Search,
    Branches,
    Paths,
}

#[derive(Clone, Debug)]
pub struct GitLogData {
    scope: Scope,
    pub common: Rc<CommonData>,

    // text boxes
    /// The search box of the filter bar.
    pub search: EditorData,
    /// The small search box above the branch tree.
    pub branch_search: EditorData,
    /// The Paths filter, shown in place of its label while it is edited.
    pub paths_input: EditorData,
    pub active_input: RwSignal<LogInput>,
    pub paths_editing: RwSignal<bool>,

    // filters
    pub regex: RwSignal<bool>,
    pub match_case: RwSignal<bool>,
    /// A branch name or `HEAD`; `None` shows everything.
    pub branch: RwSignal<Option<String>>,
    pub author: RwSignal<Option<String>>,
    pub date: RwSignal<DateFilter>,
    pub paths: RwSignal<Vec<String>>,

    // data
    pub commits: RwSignal<im::Vector<GitCommitInfo>>,
    /// One row per commit, same order.
    pub graph: RwSignal<Arc<Vec<GraphRow>>>,
    /// Bumped when the list is replaced (not when a page is appended).
    pub epoch: RwSignal<usize>,
    pub head: RwSignal<Option<String>>,
    pub has_more: RwSignal<bool>,
    pub loading: RwSignal<bool>,
    pub error: RwSignal<Option<String>>,
    pub refs: RwSignal<GitRefLists>,
    pub authors: RwSignal<Vec<String>>,
    /// Hash of the selected commit.
    pub selected: RwSignal<Option<String>>,
    pub details: RwSignal<Option<Result<GitCommitDetails, String>>>,

    // layout and folding
    pub show_branches: RwSignal<bool>,
    pub show_details: RwSignal<bool>,
    pub branches_collapsed: RwSignal<HashSet<String>>,
    pub files_collapsed: RwSignal<HashSet<String>>,
    pub selected_file: RwSignal<Option<String>>,

    loaded: RwSignal<bool>,
    /// Bumped by every new list request; older workers see it and stop.
    list_generation: Arc<AtomicUsize>,
    details_generation: Arc<AtomicUsize>,
}

impl KeyPressFocus for GitLogData {
    fn get_mode(&self) -> Mode {
        Mode::Insert
    }

    fn check_condition(&self, condition: Condition) -> bool {
        matches!(condition, Condition::PanelFocus)
    }

    fn run_command(
        &self,
        command: &LapceCommand,
        count: Option<usize>,
        mods: Modifiers,
    ) -> CommandExecuted {
        match &command.kind {
            CommandKind::Edit(EditCommand::InsertNewLine) => {
                if self.active_input.get_untracked() == LogInput::Paths {
                    self.apply_paths_input();
                }
                CommandExecuted::Yes
            }
            // the text boxes are one line: up / down walk the commit list instead
            CommandKind::Move(MoveCommand::Down) => {
                self.select_offset(1);
                CommandExecuted::Yes
            }
            CommandKind::Move(MoveCommand::Up) => {
                self.select_offset(-1);
                CommandExecuted::Yes
            }
            CommandKind::Edit(_)
            | CommandKind::Move(_)
            | CommandKind::MultiSelection(_) => {
                self.input_editor().run_command(command, count, mods)
            }
            _ => CommandExecuted::No,
        }
    }

    fn receive_char(&self, c: &str) {
        self.input_editor().receive_char(c);
    }
}

impl GitLogData {
    pub fn new(cx: Scope, editors: Editors, common: Rc<CommonData>) -> Self {
        let data = Self {
            scope: cx,
            search: editors.make_local(cx, common.clone()),
            branch_search: editors.make_local(cx, common.clone()),
            paths_input: editors.make_local(cx, common.clone()),
            active_input: cx.create_rw_signal(LogInput::Search),
            paths_editing: cx.create_rw_signal(false),
            regex: cx.create_rw_signal(false),
            match_case: cx.create_rw_signal(false),
            branch: cx.create_rw_signal(None),
            author: cx.create_rw_signal(None),
            date: cx.create_rw_signal(DateFilter::All),
            paths: cx.create_rw_signal(Vec::new()),
            commits: cx.create_rw_signal(im::Vector::new()),
            graph: cx.create_rw_signal(Arc::new(Vec::new())),
            epoch: cx.create_rw_signal(0),
            head: cx.create_rw_signal(None),
            has_more: cx.create_rw_signal(false),
            loading: cx.create_rw_signal(false),
            error: cx.create_rw_signal(None),
            refs: cx.create_rw_signal(GitRefLists::default()),
            authors: cx.create_rw_signal(Vec::new()),
            selected: cx.create_rw_signal(None),
            details: cx.create_rw_signal(None),
            show_branches: cx.create_rw_signal(true),
            show_details: cx.create_rw_signal(true),
            branches_collapsed: cx.create_rw_signal(HashSet::new()),
            files_collapsed: cx.create_rw_signal(HashSet::new()),
            selected_file: cx.create_rw_signal(None),
            loaded: cx.create_rw_signal(false),
            list_generation: Arc::new(AtomicUsize::new(0)),
            details_generation: Arc::new(AtomicUsize::new(0)),
            common,
        };

        // typing in the search box narrows the list (not before the panel was first shown)
        {
            let data = data.clone();
            cx.create_effect(move |prev: Option<String>| {
                let text = data.search_text();
                let _ = data.search.doc_signal().get().buffer.with(|_| ());
                if prev.as_ref().is_some_and(|p| p != &text) {
                    data.reload_list();
                }
                text
            });
        }
        data
    }

    fn input_editor(&self) -> &EditorData {
        match self.active_input.get_untracked() {
            LogInput::Search => &self.search,
            LogInput::Branches => &self.branch_search,
            LogInput::Paths => &self.paths_input,
        }
    }

    fn workspace(&self) -> Option<PathBuf> {
        self.common.workspace.path.clone()
    }

    /// Name of the project folder, the root of the changed-file tree.
    pub fn repo_name(&self) -> String {
        self.common
            .workspace
            .path
            .as_ref()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default()
    }

    pub fn search_text(&self) -> String {
        self.search.doc().buffer.with_untracked(|b| b.to_string())
    }

    pub fn branch_query(&self) -> String {
        self.branch_search.doc().buffer.with(|b| b.to_string())
    }

    fn query(&self, skip: usize) -> GitLogQuery {
        GitLogQuery {
            branch: self.branch.get_untracked(),
            text: self.search_text(),
            regex: self.regex.get_untracked(),
            match_case: self.match_case.get_untracked(),
            author: self.author.get_untracked(),
            since: self
                .date
                .get_untracked()
                .since(chrono::Utc::now().timestamp()),
            paths: self.paths.get_untracked(),
            skip,
            limit: PAGE_SIZE,
        }
    }

    // ----- loading ------------------------------------------------------------------------

    /// Load on first use (a panel restored as open does not go through `show_panel`).
    pub fn ensure_loaded(&self) {
        if !self.loaded.get_untracked() {
            self.refresh();
        }
    }

    /// Read branches, tags and the first page of commits again (panel shown, refresh button).
    pub fn refresh(&self) {
        self.loaded.set(true);
        self.reload_refs();
        self.authors.set(Vec::new());
        self.load_authors();
        self.reload_list();
    }

    pub fn reload_refs(&self) {
        let Some(path) = self.workspace() else {
            return;
        };
        let send = create_ext_action(self.scope, {
            let refs = self.refs;
            move |lists: Option<GitRefLists>| {
                if let Some(lists) = lists {
                    refs.set(lists);
                }
            }
        });
        std::thread::spawn(move || {
            let lists = git::get_branches(&path).ok().map(|branches| {
                let (remote, local): (Vec<_>, Vec<_>) =
                    branches.into_iter().partition(|b| b.is_remote);
                let mut lists = GitRefLists {
                    local,
                    remote: remote
                        .into_iter()
                        .filter(|b| !b.name.ends_with("/HEAD"))
                        .collect(),
                    tags: git::get_tags(&path).unwrap_or_default(),
                };
                lists.local.sort_by(|a, b| a.name.cmp(&b.name));
                lists.remote.sort_by(|a, b| a.name.cmp(&b.name));
                lists
            });
            send(lists);
        });
    }

    /// The names for the User dropdown, read the first time it is opened.
    pub fn load_authors(&self) {
        if !self.authors.with_untracked(|a| a.is_empty()) {
            return;
        }
        let Some(path) = self.workspace() else {
            return;
        };
        let authors = self.authors;
        let send = create_ext_action(self.scope, move |names: Vec<String>| authors.set(names));
        std::thread::spawn(move || send(git::get_authors(&path).unwrap_or_default()));
    }

    fn set_commits(&self, commits: im::Vector<GitCommitInfo>) {
        let graph = layout_commit_graph(
            commits.iter().map(|c| (c.oid.as_str(), c.parents.as_slice())),
        );
        self.graph.set(Arc::new(graph));
        self.commits.set(commits);
    }

    /// Replace the list with the first page for the current filters.
    pub fn reload_list(&self) {
        let generation = self.list_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let Some(path) = self.workspace() else {
            self.error.set(Some("No folder is open".to_string()));
            return;
        };
        self.loading.set(true);
        let query = self.query(0);
        let counter = self.list_generation.clone();
        let data = self.clone();
        let send = create_ext_action(self.scope, move |result: Result<GitLogPage, String>| {
            if data.list_generation.load(Ordering::SeqCst) != generation {
                return; // a newer request is on its way
            }
            data.loading.set(false);
            data.epoch.update(|e| *e += 1);
            match result {
                Ok(page) => {
                    data.error.set(None);
                    data.has_more.set(page.has_more);
                    data.head.set(page.head);
                    data.set_commits(page.commits.into_iter().collect());
                    data.select_first_if_needed();
                }
                Err(err) => {
                    data.error.set(Some(err));
                    data.has_more.set(false);
                    data.set_commits(im::Vector::new());
                    data.clear_selection();
                }
            }
        });
        std::thread::spawn(move || {
            let cancelled = || counter.load(Ordering::SeqCst) != generation;
            let result = git::get_commit_page_until(&path, &query, &cancelled)
                .map_err(|e| e.message().to_string());
            send(result);
        });
    }

    /// Append the next page.
    pub fn load_more(&self) {
        if self.loading.get_untracked() || !self.has_more.get_untracked() {
            return;
        }
        let Some(path) = self.workspace() else {
            return;
        };
        let generation = self.list_generation.load(Ordering::SeqCst);
        self.loading.set(true);
        let query = self.query(self.commits.with_untracked(|c| c.len()));
        let counter = self.list_generation.clone();
        let data = self.clone();
        let send = create_ext_action(self.scope, move |result: Result<GitLogPage, String>| {
            if data.list_generation.load(Ordering::SeqCst) != generation {
                return; // the list was reloaded meanwhile
            }
            data.loading.set(false);
            if let Ok(page) = result {
                data.has_more.set(page.has_more);
                let mut commits = data.commits.get_untracked();
                commits.extend(page.commits);
                data.set_commits(commits);
            }
        });
        std::thread::spawn(move || {
            let cancelled = || counter.load(Ordering::SeqCst) != generation;
            send(
                git::get_commit_page_until(&path, &query, &cancelled)
                    .map_err(|e| e.message().to_string()),
            );
        });
    }

    // ----- selection ----------------------------------------------------------------------

    fn clear_selection(&self) {
        self.selected.set(None);
        self.details.set(None);
    }

    /// After a reload: keep the selected commit if it is still listed, else select the first
    /// one (opening the log selects the newest commit, as in IntelliJ).
    fn select_first_if_needed(&self) {
        let still_there = self.selected.get_untracked().is_some_and(|oid| {
            self.commits.with_untracked(|c| c.iter().any(|c| c.oid == oid))
        });
        if still_there {
            return;
        }
        match self.commits.with_untracked(|c| c.front().map(|c| c.oid.clone())) {
            Some(first) => {
                self.selected.set(None); // force the details to be read again
                self.select(&first);
            }
            None => self.clear_selection(),
        }
    }

    pub fn select(&self, oid: &str) {
        if self.selected.get_untracked().as_deref() == Some(oid) && self.details.with_untracked(|d| d.is_some()) {
            return;
        }
        self.selected.set(Some(oid.to_string()));
        self.selected_file.set(None);
        self.details.set(None);
        let Some(path) = self.workspace() else {
            return;
        };
        let generation = self.details_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let current = self.details_generation.clone();
        let details = self.details;
        let send = create_ext_action(self.scope, move |result: Result<GitCommitDetails, String>| {
            if current.load(Ordering::SeqCst) == generation {
                details.set(Some(result));
            }
        });
        let oid = oid.to_string();
        std::thread::spawn(move || {
            send(git::get_commit_details(&path, &oid).map_err(|e| e.message().to_string()));
        });
    }

    /// Select the commit `delta` rows from the selected one (the arrow keys).
    pub fn select_offset(&self, delta: isize) {
        let target = self.commits.with_untracked(|commits| {
            let current = self
                .selected
                .get_untracked()
                .and_then(|oid| commits.iter().position(|c| c.oid == oid));
            let next = match current {
                Some(i) => (i as isize + delta).clamp(0, commits.len() as isize - 1),
                None => 0,
            };
            commits.get(next as usize).map(|c| c.oid.clone())
        });
        if let Some(oid) = target {
            self.select(&oid);
        }
    }

    // ----- filters ------------------------------------------------------------------------

    /// Show one branch (`None`: all of them), as the Branch dropdown does.
    pub fn set_branch(&self, branch: Option<String>) {
        self.branch.set(branch);
        self.reload_list();
    }

    /// Pick a branch in the tree; picking the one that is already selected clears the filter.
    pub fn toggle_branch(&self, revision: &str) {
        let next = (self.branch.get_untracked().as_deref() != Some(revision))
            .then(|| revision.to_string());
        self.branch.set(next);
        self.reload_list();
    }

    pub fn set_author(&self, author: Option<String>) {
        self.author.set(author);
        self.reload_list();
    }

    pub fn set_date(&self, date: DateFilter) {
        self.date.set(date);
        self.reload_list();
    }

    pub fn set_paths(&self, paths: Vec<String>) {
        self.paths.set(paths);
        self.reload_list();
    }

    pub fn toggle_regex(&self) {
        self.regex.update(|v| *v = !*v);
        self.reload_list();
    }

    pub fn toggle_match_case(&self) {
        self.match_case.update(|v| *v = !*v);
        self.reload_list();
    }

    /// Open the Paths filter for editing, starting from what it holds now.
    pub fn edit_paths(&self) {
        let text = self.paths.get_untracked().join(", ");
        self.paths_input.doc().reload(lapce_xi_rope::Rope::from(text.as_str()), true);
        self.paths_editing.set(true);
        self.active_input.set(LogInput::Paths);
    }

    /// Enter in the Paths box: comma-separated paths, relative to the project root.
    pub fn apply_paths_input(&self) {
        let text = self.paths_input.doc().buffer.with_untracked(|b| b.to_string());
        self.paths_editing.set(false);
        self.active_input.set(LogInput::Search);
        self.set_paths(
            text.split(',')
                .map(str::trim)
                .filter(|p| !p.is_empty())
                .map(str::to_string)
                .collect(),
        );
    }

    pub fn focus_input(&self, input: LogInput) {
        if self.paths_editing.get_untracked() && input != LogInput::Paths {
            self.paths_editing.set(false);
        }
        self.active_input.set(input);
    }

    // ----- layout and folding -------------------------------------------------------------

    pub fn toggle_branches(&self) {
        self.show_branches.update(|v| *v = !*v);
    }

    pub fn toggle_details(&self) {
        self.show_details.update(|v| *v = !*v);
    }

    pub fn toggle_branch_group(&self, key: &str) {
        toggle_key(self.branches_collapsed, key);
    }

    pub fn toggle_file_dir(&self, key: &str) {
        toggle_key(self.files_collapsed, key);
    }

    pub fn expand_all_files(&self) {
        self.files_collapsed.set(HashSet::new());
    }

    pub fn collapse_all_files(&self) {
        let keys = match self.details.get_untracked() {
            Some(Ok(d)) => git_log_tree::folder_keys(&self.repo_name(), &d.files),
            _ => HashSet::new(),
        };
        self.files_collapsed.set(keys);
    }
}

fn toggle_key(set: RwSignal<HashSet<String>>, key: &str) {
    set.update(|s| {
        if !s.remove(key) {
            s.insert(key.to_string());
        }
    });
}

/// `2026/10/8, 14:05` — the date format of the Flutter version's log.
pub fn format_time_in<Tz: chrono::TimeZone>(timestamp: i64, zone: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    zone.timestamp_opt(timestamp, 0)
        .single()
        .map(|t| t.format("%Y/%-m/%-d, %H:%M").to_string())
        .unwrap_or_default()
}

/// A commit time in the user's local time zone.
pub fn format_time(timestamp: i64) -> String {
    format_time_in(timestamp, &chrono::Local)
}

/// Letter of a change in the file list of a commit.
pub fn change_letter(kind: GitChangeKind) -> &'static str {
    match kind {
        GitChangeKind::Added => "A",
        GitChangeKind::Modified => "M",
        GitChangeKind::Deleted => "D",
        GitChangeKind::Renamed => "R",
        GitChangeKind::Copied => "C",
        GitChangeKind::Other => "?",
    }
}

/// How a commit's branch / tag labels read: `origin & dev`, or `None` when there are none.
/// `HEAD` itself is not a label.
pub fn ref_label(refs: &[git::GitRef]) -> Option<String> {
    let names: Vec<&str> = refs
        .iter()
        .filter(|r| r.kind != git::GitRefKind::Head)
        .map(|r| r.name.as_str())
        .collect();
    (!names.is_empty()).then(|| names.join(" & "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use git::{GitRef, GitRefKind};

    #[test]
    fn commit_times_read_like_the_flutter_log() {
        let utc = chrono::Utc;
        assert_eq!(format_time_in(0, &utc), "1970/1/1, 00:00");
        let cst = chrono::FixedOffset::east_opt(8 * 3600).unwrap();
        assert_eq!(format_time_in(1_791_000_000, &cst), "2026/10/3, 12:00");
        assert_eq!(format_time_in(1_791_000_000 + 11 * 86400, &cst), "2026/10/14, 12:00");
    }

    #[test]
    fn every_change_kind_has_a_letter() {
        use GitChangeKind::*;
        let letters: Vec<_> = [Added, Modified, Deleted, Renamed, Copied, Other].into_iter().map(change_letter).collect();
        assert_eq!(letters, ["A", "M", "D", "R", "C", "?"]);
    }

    #[test]
    fn the_date_filter_counts_back_from_now() {
        let now = 1_800_000_000;
        assert_eq!(DateFilter::All.since(now), None);
        assert_eq!(DateFilter::Day.since(now), Some(now - 86_400));
        assert_eq!(DateFilter::Week.since(now), Some(now - 7 * 86_400));
        assert_eq!(DateFilter::Month.since(now), Some(now - 30 * 86_400));
        assert_eq!(DateFilter::Year.since(now), Some(now - 365 * 86_400));
        assert_eq!(DateFilter::CHOICES.map(DateFilter::label), ["Last 24 Hours", "Last 7 Days", "Last 30 Days", "Last Year"]);
    }

    #[test]
    fn ref_labels_join_names_and_skip_head() {
        let r = |name: &str, kind| GitRef { name: name.into(), kind, is_head: false };
        assert_eq!(ref_label(&[]), None);
        assert_eq!(ref_label(&[r("HEAD", GitRefKind::Head)]), None);
        assert_eq!(
            ref_label(&[r("dev", GitRefKind::LocalBranch), r("HEAD", GitRefKind::Head), r("origin/dev", GitRefKind::RemoteBranch)]).as_deref(),
            Some("dev & origin/dev")
        );
    }
}
