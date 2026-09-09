use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub id: i64,
    pub session_id: Option<String>,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub created_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OpType {
    Create,
    Modify,
    Delete,
}

impl OpType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Create => "create",
            Self::Modify => "modify",
            Self::Delete => "delete",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "create" => Self::Create,
            "delete" => Self::Delete,
            _ => Self::Modify,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OpStatus {
    Applied,
    Reverted,
}

impl OpStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Applied => "applied",
            Self::Reverted => "reverted",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "reverted" => Self::Reverted,
            _ => Self::Applied,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Operation {
    pub id: i64,
    pub session_id: String,
    pub task_id: Option<String>,
    pub file_path: String,
    pub op_type: OpType,
    pub before_hash: Option<String>,
    pub after_hash: Option<String>,
    pub before_content: Option<String>,
    pub after_content: Option<String>,
    pub patch_diff: String,
    pub status: OpStatus,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: String,
    pub session_id: String,
    pub user_prompt: String,
    pub status: String,
    pub plan_json: Option<String>,
    pub created_at: i64,
    pub finished_at: Option<i64>,
}

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApprovalStatus {
    Pending,
    Approved,
    Rejected,
}

impl ApprovalStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
            Self::Rejected => "rejected",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "approved" => Self::Approved,
            "rejected" => Self::Rejected,
            _ => Self::Pending,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalRecord {
    pub id: String,
    pub session_id: String,
    pub task_id: Option<String>,
    pub step_id: String,
    pub tool_name: String,
    pub args_json: String,
    pub risk_level: String,
    pub status: ApprovalStatus,
    pub requested_at: i64,
    pub resolved_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub session_id: String,
    pub role: String,
    pub content: String,
    pub thought: Option<String>,
    pub plan_id: Option<String>,
    pub created_at: i64,
}

