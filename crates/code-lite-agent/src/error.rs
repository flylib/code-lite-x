use thiserror::Error;

#[derive(Debug, Error)]
pub enum ToolError {
    #[error("Storage error: {0}")]
    Storage(#[from] code_lite_storage::StorageError),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Graph error: {0}")]
    Graph(String),

    #[error("LSP error: {0}")]
    Lsp(String),

    #[error("File not found: {0}")]
    FileNotFound(String),

    #[error("Patch application failed: {0}")]
    PatchFailed(String),

    #[error("Command execution error: {0}")]
    ExecutionFailed(String),

    #[error("Permission denied: {0}")]
    PermissionDenied(String),

    #[error("Approval required for critical action: {0}")]
    ApprovalRequired(String),

    #[error("Path escape detected: path '{0}' traverses outside workspace root")]
    PathEscape(String),

    #[error("Command not allowed by security policy: '{0}'")]
    CommandNotAllowed(String),

    #[error("Invalid path: '{0}'")]
    InvalidPath(String),
}

#[derive(Debug, Error)]
pub enum AgentError {
    #[error("Tool execution error: {0}")]
    Tool(#[from] ToolError),

    #[error("Storage error: {0}")]
    Storage(#[from] code_lite_storage::StorageError),

    #[error("Step requires user approval (request_id: {0})")]
    ApprovalPending(String),

    #[error("Step was rejected by user: {0}")]
    ApprovalRejected(String),

    #[error("LSP verification failed: {0}")]
    VerificationFailed(String),

    #[error("Self-healing loop exhausted after {0} attempts")]
    SelfHealingExhausted(usize),

    #[error("Planning failed: {0}")]
    PlanningFailed(String),

    #[error("LLM error: {0}")]
    Llm(String),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
}
