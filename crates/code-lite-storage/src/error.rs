use thiserror::Error;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("SQLite database error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("Serialization error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Operation not found: id {0}")]
    OperationNotFound(i64),

    #[error("Task not found: id {0}")]
    TaskNotFound(String),

    #[error("Revert failed: {0}")]
    RevertFailed(String),
}
