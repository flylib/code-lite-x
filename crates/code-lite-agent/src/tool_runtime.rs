use crate::error::ToolError;
use code_lite_storage::{Database, EventStore, GraphStore, OpType, OperationStore, SymbolRecord};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecutionResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

/// ToolRuntime provides a strictly controlled, auditable execution environment for the AI Agent.
/// The Agent never mutates files directly; every action is executed via ToolRuntime and logged
/// into SQLite Event Log and Operations tables.
pub struct ToolRuntime {
    pub workspace_root: PathBuf,
    pub session_id: String,
    pub task_id: Option<String>,
    pub db: Database,
    pub op_store: OperationStore,
    pub event_store: EventStore,
    pub graph_store: GraphStore,
}

impl ToolRuntime {
    pub fn new<P: AsRef<Path>>(
        workspace_root: P,
        session_id: &str,
        task_id: Option<&str>,
        db: Database,
    ) -> Self {
        Self {
            workspace_root: workspace_root.as_ref().to_path_buf(),
            session_id: session_id.to_string(),
            task_id: task_id.map(|s| s.to_string()),
            op_store: OperationStore::new(db.clone()),
            event_store: EventStore::new(db.clone()),
            graph_store: GraphStore::new(db.clone()),
            db,
        }
    }

    pub const ALLOWED_COMMANDS: &'static [&'static str] = &[
        "git", "cargo", "flutter", "dart", "make", "npm", "node", "echo", "ls", "cat",
    ];

    /// Validates an external command invocation against security whitelist policy.
    pub fn validate_command(cmd: &str, args: &[&str]) -> Result<(), ToolError> {
        let trimmed_cmd = cmd.trim();
        if trimmed_cmd.is_empty() {
            return Err(ToolError::CommandNotAllowed("Command cannot be empty".into()));
        }

        // Disallow path separators in command binary name (prevents `/bin/rm`, `../../evil`)
        if trimmed_cmd.contains('/') || trimmed_cmd.contains('\\') {
            return Err(ToolError::CommandNotAllowed(format!(
                "Command names cannot contain path separators: '{}'",
                trimmed_cmd
            )));
        }

        if !Self::ALLOWED_COMMANDS.contains(&trimmed_cmd) {
            return Err(ToolError::CommandNotAllowed(format!(
                "Command '{}' is not in allowed whitelist ({:?})",
                trimmed_cmd,
                Self::ALLOWED_COMMANDS
            )));
        }

        // Additional subcommand checks
        if trimmed_cmd == "git" {
            const ALLOWED_GIT_SUBS: &[&str] = &[
                "status", "diff", "log", "branch", "commit", "add", "restore", "checkout",
                "show", "rev-parse", "config", "init", "version",
            ];
            if let Some(sub) = args.first() {
                if !ALLOWED_GIT_SUBS.contains(sub) {
                    return Err(ToolError::CommandNotAllowed(format!(
                        "Git subcommand '{}' is not in allowed whitelist",
                        sub
                    )));
                }
            }
        }

        if trimmed_cmd == "cargo" {
            const ALLOWED_CARGO_SUBS: &[&str] = &[
                "check", "test", "build", "clippy", "run", "metadata", "tree", "version",
            ];
            if let Some(sub) = args.first() {
                if !ALLOWED_CARGO_SUBS.contains(sub) {
                    return Err(ToolError::CommandNotAllowed(format!(
                        "Cargo subcommand '{}' is not in allowed whitelist",
                        sub
                    )));
                }
            }
        }

        Ok(())
    }

    /// Resolves an input relative path into a verified safe PathBuf inside workspace_root.
    ///
    /// Rejects:
    /// - Absolute paths (e.g. `/etc/passwd`, `C:\Windows`)
    /// - Parent directory traversal (e.g. `../../target`)
    /// - Symlinks escaping the workspace root
    pub fn resolve_safe_path(&self, relative_path: &str) -> Result<PathBuf, ToolError> {
        let trimmed = relative_path.trim();
        if trimmed.is_empty() {
            return Err(ToolError::InvalidPath("Path cannot be empty".to_string()));
        }

        let input_p = Path::new(trimmed);
        if input_p.is_absolute() || trimmed.starts_with('/') || trimmed.starts_with('\\') {
            return Err(ToolError::PathEscape(format!(
                "Absolute paths are forbidden in sandbox: '{}'",
                trimmed
            )));
        }

        #[cfg(windows)]
        if input_p.components().any(|c| matches!(c, std::path::Component::Prefix(_))) {
            return Err(ToolError::PathEscape(format!(
                "Drive prefix paths are forbidden: '{}'",
                trimmed
            )));
        }

        let mut normalized = PathBuf::new();
        for component in input_p.components() {
            match component {
                std::path::Component::Prefix(_) | std::path::Component::RootDir => {
                    return Err(ToolError::PathEscape(format!(
                        "Root-relative paths are forbidden: '{}'",
                        trimmed
                    )));
                }
                std::path::Component::CurDir => continue,
                std::path::Component::ParentDir => {
                    if !normalized.pop() {
                        return Err(ToolError::PathEscape(format!(
                            "Parent directory traversal above workspace root: '{}'",
                            trimmed
                        )));
                    }
                }
                std::path::Component::Normal(c) => {
                    normalized.push(c);
                }
            }
        }

        let canonical_root = self
            .workspace_root
            .canonicalize()
            .unwrap_or_else(|_| self.workspace_root.clone());

        let candidate = canonical_root.join(&normalized);

        if candidate.exists() {
            let canonical_candidate = candidate.canonicalize().map_err(ToolError::Io)?;
            if !canonical_candidate.starts_with(&canonical_root) {
                return Err(ToolError::PathEscape(format!(
                    "Path resolves outside workspace root (symlink escape): '{}'",
                    trimmed
                )));
            }
            Ok(canonical_candidate)
        } else {
            // For new files, verify existing ancestor directory canonicalizes within root
            let mut cur = candidate.as_path();
            let mut found_ancestor = None;
            while let Some(parent) = cur.parent() {
                if parent.exists() {
                    let canonical_parent = parent.canonicalize().map_err(ToolError::Io)?;
                    found_ancestor = Some(canonical_parent);
                    break;
                }
                cur = parent;
            }

            let ancestor = found_ancestor.unwrap_or_else(|| canonical_root.clone());
            if !ancestor.starts_with(&canonical_root) {
                return Err(ToolError::PathEscape(format!(
                    "Ancestor directory escapes workspace root: '{}'",
                    trimmed
                )));
            }

            if !candidate.starts_with(&canonical_root) {
                return Err(ToolError::PathEscape(format!(
                    "Resolved candidate path escapes workspace root: '{}'",
                    trimmed
                )));
            }

            Ok(candidate)
        }
    }

    /// Tool 1: read_file
    pub fn read_file(&self, relative_path: &str) -> Result<String, ToolError> {
        let full_path = self.resolve_safe_path(relative_path)?;
        let content = if full_path.exists() {
            fs::read_to_string(&full_path)?
        } else {
            String::new()
        };

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:read_file",
            &serde_json::json!({
                "path": relative_path,
                "bytes": content.len(),
                "exists": full_path.exists(),
            }),
        );

        Ok(content)
    }

    /// Tool 2: search_symbol via CodeGraph
    pub fn search_symbol(&self, query: &str) -> Result<Vec<SymbolRecord>, ToolError> {
        let symbols = self.graph_store.find_symbols_by_name(query)?;

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:search_symbol",
            &serde_json::json!({
                "query": query,
                "matches": symbols.len(),
            }),
        );

        Ok(symbols)
    }

    /// Tool 3: apply_patch
    /// Replaces file content, writes atomic diff patch and hashes into SQLite.
    pub fn apply_patch(
        &self,
        relative_path: &str,
        new_content: &str,
    ) -> Result<i64, ToolError> {
        let full_path = self.resolve_safe_path(relative_path)?;
        let before_content = if full_path.exists() {
            Some(fs::read_to_string(&full_path)?)
        } else {
            None
        };

        if let Some(parent) = full_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&full_path, new_content)?;

        let op_type = if before_content.is_some() {
            OpType::Modify
        } else {
            OpType::Create
        };

        let op_id = self.op_store.record_apply(
            &self.session_id,
            self.task_id.as_deref(),
            &full_path.to_string_lossy(),
            op_type,
            before_content,
            Some(new_content.to_string()),
        )?;

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:apply_patch",
            &serde_json::json!({
                "path": relative_path,
                "op_id": op_id,
            }),
        );

        Ok(op_id)
    }

    /// Tool 4: execute command
    pub fn execute(&self, cmd: &str, args: &[&str]) -> Result<ExecutionResult, ToolError> {
        Self::validate_command(cmd, args)?;

        let output = Command::new(cmd)
            .args(args)
            .current_dir(&self.workspace_root)
            .output()?;

        let exit_code = output.status.code().unwrap_or(-1);
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let success = output.status.success();

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:execute",
            &serde_json::json!({
                "cmd": cmd,
                "args": args,
                "exit_code": exit_code,
                "success": success,
            }),
        );

        Ok(ExecutionResult {
            exit_code,
            stdout,
            stderr,
            success,
        })
    }

    /// Tool 5: rollback_to_step
    /// Reverts all operations performed after target_op_id in this session.
    pub fn rollback_to_step(&self, target_op_id: i64) -> Result<usize, ToolError> {
        let count = self.op_store.rollback_to_op(&self.session_id, target_op_id)?;

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:rollback_to_step",
            &serde_json::json!({
                "target_op_id": target_op_id,
                "reverted_count": count,
            }),
        );

        Ok(count)
    }

    /// Tool 6: restore_session_start
    /// Reverts all operations performed in this session.
    pub fn restore_session_start(&self) -> Result<usize, ToolError> {
        let count = self.op_store.restore_session_start(&self.session_id)?;

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:restore_session_start",
            &serde_json::json!({
                "reverted_count": count,
            }),
        );

        Ok(count)
    }

    /// Tool 6b: rollback_step
    /// Reverts a single operation by its operation ID.
    pub fn rollback_step(&self, op_id: i64) -> Result<(), ToolError> {
        self.op_store.revert(op_id)?;

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:rollback_step",
            &serde_json::json!({
                "op_id": op_id,
            }),
        );

        Ok(())
    }

    /// Tool 7: delete_file
    /// Deletes a file and records an atomic undo snapshot in SQLite operations.
    pub fn delete_file(&self, relative_path: &str) -> Result<i64, ToolError> {
        let full_path = self.resolve_safe_path(relative_path)?;
        if !full_path.exists() {
            return Err(ToolError::FileNotFound(relative_path.to_string()));
        }

        let before_content = fs::read_to_string(&full_path)?;
        fs::remove_file(&full_path)?;

        let op_id = self.op_store.record_apply(
            &self.session_id,
            self.task_id.as_deref(),
            &full_path.to_string_lossy(),
            OpType::Delete,
            Some(before_content),
            None,
        )?;

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:delete_file",
            &serde_json::json!({
                "path": relative_path,
                "op_id": op_id,
            }),
        );

        Ok(op_id)
    }

    /// Tool 8: get_code_context
    /// Queries the CodeGraph for rich, focused context around a symbol.
    pub fn get_code_context(
        &self,
        graph: &dyn code_lite_graph::CodeGraph,
        symbol_key_or_name: &str,
    ) -> Result<code_lite_graph::CodeContext, ToolError> {
        let ctx = graph
            .get_code_context(symbol_key_or_name)
            .map_err(|e| ToolError::Graph(e.to_string()))?
            .ok_or_else(|| ToolError::Graph(format!("Symbol '{}' not found in CodeGraph", symbol_key_or_name)))?;

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:get_code_context",
            &serde_json::json!({
                "symbol": symbol_key_or_name,
                "name": ctx.name,
                "callers_count": ctx.callers.len(),
                "callees_count": ctx.callees.len(),
            }),
        );

        Ok(ctx)
    }

    /// Tool 9: lsp_diagnostics
    /// Retrieves LSP diagnostics for a file to check for compilation/syntax errors.
    pub fn lsp_diagnostics(
        &self,
        lsp: &code_lite_lsp::LspClient,
        relative_path: &str,
    ) -> Result<Vec<code_lite_lsp::Diagnostic>, ToolError> {
        let full_path = self.resolve_safe_path(relative_path)?;
        let uri = format!("file://{}", full_path.to_string_lossy());
        let diags = lsp.get_diagnostics(&uri);

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:lsp_diagnostics",
            &serde_json::json!({
                "path": relative_path,
                "diagnostics_count": diags.len(),
            }),
        );

        Ok(diags)
    }

    /// Tool 10: session_diff
    /// Computes unified diff of changes made during this session.
    pub fn session_diff(&self) -> Result<String, ToolError> {
        let ops = self.op_store.list_operations(&self.session_id)?;
        let mut diffs = Vec::new();
        for op in ops {
            if !op.patch_diff.trim().is_empty() {
                diffs.push(op.patch_diff);
            }
        }
        let result = diffs.join("\n\n");

        let _ = self.event_store.log(
            Some(&self.session_id),
            "tool:session_diff",
            &serde_json::json!({
                "diff_length": result.len(),
            }),
        );

        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_lite_storage::SessionStore;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn test_tool_runtime_session_lifecycle_and_rollback() {
        let db = Database::open_in_memory().unwrap();
        let session_store = SessionStore::new(db.clone());

        session_store.create_session("sess-1024", "Refactor Auth Task").unwrap();
        session_store.create_task("task-1", "sess-1024", "Implement token refresh").unwrap();

        let temp_dir = std::env::temp_dir().join(format!(
            "test_workspace_{}",
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&temp_dir).unwrap();

        let runtime = ToolRuntime::new(&temp_dir, "sess-1024", Some("task-1"), db);

        // Step 1: Create file v0
        let v0 = "fn auth() -> bool { false }\n";
        let op1 = runtime.apply_patch("src/auth.rs", v0).unwrap();
        assert!(op1 > 0);

        // Read back
        let read = runtime.read_file("src/auth.rs").unwrap();
        assert_eq!(read, v0);

        // Step 2: Apply patch v1
        let v1 = "fn auth() -> bool { true }\n";
        let op2 = runtime.apply_patch("src/auth.rs", v1).unwrap();
        assert!(op2 > op1);
        assert_eq!(runtime.read_file("src/auth.rs").unwrap(), v1);

        // Step 3: Apply patch v2 (with a bug)
        let v2 = "fn auth() -> bool { panic!(\"broken\") }\n";
        let op3 = runtime.apply_patch("src/auth.rs", v2).unwrap();
        assert!(op3 > op2);
        assert_eq!(runtime.read_file("src/auth.rs").unwrap(), v2);

        // Rollback -> Step 2 (reverts op3, returns to v1!)
        let reverted = runtime.rollback_to_step(op2).unwrap();
        assert_eq!(reverted, 1);
        assert_eq!(runtime.read_file("src/auth.rs").unwrap(), v1);

        // Restore -> Session Start (reverts op2 and op1!)
        let restored = runtime.restore_session_start().unwrap();
        assert_eq!(restored, 2);

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_path_guard_rejects_escape_and_traversal() {
        let db = Database::open_in_memory().unwrap();
        let session_store = SessionStore::new(db.clone());
        session_store.create_session("sess-guard", "Guard Test Session").unwrap();

        let temp_dir = std::env::temp_dir().join(format!(
            "test_workspace_guard_{}",
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&temp_dir).unwrap();

        let runtime = ToolRuntime::new(&temp_dir, "sess-guard", None, db);

        // 1. Absolute path must be rejected
        let abs_res = runtime.read_file("/etc/passwd");
        assert!(abs_res.is_err());
        match abs_res.unwrap_err() {
            ToolError::PathEscape(msg) => assert!(msg.contains("Absolute paths are forbidden")),
            other => panic!("Expected PathEscape error, got: {:?}", other),
        }

        // 2. Traversal out of workspace root must be rejected
        let trav_res = runtime.read_file("../../outside.txt");
        assert!(trav_res.is_err());
        match trav_res.unwrap_err() {
            ToolError::PathEscape(msg) => assert!(msg.contains("traversal above workspace root")),
            other => panic!("Expected PathEscape error, got: {:?}", other),
        }

        // 3. Traversal inside a nested relative path out of workspace must be rejected
        let nested_trav = runtime.apply_patch("sub/dir/../../../../outside.txt", "content");
        assert!(nested_trav.is_err());
        match nested_trav.unwrap_err() {
            ToolError::PathEscape(msg) => assert!(msg.contains("traversal above workspace root")),
            other => panic!("Expected PathEscape error, got: {:?}", other),
        }

        // 4. Legitimate relative path succeeds
        let valid_res = runtime.apply_patch("nested/valid.txt", "hello safe world");
        assert!(valid_res.is_ok());
        let read_back = runtime.read_file("nested/valid.txt").unwrap();
        assert_eq!(read_back, "hello safe world");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_command_whitelist_security() {
        let db = Database::open_in_memory().unwrap();
        let temp_dir = std::env::temp_dir().join(format!(
            "test_workspace_cmd_{}",
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&temp_dir).unwrap();

        let runtime = ToolRuntime::new(&temp_dir, "sess-cmd", None, db);

        // 1. Disallowed commands are blocked
        let blocked = runtime.execute("rm", &["-rf", "/tmp"]);
        assert!(blocked.is_err());
        match blocked.unwrap_err() {
            ToolError::CommandNotAllowed(msg) => assert!(msg.contains("not in allowed whitelist")),
            other => panic!("Expected CommandNotAllowed, got: {:?}", other),
        }

        let curl_res = runtime.execute("curl", &["https://evil.com"]);
        assert!(curl_res.is_err());

        // 2. Command with path separators blocked
        let path_cmd = runtime.execute("/bin/echo", &["hi"]);
        assert!(path_cmd.is_err());
        match path_cmd.unwrap_err() {
            ToolError::CommandNotAllowed(msg) => assert!(msg.contains("cannot contain path separators")),
            other => panic!("Expected CommandNotAllowed, got: {:?}", other),
        }

        // 3. Whitelisted command succeeds
        let allowed = runtime.execute("echo", &["code-lite-safe-test"]);
        assert!(allowed.is_ok());
        let output = allowed.unwrap();
        assert!(output.stdout.contains("code-lite-safe-test"));

        let _ = fs::remove_dir_all(&temp_dir);
    }
}

