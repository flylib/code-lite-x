use serde::{Deserialize, Serialize};

/// Granular permissions a plugin must declare to access host capabilities.
/// Any undeclared Host API call will be immediately rejected.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PluginPermission {
    /// Permission to read buffer or workspace file contents (read-only)
    ReadBuffer,
    /// Permission to query active LSP diagnostics and syntax errors
    GetDiagnostics,
    /// Permission to register custom tools into ToolRuntime
    RegisterTool,
    /// Permission to log messages to the IDE event stream
    Log,
}

impl PluginPermission {
    pub fn as_str(&self) -> &'static str {
        match self {
            PluginPermission::ReadBuffer => "read_buffer",
            PluginPermission::GetDiagnostics => "get_diagnostics",
            PluginPermission::RegisterTool => "register_tool",
            PluginPermission::Log => "log",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "read_buffer" => Some(PluginPermission::ReadBuffer),
            "get_diagnostics" => Some(PluginPermission::GetDiagnostics),
            "register_tool" => Some(PluginPermission::RegisterTool),
            "log" => Some(PluginPermission::Log),
            _ => None,
        }
    }
}

/// Specification of a Tool exported by a plugin.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginToolSpec {
    pub name: String,
    pub description: String,
    #[serde(default = "default_schema")]
    pub input_schema: serde_json::Value,
    #[serde(default = "default_risk_level")]
    pub risk_level: String,
}

fn default_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "properties": {}
    })
}

fn default_risk_level() -> String {
    "low".to_string()
}

/// The plugin's declared manifest (`plugin.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PluginManifest {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    #[serde(default = "default_entrypoint")]
    pub entrypoint: String,
    #[serde(default)]
    pub permissions: Vec<PluginPermission>,
    #[serde(default)]
    pub provided_tools: Vec<PluginToolSpec>,
}

fn default_entrypoint() -> String {
    "plugin.wasm".to_string()
}

/// Execution state of a loaded plugin.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PluginStatus {
    Loaded,
    Enabled,
    Disabled,
    Error(String),
}

/// Public information about a plugin presented to the FFI and Flutter UI.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PluginInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub status: PluginStatus,
    pub permissions: Vec<String>,
    pub tools: Vec<PluginToolSpec>,
}
