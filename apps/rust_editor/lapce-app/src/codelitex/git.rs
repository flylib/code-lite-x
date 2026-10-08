//! CodeLiteX Native Git Operations
//!
//! Provides native Git repository status, history logging, branch inspection,
//! and diff querying using libgit2.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
};

use git2::{BranchType, Delta, DiffFindOptions, Oid, Repository, Sort, StatusOptions};

/// Details of a single Git commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitCommitInfo {
    pub oid: String,
    pub short_id: String,
    pub summary: String,
    pub author_name: String,
    pub author_email: String,
    pub timestamp: i64,
    pub parent_count: usize,
    pub parents: Vec<String>,
    /// Branches, tags and `HEAD` pointing at this commit.
    pub refs: Vec<GitRef>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitRefKind {
    LocalBranch,
    RemoteBranch,
    Tag,
    /// Detached `HEAD`.
    Head,
}

/// A named reference shown as a label next to a commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitRef {
    pub name: String,
    pub kind: GitRefKind,
    /// The branch `HEAD` is on (or the detached `HEAD` itself).
    pub is_head: bool,
}

/// Information about a Git branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitBranchInfo {
    pub name: String,
    pub is_head: bool,
    pub is_remote: bool,
}

/// A changed file in the Git working directory or staging index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitFileStatus {
    pub path: PathBuf,
    pub status: String,
    pub staged: bool,
}

/// High-level Git repository status overview.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitRepoStatus {
    pub branch: String,
    pub is_clean: bool,
    pub files: Vec<GitFileStatus>,
    pub branches: Vec<GitBranchInfo>,
}

/// Queries the repository status (current branch, changed files, branch list).
pub fn get_repo_status(workspace_path: &Path) -> Result<GitRepoStatus, git2::Error> {
    let repo = Repository::discover(workspace_path)?;

    // Current branch
    let head = repo.head().ok();
    let branch = head
        .as_ref()
        .and_then(|h| h.shorthand())
        .unwrap_or("(HEAD detached)")
        .to_string();

    // Changed files
    let mut status_opts = StatusOptions::new();
    status_opts
        .include_untracked(true)
        .recurse_untracked_dirs(true);

    let statuses = repo.statuses(Some(&mut status_opts))?;
    let mut files = Vec::new();

    for entry in statuses.iter() {
        let s = entry.status();
        let path = entry.path().map(PathBuf::from).unwrap_or_default();

        let (status_str, staged) = if s.is_index_new() {
            ("added", true)
        } else if s.is_index_modified() {
            ("modified", true)
        } else if s.is_index_deleted() {
            ("deleted", true)
        } else if s.is_index_renamed() {
            ("renamed", true)
        } else if s.is_wt_new() {
            ("untracked", false)
        } else if s.is_wt_modified() {
            ("modified", false)
        } else if s.is_wt_deleted() {
            ("deleted", false)
        } else if s.is_wt_renamed() {
            ("renamed", false)
        } else {
            ("other", false)
        };

        files.push(GitFileStatus {
            path,
            status: status_str.to_string(),
            staged,
        });
    }

    let is_clean = files.is_empty();
    let branches = get_branches_from_repo(&repo)?;

    Ok(GitRepoStatus {
        branch,
        is_clean,
        files,
        branches,
    })
}

/// Lists all local and remote branches for the workspace repository.
pub fn get_branches(workspace_path: &Path) -> Result<Vec<GitBranchInfo>, git2::Error> {
    let repo = Repository::discover(workspace_path)?;
    get_branches_from_repo(&repo)
}

fn get_branches_from_repo(repo: &Repository) -> Result<Vec<GitBranchInfo>, git2::Error> {
    let mut branch_list = Vec::new();

    if let Ok(branches) = repo.branches(None) {
        for branch_res in branches {
            if let Ok((branch, branch_type)) = branch_res {
                if let Ok(Some(name)) = branch.name() {
                    let is_head = branch.is_head();
                    let is_remote = branch_type == BranchType::Remote;
                    branch_list.push(GitBranchInfo {
                        name: name.to_string(),
                        is_head,
                        is_remote,
                    });
                }
            }
        }
    }

    Ok(branch_list)
}

