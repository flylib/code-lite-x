use crate::db::Database;
use crate::error::StorageError;
use crate::models::{ApprovalRecord, ApprovalStatus};
use rusqlite::params;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct ApprovalStore {
    db: Database,
}

pub const APPROVAL_COLS: &str =
    "id, session_id, task_id, step_id, tool_name, args_json, risk_level, status, requested_at, resolved_at";

fn row_to_approval(row: &rusqlite::Row) -> rusqlite::Result<ApprovalRecord> {
    let status_str: String = row.get(7)?;
    Ok(ApprovalRecord {
        id: row.get(0)?,
        session_id: row.get(1)?,
        task_id: row.get(2)?,
        step_id: row.get(3)?,
        tool_name: row.get(4)?,
        args_json: row.get(5)?,
        risk_level: row.get(6)?,
        status: ApprovalStatus::from_str(&status_str),
        requested_at: row.get(8)?,
        resolved_at: row.get(9)?,
    })
}

impl ApprovalStore {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Creates and persists a new approval request in `Pending` state.
    pub fn create_request(&self, record: &ApprovalRecord) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                r#"
                INSERT INTO approvals (
                    id, session_id, task_id, step_id, tool_name, args_json,
                    risk_level, status, requested_at, resolved_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                "#,
                params![
                    record.id,
                    record.session_id,
                    record.task_id,
                    record.step_id,
                    record.tool_name,
                    record.args_json,
                    record.risk_level,
                    record.status.as_str(),
                    record.requested_at,
                    record.resolved_at,
                ],
            )?;
            Ok(())
        })
    }

    /// Resolves an approval request with Approved or Rejected.
    pub fn resolve_request(&self, id: &str, status: ApprovalStatus) -> Result<bool, StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        self.db.with_conn(|conn| {
            let affected = conn.execute(
                r#"
                UPDATE approvals
                SET status = ?1, resolved_at = ?2
                WHERE id = ?3 AND status = 'pending'
                "#,
                params![status.as_str(), now, id],
            )?;
            Ok(affected > 0)
        })
    }

    /// Retrieves a single approval record by its ID.
    pub fn get_approval(&self, id: &str) -> Result<Option<ApprovalRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let query = format!("SELECT {} FROM approvals WHERE id = ?1", APPROVAL_COLS);
            let mut stmt = conn.prepare(&query)?;
            let mut rows = stmt.query_map(params![id], row_to_approval)?;
            if let Some(row) = rows.next() {
                Ok(Some(row?))
            } else {
                Ok(None)
            }
        })
    }

    /// Retrieves all pending approval requests, optionally filtered by session_id.
    pub fn get_pending_approvals(
        &self,
        session_id: Option<&str>,
    ) -> Result<Vec<ApprovalRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let mut results = Vec::new();
            if let Some(sid) = session_id {
                let query = format!(
                    "SELECT {} FROM approvals WHERE status = 'pending' AND session_id = ?1 ORDER BY requested_at ASC",
                    APPROVAL_COLS
                );
                let mut stmt = conn.prepare(&query)?;
                let rows = stmt.query_map(params![sid], row_to_approval)?;
                for r in rows {
                    results.push(r?);
                }
            } else {
                let query = format!(
                    "SELECT {} FROM approvals WHERE status = 'pending' ORDER BY requested_at ASC",
                    APPROVAL_COLS
                );
                let mut stmt = conn.prepare(&query)?;
                let rows = stmt.query_map([], row_to_approval)?;
                for r in rows {
                    results.push(r?);
                }
            }
            Ok(results)
        })
    }

    /// Lists all approvals for a specific session ordered by requested_at.
    pub fn list_approvals(&self, session_id: &str) -> Result<Vec<ApprovalRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let query = format!(
                "SELECT {} FROM approvals WHERE session_id = ?1 ORDER BY requested_at ASC",
                APPROVAL_COLS
            );
            let mut stmt = conn.prepare(&query)?;
            let rows = stmt.query_map(params![session_id], row_to_approval)?;
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
    use crate::session_store::SessionStore;

    #[test]
    fn test_approval_store_lifecycle() {
        let db = Database::open_in_memory().unwrap();
        let session_store = SessionStore::new(db.clone());
        let approval_store = ApprovalStore::new(db.clone());

        session_store.create_session("sess-test", "Test Session").unwrap();
        session_store.create_task("task-1", "sess-test", "Do something critical").unwrap();

        let req = ApprovalRecord {
            id: "appr-001".to_string(),
            session_id: "sess-test".to_string(),
            task_id: Some("task-1".to_string()),
            step_id: "step-1".to_string(),
            tool_name: "execute".to_string(),
            args_json: r#"{"cmd":"rm -rf target"}"#.to_string(),
            risk_level: "critical".to_string(),
            status: ApprovalStatus::Pending,
            requested_at: 1000,
            resolved_at: None,
        };

        approval_store.create_request(&req).unwrap();

        // 1. Pending check
        let pending = approval_store.get_pending_approvals(Some("sess-test")).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, "appr-001");
        assert_eq!(pending[0].status, ApprovalStatus::Pending);

        // 2. Resolve to Approved
        let resolved = approval_store.resolve_request("appr-001", ApprovalStatus::Approved).unwrap();
        assert!(resolved);

        // 3. No longer pending
        let pending_after = approval_store.get_pending_approvals(Some("sess-test")).unwrap();
        assert!(pending_after.is_empty());

        // 4. Retrieve record
        let record = approval_store.get_approval("appr-001").unwrap().expect("record exists");
        assert_eq!(record.status, ApprovalStatus::Approved);
        assert!(record.resolved_at.is_some());
    }
}
