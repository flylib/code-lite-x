use rusqlite::{Connection, Result};

pub const SCHEMA_VERSION: i32 = 1;

/// 只建仍在使用的表。旧版本库里遗留的 sessions / tasks / operations / events /
/// approvals / messages / *_memories 表不再创建也不主动删除:`CREATE TABLE IF NOT EXISTS`
/// 不会碰它们,旧的 `.codelite/workspace.db` 照常能打开。
pub fn initialize_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        -- 1. Files metadata
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            content_hash TEXT NOT NULL,
            language TEXT NOT NULL,
            line_count INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            indexed_at INTEGER NOT NULL
        );

        -- 2. Symbol definitions
        CREATE TABLE IF NOT EXISTS symbols (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol_key TEXT UNIQUE NOT NULL,
            identity_id TEXT,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            signature TEXT,
            doc_comment TEXT,
            line_start INTEGER NOT NULL,
            col_start INTEGER NOT NULL,
            line_end INTEGER NOT NULL,
            col_end INTEGER NOT NULL,
            scope_path TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_symbols_key ON symbols(symbol_key);
        CREATE INDEX IF NOT EXISTS idx_symbols_identity ON symbols(identity_id);
        CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
        CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);

        -- 3. Symbol references
        CREATE TABLE IF NOT EXISTS symbol_references (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol_id INTEGER REFERENCES symbols(id) ON DELETE SET NULL,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            symbol_name TEXT NOT NULL,
            line INTEGER NOT NULL,
            col INTEGER NOT NULL,
            is_write BOOLEAN DEFAULT 0
        );

        -- 4. Call graph (caller -> callee)
        CREATE TABLE IF NOT EXISTS call_graph (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            caller_symbol_id INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
            callee_symbol_id INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            call_line INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_call_caller ON call_graph(caller_symbol_id);
        CREATE INDEX IF NOT EXISTS idx_call_callee ON call_graph(callee_symbol_id);

        -- 5. Import dependency graph
        CREATE TABLE IF NOT EXISTS import_graph (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            importer_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            imported_file_id INTEGER REFERENCES files(id) ON DELETE CASCADE,
            raw_specifier TEXT NOT NULL
        );

        -- 6. Index Jobs (Resumable, Crash-Safe Background Indexing)
        CREATE TABLE IF NOT EXISTS index_jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT UNIQUE NOT NULL,
            file_path TEXT NOT NULL,
            old_hash TEXT,
            new_hash TEXT,
            started_at INTEGER NOT NULL,
            finished_at INTEGER,
            status TEXT NOT NULL,
            error TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_index_jobs_status ON index_jobs(status);
        CREATE INDEX IF NOT EXISTS idx_index_jobs_path ON index_jobs(file_path);

        -- 7. LSP Diagnostics (Errors, Warnings, Information, Hints)
        CREATE TABLE IF NOT EXISTS diagnostics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL,
            severity INTEGER NOT NULL, -- 1: Error, 2: Warning, 3: Information, 4: Hint
            line_start INTEGER NOT NULL,
            col_start INTEGER NOT NULL,
            line_end INTEGER NOT NULL,
            col_end INTEGER NOT NULL,
            code TEXT,
            source TEXT,
            message TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_diagnostics_file ON diagnostics(file_path);
        CREATE INDEX IF NOT EXISTS idx_diagnostics_severity ON diagnostics(severity);
        "#,
    )?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_legacy_db_with_removed_tables_still_opens() {
        // 模拟旧版本留下的库:含已下线功能的表和数据,再跑一次建表必须不报错且不动旧数据
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            PRAGMA foreign_keys = ON;
            CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
            CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, event_type TEXT NOT NULL, payload_json TEXT NOT NULL, created_at INTEGER NOT NULL);
            INSERT INTO sessions VALUES ('s1', 'old', 0, 0);
            INSERT INTO events (event_type, payload_json, created_at) VALUES ('WorkspaceOpened', '{}', 0);
            "#,
        )
        .unwrap();

        initialize_schema(&conn).unwrap();
        initialize_schema(&conn).unwrap();

        let legacy: i64 = conn.query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0)).unwrap();
        assert_eq!(legacy, 1);
        let has_symbols: i64 = conn
            .query_row("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='symbols'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(has_symbols, 1);
    }
}
