use thiserror::Error;

#[derive(Debug, Error)]
pub enum PluginError {
    #[error("Invalid WebAssembly binary: {0}")]
    InvalidWasm(String),

    #[error("WebAssembly magic header missing or corrupt")]
    MissingMagic,

    #[error("Plugin memory out of bounds access (requested {offset} with len {len}, max {max})")]
    MemoryOutOfBounds {
        offset: usize,
        len: usize,
        max: usize,
    },

    #[error("Plugin execution fuel exhausted (instruction budget exceeded): {0}")]
    FuelExhausted(String),

    #[error("Call stack depth exceeded maximum limit ({limit})")]
    StackOverflow { limit: usize },

    #[error("Permission denied: plugin '{plugin}' is not authorized for '{permission}'")]
    PermissionDenied {
        plugin: String,
        permission: String,
    },

    #[error("Plugin '{0}' is currently disabled")]
    PluginDisabled(String),

    #[error("Tool '{tool}' was not found on plugin '{plugin}'")]
    ToolNotFound { plugin: String, tool: String },

    #[error("Plugin '{0}' not found in registry")]
    PluginNotFound(String),

    #[error("Serialization / Deserialization error: {0}")]
    Serialization(String),

    #[error("Host API error: {0}")]
    HostError(String),
}
