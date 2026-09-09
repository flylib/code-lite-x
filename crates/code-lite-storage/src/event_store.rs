use crate::db::Database;
use crate::error::StorageError;
use crate::models::Event;
use rusqlite::params;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct EventStore {
    db: Database,
}

impl EventStore {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Logs an event to the global event stream.
    pub fn log(
        &self,
        session_id: Option<&str>,
        event_type: &str,
        payload: &serde_json::Value,
    ) -> Result<i64, StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        let payload_str = serde_json::to_string(payload)?;

        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO events (session_id, event_type, payload_json, created_at) VALUES (?1, ?2, ?3, ?4)",
                params![session_id, event_type, payload_str, now],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Retrieves events, optionally filtered by session_id, ordered chronologically.
    pub fn list(
        &self,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Event>, StorageError> {
        self.db.with_conn(|conn| {
            let map_row = |row: &rusqlite::Row| -> rusqlite::Result<Event> {
                let payload_str: String = row.get(3)?;
                let payload = serde_json::from_str(&payload_str).unwrap_or(serde_json::Value::Null);
                Ok(Event {
                    id: row.get(0)?,
                    session_id: row.get(1)?,
                    event_type: row.get(2)?,
                    payload,
                    created_at: row.get(4)?,
                })
            };

            let mut events = Vec::new();
            if let Some(sid) = session_id {
                let mut stmt = conn.prepare(
                    "SELECT id, session_id, event_type, payload_json, created_at FROM events WHERE session_id = ?1 ORDER BY id ASC LIMIT ?2",
                )?;
                let rows = stmt.query_map(params![sid, limit as i64], map_row)?;
                for r in rows {
                    events.push(r?);
                }
            } else {
                let mut stmt = conn.prepare(
                    "SELECT id, session_id, event_type, payload_json, created_at FROM events ORDER BY id ASC LIMIT ?1",
                )?;
                let rows = stmt.query_map(params![limit as i64], map_row)?;
                for r in rows {
                    events.push(r?);
                }
            }
            Ok(events)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_event_store_log_and_list() {
        let db = Database::open_in_memory().unwrap();
        let store = EventStore::new(db);

        let id1 = store
            .log(
                Some("sess-1"),
                "FileOpened",
                &serde_json::json!({"path": "src/main.rs"}),
            )
            .unwrap();
        assert!(id1 > 0);

        let id2 = store
            .log(
                Some("sess-1"),
                "FileChanged",
                &serde_json::json!({"line": 10}),
            )
            .unwrap();
        assert_eq!(id2, id1 + 1);

        let events = store.list(Some("sess-1"), 10).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].event_type, "FileOpened");
        assert_eq!(events[1].event_type, "FileChanged");
    }
}
