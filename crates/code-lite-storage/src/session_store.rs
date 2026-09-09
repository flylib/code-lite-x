use crate::db::Database;
use crate::error::StorageError;
use crate::models::{Message, Session, Task};
use rusqlite::params;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct SessionStore {
    db: Database,
}

impl SessionStore {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Creates a new session record.
    pub fn create_session(&self, id: &str, title: &str) -> Result<Session, StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO sessions (id, title, created_at, updated_at) VALUES (?1, ?2, ?3, ?4)",
                params![id, title, now, now],
            )?;
            Ok(Session {
                id: id.to_string(),
                title: title.to_string(),
                created_at: now,
                updated_at: now,
            })
        })
    }

    /// Creates a new task under a session.
    pub fn create_task(
        &self,
        id: &str,
        session_id: &str,
        user_prompt: &str,
    ) -> Result<Task, StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO tasks (id, session_id, user_prompt, status, created_at) VALUES (?1, ?2, ?3, 'pending', ?4)",
                params![id, session_id, user_prompt, now],
            )?;
            Ok(Task {
                id: id.to_string(),
                session_id: session_id.to_string(),
                user_prompt: user_prompt.to_string(),
                status: "pending".to_string(),
                plan_json: None,
                created_at: now,
                finished_at: None,
            })
        })
    }

    /// Lists all sessions ordered by updated_at descending.
    pub fn list_sessions(&self) -> Result<Vec<Session>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, title, created_at, updated_at FROM sessions ORDER BY updated_at DESC",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok(Session {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    created_at: row.get(2)?,
                    updated_at: row.get(3)?,
                })
            })?;

            let mut sessions = Vec::new();
            for r in rows {
                sessions.push(r?);
            }
            Ok(sessions)
        })
    }

    /// Adds a chat message to the session.
    pub fn add_message(&self, message: &Message) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO messages (id, session_id, role, content, thought, plan_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    message.id,
                    message.session_id,
                    message.role,
                    message.content,
                    message.thought,
                    message.plan_id,
                    message.created_at,
                ],
            )?;
            conn.execute(
                "UPDATE sessions SET updated_at = ?1 WHERE id = ?2",
                params![message.created_at, message.session_id],
            )?;
            Ok(())
        })
    }

    /// Lists all messages in a session ordered chronologically.
    pub fn list_messages(&self, session_id: &str) -> Result<Vec<Message>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, session_id, role, content, thought, plan_id, created_at
                 FROM messages WHERE session_id = ?1 ORDER BY created_at ASC",
            )?;
            let rows = stmt.query_map(params![session_id], |row| {
                Ok(Message {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    role: row.get(2)?,
                    content: row.get(3)?,
                    thought: row.get(4)?,
                    plan_id: row.get(5)?,
                    created_at: row.get(6)?,
                })
            })?;

            let mut messages = Vec::new();
            for r in rows {
                messages.push(r?);
            }
            Ok(messages)
        })
    }

    /// Clears all messages belonging to a session.
    pub fn clear_session_messages(&self, session_id: &str) -> Result<usize, StorageError> {
        self.db.with_conn(|conn| {
            let count = conn.execute(
                "DELETE FROM messages WHERE session_id = ?1",
                params![session_id],
            )?;
            Ok(count)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_and_task_lifecycle() {
        let db = Database::open_in_memory().unwrap();
        let store = SessionStore::new(db);

        let sess = store.create_session("sess-abc", "Refactor Auth").unwrap();
        assert_eq!(sess.id, "sess-abc");
        assert_eq!(sess.title, "Refactor Auth");

        let task = store
            .create_task("task-123", &sess.id, "Add JWT validation")
            .unwrap();
        assert_eq!(task.id, "task-123");
        assert_eq!(task.status, "pending");

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "sess-abc");
    }

    #[test]
    fn test_messages_persistence() {
        let db = Database::open_in_memory().unwrap();
        let store = SessionStore::new(db);

        store.create_session("sess-1", "Chat Session").unwrap();

        let msg1 = Message {
            id: "msg-1".into(),
            session_id: "sess-1".into(),
            role: "user".into(),
            content: "Please refactor main.rs".into(),
            thought: None,
            plan_id: None,
            created_at: 1000,
        };
        store.add_message(&msg1).unwrap();

        let msg2 = Message {
            id: "msg-2".into(),
            session_id: "sess-1".into(),
            role: "assistant".into(),
            content: "I will refactor main.rs now.".into(),
            thought: Some("Analyzing AST symbols...".into()),
            plan_id: Some("plan-1".into()),
            created_at: 1005,
        };
        store.add_message(&msg2).unwrap();

        let msgs = store.list_messages("sess-1").unwrap();
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].role, "user");
        assert_eq!(msgs[1].role, "assistant");
        assert_eq!(msgs[1].thought.as_deref(), Some("Analyzing AST symbols..."));

        let deleted = store.clear_session_messages("sess-1").unwrap();
        assert_eq!(deleted, 2);
        assert!(store.list_messages("sess-1").unwrap().is_empty());
    }
}

