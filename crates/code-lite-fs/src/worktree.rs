use crate::git::{GitEngine, GitError};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Represents an active Git Worktree session providing a completely isolated file system
/// sandbox for autonomous agent experiments and builds.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorktreeSession {
    pub task_id: String,
    pub branch_name: String,
    pub worktree_path: PathBuf,
}

pub struct WorktreeManager {
    git: GitEngine,
    worktree_base: PathBuf,
}

impl WorktreeManager {
    pub fn new<P: Into<PathBuf>>(repo_path: P) -> Self {
        let repo = repo_path.into();
        let base = repo.join(".codelite").join("worktree");
        Self {
            git: GitEngine::new(repo),
            worktree_base: base,
        }
    }

    pub fn worktree_base(&self) -> &Path {
        &self.worktree_base
    }

    /// Creates an isolated git worktree for the given task.
    /// Executes: `git worktree add .codelite/worktree/<task_id> -B agent/<task_id> HEAD`
    pub fn create_worktree(&self, task_id: &str) -> Result<WorktreeSession, GitError> {
        let branch_name = format!("agent/{}", task_id);
        let worktree_path = self.worktree_base.join(task_id);

        if let Some(parent) = worktree_path.parent() {
            fs::create_dir_all(parent)?;
        }

        // If directory exists from prior execution, clean it up first
        if worktree_path.exists() {
            let _ = Command::new("git")
                .arg("-C")
                .arg(self.git.repo_path())
                .arg("worktree")
                .arg("remove")
                .arg("--force")
                .arg(&worktree_path)
                .output();
            let _ = fs::remove_dir_all(&worktree_path);
        }

        let output = Command::new("git")
            .arg("-C")
            .arg(self.git.repo_path())
            .arg("worktree")
            .arg("add")
            .arg("-B")
            .arg(&branch_name)
            .arg(&worktree_path)
            .arg("HEAD")
            .output()?;

        if !output.status.success() {
            let err_msg = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(GitError::CommandFailed(
                output.status.code().unwrap_or(-1),
                err_msg,
            ));
        }

        Ok(WorktreeSession {
            task_id: task_id.to_string(),
            branch_name,
            worktree_path,
        })
    }

    /// Runs an autonomous command inside the isolated worktree directory.
    pub fn run_in_worktree(
        &self,
        session: &WorktreeSession,
        cmd: &str,
        args: &[&str],
    ) -> Result<(bool, String), GitError> {
        let output = Command::new(cmd)
            .args(args)
            .current_dir(&session.worktree_path)
            .output()?;

        let success = output.status.success();
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let full_output = format!("{}\n{}", stdout, stderr).trim().to_string();

        Ok((success, full_output))
    }

    /// Fast-forward merges the worktree branch back into the main repository and cleans up the worktree.
    pub fn merge_and_cleanup(&self, session: &WorktreeSession) -> Result<(), GitError> {
        // First commit changes in worktree if any exist
        let _ = Command::new("git")
            .arg("-C")
            .arg(&session.worktree_path)
            .arg("add")
            .arg("-A")
            .output();

        let _ = Command::new("git")
            .arg("-C")
            .arg(&session.worktree_path)
            .arg("commit")
            .arg("-m")
            .arg(format!("agent(worktree): completed task {}", session.task_id))
            .output();

        // Fast-forward merge into main repository
        let merge_out = Command::new("git")
            .arg("-C")
            .arg(self.git.repo_path())
            .arg("merge")
            .arg("--ff-only")
            .arg(&session.branch_name)
            .output()?;

        if !merge_out.status.success() {
            let err_msg = String::from_utf8_lossy(&merge_out.stderr).to_string();
            return Err(GitError::CommandFailed(
                merge_out.status.code().unwrap_or(-1),
                err_msg,
            ));
        }

        // Clean up worktree and delete the temporary branch
        let _ = Command::new("git")
            .arg("-C")
            .arg(self.git.repo_path())
            .arg("worktree")
            .arg("remove")
            .arg("--force")
            .arg(&session.worktree_path)
            .output();

        let _ = Command::new("git")
            .arg("-C")
            .arg(self.git.repo_path())
            .arg("branch")
            .arg("-D")
            .arg(&session.branch_name)
            .output();

        let _ = fs::remove_dir_all(&session.worktree_path);

        Ok(())
    }

    /// Discards the worktree completely without modifying the main repository.
    pub fn discard_worktree(&self, session: &WorktreeSession) -> Result<(), GitError> {
        let _ = Command::new("git")
            .arg("-C")
            .arg(self.git.repo_path())
            .arg("worktree")
            .arg("remove")
            .arg("--force")
            .arg(&session.worktree_path)
            .output();

        let _ = Command::new("git")
            .arg("-C")
            .arg(self.git.repo_path())
            .arg("branch")
            .arg("-D")
            .arg(&session.branch_name)
            .output();

        let _ = fs::remove_dir_all(&session.worktree_path);

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn test_worktree_manager_initialization() {
        let mgr = WorktreeManager::new("/tmp/test-repo");
        assert_eq!(
            mgr.worktree_base(),
            Path::new("/tmp/test-repo/.codelite/worktree")
        );
    }

    #[test]
    fn test_worktree_lifecycle_and_discard() {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let temp_repo = std::env::temp_dir().join(format!("test_wt_repo_{}", now));
        let _ = fs::remove_dir_all(&temp_repo);
        fs::create_dir_all(&temp_repo).unwrap();

        // Initialize git repo
        let _ = Command::new("git").arg("-C").arg(&temp_repo).arg("init").output().unwrap();
        let _ = Command::new("git").arg("-C").arg(&temp_repo).args(["config", "user.name", "Tester"]).output().unwrap();
        let _ = Command::new("git").arg("-C").arg(&temp_repo).args(["config", "user.email", "tester@test.com"]).output().unwrap();

        fs::write(temp_repo.join("README.md"), "# Initial Commit\n").unwrap();
        let _ = Command::new("git").arg("-C").arg(&temp_repo).args(["add", "README.md"]).output().unwrap();
        let _ = Command::new("git").arg("-C").arg(&temp_repo).args(["commit", "-m", "init"]).output().unwrap();

        let mgr = WorktreeManager::new(&temp_repo);
        let session = mgr.create_worktree("wt-task-1").expect("create worktree");

        assert!(session.worktree_path.exists());
        assert_eq!(session.branch_name, "agent/wt-task-1");

        // Run command inside worktree
        let (success, out) = mgr.run_in_worktree(&session, "git", &["status"]).unwrap();
        assert!(success);
        assert!(out.contains("On branch agent/wt-task-1"));

        // Discard worktree
        mgr.discard_worktree(&session).expect("discard worktree");
        assert!(!session.worktree_path.exists());

        // Cleanup
        let _ = fs::remove_dir_all(&temp_repo);
    }
}

