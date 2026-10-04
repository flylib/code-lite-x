use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileRecord {
    pub id: i64,
    pub path: String,
    pub content_hash: String,
    pub language: String,
    pub line_count: usize,
    pub mtime: i64,
    pub indexed_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SymbolRecord {
    pub id: i64,
    pub symbol_key: String,
    pub identity_id: Option<String>,
    pub file_id: i64,
    pub name: String,
    pub kind: String,
    pub signature: Option<String>,
    pub doc_comment: Option<String>,
    pub line_start: usize,
    pub col_start: usize,
    pub line_end: usize,
    pub col_end: usize,
    pub scope_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CallRecord {
    pub id: i64,
    pub caller_symbol_id: i64,
    pub callee_symbol_id: i64,
    pub file_id: i64,
    pub call_line: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportRecord {
    pub id: i64,
    pub importer_file_id: i64,
    pub imported_file_id: Option<i64>,
    pub raw_specifier: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexJobRecord {
    pub id: i64,
    pub job_id: String,
    pub file_path: String,
    pub old_hash: Option<String>,
    pub new_hash: Option<String>,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub status: String,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiagnosticRecord {
    pub id: i64,
    pub file_path: String,
    pub severity: i32, // 1: Error, 2: Warning, 3: Information, 4: Hint
    pub line_start: usize,
    pub col_start: usize,
    pub line_end: usize,
    pub col_end: usize,
    pub code: Option<String>,
    pub source: Option<String>,
    pub message: String,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewDiagnostic {
    pub file_path: String,
    pub severity: i32,
    pub line_start: usize,
    pub col_start: usize,
    pub line_end: usize,
    pub col_end: usize,
    pub code: Option<String>,
    pub source: Option<String>,
    pub message: String,
}