/// Which commits the history window asks for.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GitLogQuery {
    /// Short name of a local or remote branch, or a tag. `None` shows every branch and tag.
    pub branch: Option<String>,
    /// Case-insensitive match on the subject, author name / email or the start of the hash.
    pub text: String,
    pub skip: usize,
    pub limit: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GitLogPage {
    pub commits: Vec<GitCommitInfo>,
    /// More commits follow the ones returned.
    pub has_more: bool,
}

/// Retrieves the Git commit history from HEAD up to `max_count` commits.
pub fn get_commit_history(
    workspace_path: &Path,
    max_count: usize,
) -> Result<Vec<GitCommitInfo>, git2::Error> {
    let repo = Repository::discover(workspace_path)?;
    let mut revwalk = repo.revwalk()?;
    revwalk.push_head()?;
    revwalk.set_sorting(Sort::TIME)?;
    let refs = collect_refs(&repo)?;
    revwalk
        .take(max_count)
        .map(|oid| commit_info(&repo.find_commit(oid?)?, &refs))
        .collect()
}

/// A page of the history, newest first, parents after their children.
pub fn get_commit_page(
    workspace_path: &Path,
    query: &GitLogQuery,
) -> Result<GitLogPage, git2::Error> {
    get_commit_page_until(workspace_path, query, &|| false)
}

/// Like [`get_commit_page`], but gives up with an error as soon as `cancelled` says so, so a
/// search that has been typed over does not keep walking a large history.
pub fn get_commit_page_until(
    workspace_path: &Path,
    query: &GitLogQuery,
    cancelled: &dyn Fn() -> bool,
) -> Result<GitLogPage, git2::Error> {
    let repo = Repository::discover(workspace_path)?;
    let mut revwalk = repo.revwalk()?;
    revwalk.set_sorting(Sort::TOPOLOGICAL | Sort::TIME)?;
    match &query.branch {
        Some(name) => {
            let object = repo.revparse_single(name)?;
            revwalk.push(object.peel_to_commit()?.id())?;
        }
        None => {
            for glob in ["refs/heads/*", "refs/remotes/*", "refs/tags/*"] {
                revwalk.push_glob(glob)?;
            }
            // a detached HEAD is on no branch
            if repo.head_detached().unwrap_or(false) {
                revwalk.push_head()?;
            }
        }
    }
    let refs = collect_refs(&repo)?;
    let needle = query.text.trim().to_lowercase();
    let mut matched = 0;
    let mut page = GitLogPage::default();
    for oid in revwalk {
        if cancelled() {
            return Err(git2::Error::from_str("cancelled"));
        }
        let commit = repo.find_commit(oid?)?;
        if !needle.is_empty() && !commit_matches(&commit, &needle) {
            continue;
        }
        matched += 1;
        if matched <= query.skip {
            continue;
        }
        if page.commits.len() == query.limit {
            page.has_more = true;
            break;
        }
        page.commits.push(commit_info(&commit, &refs)?);
    }
    Ok(page)
}

fn commit_matches(commit: &git2::Commit, needle: &str) -> bool {
    let author = commit.author();
    commit.id().to_string().starts_with(needle)
        || commit.summary().unwrap_or("").to_lowercase().contains(needle)
        || author.name().unwrap_or("").to_lowercase().contains(needle)
        || author.email().unwrap_or("").to_lowercase().contains(needle)
}

fn commit_info(
    commit: &git2::Commit,
    refs: &HashMap<Oid, Vec<GitRef>>,
) -> Result<GitCommitInfo, git2::Error> {
    let oid = commit.id();
    let oid_str = oid.to_string();
    let author = commit.author();
    Ok(GitCommitInfo {
        short_id: oid_str.chars().take(7).collect(),
        oid: oid_str,
        summary: commit.summary().unwrap_or("").to_string(),
        author_name: author.name().unwrap_or("").to_string(),
        author_email: author.email().unwrap_or("").to_string(),
        timestamp: commit.time().seconds(),
        parent_count: commit.parent_count(),
        parents: commit.parent_ids().map(|id| id.to_string()).collect(),
        refs: refs.get(&oid).cloned().unwrap_or_default(),
    })
}

