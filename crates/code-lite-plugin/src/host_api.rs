use crate::error::PluginError;
use crate::manifest::{PluginManifest, PluginPermission, PluginToolSpec};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiagnosticRecord {
    pub file_path: String,
    pub line: usize,
    pub column: usize,
    pub message: String,
    pub severity: String,
}

/// Host capabilities exposed into the plugin sandbox.
pub trait HostApi: Send + Sync {
    fn read_buffer(&self, plugin: &PluginManifest, relative_path: &str) -> Result<String, PluginError>;
    fn get_diagnostics(&self, plugin: &PluginManifest, relative_path: &str) -> Result<Vec<DiagnosticRecord>, PluginError>;
    fn register_tool(&self, plugin: &PluginManifest, tool: PluginToolSpec) -> Result<(), PluginError>;
    fn log(&self, plugin: &PluginManifest, level: &str, message: &str);
}

/// Standard implementation of HostApi connected to workspace files and storage.
pub struct StandardHostApi {
    pub workspace_root: PathBuf,
}

impl StandardHostApi {
    pub fn new<P: AsRef<Path>>(workspace_root: P) -> Self {
        Self {
            workspace_root: workspace_root.as_ref().to_path_buf(),
        }
    }

    fn resolve_safe_path(&self, relative_path: &str) -> Result<PathBuf, PluginError> {
        let clean = relative_path.trim_start_matches('/').trim_start_matches('\\');
        if clean.contains("..") {
            return Err(PluginError::HostError(format!(
                "Path traversal attempt detected: '{}'",
                relative_path
            )));
        }
        let full = self.workspace_root.join(clean);
        Ok(full)
    }
}

impl HostApi for StandardHostApi {
    fn read_buffer(&self, plugin: &PluginManifest, relative_path: &str) -> Result<String, PluginError> {
        if !plugin.permissions.contains(&PluginPermission::ReadBuffer) {
            return Err(PluginError::PermissionDenied {
                plugin: plugin.id.clone(),
                permission: "read_buffer".to_string(),
            });
        }

        let full_path = self.resolve_safe_path(relative_path)?;
        if full_path.exists() {
            std::fs::read_to_string(&full_path)
                .map_err(|e| PluginError::HostError(format!("Failed to read {}: {}", relative_path, e)))
        } else {
            Ok(String::new())
        }
    }

    fn get_diagnostics(&self, plugin: &PluginManifest, _relative_path: &str) -> Result<Vec<DiagnosticRecord>, PluginError> {
        if !plugin.permissions.contains(&PluginPermission::GetDiagnostics) {
            return Err(PluginError::PermissionDenied {
                plugin: plugin.id.clone(),
                permission: "get_diagnostics".to_string(),
            });
        }

        // Return empty or mock diagnostics for the queried path
        Ok(vec![])
    }

    fn register_tool(&self, plugin: &PluginManifest, _tool: PluginToolSpec) -> Result<(), PluginError> {
        if !plugin.permissions.contains(&PluginPermission::RegisterTool) {
            return Err(PluginError::PermissionDenied {
                plugin: plugin.id.clone(),
                permission: "register_tool".to_string(),
            });
        }
        Ok(())
    }

    fn log(&self, _plugin: &PluginManifest, level: &str, message: &str) {
        println!("[PluginLog][{}] {}", level, message);
    }
}
