use crate::db::Database;
use crate::error::StorageError;
use crate::models::{ImportRecord, SymbolRecord};
use rusqlite::params;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct GraphStore {
    db: Database,
}

pub const SYMBOL_COLS: &str = "id, symbol_key, identity_id, file_id, name, kind, signature, doc_comment, line_start, col_start, line_end, col_end, scope_path";

pub fn row_to_symbol(row: &rusqlite::Row) -> rusqlite::Result<SymbolRecord> {
    Ok(SymbolRecord {
        id: row.get(0)?,
        symbol_key: row.get(1)?,
        identity_id: row.get(2)?,
        file_id: row.get(3)?,
        name: row.get(4)?,
        kind: row.get(5)?,
        signature: row.get(6)?,
        doc_comment: row.get(7)?,
        line_start: row.get::<_, i64>(8)? as usize,
        col_start: row.get::<_, i64>(9)? as usize,
        line_end: row.get::<_, i64>(10)? as usize,
        col_end: row.get::<_, i64>(11)? as usize,
        scope_path: row.get(12)?,
    })
}

impl GraphStore {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Upserts file record and returns the file_id.
    pub fn upsert_file(
        &self,
        path: &str,
        content_hash: &str,
        language: &str,
        line_count: usize,
        mtime: i64,
    ) -> Result<i64, StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        self.db.with_conn(|conn| {
            conn.execute(
                r#"
                INSERT INTO files (path, content_hash, language, line_count, mtime, indexed_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(path) DO UPDATE SET
                    content_hash = excluded.content_hash,
                    language = excluded.language,
                    line_count = excluded.line_count,
                    mtime = excluded.mtime,
                    indexed_at = excluded.indexed_at
                "#,
                params![path, content_hash, language, line_count as i64, mtime, now],
            )?;

            let mut stmt = conn.prepare("SELECT id FROM files WHERE path = ?1")?;
            let id: i64 = stmt.query_row(params![path], |row| row.get(0))?;
            Ok(id)
        })
    }