/// Every branch, tag and `HEAD` by the commit it points at.
fn collect_refs(repo: &Repository) -> Result<HashMap<Oid, Vec<GitRef>>, git2::Error> {
    let mut map: HashMap<Oid, Vec<GitRef>> = HashMap::new();
    let head_name = repo
        .head()
        .ok()
        .filter(|_| !repo.head_detached().unwrap_or(false))
        .and_then(|h| h.name().map(str::to_string));
    for reference in repo.references()?.flatten() {
        let Some(full) = reference.name() else { continue };
        let (kind, short) = if let Some(n) = full.strip_prefix("refs/heads/") {
            (GitRefKind::LocalBranch, n)
        } else if let Some(n) = full.strip_prefix("refs/remotes/") {
            if n.ends_with("/HEAD") {
                continue;
            }
            (GitRefKind::RemoteBranch, n)
        } else if let Some(n) = full.strip_prefix("refs/tags/") {
            (GitRefKind::Tag, n)
        } else {
            continue;
        };
        let Ok(commit) = reference.peel_to_commit() else { continue };
        map.entry(commit.id()).or_default().push(GitRef {
            name: short.to_string(),
            kind,
            is_head: head_name.as_deref() == Some(full),
        });
    }
    if repo.head_detached().unwrap_or(false) {
        if let Ok(commit) = repo.head().and_then(|h| h.peel_to_commit()) {
            map.entry(commit.id()).or_default().push(GitRef {
                name: "HEAD".to_string(),
                kind: GitRefKind::Head,
                is_head: true,
            });
        }
    }
    for refs in map.values_mut() {
        // the checked-out branch first, then local branches, remotes, tags
        refs.sort_by_key(|r| (!r.is_head, r.kind as u8, r.name.clone()));
    }
    Ok(map)
}

/// Tag names, newest-looking last.
pub fn get_tags(workspace_path: &Path) -> Result<Vec<String>, git2::Error> {
    let repo = Repository::discover(workspace_path)?;
    let mut tags: Vec<String> = repo.tag_names(None)?.iter().flatten().map(str::to_string).collect();
    tags.sort();
    Ok(tags)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitChangedFile {
    pub path: String,
    /// The path before a rename or copy.
    pub old_path: Option<String>,
    pub kind: GitChangeKind,
}

/// A commit with its full message and the files it changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitCommitDetails {
    pub info: GitCommitInfo,
    pub message: String,
    pub committer_name: String,
    pub committer_email: String,
    pub commit_timestamp: i64,
    /// Against the first parent; against the empty tree for a root commit.
    pub files: Vec<GitChangedFile>,
}

