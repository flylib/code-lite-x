use crate::db::Database;
use crate::error::StorageError;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DecisionMemory {
    pub id: i64,
    pub session_id: Option<String>,
    pub decision_type: String,
    pub subject: String,
    pub detail: String,
    pub context_tags: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewDecisionMemory {
    pub session_id: Option<String>,
    pub decision_type: String,
    pub subject: String,
    pub detail: String,
    pub context_tags: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ErrorMemory {
    pub id: i64,
    pub session_id: Option<String>,
    pub error_type: String,
    pub target_path: Option<String>,
    pub error_summary: String,
    pub lesson_learned: String,
    pub context_snippet: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewErrorMemory {
    pub session_id: Option<String>,
    pub error_type: String,
    pub target_path: Option<String>,
    pub error_summary: String,
    pub lesson_learned: String,
    pub context_snippet: Option<String>,
}

#[derive(Clone)]
pub struct MemoryStore {
    db: Database,
}

impl MemoryStore {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    fn now_ts() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }

    /// Records a decision memory (user approval, rejection, or architectural choice).
    pub fn record_decision(&self, memory: &NewDecisionMemory) -> Result<i64, StorageError> {
        let now = Self::now_ts();
        self.db.with_conn(|conn| {
            conn.execute(
                r#"
                INSERT INTO decision_memories (
                    session_id, decision_type, subject, detail, context_tags, created_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                "#,
                params![
                    memory.session_id,
                    memory.decision_type,
                    memory.subject,
                    memory.detail,
                    memory.context_tags,
                    now,
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Queries decision memories matching subject or detail or context_tags.
    pub fn query_decisions(&self, query: &str, limit: usize) -> Result<Vec<DecisionMemory>, StorageError> {
        let trimmed = query.trim();
        let tokens: Vec<String> = if trimmed.is_empty() {
            vec!["%".to_string()]
        } else {
            let mut words: Vec<String> = trimmed
                .split(|c: char| !c.is_alphanumeric() && c != '-' && c != '_')
                .filter(|w| w.len() >= 3)
                .map(|w| format!("%{}%", w))
                .collect();
            if words.is_empty() {
                words.push(format!("%{}%", trimmed));
            }
            words
        };

        self.db.with_conn(|conn| {
            let mut results = Vec::new();
            let mut seen_ids = std::collections::HashSet::new();

            for pat in &tokens {
                let mut stmt = conn.prepare(
                    r#"
                    SELECT id, session_id, decision_type, subject, detail, context_tags, created_at
                    FROM decision_memories
                    WHERE subject LIKE ?1 OR detail LIKE ?1 OR context_tags LIKE ?1
                    ORDER BY created_at DESC
                    LIMIT ?2
                    "#,
                )?;
                let rows = stmt.query_map(params![pat, limit as i64], |row| {
                    Ok(DecisionMemory {
                        id: row.get(0)?,
                        session_id: row.get(1)?,
                        decision_type: row.get(2)?,
                        subject: row.get(3)?,
                        detail: row.get(4)?,
                        context_tags: row.get(5)?,
                        created_at: row.get(6)?,
                    })
                })?;
                for r in rows {
                    let d = r?;
                    if seen_ids.insert(d.id) {
                        results.push(d);
                        if results.len() >= limit {
                            return Ok(results);
                        }
                    }
                }
            }
            Ok(results)
        })
    }

    /// Records an error memory (LSP compilation failure, rollback, command failure, "此路不通" lesson).
    pub fn record_error(&self, memory: &NewErrorMemory) -> Result<i64, StorageError> {
        let now = Self::now_ts();
        self.db.with_conn(|conn| {
            conn.execute(
                r#"
                INSERT INTO error_memories (
                    session_id, error_type, target_path, error_summary, lesson_learned, context_snippet, created_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                "#,
                params![
                    memory.session_id,
                    memory.error_type,
                    memory.target_path,
                    memory.error_summary,
                    memory.lesson_learned,
                    memory.context_snippet,
                    now,
                ],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Queries error memories matching query or target_path.
    pub fn query_errors(
        &self,
        query: &str,
        target_path: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ErrorMemory>, StorageError> {
        let trimmed = query.trim();
        let mut tokens: Vec<String> = if trimmed.is_empty() {
            Vec::new()
        } else {
            trimmed
                .split(|c: char| !c.is_alphanumeric() && c != '-' && c != '_')
                .filter(|w| w.len() >= 3)
                .map(|w| format!("%{}%", w))
                .collect()
        };

        self.db.with_conn(|conn| {
            let mut results = Vec::new();
            let mut seen_ids = std::collections::HashSet::new();

            // 1. If target_path is specified, prioritize past errors associated with this file/path
            if let Some(path) = target_path {
                let path_pat = format!("%{}%", path.trim());
                let mut stmt = conn.prepare(
                    r#"
                    SELECT id, session_id, error_type, target_path, error_summary, lesson_learned, context_snippet, created_at
                    FROM error_memories
                    WHERE target_path LIKE ?1 OR ?1 LIKE '%' || target_path || '%'
                    ORDER BY created_at DESC
                    LIMIT ?2
                    "#,
                )?;
                let rows = stmt.query_map(params![path_pat, limit as i64], |row| {
                    Ok(ErrorMemory {
                        id: row.get(0)?,
                        session_id: row.get(1)?,
                        error_type: row.get(2)?,
                        target_path: row.get(3)?,
                        error_summary: row.get(4)?,
                        lesson_learned: row.get(5)?,
                        context_snippet: row.get(6)?,
                        created_at: row.get(7)?,
                    })
                })?;
                for r in rows {
                    let e = r?;
                    if seen_ids.insert(e.id) {
                        results.push(e);
                        if results.len() >= limit {
                            return Ok(results);
                        }
                    }
                }
            }

            // 2. Search by tokens in error_summary, lesson_learned, or target_path
            if tokens.is_empty() {
                tokens.push("%".to_string());
            }

            for pat in &tokens {
                let mut stmt = conn.prepare(
                    r#"
                    SELECT id, session_id, error_type, target_path, error_summary, lesson_learned, context_snippet, created_at
                    FROM error_memories
                    WHERE error_summary LIKE ?1 OR lesson_learned LIKE ?1 OR target_path LIKE ?1
                    ORDER BY created_at DESC
                    LIMIT ?2
                    "#,
                )?;
                let rows = stmt.query_map(params![pat, limit as i64], |row| {
                    Ok(ErrorMemory {
                        id: row.get(0)?,
                        session_id: row.get(1)?,
                        error_type: row.get(2)?,
                        target_path: row.get(3)?,
                        error_summary: row.get(4)?,
                        lesson_learned: row.get(5)?,
                        context_snippet: row.get(6)?,
                        created_at: row.get(7)?,
                    })
                })?;
                for r in rows {
                    let e = r?;
                    if seen_ids.insert(e.id) {
                        results.push(e);
                        if results.len() >= limit {
                            return Ok(results);
                        }
                    }
                }
            }

            Ok(results)
        })
    }

    /// Retrieves recent memories across both categories.
    pub fn get_recent_memories(
        &self,
        limit: usize,
    ) -> Result<(Vec<DecisionMemory>, Vec<ErrorMemory>), StorageError> {
        self.db.with_conn(|conn| {
            let mut d_stmt = conn.prepare(
                r#"
                SELECT id, session_id, decision_type, subject, detail, context_tags, created_at
                FROM decision_memories
                ORDER BY created_at DESC
                LIMIT ?1
                "#,
            )?;
            let d_rows = d_stmt.query_map(params![limit as i64], |row| {
                Ok(DecisionMemory {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    decision_type: row.get(2)?,
                    subject: row.get(3)?,
                    detail: row.get(4)?,
                    context_tags: row.get(5)?,
                    created_at: row.get(6)?,
                })
            })?;
            let mut decisions = Vec::new();
            for r in d_rows {
                decisions.push(r?);
            }

            let mut e_stmt = conn.prepare(
                r#"
                SELECT id, session_id, error_type, target_path, error_summary, lesson_learned, context_snippet, created_at
                FROM error_memories
                ORDER BY created_at DESC
                LIMIT ?1
                "#,
            )?;
            let e_rows = e_stmt.query_map(params![limit as i64], |row| {
                Ok(ErrorMemory {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    error_type: row.get(2)?,
                    target_path: row.get(3)?,
                    error_summary: row.get(4)?,
                    lesson_learned: row.get(5)?,
                    context_snippet: row.get(6)?,
                    created_at: row.get(7)?,
                })
            })?;
            let mut errors = Vec::new();
            for r in e_rows {
                errors.push(r?);
            }

            Ok((decisions, errors))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decision_and_error_memories() {
        let db = Database::open_in_memory().unwrap();
        let store = MemoryStore::new(db);

        // 1. Record decision memories
        let d1 = NewDecisionMemory {
            session_id: Some("session-1".into()),
            decision_type: "approval_rejected".into(),
            subject: "apply_patch".into(),
            detail: "User rejected patch due to missing defensive error boundary".into(),
            context_tags: Some("security,patch,defensive".into()),
        };
        let d1_id = store.record_decision(&d1).unwrap();
        assert!(d1_id > 0);

        let d2 = NewDecisionMemory {
            session_id: Some("session-1".into()),
            decision_type: "architecture_choice".into(),
            subject: "storage".into(),
            detail: "Use SQLite WAL mode and stable SymbolKeys instead of rowid".into(),
            context_tags: Some("sqlite,architecture".into()),
        };
        store.record_decision(&d2).unwrap();

        // Query decisions
        let matched = store.query_decisions("defensive", 10).unwrap();
        assert_eq!(matched.len(), 1);
        assert_eq!(matched[0].id, d1_id);

        let all_decisions = store.query_decisions("", 10).unwrap();
        assert_eq!(all_decisions.len(), 2);

        // 2. Record error memories
        let e1 = NewErrorMemory {
            session_id: Some("session-2".into()),
            error_type: "rollback".into(),
            target_path: Some("crates/code-lite-agent/src/planner.rs".into()),
            error_summary: "Duplicate match arm for tool_name caused compiler failure".into(),
            lesson_learned: "Do not redefine existing match arms in planner enum dispatch".into(),
            context_snippet: Some("match tool.as_str() { ... }".into()),
        };
        let e1_id = store.record_error(&e1).unwrap();
        assert!(e1_id > 0);

        // Query errors
        let errs = store.query_errors("planner", None, 10).unwrap();
        assert_eq!(errs.len(), 1);
        assert_eq!(errs[0].lesson_learned, "Do not redefine existing match arms in planner enum dispatch");

        // Query recent
        let (recent_d, recent_e) = store.get_recent_memories(5).unwrap();
        assert_eq!(recent_d.len(), 2);
        assert_eq!(recent_e.len(), 1);
    }
}
