use crate::db::Database;
use crate::error::StorageError;
use crate::models::{DiagnosticRecord, NewDiagnostic};
use rusqlite::params;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct DiagnosticStore {
    db: Database,
}

pub const DIAGNOSTIC_COLS: &str = "id, file_path, severity, line_start, col_start, line_end, col_end, code, source, message, updated_at";

pub fn row_to_diagnostic(row: &rusqlite::Row) -> rusqlite::Result<DiagnosticRecord> {
    Ok(DiagnosticRecord {
        id: row.get(0)?,
        file_path: row.get(1)?,
        severity: row.get(2)?,
        line_start: row.get::<_, i64>(3)? as usize,
        col_start: row.get::<_, i64>(4)? as usize,
        line_end: row.get::<_, i64>(5)? as usize,
        col_end: row.get::<_, i64>(6)? as usize,
        code: row.get(7)?,
        source: row.get(8)?,
        message: row.get(9)?,
        updated_at: row.get(10)?,
    })
}

impl DiagnosticStore {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Atomically replaces all diagnostics for the given file in a single transaction.
    pub fn replace_file_diagnostics(
        &self,
        file_path: &str,
        items: &[NewDiagnostic],
    ) -> Result<usize, StorageError> {
        self.db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;

            tx.execute(
                "DELETE FROM diagnostics WHERE file_path = ?1",
                params![file_path],
            )?;

            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs() as i64;

            let mut inserted = 0;
            for item in items {
                tx.execute(
                    r#"
                    INSERT INTO diagnostics (
                        file_path, severity, line_start, col_start, line_end, col_end,
                        code, source, message, updated_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                    "#,
                    params![
                        item.file_path,
                        item.severity,
                        item.line_start as i64,
                        item.col_start as i64,
                        item.line_end as i64,
                        item.col_end as i64,
                        item.code,
                        item.source,
                        item.message,
                        now,
                    ],
                )?;
                inserted += 1;
            }

            tx.commit()?;
            Ok(inserted)
        })
    }

    /// Retrieves all diagnostics for a specific file, ordered by severity (errors first) and line.
    pub fn get_diagnostics_by_file(&self, file_path: &str) -> Result<Vec<DiagnosticRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let query = format!(
                "SELECT {} FROM diagnostics WHERE file_path = ?1 ORDER BY severity ASC, line_start ASC, col_start ASC",
                DIAGNOSTIC_COLS
            );
            let mut stmt = conn.prepare(&query)?;
            let rows = stmt.query_map(params![file_path], row_to_diagnostic)?;
            let mut results = Vec::new();
            for row in rows {
                results.push(row?);
            }
            Ok(results)
        })
    }

    /// Retrieves all compilation/syntax errors (severity = 1) across the entire workspace.
    pub fn get_all_errors(&self) -> Result<Vec<DiagnosticRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let query = format!(
                "SELECT {} FROM diagnostics WHERE severity = 1 ORDER BY file_path ASC, line_start ASC",
                DIAGNOSTIC_COLS
            );
            let mut stmt = conn.prepare(&query)?;
            let rows = stmt.query_map([], row_to_diagnostic)?;
            let mut results = Vec::new();
            for row in rows {
                results.push(row?);
            }
            Ok(results)
        })
    }

    /// Retrieves all diagnostics across the entire workspace.
    pub fn get_all_diagnostics(&self) -> Result<Vec<DiagnosticRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let query = format!(
                "SELECT {} FROM diagnostics ORDER BY severity ASC, file_path ASC, line_start ASC",
                DIAGNOSTIC_COLS
            );
            let mut stmt = conn.prepare(&query)?;
            let rows = stmt.query_map([], row_to_diagnostic)?;
            let mut results = Vec::new();
            for row in rows {
                results.push(row?);
            }
            Ok(results)
        })
    }

    /// Clears all diagnostics for a file.
    pub fn clear_file_diagnostics(&self, file_path: &str) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "DELETE FROM diagnostics WHERE file_path = ?1",
                params![file_path],
            )?;
            Ok(())
        })
    }

    /// Clears all diagnostics across the workspace.
    pub fn clear_all(&self) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute("DELETE FROM diagnostics", [])?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_diagnostic_store_lifecycle() {
        let db = Database::open_in_memory().unwrap();
        let store = DiagnosticStore::new(db);

        let file = "src/main.rs";
        let items = vec![
            NewDiagnostic {
                file_path: file.to_string(),
                severity: 1, // Error
                line_start: 10,
                col_start: 5,
                line_end: 10,
                col_end: 12,
                code: Some("E0308".to_string()),
                source: Some("rustc".to_string()),
                message: "mismatched types: expected usize, found &str".to_string(),
            },
            NewDiagnostic {
                file_path: file.to_string(),
                severity: 2, // Warning
                line_start: 3,
                col_start: 0,
                line_end: 3,
                col_end: 20,
                code: Some("unused_imports".to_string()),
                source: Some("rustc".to_string()),
                message: "unused import: `std::collections::HashMap`".to_string(),
            },
        ];

        let count = store.replace_file_diagnostics(file, &items).unwrap();
        assert_eq!(count, 2);

        let diags = store.get_diagnostics_by_file(file).unwrap();
        assert_eq!(diags.len(), 2);
        assert_eq!(diags[0].severity, 1);
        assert_eq!(diags[0].code.as_deref(), Some("E0308"));
        assert_eq!(diags[1].severity, 2);

        let errors = store.get_all_errors().unwrap();
        assert_eq!(errors.len(), 1);
        assert_eq!(errors[0].message, "mismatched types: expected usize, found &str");

        // Test replacement
        let new_items = vec![NewDiagnostic {
            file_path: file.to_string(),
            severity: 2,
            line_start: 5,
            col_start: 0,
            line_end: 5,
            col_end: 10,
            code: None,
            source: Some("clippy".to_string()),
            message: "minor style hint".to_string(),
        }];
        store.replace_file_diagnostics(file, &new_items).unwrap();

        let updated_errors = store.get_all_errors().unwrap();
        assert_eq!(updated_errors.len(), 0);

        let updated_diags = store.get_diagnostics_by_file(file).unwrap();
        assert_eq!(updated_diags.len(), 1);
        assert_eq!(updated_diags[0].message, "minor style hint");
    }
}