pub fn get_commit_details(
    workspace_path: &Path,
    oid: &str,
) -> Result<GitCommitDetails, git2::Error> {
    let repo = Repository::discover(workspace_path)?;
    let commit = repo.find_commit(Oid::from_str(oid)?)?;
    let refs = collect_refs(&repo)?;
    let tree = commit.tree()?;
    let parent_tree = commit.parent(0).ok().map(|p| p.tree()).transpose()?;
    let mut diff = repo.diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), None)?;
    diff.find_similar(Some(DiffFindOptions::new().renames(true)))?;

    let path_of = |file: git2::DiffFile| {
        file.path().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()
    };
    let mut files: Vec<GitChangedFile> = diff
        .deltas()
        .map(|delta| {
            let kind = match delta.status() {
                Delta::Added | Delta::Untracked => GitChangeKind::Added,
                Delta::Modified | Delta::Typechange => GitChangeKind::Modified,
                Delta::Deleted => GitChangeKind::Deleted,
                Delta::Renamed => GitChangeKind::Renamed,
                Delta::Copied => GitChangeKind::Copied,
                _ => GitChangeKind::Other,
            };
            let renamed = matches!(kind, GitChangeKind::Renamed | GitChangeKind::Copied);
            GitChangedFile {
                path: path_of(if kind == GitChangeKind::Deleted { delta.old_file() } else { delta.new_file() }),
                old_path: renamed.then(|| path_of(delta.old_file())),
                kind,
            }
        })
        .collect();
    files.sort_by(|a, b| a.path.cmp(&b.path));

    let committer = commit.committer();
    Ok(GitCommitDetails {
        info: commit_info(&commit, &refs)?,
        message: commit.message().unwrap_or("").trim_end().to_string(),
        committer_name: committer.name().unwrap_or("").to_string(),
        committer_email: committer.email().unwrap_or("").to_string(),
        commit_timestamp: commit.time().seconds(),
        files,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_non_repo_handling() {
        let temp_dir = std::env::temp_dir().join("clx_non_repo_test");
        let _ = fs::create_dir_all(&temp_dir);
        let res = get_repo_status(&temp_dir);
        assert!(res.is_err(), "Non-git directory should return Err");
        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_git_repo_discovery_and_history() {
        let temp_dir = std::env::temp_dir().join("clx_git_test_repo");
        let _ = fs::remove_dir_all(&temp_dir);
        let _ = fs::create_dir_all(&temp_dir);

        // Initialize repo
        let repo = Repository::init(&temp_dir).expect("init repo");
        let sig = git2::Signature::now("Tester", "tester@codelitex.org").expect("sig");

        // Commit 1
        let file1 = temp_dir.join("file1.txt");
        fs::write(&file1, "hello world\n").expect("write file1");
        let mut index = repo.index().expect("index");
        index.add_path(Path::new("file1.txt")).expect("add file1");
        index.write().expect("write index");
        let tree_id = index.write_tree().expect("write tree");
        let tree = repo.find_tree(tree_id).expect("find tree");
        let c1_id = repo
            .commit(Some("HEAD"), &sig, &sig, "Initial commit", &tree, &[])
            .expect("commit 1");

        // Commit 2
        let file2 = temp_dir.join("file2.txt");
        fs::write(&file2, "second file\n").expect("write file2");
        index.add_path(Path::new("file2.txt")).expect("add file2");
        index.write().expect("write index");
        let tree_id2 = index.write_tree().expect("write tree 2");
        let tree2 = repo.find_tree(tree_id2).expect("find tree 2");
        let c1 = repo.find_commit(c1_id).expect("find c1");
        repo.commit(Some("HEAD"), &sig, &sig, "Second commit", &tree2, &[&c1])
            .expect("commit 2");

        // Make working tree dirty
        fs::write(&file1, "modified content\n").expect("modify file1");
        let file3 = temp_dir.join("untracked.txt");
        fs::write(&file3, "untracked\n").expect("untracked file");

        // Test repo status
        let status = get_repo_status(&temp_dir).expect("get repo status");
        assert!(!status.is_clean, "Repo should not be clean");
        assert_eq!(status.files.len(), 2, "Should have 2 modified/untracked files");

        let has_modified = status.files.iter().any(|f| f.status == "modified");
        let has_untracked = status.files.iter().any(|f| f.status == "untracked");
        assert!(has_modified, "Should have modified file");
        assert!(has_untracked, "Should have untracked file");

        // Test commit history
        let history = get_commit_history(&temp_dir, 10).expect("get commit history");
        assert_eq!(history.len(), 2, "Should have 2 commits in history");
        assert_eq!(history[0].summary, "Second commit");
        assert_eq!(history[0].author_name, "Tester");
        assert_eq!(history[0].author_email, "tester@codelitex.org");
        assert_eq!(history[0].parent_count, 1);
        assert_eq!(history[1].summary, "Initial commit");
        assert_eq!(history[1].parent_count, 0);

        // Test branches
        let branches = get_branches(&temp_dir).expect("get branches");
        assert!(!branches.is_empty(), "Should have at least 1 branch");
        assert!(branches.iter().any(|b| b.is_head), "Head branch should be marked");

        // Cleanup
        let _ = fs::remove_dir_all(&temp_dir);
    }

    // ----- history window -----------------------------------------------------------------

    use git2::{FileMode, RepositoryInitOptions, Signature, Time};

    fn new_repo(dir: &Path) -> Repository {
        let mut opts = RepositoryInitOptions::new();
        opts.initial_head("main");
        Repository::init_opts(dir, &opts).expect("init")
    }

    /// Commit `changes` (flat file names; `None` deletes) on top of the first parent's tree
    /// and move `refname` to it. Times are fixed so the order is deterministic.
    fn commit(
        repo: &Repository,
        refname: &str,
        parents: &[Oid],
        changes: &[(&str, Option<&str>)],
        message: &str,
        secs: i64,
        author: (&str, &str),
    ) -> Oid {
        let parent_commits: Vec<_> = parents.iter().map(|p| repo.find_commit(*p).unwrap()).collect();
        let base = parent_commits.first().map(|c| c.tree().unwrap());
        let mut builder = repo.treebuilder(base.as_ref()).unwrap();
        for (name, content) in changes {
            match content {
                Some(c) => {
                    let blob = repo.blob(c.as_bytes()).unwrap();
                    builder.insert(name, blob, FileMode::Blob.into()).unwrap();
                }
                None => {
                    builder.remove(name).unwrap();
                }
            }
        }
        let tree = repo.find_tree(builder.write().unwrap()).unwrap();
        let sig = Signature::new(author.0, author.1, &Time::new(secs, 0)).unwrap();
        let refs: Vec<&git2::Commit> = parent_commits.iter().collect();
        repo.commit(Some(refname), &sig, &sig, message, &tree, &refs).unwrap()
    }

    const ANN: (&str, &str) = ("Ann", "ann@example.com");
    const BOB: (&str, &str) = ("Bob", "bob@example.com");

    /// main: c1 - c2 - c4(merge) ; feature: c1 - c3 - (c4 second parent)
    fn merged_repo(dir: &Path) -> (Repository, [Oid; 4]) {
        let repo = new_repo(dir);
        let c1 = commit(&repo, "refs/heads/main", &[], &[("a.txt", Some("a\n"))], "first", 100, ANN);
        let c2 = commit(&repo, "refs/heads/main", &[c1], &[("b.txt", Some("b\n"))], "second on main", 200, ANN);
        let c3 = commit(&repo, "refs/heads/feature", &[c1], &[("c.txt", Some("c\n"))], "work on feature", 300, BOB);
        let c4 = commit(&repo, "refs/heads/main", &[c2, c3], &[("c.txt", Some("c\n"))], "Merge feature", 400, ANN);
        repo.set_head("refs/heads/main").unwrap();
        (repo, [c1, c2, c3, c4])
    }

    fn query(branch: Option<&str>, text: &str, skip: usize, limit: usize) -> GitLogQuery {
        GitLogQuery { branch: branch.map(str::to_string), text: text.to_string(), skip, limit }
    }

    fn summaries(page: &GitLogPage) -> Vec<&str> {
        page.commits.iter().map(|c| c.summary.as_str()).collect()
    }

    #[test]
    fn the_log_lists_every_branch_children_before_parents() {
        let dir = tempfile::tempdir().unwrap();
        merged_repo(dir.path());
        let page = get_commit_page(dir.path(), &query(None, "", 0, 50)).unwrap();
        assert_eq!(summaries(&page), ["Merge feature", "work on feature", "second on main", "first"]);
        assert!(!page.has_more);
        assert_eq!(page.commits[0].parent_count, 2);
        assert_eq!(page.commits[0].parents.len(), 2);
    }

    #[test]
    fn pages_continue_where_the_last_one_stopped() {
        let dir = tempfile::tempdir().unwrap();
        merged_repo(dir.path());
        let first = get_commit_page(dir.path(), &query(None, "", 0, 3)).unwrap();
        assert_eq!(first.commits.len(), 3);
        assert!(first.has_more);
        let rest = get_commit_page(dir.path(), &query(None, "", 3, 3)).unwrap();
        assert_eq!(summaries(&rest), ["first"]);
        assert!(!rest.has_more);
    }

    #[test]
    fn picking_a_branch_shows_only_its_history() {
        let dir = tempfile::tempdir().unwrap();
        let (repo, [c1, ..]) = merged_repo(dir.path());
        commit(&repo, "refs/heads/side", &[c1], &[("s.txt", Some("s"))], "only on side", 500, BOB);
        let side = get_commit_page(dir.path(), &query(Some("side"), "", 0, 50)).unwrap();
        assert_eq!(summaries(&side), ["only on side", "first"]);
        let feature = get_commit_page(dir.path(), &query(Some("feature"), "", 0, 50)).unwrap();
        assert_eq!(summaries(&feature), ["work on feature", "first"]);
        let all = get_commit_page(dir.path(), &query(None, "", 0, 50)).unwrap();
        assert!(summaries(&all).contains(&"only on side"));
    }

    #[test]
    fn search_matches_subject_author_email_and_hash_prefix_ignoring_case() {
        let dir = tempfile::tempdir().unwrap();
        let (_repo, [c1, ..]) = merged_repo(dir.path());
        let by = |text: &str| summaries(&get_commit_page(dir.path(), &query(None, text, 0, 50)).unwrap()).into_iter().map(str::to_string).collect::<Vec<_>>();
        assert_eq!(by("MERGE"), ["Merge feature"]);
        assert_eq!(by("bob"), ["work on feature"]);
        assert_eq!(by("ann@EXAMPLE"), ["Merge feature", "second on main", "first"]);
        assert_eq!(by(&c1.to_string()[..8]), ["first"]);
        assert!(by("nothing like this").is_empty());
        // paging applies to the matches, not to the whole history
        let page = get_commit_page(dir.path(), &query(None, "ann@", 1, 1)).unwrap();
        assert_eq!(summaries(&page), ["second on main"]);
        assert!(page.has_more);
    }

    #[test]
    fn commits_carry_their_branch_tag_and_head_labels() {
        let dir = tempfile::tempdir().unwrap();
        let (repo, [c1, c2, c3, c4]) = merged_repo(dir.path());
        repo.tag_lightweight("v1", &repo.find_object(c1, None).unwrap(), false).unwrap();
        repo.reference("refs/remotes/origin/main", c2, true, "test").unwrap();
        repo.reference("refs/remotes/origin/HEAD", c2, true, "test").unwrap();
        let page = get_commit_page(dir.path(), &query(None, "", 0, 50)).unwrap();
        let refs_of = |oid: Oid| page.commits.iter().find(|c| c.oid == oid.to_string()).unwrap().refs.clone();

        let tip = refs_of(c4);
        assert_eq!(tip[0], GitRef { name: "main".into(), kind: GitRefKind::LocalBranch, is_head: true });
        assert_eq!(refs_of(c3), [GitRef { name: "feature".into(), kind: GitRefKind::LocalBranch, is_head: false }]);
        assert_eq!(refs_of(c2), [GitRef { name: "origin/main".into(), kind: GitRefKind::RemoteBranch, is_head: false }], "origin/HEAD only repeats origin/main");
        assert_eq!(refs_of(c1), [GitRef { name: "v1".into(), kind: GitRefKind::Tag, is_head: false }]);
        assert_eq!(get_tags(dir.path()).unwrap(), ["v1"]);
    }

    #[test]
    fn a_detached_head_is_shown_and_reachable() {
        let dir = tempfile::tempdir().unwrap();
        let (repo, [_, c2, ..]) = merged_repo(dir.path());
        repo.set_head_detached(c2).unwrap();
        let page = get_commit_page(dir.path(), &query(None, "", 0, 50)).unwrap();
        let at = page.commits.iter().find(|c| c.oid == c2.to_string()).unwrap();
        assert!(at.refs.iter().any(|r| r.kind == GitRefKind::Head && r.is_head));
        assert!(!page.commits.iter().flat_map(|c| &c.refs).any(|r| r.name == "main" && r.is_head), "no branch is checked out");
    }

    #[test]
    fn details_list_added_modified_deleted_and_renamed_files() {
        let dir = tempfile::tempdir().unwrap();
        let repo = new_repo(dir.path());
        let long = "line one\nline two\nline three\nline four\nline five\nline six\n";
        let c1 = commit(&repo, "refs/heads/main", &[], &[("keep.txt", Some("k\n")), ("old.txt", Some(long)), ("gone.txt", Some("g\n"))], "init", 100, ANN);
        let c2 = commit(&repo, "refs/heads/main", &[c1], &[("keep.txt", Some("k2\n")), ("old.txt", None), ("new.txt", Some(long)), ("gone.txt", None), ("fresh.txt", Some("f\n"))], "change things\n\nlonger body\nmore body", 200, BOB);

        let root = get_commit_details(dir.path(), &c1.to_string()).unwrap();
        assert!(root.files.iter().all(|f| f.kind == GitChangeKind::Added), "a root commit adds everything");
        assert_eq!(root.files.len(), 3);

        let d = get_commit_details(dir.path(), &c2.to_string()).unwrap();
        assert_eq!(d.message, "change things\n\nlonger body\nmore body");
        assert_eq!(d.info.author_name, "Bob");
        assert_eq!(d.committer_email, "bob@example.com");
        assert_eq!(d.commit_timestamp, 200);
        let by_path = |p: &str| d.files.iter().find(|f| f.path == p).unwrap_or_else(|| panic!("{p} in {:?}", d.files));
        assert_eq!(by_path("keep.txt").kind, GitChangeKind::Modified);
        assert_eq!(by_path("fresh.txt").kind, GitChangeKind::Added);
        assert_eq!(by_path("gone.txt").kind, GitChangeKind::Deleted);
        let renamed = by_path("new.txt");
        assert_eq!(renamed.kind, GitChangeKind::Renamed);
        assert_eq!(renamed.old_path.as_deref(), Some("old.txt"));
        assert_eq!(d.files.len(), 4);
        let paths: Vec<_> = d.files.iter().map(|f| f.path.as_str()).collect();
        assert!(paths.windows(2).all(|w| w[0] <= w[1]), "sorted by path: {paths:?}");
    }

    #[test]
    fn a_merge_commit_is_compared_with_its_first_parent() {
        let dir = tempfile::tempdir().unwrap();
        let (_repo, [.., c4]) = merged_repo(dir.path());
        let d = get_commit_details(dir.path(), &c4.to_string()).unwrap();
        assert_eq!(d.files.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(), ["c.txt"], "what the merge brought into main");
        assert_eq!(d.info.parent_count, 2);
    }

    #[test]
    fn history_queries_outside_a_repository_or_for_unknown_commits_fail() {
        let dir = tempfile::tempdir().unwrap();
        assert!(get_commit_page(dir.path(), &query(None, "", 0, 10)).is_err());
        let sub = tempfile::tempdir().unwrap();
        merged_repo(sub.path());
        assert!(get_commit_details(sub.path(), "0000000000000000000000000000000000000001").is_err());
        assert!(get_commit_details(sub.path(), "not a hash").is_err());
        assert!(get_commit_page(sub.path(), &query(Some("no-such-branch"), "", 0, 10)).is_err());
    }

    #[test]
    fn a_cancelled_query_stops_early() {
        let dir = tempfile::tempdir().unwrap();
        merged_repo(dir.path());
        let err = get_commit_page_until(dir.path(), &query(None, "", 0, 50), &|| true).unwrap_err();
        assert_eq!(err.message(), "cancelled");
    }
}
