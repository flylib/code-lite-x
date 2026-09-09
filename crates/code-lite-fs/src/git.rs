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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DiffHunkKind {
    Added,
    Modified,
    Deleted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitLineDiff {
    pub line: usize,
    pub kind: DiffHunkKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_content: Option<String>,
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

    /// Parses diff hunks for a file, returning line-by-line diff markers with original & new content.
    pub fn diff_hunks(&self, file_path: &str) -> Result<Vec<GitLineDiff>, GitError> {
        if file_path.trim().is_empty() {
            return Ok(Vec::new());
        }

        let raw_diff = match self.run_git(&["diff", "-U0", "HEAD", "--", file_path]) {
            Ok(out) if !out.trim().is_empty() => out,
            _ => match self.run_git(&["diff", "-U0", "--", file_path]) {
                Ok(out) => out,
                Err(_) => return Ok(Vec::new()),
            },
        };

        if raw_diff.trim().is_empty() {
            return Ok(Vec::new());
        }

        let mut results = Vec::new();
        let mut current_hunk: Option<(usize, usize, usize, usize)> = None;
        let mut old_lines: Vec<String> = Vec::new();
        let mut new_lines: Vec<String> = Vec::new();

        let flush_hunk = |results: &mut Vec<GitLineDiff>,
                          hunk: (usize, usize, usize, usize),
                          old_l: &[String],
                          new_l: &[String]| {
            let (_old_start, old_count, new_start, new_count) = hunk;
            if old_count == 0 && new_count > 0 {
                let start = if new_start > 0 { new_start - 1 } else { 0 };
                for (idx, line_text) in new_l.iter().enumerate() {
                    results.push(GitLineDiff {
                        line: start + idx,
                        kind: DiffHunkKind::Added,
                        original_content: None,
                        new_content: Some(line_text.clone()),
                    });
                }
            } else if old_count > 0 && new_count == 0 {
                let target_line = if new_start > 0 { new_start - 1 } else { 0 };
                results.push(GitLineDiff {
                    line: target_line,
                    kind: DiffHunkKind::Deleted,
                    original_content: Some(old_l.join("\n")),
                    new_content: None,
                });
            } else {
                let start = if new_start > 0 { new_start - 1 } else { 0 };
                let old_str = if old_l.is_empty() { None } else { Some(old_l.join("\n")) };
                let new_count_len = new_l.len().max(new_count);
                for idx in 0..new_count_len {
                    let line_text = new_l.get(idx).cloned();
                    results.push(GitLineDiff {
                        line: start + idx,
                        kind: DiffHunkKind::Modified,
                        original_content: if idx == 0 { old_str.clone() } else { None },
                        new_content: line_text,
                    });
                }
            }
        };

        for line in raw_diff.lines() {
            if line.starts_with("@@") {
                if let Some(hunk) = current_hunk.take() {
                    flush_hunk(&mut results, hunk, &old_lines, &new_lines);
                    old_lines.clear();
                    new_lines.clear();
                }

                if let Some(hunk_info) = parse_hunk_header(line) {
                    current_hunk = Some(hunk_info);
                }
            } else if current_hunk.is_some() {
                if let Some(rest) = line.strip_prefix('-') {
                    old_lines.push(rest.to_string());
                } else if let Some(rest) = line.strip_prefix('+') {
                    new_lines.push(rest.to_string());
                }
            }
        }

        if let Some(hunk) = current_hunk {
            flush_hunk(&mut results, hunk, &old_lines, &new_lines);
        }

        Ok(results)
    }

    /// Reverts uncommitted changes on a file (working tree checkout / restore).
    pub fn revert_file(&self, file_path: &str) -> Result<(), GitError> {
        let res = self.run_git(&["checkout", "HEAD", "--", file_path]);
        if res.is_err() {
            self.run_git(&["restore", file_path])?;
        }
        Ok(())
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

fn parse_hunk_header(line: &str) -> Option<(usize, usize, usize, usize)> {
    let parts: Vec<&str> = line.split("@@").collect();
    if parts.len() < 3 {
        return None;
    }
    let body = parts[1].trim();
    let tokens: Vec<&str> = body.split_whitespace().collect();
    if tokens.len() < 2 {
        return None;
    }

    let parse_token = |token: &str, prefix: char| -> Option<(usize, usize)> {
        let clean = token.strip_prefix(prefix)?;
        if let Some(pos) = clean.find(',') {
            let start = clean[..pos].parse::<usize>().ok()?;
            let count = clean[pos + 1..].parse::<usize>().ok()?;
            Some((start, count))
        } else {
            let start = clean.parse::<usize>().ok()?;
            Some((start, 1))
        }
    };

    let (old_start, old_count) = parse_token(tokens[0], '-')?;
    let (new_start, new_count) = parse_token(tokens[1], '+')?;
    Some((old_start, old_count, new_start, new_count))
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

    #[test]
    fn test_diff_hunks_and_revert() {
        let (dir, engine) = create_test_repo();

        let file_path = dir.join("main.rs");
        fs::write(&file_path, "fn main() {\n    println!(\"Hello\");\n}\n").unwrap();
        engine.stage("main.rs").unwrap();
        engine.commit("Add main.rs").unwrap();

        // Now append line 4 and modify line 2
        fs::write(&file_path, "fn main() {\n    println!(\"CodeLiteX\");\n}\n// EOF\n").unwrap();

        let hunks = engine.diff_hunks("main.rs").unwrap();
        assert!(!hunks.is_empty());
        assert!(hunks.iter().any(|h| h.kind == DiffHunkKind::Modified || h.kind == DiffHunkKind::Added));

        // Revert file
        engine.revert_file("main.rs").unwrap();
        let restored = fs::read_to_string(&file_path).unwrap();
        assert!(restored.contains("println!(\"Hello\");"));
        assert!(!restored.contains("CodeLiteX"));

        let hunks_after = engine.diff_hunks("main.rs").unwrap();
        assert!(hunks_after.is_empty());
    }
}
