use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::Command;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum GitError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Git command failed (exit code {0}): {1}")]
    CommandFailed(i32, String),

    #[error("Not a git repository: {0}")]
    NotARepository(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GitStatusKind {
    Modified,
    Added,
    Deleted,
    Untracked,
    Renamed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitFileChange {
    pub path: String,
    pub status: GitStatusKind,
    pub is_staged: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct GitStatusResult {
    pub branch: String,
    pub changes: Vec<GitFileChange>,
}

#[derive(Debug, Clone)]
pub struct GitEngine {
    repo_path: PathBuf,
}

impl GitEngine {
    pub fn new<P: Into<PathBuf>>(repo_path: P) -> Self {
        Self {
            repo_path: repo_path.into(),
        }
    }

    pub fn repo_path(&self) -> &Path {
        &self.repo_path
    }

    /// Checks whether the directory is inside a valid git repository.
    pub fn is_repo(&self) -> bool {
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.repo_path)
            .arg("rev-parse")
            .arg("--is-inside-work-tree")
            .output();

        match output {
            Ok(out) => out.status.success(),
            Err(_) => false,
        }
    }

    /// Gets the current branch name (e.g. "main").
    pub fn current_branch(&self) -> Result<String, GitError> {
        let output = self.run_git(&["rev-parse", "--abbrev-ref", "HEAD"])?;
        Ok(output.trim().to_string())
    }

    /// Retrieves git status including branch and list of changed/staged/untracked files.
    pub fn status(&self) -> Result<GitStatusResult, GitError> {
        let raw = self.run_git(&["status", "--porcelain=v1", "-b"])?;
        let mut branch = String::new();
        let mut changes = Vec::new();

        for line in raw.lines() {
            if line.starts_with("##") {
                let branch_part = line.trim_start_matches("##").trim();
                let b = branch_part.split("...").next().unwrap_or(branch_part);
                branch = b.to_string();
                continue;
            }

            if line.len() < 4 {
                continue;
            }

            let index_code = line.chars().next().unwrap_or(' ');
            let work_code = line.chars().nth(1).unwrap_or(' ');
            let mut file_path = line[3..].trim();

            if let Some(pos) = file_path.find(" -> ") {
                file_path = &file_path[pos + 4..];
            }

            if index_code == '?' && work_code == '?' {
                changes.push(GitFileChange {
                    path: file_path.to_string(),
                    status: GitStatusKind::Untracked,
                    is_staged: false,
                });
                continue;
            }

            // Staged change
            if index_code != ' ' && index_code != '?' {
                let kind = match index_code {
                    'M' => GitStatusKind::Modified,
                    'A' => GitStatusKind::Added,
                    'D' => GitStatusKind::Deleted,
                    'R' => GitStatusKind::Renamed,
                    _ => GitStatusKind::Modified,
                };
                changes.push(GitFileChange {
                    path: file_path.to_string(),
                    status: kind,
                    is_staged: true,
                });
            }

            // Unstaged change
            if work_code != ' ' && work_code != '?' {
                let kind = match work_code {
                    'M' => GitStatusKind::Modified,
                    'D' => GitStatusKind::Deleted,
                    _ => GitStatusKind::Modified,
                };
                changes.push(GitFileChange {
                    path: file_path.to_string(),
                    status: kind,
                    is_staged: false,
                });
            }
        }

        if branch.is_empty() {
            branch = self.current_branch().unwrap_or_else(|_| "HEAD".into());
        }

        Ok(GitStatusResult { branch, changes })
    }

    /// Computes the diff. If `staged` is true, runs `git diff --cached`.
    pub fn diff(&self, file_path: Option<&str>, staged: bool) -> Result<String, GitError> {
        let mut args = vec!["diff"];
        if staged {
            args.push("--cached");
        }

        if let Some(fp) = file_path.filter(|s| !s.trim().is_empty()) {
            args.push("--");
            args.push(fp);
        }

        self.run_git(&args)
    }

    /// Stages a file or pathspec (`git add <file>`).
    pub fn stage(&self, file_path: &str) -> Result<(), GitError> {
        self.run_git(&["add", file_path])?;
        Ok(())
    }

    /// Unstages a file (`git restore --staged <file>`).
    pub fn unstage(&self, file_path: &str) -> Result<(), GitError> {
        self.run_git(&["restore", "--staged", file_path])?;
        Ok(())
    }

    /// Commits staged changes with a commit message. Returns the commit hash.
    pub fn commit(&self, message: &str) -> Result<String, GitError> {
        self.run_git(&["commit", "-m", message])?;
        let hash = self.run_git(&["rev-parse", "--short", "HEAD"])?;
        Ok(hash.trim().to_string())
    }

    fn run_git(&self, args: &[&str]) -> Result<String, GitError> {
        let output = Command::new("git")
            .arg("-C")
            .arg(&self.repo_path)
            .args(args)
            .output()?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        } else {
            let err_msg = String::from_utf8_lossy(&output.stderr).to_string();
            let code = output.status.code().unwrap_or(-1);
            Err(GitError::CommandFailed(code, err_msg))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn create_test_repo() -> (PathBuf, GitEngine) {
        let dir = std::env::temp_dir().join(format!(
            "git_test_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();

        // Init git repo
        let _ = Command::new("git")
            .arg("-C")
            .arg(&dir)
            .arg("init")
            .output();

        let _ = Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(&["config", "user.name", "CodeLite Tester"])
            .output();

        let _ = Command::new("git")
            .arg("-C")
            .arg(&dir)
            .args(&["config", "user.email", "tester@codelite.dev"])
            .output();

        let engine = GitEngine::new(&dir);
        (dir, engine)
    }

    #[test]
    fn test_git_engine_workflow() {
        let (dir, engine) = create_test_repo();

        assert!(engine.is_repo());

        // 1. Untracked file
        let file_path = dir.join("README.md");
        fs::write(&file_path, "# CodeLiteX Project\n").unwrap();

        let status1 = engine.status().unwrap();
        assert!(status1.changes.iter().any(|c| c.path == "README.md"
            && c.status == GitStatusKind::Untracked
            && !c.is_staged));

        // 2. Stage file
        engine.stage("README.md").unwrap();
        let status2 = engine.status().unwrap();
        assert!(status2.changes.iter().any(|c| c.path == "README.md"
            && c.status == GitStatusKind::Added
            && c.is_staged));

        // 3. Commit
        let hash = engine.commit("Initial commit").unwrap();
        assert!(!hash.is_empty());

        let status3 = engine.status().unwrap();
        assert!(status3.changes.is_empty());

        // 4. Modify file
        fs::write(&file_path, "# CodeLiteX Project\nLine 2.\n").unwrap();
        let status4 = engine.status().unwrap();
        assert!(status4.changes.iter().any(|c| c.path == "README.md"
            && c.status == GitStatusKind::Modified
            && !c.is_staged));

        // 5. Diff
        let diff = engine.diff(Some("README.md"), false).unwrap();
        assert!(diff.contains("+Line 2."));
    }
}
