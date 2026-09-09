use thiserror::Error;

#[derive(Debug, Error)]
pub enum GraphError {
    #[error("Storage error: {0}")]
    Storage(#[from] code_lite_storage::StorageError),

    #[error("Parse error: {0}")]
    Parse(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
}
