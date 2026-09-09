use rusqlite::{Connection, Result};

pub const SCHEMA_VERSION: i32 = 1;

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

        -- 6. Sessions & Tasks
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            user_prompt TEXT NOT NULL,
            status TEXT NOT NULL,
            plan_json TEXT,
            created_at INTEGER NOT NULL,
            finished_at INTEGER
        );

        -- 7. Operations & File Patches (Supports atomic undo / rollback)
        CREATE TABLE IF NOT EXISTS operations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
            file_path TEXT NOT NULL,
            op_type TEXT NOT NULL,
            before_hash TEXT,
            after_hash TEXT,
            before_content TEXT,
            after_content TEXT,
            patch_diff TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );

        -- 8. Global Event Stream
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            event_type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
        CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);

        -- 9. Index Jobs (Resumable, Crash-Safe Background Indexing)
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

        -- 10. LSP Diagnostics (Errors, Warnings, Information, Hints)
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

        -- 11. Agent Approvals & Gateways (Three-Tier Permission Architecture)
        CREATE TABLE IF NOT EXISTS approvals (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
            step_id TEXT NOT NULL,
            tool_name TEXT NOT NULL,
            args_json TEXT NOT NULL,
            risk_level TEXT NOT NULL,
            status TEXT NOT NULL,
            requested_at INTEGER NOT NULL,
            resolved_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_approvals_session ON approvals(session_id);
        CREATE INDEX IF NOT EXISTS idx_approvals_status ON approvals(status);

        -- 12. Chat Messages & Thought Chains (Persistent Multi-turn AI Assistant)
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            thought TEXT,
            plan_id TEXT,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);

        -- 13. Decision Memory (Architecture choices, user approvals/rejections, manual interventions)
        CREATE TABLE IF NOT EXISTS decision_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            decision_type TEXT NOT NULL, -- e.g. 'approval_granted', 'approval_rejected', 'user_directive', 'architecture_choice'
            subject TEXT NOT NULL,       -- tool name, file, or topic
            detail TEXT NOT NULL,        -- rationale, user reason, or summary
            context_tags TEXT,           -- comma-separated tags or JSON
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_decision_memories_type ON decision_memories(decision_type);
        CREATE INDEX IF NOT EXISTS idx_decision_memories_subject ON decision_memories(subject);

        -- 14. Error Memory (Lessons learned from failures, rollbacks, test failures, lsp errors)
        CREATE TABLE IF NOT EXISTS error_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT,
            error_type TEXT NOT NULL,    -- e.g. 'lsp_diagnostic', 'rollback', 'command_failure', 'test_failure'
            target_path TEXT,            -- file path or module affected
            error_summary TEXT NOT NULL, -- the error message or symptom
            lesson_learned TEXT NOT NULL,-- what went wrong / what not to do ("此路不通")
            context_snippet TEXT,        -- code snippet or failed diff
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_error_memories_type ON error_memories(error_type);
        CREATE INDEX IF NOT EXISTS idx_error_memories_path ON error_memories(target_path);
        "#,
    )?;

    Ok(())
}
