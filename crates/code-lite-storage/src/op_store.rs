use crate::db::Database;
use crate::error::StorageError;
use crate::models::{OpStatus, OpType, Operation};
use rusqlite::params;
use similar::TextDiff;
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct OperationStore {
    db: Database,
}

impl OperationStore {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Computes unified diff string between before and after content.
    pub fn compute_diff(file_name: &str, before: &str, after: &str) -> String {
        let diff = TextDiff::from_lines(before, after);
        diff.unified_diff()
            .header(&format!("a/{}", file_name), &format!("b/{}", file_name))
            .to_string()
    }

    /// Records an applied operation into the operations table.
    pub fn record_apply(
        &self,
        session_id: &str,
        task_id: Option<&str>,
        file_path: &str,
        op_type: OpType,
        before_content: Option<String>,
        after_content: Option<String>,
    ) -> Result<i64, StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        let before_hash = before_content.as_ref().map(|c| format!("{:x}", c.len()));
        let after_hash = after_content.as_ref().map(|c| format!("{:x}", c.len()));

        let patch_diff = Self::compute_diff(
            file_path,
            before_content.as_deref().unwrap_or(""),
            after_content.as_deref().unwrap_or(""),
        );

        self.db.with_conn(|conn| {
            conn.execute(
                r#"
                INSERT INTO operations (
                    session_id, task_id, file_path, op_type,
                    before_hash, after_hash, before_content, after_content,
                    patch_diff, status, created_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                "#,
                params![
                    session_id,
                    task_id,
                    file_path,
                    op_type.as_str(),
                    before_hash,
                    after_hash,
                    before_content,
                    after_content,
                    patch_diff,
                    OpStatus::Applied.as_str(),
                    now,
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Retrieves an operation by its ID.
    pub fn get(&self, op_id: i64) -> Result<Operation, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                r#"
                SELECT id, session_id, task_id, file_path, op_type,
                       before_hash, after_hash, before_content, after_content,
                       patch_diff, status, created_at
                FROM operations WHERE id = ?1
                "#,
            )?;

            let op = stmt.query_row(params![op_id], |row| {
                let op_type_str: String = row.get(4)?;
                let status_str: String = row.get(10)?;
                Ok(Operation {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    task_id: row.get(2)?,
                    file_path: row.get(3)?,
                    op_type: OpType::from_str(&op_type_str),
                    before_hash: row.get(5)?,
                    after_hash: row.get(6)?,
                    before_content: row.get(7)?,
                    after_content: row.get(8)?,
                    patch_diff: row.get(9)?,
                    status: OpStatus::from_str(&status_str),
                    created_at: row.get(11)?,
                })
            })?;

            Ok(op)
        })
    }

    /// Reverts a previously applied operation, restoring the target file on disk to `before_content`.
    pub fn revert(&self, op_id: i64) -> Result<(), StorageError> {
        let op = self.get(op_id)?;
        if op.status == OpStatus::Reverted {
            return Ok(());
        }

        let path = Path::new(&op.file_path);
        match op.op_type {
            OpType::Create => {
                if path.exists() {
                    fs::remove_file(path)?;
                }
            }
            OpType::Modify => {
                if let Some(before) = &op.before_content {
                    if let Some(parent) = path.parent() {
                        fs::create_dir_all(parent)?;
                    }
                    fs::write(path, before)?;
                }
            }
            OpType::Delete => {
                if let Some(before) = &op.before_content {
                    if let Some(parent) = path.parent() {
                        fs::create_dir_all(parent)?;
                    }
                    fs::write(path, before)?;
                }
            }
        }

        self.db.with_conn(|conn| {
            conn.execute(
                "UPDATE operations SET status = ?1 WHERE id = ?2",
                params![OpStatus::Reverted.as_str(), op_id],
            )?;
            Ok(())
        })
    }

    /// Reverts all operations associated with a task in reverse chronological order.
    pub fn revert_task(&self, task_id: &str) -> Result<usize, StorageError> {
        let op_ids: Vec<i64> = self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id FROM operations WHERE task_id = ?1 AND status = 'applied' ORDER BY id DESC",
            )?;
            let rows = stmt.query_map(params![task_id], |row| row.get(0))?;
            let mut ids = Vec::new();
            for r in rows {
                ids.push(r?);
            }
            Ok(ids)
        })?;

        let count = op_ids.len();
        for id in op_ids {
            self.revert(id)?;
        }

        self.db.with_conn(|conn| {
            conn.execute(
                "UPDATE tasks SET status = 'reverted' WHERE id = ?1",
                params![task_id],
            )?;
            Ok(())
        })?;

        Ok(count)
    }

    /// Rolls back all operations in a session that occurred after a specific target operation ID.
    /// This allows rolling back to any step in an Agent session (e.g. Rollback -> Step 3).
    pub fn rollback_to_op(&self, session_id: &str, target_op_id: i64) -> Result<usize, StorageError> {
        let op_ids: Vec<i64> = self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id FROM operations WHERE session_id = ?1 AND id > ?2 AND status = 'applied' ORDER BY id DESC",
            )?;
            let rows = stmt.query_map(params![session_id, target_op_id], |row| row.get(0))?;
            let mut ids = Vec::new();
            for r in rows {
                ids.push(r?);
            }
            Ok(ids)
        })?;

        let count = op_ids.len();
        for id in op_ids {
            self.revert(id)?;
        }
        Ok(count)
    }

    /// Restores the workspace to the start of the session by reverting all operations in that session.
    pub fn restore_session_start(&self, session_id: &str) -> Result<usize, StorageError> {
        let op_ids: Vec<i64> = self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id FROM operations WHERE session_id = ?1 AND status = 'applied' ORDER BY id DESC",
            )?;
            let rows = stmt.query_map(params![session_id], |row| row.get(0))?;
            let mut ids = Vec::new();
            for r in rows {
                ids.push(r?);
            }
            Ok(ids)
        })?;

        let count = op_ids.len();
        for id in op_ids {
            self.revert(id)?;
        }
        Ok(count)
    }

    /// Lists all operations for a given session in chronological order.
    pub fn list_operations(&self, session_id: &str) -> Result<Vec<Operation>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                r#"
                SELECT id, session_id, task_id, file_path, op_type,
                       before_hash, after_hash, before_content, after_content,
                       patch_diff, status, created_at
                FROM operations WHERE session_id = ?1 ORDER BY id ASC
                "#,
            )?;
            let rows = stmt.query_map(params![session_id], |row| {
                let op_type_str: String = row.get(4)?;
                let status_str: String = row.get(10)?;
                Ok(Operation {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    task_id: row.get(2)?,
                    file_path: row.get(3)?,
                    op_type: OpType::from_str(&op_type_str),
                    before_hash: row.get(5)?,
                    after_hash: row.get(6)?,
                    before_content: row.get(7)?,
                    after_content: row.get(8)?,
                    patch_diff: row.get(9)?,
                    status: OpStatus::from_str(&status_str),
                    created_at: row.get(11)?,
                })
            })?;

            let mut results = Vec::new();
            for r in rows {
                results.push(r?);
            }
            Ok(results)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn test_operation_record_and_revert() {
        let db = Database::open_in_memory().unwrap();
        let store = OperationStore::new(db.clone());

        // Create a unique temporary file path using std::env::temp_dir
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let file_path = std::env::temp_dir()
            .join(format!("test_codelite_{}.rs", nonce))
            .to_string_lossy()
            .to_string();

        let original_text = "fn hello() -> &'static str {\n    \"hello\"\n}\n";
        fs::write(&file_path, original_text).unwrap();

        // Initialize Session and Task to satisfy foreign key constraints
        let session_store = crate::session_store::SessionStore::new(db.clone());
        session_store.create_session("sess-1", "Test Session").unwrap();
        session_store.create_task("task-1", "sess-1", "Modify greeting").unwrap();

        // Agent modifies file
        let modified_text = "fn hello() -> &'static str {\n    \"world\"\n}\n";
        fs::write(&file_path, modified_text).unwrap();

        // Record operation
        let op_id = store
            .record_apply(
                "sess-1",
                Some("task-1"),
                &file_path,
                OpType::Modify,
                Some(original_text.to_string()),
                Some(modified_text.to_string()),
            )
            .unwrap();

        let op = store.get(op_id).unwrap();
        assert_eq!(op.status, OpStatus::Applied);
        assert!(op.patch_diff.contains("-    \"hello\""));
        assert!(op.patch_diff.contains("+    \"world\""));

        // Revert operation
        store.revert(op_id).unwrap();
        let content_after_revert = fs::read_to_string(&file_path).unwrap();
        assert_eq!(content_after_revert, original_text);

        let op_reverted = store.get(op_id).unwrap();
        assert_eq!(op_reverted.status, OpStatus::Reverted);

        // Clean up
        let _ = fs::remove_file(&file_path);
    }

    #[test]
    fn test_step_level_rollback() {
        let db = Database::open_in_memory().unwrap();
        let store = OperationStore::new(db.clone());
        let session_store = crate::session_store::SessionStore::new(db.clone());

        session_store.create_session("sess-1024", "Agent Refactor Session").unwrap();
        session_store.create_task("task-1", "sess-1024", "Refactor service").unwrap();

        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let file_path = std::env::temp_dir()
            .join(format!("test_rollback_{}.rs", nonce))
            .to_string_lossy()
            .to_string();

        let v0 = "version 0\n";
        let v1 = "version 1\n";
        let v2 = "version 2\n";

        fs::write(&file_path, v0).unwrap();

        // Step 1: apply patch to v1
        fs::write(&file_path, v1).unwrap();
        let op1 = store.record_apply("sess-1024", Some("task-1"), &file_path, OpType::Modify, Some(v0.to_string()), Some(v1.to_string())).unwrap();

        // Step 2: apply patch to v2
        fs::write(&file_path, v2).unwrap();
        let _op2 = store.record_apply("sess-1024", Some("task-1"), &file_path, OpType::Modify, Some(v1.to_string()), Some(v2.to_string())).unwrap();

        assert_eq!(fs::read_to_string(&file_path).unwrap(), v2);

        // Rollback to op1 (undoes op2, reverts back to v1!)
        let reverted = store.rollback_to_op("sess-1024", op1).unwrap();
        assert_eq!(reverted, 1);
        assert_eq!(fs::read_to_string(&file_path).unwrap(), v1);

        // Restore to session start (undoes op1, reverts back to v0!)
        let restored = store.restore_session_start("sess-1024").unwrap();
        assert_eq!(restored, 1);
        assert_eq!(fs::read_to_string(&file_path).unwrap(), v0);

        let _ = fs::remove_file(&file_path);
    }
}
