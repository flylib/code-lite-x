use crate::generated::types::{GitFileChange, GitStatusParams, GitStatusResult};
use crate::CodeLiteContext;
use code_lite_fs::git::GitEngine;
use std::path::PathBuf;

pub fn handle_status(
    ctx: *mut CodeLiteContext,
    params: GitStatusParams,
) -> Result<GitStatusResult, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let root = if params.workspace_path.is_empty() {
        ctx.workspace_root.clone()
    } else {
        PathBuf::from(&params.workspace_path)
    };

    let engine = GitEngine::new(&root);
    match engine.status() {
        Ok(status) => {
            let is_clean = status.changes.is_empty();
            let changes = status
                .changes
                .into_iter()
                .map(|c| GitFileChange {
                    path: c.path,
                    status: format!("{:?}", c.status),
                    staged: c.is_staged,
                })
                .collect();

            Ok(GitStatusResult {
                branch: status.branch,
                is_clean,
                changes,
            })
        }
        Err(e) => Err(format!("Git status failed: {}", e)),
    }
}
