use crate::builtins::{CustomLinterPlugin, SqlInspectorPlugin};
use crate::engine::{PluginRunner, WasmBytecodeRunner};
use crate::error::PluginError;
use crate::host_api::HostApi;
use crate::manifest::{PluginInfo, PluginManifest, PluginStatus};
use parking_lot::RwLock;
use std::collections::HashMap;
use std::sync::Arc;

struct PluginEntry {
    runner: Arc<dyn PluginRunner>,
    status: PluginStatus,
}

/// Central registry managing the lifecycle, tools, and execution of plugins.
pub struct PluginRegistry {
    plugins: RwLock<HashMap<String, PluginEntry>>,
}

impl Default for PluginRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl PluginRegistry {
    pub fn new() -> Self {
        let registry = Self {
            plugins: RwLock::new(HashMap::new()),
        };

        // Register default built-in reference plugins
        let sql = Arc::new(SqlInspectorPlugin::new());
        let linter = Arc::new(CustomLinterPlugin::new());

        let _ = registry.register_runner(sql);
        let _ = registry.register_runner(linter);

        registry
    }

    /// Internal helper to register a PluginRunner.
    fn register_runner(&self, runner: Arc<dyn PluginRunner>) -> Result<PluginInfo, PluginError> {
        let manifest = runner.manifest().clone();
        let id = manifest.id.clone();

        let info = PluginInfo {
            id: manifest.id.clone(),
            name: manifest.name.clone(),
            version: manifest.version.clone(),
            author: manifest.author.clone(),
            description: manifest.description.clone(),
            status: PluginStatus::Enabled,
            permissions: manifest.permissions.iter().map(|p| p.as_str().to_string()).collect(),
            tools: manifest.provided_tools.clone(),
        };

        let mut lock = self.plugins.write();
        lock.insert(
            id,
            PluginEntry {
                runner,
                status: PluginStatus::Enabled,
            },
        );

        Ok(info)
    }

    /// Loads a WebAssembly bytecode plugin with its manifest.
    pub fn load_wasm_plugin(&self, manifest: PluginManifest, wasm_bytes: &[u8]) -> Result<PluginInfo, PluginError> {
        let runner = Arc::new(WasmBytecodeRunner::new(manifest, wasm_bytes)?);
        self.register_runner(runner)
    }

    /// Unloads a plugin by id.
    pub fn unload_plugin(&self, plugin_id: &str) -> Result<(), PluginError> {
        let mut lock = self.plugins.write();
        if lock.remove(plugin_id).is_some() {
            Ok(())
        } else {
            Err(PluginError::PluginNotFound(plugin_id.to_string()))
        }
    }

    /// Enables or disables a loaded plugin.
    pub fn toggle_plugin(&self, plugin_id: &str, enable: bool) -> Result<PluginInfo, PluginError> {
        let mut lock = self.plugins.write();
        let entry = lock.get_mut(plugin_id).ok_or_else(|| PluginError::PluginNotFound(plugin_id.to_string()))?;

        entry.status = if enable {
            PluginStatus::Enabled
        } else {
            PluginStatus::Disabled
        };

        let manifest = entry.runner.manifest();
        Ok(PluginInfo {
            id: manifest.id.clone(),
            name: manifest.name.clone(),
            version: manifest.version.clone(),
            author: manifest.author.clone(),
            description: manifest.description.clone(),
            status: entry.status.clone(),
            permissions: manifest.permissions.iter().map(|p| p.as_str().to_string()).collect(),
            tools: manifest.provided_tools.clone(),
        })
    }

    /// Lists all installed plugins.
    pub fn list_plugins(&self) -> Vec<PluginInfo> {
        let lock = self.plugins.read();
        lock.values()
            .map(|entry| {
                let m = entry.runner.manifest();
                PluginInfo {
                    id: m.id.clone(),
                    name: m.name.clone(),
                    version: m.version.clone(),
                    author: m.author.clone(),
                    description: m.description.clone(),
                    status: entry.status.clone(),
                    permissions: m.permissions.iter().map(|p| p.as_str().to_string()).collect(),
                    tools: m.provided_tools.clone(),
                }
            })
            .collect()
    }

    /// Executes a tool provided by a loaded and active plugin.
    pub fn execute_tool(
        &self,
        plugin_id: &str,
        tool_name: &str,
        args: serde_json::Value,
        host: &dyn HostApi,
    ) -> Result<serde_json::Value, PluginError> {
        let lock = self.plugins.read();
        let entry = lock
            .get(plugin_id)
            .ok_or_else(|| PluginError::PluginNotFound(plugin_id.to_string()))?;

        if entry.status != PluginStatus::Enabled {
            return Err(PluginError::PluginDisabled(plugin_id.to_string()));
        }

        entry.runner.execute(tool_name, args, host)
    }
}
