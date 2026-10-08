//! CodeLiteX Native Git Operations
//!
//! Provides native Git repository status, history logging, branch inspection,
//! and diff querying using libgit2.

use std::path::{Path, PathBuf};
use git2::{BranchType, Repository, StatusOptions};

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

/// Retrieves the Git commit history from HEAD up to `max_count` commits.
pub fn get_commit_history(
    workspace_path: &Path,
    max_count: usize,
) -> Result<Vec<GitCommitInfo>, git2::Error> {
    let repo = Repository::discover(workspace_path)?;
    let mut revwalk = repo.revwalk()?;
    revwalk.push_head()?;
    revwalk.set_sorting(git2::Sort::TIME)?;

    let mut commits = Vec::new();
    for oid in revwalk.take(max_count) {
        let oid = oid?;
        let commit = repo.find_commit(oid)?;
        let summary = commit.summary().unwrap_or("").to_string();
        let author = commit.author();
        let author_name = author.name().unwrap_or("").to_string();
        let author_email = author.email().unwrap_or("").to_string();
        let timestamp = commit.time().seconds();
        let parent_count = commit.parent_count();

        let oid_str = oid.to_string();
        let short_id = if oid_str.len() >= 7 {
            oid_str[..7].to_string()
        } else {
            oid_str.clone()
        };

        commits.push(GitCommitInfo {
            oid: oid_str,
            short_id,
            summary,
            author_name,
            author_email,
            timestamp,
            parent_count,
        });
    }

    Ok(commits)
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
}
