//! State of the Git history panel: the commit list, the branch filter, the search box and the
//! selected commit. Reading the repository happens on a worker thread; a newer request makes
//! the older one's result (and, where it can, its work) obsolete.

use std::{
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
use lapce_core::{command::EditCommand, mode::Mode};

use super::git::{
    self, GitBranchInfo, GitCommitDetails, GitCommitInfo, GitLogPage, GitLogQuery,
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

#[derive(Clone, Debug)]
pub struct GitLogData {
    scope: Scope,
    pub common: Rc<CommonData>,
    /// The search box.
    pub search: EditorData,
    pub commits: RwSignal<im::Vector<GitCommitInfo>>,
    pub has_more: RwSignal<bool>,
    pub loading: RwSignal<bool>,
    pub error: RwSignal<Option<String>>,
    /// Short branch / tag name the list is limited to; `None` shows everything.
    pub branch: RwSignal<Option<String>>,
    pub refs: RwSignal<GitRefLists>,
    /// Hash of the selected commit.
    pub selected: RwSignal<Option<String>>,
    pub details: RwSignal<Option<Result<GitCommitDetails, String>>>,
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
            CommandKind::Edit(EditCommand::InsertNewLine) => CommandExecuted::Yes,
            CommandKind::Edit(_)
            | CommandKind::Move(_)
            | CommandKind::MultiSelection(_) => {
                self.search.run_command(command, count, mods)
            }
            _ => CommandExecuted::No,
        }
    }

    fn receive_char(&self, c: &str) {
        self.search.receive_char(c);
    }
}

impl GitLogData {
    pub fn new(cx: Scope, editors: Editors, common: Rc<CommonData>) -> Self {
        let data = Self {
            scope: cx,
            search: editors.make_local(cx, common.clone()),
            commits: cx.create_rw_signal(im::Vector::new()),
            has_more: cx.create_rw_signal(false),
            loading: cx.create_rw_signal(false),
            error: cx.create_rw_signal(None),
            branch: cx.create_rw_signal(None),
            refs: cx.create_rw_signal(GitRefLists::default()),
            selected: cx.create_rw_signal(None),
            details: cx.create_rw_signal(None),
            loaded: cx.create_rw_signal(false),
            list_generation: Arc::new(AtomicUsize::new(0)),
            details_generation: Arc::new(AtomicUsize::new(0)),
            common,
        };

        // typing in the search box narrows the list (not before the panel was first shown)
        {
            let data = data.clone();
            cx.create_effect(move |prev: Option<String>| {
                let text = data
                    .search
                    .doc_signal()
                    .get()
                    .buffer
                    .with(|b| b.to_string());
                if prev.as_ref().is_some_and(|p| p != &text) {
                    data.reload_list();
                }
                text
            });
        }
        data
    }

    fn workspace(&self) -> Option<PathBuf> {
        self.common.workspace.path.clone()
    }

    pub fn search_text(&self) -> String {
        self.search.doc().buffer.with_untracked(|b| b.to_string())
    }

    fn query(&self, skip: usize) -> GitLogQuery {
        GitLogQuery {
            branch: self.branch.get_untracked(),
            text: self.search_text(),
            skip,
            limit: PAGE_SIZE,
        }
    }

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
        self.reload_list();
    }

    pub fn set_branch(&self, branch: Option<String>) {
        if self.branch.get_untracked() == branch {
            return;
        }
        self.branch.set(branch);
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

    /// Replace the list with the first page for the current branch and search text.
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
            match result {
                Ok(page) => {
                    data.error.set(None);
                    data.has_more.set(page.has_more);
                    data.commits.set(page.commits.into_iter().collect());
                    data.keep_selection();
                }
                Err(err) => {
                    data.error.set(Some(err));
                    data.has_more.set(false);
                    data.commits.set(im::Vector::new());
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
                data.commits.update(|commits| commits.extend(page.commits));
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

    /// After a reload: keep the selected commit if it is still listed, else drop it.
    fn keep_selection(&self) {
        let Some(oid) = self.selected.get_untracked() else {
            return;
        };
        if !self.commits.with_untracked(|c| c.iter().any(|c| c.oid == oid)) {
            self.selected.set(None);
            self.details.set(None);
        }
    }

    pub fn select(&self, oid: &str) {
        if self.selected.get_untracked().as_deref() == Some(oid) {
            return;
        }
        self.selected.set(Some(oid.to_string()));
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
}

/// `2026-10-08 14:05` in the given zone.
pub fn format_time_in<Tz: chrono::TimeZone>(timestamp: i64, zone: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    zone.timestamp_opt(timestamp, 0)
        .single()
        .map(|t| t.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_default()
}

/// A commit time in the user's local time zone.
pub fn format_time(timestamp: i64) -> String {
    format_time_in(timestamp, &chrono::Local)
}

/// Letter and meaning of a change in the file list of a commit.
pub fn change_letter(kind: git::GitChangeKind) -> &'static str {
    match kind {
        git::GitChangeKind::Added => "A",
        git::GitChangeKind::Modified => "M",
        git::GitChangeKind::Deleted => "D",
        git::GitChangeKind::Renamed => "R",
        git::GitChangeKind::Copied => "C",
        git::GitChangeKind::Other => "?",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commit_times_are_shown_in_the_given_zone() {
        let utc = chrono::Utc;
        assert_eq!(format_time_in(0, &utc), "1970-01-01 00:00");
        let cst = chrono::FixedOffset::east_opt(8 * 3600).unwrap();
        assert_eq!(format_time_in(1_791_000_000, &cst), "2026-10-03 12:00");
    }

    #[test]
    fn every_change_kind_has_a_letter() {
        use git::GitChangeKind::*;
        let letters: Vec<_> = [Added, Modified, Deleted, Renamed, Copied, Other].into_iter().map(change_letter).collect();
        assert_eq!(letters, ["A", "M", "D", "R", "C", "?"]);
    }
}