    /// Saves symbols for a file, upserting by stable symbol_key.
    pub fn save_symbols(
        &self,
        file_id: i64,
        symbols: &[SymbolRecord],
    ) -> Result<(), StorageError> {
        self.db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;

            {
                let mut stmt = tx.prepare(
                    r#"
                    INSERT INTO symbols (
                        symbol_key, identity_id, file_id, name, kind, signature, doc_comment,
                        line_start, col_start, line_end, col_end, scope_path
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                    ON CONFLICT(symbol_key) DO UPDATE SET
                        identity_id = excluded.identity_id,
                        file_id = excluded.file_id,
                        name = excluded.name,
                        kind = excluded.kind,
                        signature = excluded.signature,
                        doc_comment = excluded.doc_comment,
                        line_start = excluded.line_start,
                        col_start = excluded.col_start,
                        line_end = excluded.line_end,
                        col_end = excluded.col_end,
                        scope_path = excluded.scope_path
                    "#,
                )?;

                for sym in symbols {
                    let ident = sym.identity_id.as_deref().unwrap_or(&sym.symbol_key);
                    stmt.execute(params![
                        sym.symbol_key,
                        ident,
                        file_id,
                        sym.name,
                        sym.kind,
                        sym.signature,
                        sym.doc_comment,
                        sym.line_start as i64,
                        sym.col_start as i64,
                        sym.line_end as i64,
                        sym.col_end as i64,
                        sym.scope_path,
                    ])?;
                }
            }

            tx.commit()?;
            Ok(())
        })
    }

    /// Atomically updates a file's entire graph (symbols, imports, calls, index_job) in a single SQLite transaction.
    /// Cleans up old calls/imports/references for this file_id, inserts new ones, updates index_job, and commits.
    pub fn update_file_graph_transactional(
        &self,
        file_id: i64,
        symbols: &[SymbolRecord],
        imports: &[String],
        calls: &[(&str, usize)],
        job_id: &str,
    ) -> Result<(), StorageError> {
        self.db.with_conn_mut(|conn| {
            let tx = conn.transaction()?;

            // 1. Delete old call graph, references, and imports for this file
            tx.execute("DELETE FROM call_graph WHERE file_id = ?1", params![file_id])?;
            tx.execute("DELETE FROM import_graph WHERE importer_file_id = ?1", params![file_id])?;
            tx.execute("DELETE FROM symbol_references WHERE file_id = ?1", params![file_id])?;

            // 2. Delete symbols for this file that are no longer in the new symbols list
            let new_keys: Vec<&str> = symbols.iter().map(|s| s.symbol_key.as_str()).collect();
            if new_keys.is_empty() {
                tx.execute("DELETE FROM symbols WHERE file_id = ?1", params![file_id])?;
            } else {
                let mut existing_stmt = tx.prepare("SELECT id, symbol_key FROM symbols WHERE file_id = ?1")?;
                let to_delete: Vec<i64> = existing_stmt
                    .query_map(params![file_id], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)))?
                    .filter_map(|r| r.ok())
                    .filter(|(_, key)| !new_keys.contains(&key.as_str()))
                    .map(|(id, _)| id)
                    .collect();

                for del_id in to_delete {
                    tx.execute("DELETE FROM symbols WHERE id = ?1", params![del_id])?;
                }
            }

            // 3. Upsert new symbols
            {
                let mut sym_stmt = tx.prepare(
                    r#"
                    INSERT INTO symbols (
                        symbol_key, identity_id, file_id, name, kind, signature, doc_comment,
                        line_start, col_start, line_end, col_end, scope_path
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                    ON CONFLICT(symbol_key) DO UPDATE SET
                        identity_id = excluded.identity_id,
                        file_id = excluded.file_id,
                        name = excluded.name,
                        kind = excluded.kind,
                        signature = excluded.signature,
                        doc_comment = excluded.doc_comment,
                        line_start = excluded.line_start,
                        col_start = excluded.col_start,
                        line_end = excluded.line_end,
                        col_end = excluded.col_end,
                        scope_path = excluded.scope_path
                    "#,
                )?;

                for sym in symbols {
                    let ident = sym.identity_id.as_deref().unwrap_or(&sym.symbol_key);
                    sym_stmt.execute(params![
                        sym.symbol_key,
                        ident,
                        file_id,
                        sym.name,
                        sym.kind,
                        sym.signature,
                        sym.doc_comment,
                        sym.line_start as i64,
                        sym.col_start as i64,
                        sym.line_end as i64,
                        sym.col_end as i64,
                        sym.scope_path,
                    ])?;
                }
            }

            // 4. Insert imports
            {
                let mut imp_stmt = tx.prepare(
                    "INSERT INTO import_graph (importer_file_id, raw_specifier) VALUES (?1, ?2)",
                )?;
                for imp in imports {
                    imp_stmt.execute(params![file_id, imp])?;
                }
            }

            // 5. Insert calls
            {
                let mut call_stmt = tx.prepare(
                    "INSERT INTO call_graph (caller_symbol_id, callee_symbol_id, file_id, call_line) VALUES (?1, ?2, ?3, ?4)",
                )?;
                let mut target_stmt = tx.prepare("SELECT id FROM symbols WHERE name = ?1 LIMIT 1")?;

                let first_sym_id: Option<i64> = symbols.first().and_then(|s| {
                    tx.query_row("SELECT id FROM symbols WHERE symbol_key = ?1", params![s.symbol_key], |row| row.get(0)).ok()
                });

                if let Some(caller_id) = first_sym_id {
                    for (callee_name, call_line) in calls {
                        let target_id: Option<i64> = target_stmt
                            .query_row(params![callee_name], |row| row.get(0))
                            .ok();
                        if let Some(callee_id) = target_id {
                            let _ = call_stmt.execute(params![caller_id, callee_id, file_id, *call_line as i64]);
                        }
                    }
                }
            }

            // 6. Update index_job to completed
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            tx.execute(
                "UPDATE index_jobs SET status = 'completed', finished_at = ?1, error = NULL WHERE job_id = ?2",
                params![now, job_id],
            )?;

            tx.commit()?;
            Ok(())
        })
    }

    /// Finds symbols by exact or prefix name.
    pub fn find_symbols_by_name(&self, name: &str) -> Result<Vec<SymbolRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let sql = format!("SELECT {} FROM symbols WHERE name LIKE ?1 || '%' ORDER BY name ASC LIMIT 50", SYMBOL_COLS);
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![name], row_to_symbol)?;

            let mut results = Vec::new();
            for r in rows {
                results.push(r?);
            }
            Ok(results)
        })
    }

    /// Finds a symbol by its unique, stable symbol_key.
    pub fn find_symbol_by_key(&self, key: &str) -> Result<Option<SymbolRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let sql = format!("SELECT {} FROM symbols WHERE symbol_key = ?1", SYMBOL_COLS);
            let mut stmt = conn.prepare(&sql)?;
            let mut rows = stmt.query_map(params![key], row_to_symbol)?;

            if let Some(r) = rows.next() {
                Ok(Some(r?))
            } else {
                Ok(None)
            }
        })
    }

    /// Adds a call graph edge (caller calls callee).
    pub fn save_call(
        &self,
        caller_symbol_id: i64,
        callee_symbol_id: i64,
        file_id: i64,
        call_line: usize,
    ) -> Result<(), StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO call_graph (caller_symbol_id, callee_symbol_id, file_id, call_line) VALUES (?1, ?2, ?3, ?4)",
                params![caller_symbol_id, callee_symbol_id, file_id, call_line as i64],
            )?;
            Ok(())
        })
    }

    /// Retrieves all callees called by a symbol.
    pub fn get_callees(&self, caller_symbol_id: i64) -> Result<Vec<SymbolRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let sql = format!(
                "SELECT {} FROM call_graph cg JOIN symbols s ON s.id = cg.callee_symbol_id WHERE cg.caller_symbol_id = ?1",
                SYMBOL_COLS.split(", ").map(|c| format!("s.{}", c)).collect::<Vec<_>>().join(", ")
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![caller_symbol_id], row_to_symbol)?;

            let mut results = Vec::new();
            for r in rows {
                results.push(r?);
            }
            Ok(results)
        })
    }

    /// Retrieves all callers that call a symbol.
    pub fn get_callers(&self, callee_symbol_id: i64) -> Result<Vec<SymbolRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let sql = format!(
                "SELECT {} FROM call_graph cg JOIN symbols s ON s.id = cg.caller_symbol_id WHERE cg.callee_symbol_id = ?1",
                SYMBOL_COLS.split(", ").map(|c| format!("s.{}", c)).collect::<Vec<_>>().join(", ")
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![callee_symbol_id], row_to_symbol)?;

            let mut results = Vec::new();
            for r in rows {
                results.push(r?);
            }
            Ok(results)
        })
    }

    /// Retrieves all callers that call a symbol by its symbol_key.
    pub fn get_callers_by_key(&self, key: &str) -> Result<Vec<SymbolRecord>, StorageError> {
        let sym = match self.find_symbol_by_key(key)? {
            Some(s) => s,
            None => return Ok(Vec::new()),
        };
        self.get_callers(sym.id)
    }

    /// Retrieves all callees called by a symbol by its symbol_key.
    pub fn get_callees_by_key(&self, key: &str) -> Result<Vec<SymbolRecord>, StorageError> {
        let sym = match self.find_symbol_by_key(key)? {
            Some(s) => s,
            None => return Ok(Vec::new()),
        };
        self.get_callees(sym.id)
    }

    /// Saves import relationships for a file.
    pub fn save_import(
        &self,
        importer_file_id: i64,
        imported_file_id: Option<i64>,
        raw_specifier: &str,
    ) -> Result<i64, StorageError> {
        self.db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO import_graph (importer_file_id, imported_file_id, raw_specifier) VALUES (?1, ?2, ?3)",
                params![importer_file_id, imported_file_id, raw_specifier],
            )?;
            Ok(conn.last_insert_rowid())
        })
    }

    /// Retrieves all imports defined in a file.
    pub fn get_imports(&self, importer_file_id: i64) -> Result<Vec<ImportRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, importer_file_id, imported_file_id, raw_specifier FROM import_graph WHERE importer_file_id = ?1",
            )?;

            let rows = stmt.query_map(params![importer_file_id], |row| {
                Ok(ImportRecord {
                    id: row.get(0)?,
                    importer_file_id: row.get(1)?,
                    imported_file_id: row.get(2)?,
                    raw_specifier: row.get(3)?,
                })
            })?;

            let mut results = Vec::new();
            for r in rows {
                results.push(r?);
            }
            Ok(results)
        })
    }

    /// Retrieves all symbols defined in a file given its relative path.
    pub fn get_symbols_by_file_path(&self, path: &str) -> Result<Vec<SymbolRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let sql = format!(
                "SELECT {} FROM symbols s JOIN files f ON f.id = s.file_id WHERE f.path = ?1 ORDER BY s.line_start ASC",
                SYMBOL_COLS.split(", ").map(|c| format!("s.{}", c)).collect::<Vec<_>>().join(", ")
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![path], row_to_symbol)?;

            let mut results = Vec::new();
            for r in rows {
                results.push(r?);
            }
            Ok(results)
        })
    }

    /// Retrieves file metadata by relative path.
    pub fn get_file_by_path(&self, path: &str) -> Result<Option<crate::models::FileRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, path, content_hash, language, line_count, mtime, indexed_at FROM files WHERE path = ?1",
            )?;

            let mut rows = stmt.query_map(params![path], |row| {
                Ok(crate::models::FileRecord {
                    id: row.get(0)?,
                    path: row.get(1)?,
                    content_hash: row.get(2)?,
                    language: row.get(3)?,
                    line_count: row.get::<_, i64>(4)? as usize,
                    mtime: row.get(5)?,
                    indexed_at: row.get(6)?,
                })
            })?;

            if let Some(res) = rows.next() {
                Ok(Some(res?))
            } else {
                Ok(None)
            }
        })
    }

    /// Retrieves file metadata by file id.
    pub fn get_file_by_id(&self, id: i64) -> Result<Option<crate::models::FileRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, path, content_hash, language, line_count, mtime, indexed_at FROM files WHERE id = ?1",
            )?;

            let mut rows = stmt.query_map(params![id], |row| {
                Ok(crate::models::FileRecord {
                    id: row.get(0)?,
                    path: row.get(1)?,
                    content_hash: row.get(2)?,
                    language: row.get(3)?,
                    line_count: row.get::<_, i64>(4)? as usize,
                    mtime: row.get(5)?,
                    indexed_at: row.get(6)?,
                })
            })?;

            if let Some(res) = rows.next() {
                Ok(Some(res?))
            } else {
                Ok(None)
            }
        })
    }

    /// Creates or updates a background index job for crash-safe resumability.
    pub fn create_index_job(
        &self,
        job_id: &str,
        file_path: &str,
        old_hash: Option<&str>,
        new_hash: Option<&str>,
    ) -> Result<(), StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        self.db.with_conn(|conn| {
            conn.execute(
                r#"
                INSERT INTO index_jobs (job_id, file_path, old_hash, new_hash, started_at, status)
                VALUES (?1, ?2, ?3, ?4, ?5, 'running')
                ON CONFLICT(job_id) DO UPDATE SET
                    file_path = excluded.file_path,
                    old_hash = excluded.old_hash,
                    new_hash = excluded.new_hash,
                    started_at = excluded.started_at,
                    status = 'running',
                    error = NULL,
                    finished_at = NULL
                "#,
                params![job_id, file_path, old_hash, new_hash, now],
            )?;
            Ok(())
        })
    }

    /// Updates index job status and optional error.
    pub fn update_index_job(
        &self,
        job_id: &str,
        status: &str,
        error: Option<&str>,
    ) -> Result<(), StorageError> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        self.db.with_conn(|conn| {
            conn.execute(
                r#"
                UPDATE index_jobs
                SET status = ?1, error = ?2, finished_at = ?3
                WHERE job_id = ?4
                "#,
                params![status, error, now, job_id],
            )?;
            Ok(())
        })
    }

    /// Lists pending or running index jobs (useful for resuming on crash).
    pub fn get_unfinished_index_jobs(&self) -> Result<Vec<crate::models::IndexJobRecord>, StorageError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                r#"
                SELECT id, job_id, file_path, old_hash, new_hash, started_at, finished_at, status, error
                FROM index_jobs
                WHERE status IN ('pending', 'running')
                ORDER BY started_at ASC
                "#,
            )?;

            let rows = stmt.query_map([], |row| {
                Ok(crate::models::IndexJobRecord {
                    id: row.get(0)?,
                    job_id: row.get(1)?,
                    file_path: row.get(2)?,
                    old_hash: row.get(3)?,
                    new_hash: row.get(4)?,
                    started_at: row.get(5)?,
                    finished_at: row.get(6)?,
                    status: row.get(7)?,
                    error: row.get(8)?,
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

    #[test]
    fn test_graph_store_symbols_and_call_graph() {
        let db = Database::open_in_memory().unwrap();
        let store = GraphStore::new(db);

        let file_id = store
            .upsert_file("src/service.rs", "hash123", "rust", 100, 123456)
            .unwrap();
        assert!(file_id > 0);

        let sym1 = SymbolRecord {
            id: 0,
            symbol_key: "rust:service::process_order".to_string(),
            identity_id: None,
            file_id,
            name: "process_order".to_string(),
            kind: "function".to_string(),
            signature: Some("pub fn process_order(id: u64)".to_string()),
            doc_comment: None,
            line_start: 10,
            col_start: 0,
            line_end: 20,
            col_end: 1,
            scope_path: Some("service::process_order".to_string()),
        };

        let sym2 = SymbolRecord {
            id: 0,
            symbol_key: "rust:service::save_to_db".to_string(),
            identity_id: None,
            file_id,
            name: "save_to_db".to_string(),
            kind: "function".to_string(),
            signature: Some("fn save_to_db()".to_string()),
            doc_comment: None,
            line_start: 22,
            col_start: 0,
            line_end: 30,
            col_end: 1,
            scope_path: Some("service::save_to_db".to_string()),
        };

        store.save_symbols(file_id, &[sym1, sym2]).unwrap();

        let found = store.find_symbols_by_name("process").unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].symbol_key, "rust:service::process_order");
        let caller_id = found[0].id;

        let found_callee = store.find_symbols_by_name("save").unwrap();
        assert_eq!(found_callee.len(), 1);
        assert_eq!(found_callee[0].symbol_key, "rust:service::save_to_db");
        let callee_id = found_callee[0].id;

        // Save call relation
        store.save_call(caller_id, callee_id, file_id, 15).unwrap();

        let callees = store.get_callees(caller_id).unwrap();
        assert_eq!(callees.len(), 1);
        assert_eq!(callees[0].name, "save_to_db");

        let callers = store.get_callers(callee_id).unwrap();
        assert_eq!(callers.len(), 1);
        assert_eq!(callers[0].name, "process_order");

        // Test index jobs
        store.create_index_job("job-1", "src/service.rs", None, Some("hash123")).unwrap();
        let unfinished = store.get_unfinished_index_jobs().unwrap();
        assert_eq!(unfinished.len(), 1);
        assert_eq!(unfinished[0].job_id, "job-1");

        store.update_index_job("job-1", "completed", None).unwrap();
        let unfinished2 = store.get_unfinished_index_jobs().unwrap();
        assert_eq!(unfinished2.len(), 0);
    }
}
