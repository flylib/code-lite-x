use crate::permission::RiskLevel;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct McpToolDefinition {
    pub name: String,
    pub server_name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
    pub risk_level: RiskLevel,
}

#[derive(Debug, Clone, Default)]
pub struct McpRegistry {
    tools: HashMap<String, McpToolDefinition>,
}

impl McpRegistry {
    pub fn new() -> Self {
        Self {
            tools: HashMap::new(),
        }
    }

    /// Determines default three-tier risk level for an external MCP tool.
    pub fn infer_risk_level(tool_name: &str, description: &str) -> RiskLevel {
        let lower = format!("{} {}", tool_name, description).to_lowercase();
        if lower.contains("delete")
            || lower.contains("remove")
            || lower.contains("drop")
            || lower.contains("shell")
            || lower.contains("exec")
            || lower.contains("kill")
            || lower.contains("terminal")
        {
            RiskLevel::Critical
        } else if lower.contains("write")
            || lower.contains("patch")
            || lower.contains("edit")
            || lower.contains("apply")
            || lower.contains("update")
            || lower.contains("create")
            || lower.contains("modify")
        {
            RiskLevel::Medium
        } else {
            // Read-only queries, status, searches, inspecting
            RiskLevel::Low
        }
    }

    /// Registers an MCP tool definition.
    pub fn register_tool(&mut self, mut tool: McpToolDefinition) {
        if tool.risk_level == RiskLevel::Low {
            tool.risk_level = Self::infer_risk_level(&tool.name, &tool.description);
        }
        self.tools.insert(tool.name.clone(), tool);
    }

    /// Registers a tool directly with basic attributes.
    pub fn register(
        &mut self,
        name: &str,
        server_name: &str,
        description: &str,
        input_schema: serde_json::Value,
    ) {
        let risk_level = Self::infer_risk_level(name, description);
        self.register_tool(McpToolDefinition {
            name: name.to_string(),
            server_name: server_name.to_string(),
            description: description.to_string(),
            input_schema,
            risk_level,
        });
    }

    pub fn get_tool(&self, name: &str) -> Option<&McpToolDefinition> {
        self.tools.get(name)
    }

    pub fn list_tools(&self) -> Vec<&McpToolDefinition> {
        let mut list: Vec<&McpToolDefinition> = self.tools.values().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    /// Loads MCP tool configurations from `.codelite/mcp_servers.json` if present.
    pub fn load_from_workspace(&mut self, workspace_root: &Path) {
        let config_path = workspace_root.join(".codelite").join("mcp_servers.json");
        if config_path.is_file() {
            if let Ok(content) = std::fs::read_to_string(&config_path) {
                if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(servers) = json.get("mcpServers").and_then(|v| v.as_object()) {
                        for (server_name, s_val) in servers {
                            if let Some(tools_arr) = s_val.get("tools").and_then(|t| t.as_array()) {
                                for t_val in tools_arr {
                                    let name = t_val.get("name").and_then(|v| v.as_str()).unwrap_or("");
                                    let desc = t_val.get("description").and_then(|v| v.as_str()).unwrap_or("");
                                    let schema = t_val.get("inputSchema").cloned().unwrap_or(serde_json::json!({}));
                                    if !name.is_empty() {
                                        self.register(name, server_name, desc, schema);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Formats all registered MCP tools into a markdown context block for LLM prompt context.
    pub fn format_for_prompt(&self) -> Option<String> {
        if self.tools.is_empty() {
            return None;
        }

        let mut output = String::from("### Available External MCP Tools (Governed by Three-Tier Security Gateway):\n");
        for tool in self.list_tools() {
            output.push_str(&format!(
                "- **`{}`** (Provider: `{}`, Risk: `{:?}`): {}\n",
                tool.name, tool.server_name, tool.risk_level, tool.description
            ));
        }

        Some(output.trim_end().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mcp_registry_risk_inference_and_formatting() {
        let mut registry = McpRegistry::new();

        registry.register(
            "codegraph_search",
            "codegraph",
            "Search symbols and call graphs across workspace",
            serde_json::json!({"type": "object"}),
        );
        registry.register(
            "codegraph_impact",
            "codegraph",
            "Analyze symbol blast radius and callers",
            serde_json::json!({"type": "object"}),
        );
        registry.register(
            "db_drop_table",
            "database",
            "Drop a database table irreversibly",
            serde_json::json!({"type": "object"}),
        );
        registry.register(
            "edit_buffer",
            "editor",
            "Modify buffer lines with patch",
            serde_json::json!({"type": "object"}),
        );

        let search_tool = registry.get_tool("codegraph_search").unwrap();
        assert_eq!(search_tool.risk_level, RiskLevel::Low);

        let drop_tool = registry.get_tool("db_drop_table").unwrap();
        assert_eq!(drop_tool.risk_level, RiskLevel::Critical);

        let edit_tool = registry.get_tool("edit_buffer").unwrap();
        assert_eq!(edit_tool.risk_level, RiskLevel::Medium);

        let prompt = registry.format_for_prompt().unwrap();
        assert!(prompt.contains("codegraph_search"));
        assert!(prompt.contains("Provider: `codegraph`"));
        assert!(prompt.contains("Risk: `Low`"));
        assert!(prompt.contains("Risk: `Critical`"));
    }
}
