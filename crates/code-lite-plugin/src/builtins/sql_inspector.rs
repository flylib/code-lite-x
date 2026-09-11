use crate::engine::PluginRunner;
use crate::error::PluginError;
use crate::host_api::HostApi;
use crate::manifest::{PluginManifest, PluginPermission, PluginToolSpec};

pub struct SqlInspectorPlugin {
    manifest: PluginManifest,
}

impl SqlInspectorPlugin {
    pub fn new() -> Self {
        Self {
            manifest: PluginManifest {
                id: "codelite.sql_inspector".to_string(),
                name: "SQL Inspector".to_string(),
                version: "0.1.0".to_string(),
                author: "CodeLiteX Core Team".to_string(),
                description: "Analyzes SQL queries, checks syntax, extracts tables, and classifies destructive DDL/DML commands".to_string(),
                entrypoint: "builtin:sql_inspector".to_string(),
                permissions: vec![PluginPermission::Log],
                provided_tools: vec![
                    PluginToolSpec {
                        name: "inspect_sql".to_string(),
                        description: "Analyzes an SQL query for syntax validity, affected tables, and destructive operation risks".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "properties": {
                                "query": { "type": "string", "description": "SQL statement to inspect" }
                            },
                            "required": ["query"]
                        }),
                        risk_level: "low".to_string(),
                    }
                ],
            },
        }
    }

    fn inspect_sql(&self, query: &str) -> serde_json::Value {
        let trimmed = query.trim();
        let upper = trimmed.to_uppercase();

        let operation = if upper.starts_with("SELECT") {
            "SELECT"
        } else if upper.starts_with("INSERT") {
            "INSERT"
        } else if upper.starts_with("UPDATE") {
            "UPDATE"
        } else if upper.starts_with("DELETE") {
            "DELETE"
        } else if upper.starts_with("DROP") {
            "DROP"
        } else if upper.starts_with("TRUNCATE") {
            "TRUNCATE"
        } else if upper.starts_with("CREATE") {
            "CREATE"
        } else if upper.starts_with("ALTER") {
            "ALTER"
        } else {
            "UNKNOWN"
        };

        let is_drop_or_truncate = upper.contains("DROP ") || upper.contains("TRUNCATE ");
        let is_delete_without_where = upper.contains("DELETE ") && !upper.contains(" WHERE ");
        let is_destructive = is_drop_or_truncate || is_delete_without_where;

        // Extract simple table names from FROM or INTO or TABLE
        let mut tables = Vec::new();
        let tokens: Vec<&str> = trimmed.split_whitespace().collect();
        for (i, token) in tokens.iter().enumerate() {
            let t_upper = token.to_uppercase();
            if (t_upper == "FROM" || t_upper == "INTO" || t_upper == "TABLE" || t_upper == "UPDATE") && i + 1 < tokens.len() {
                let clean_table = tokens[i + 1].trim_matches(|c: char| c == ';' || c == '(' || c == ')' || c == '`' || c == '"');
                if !clean_table.is_empty() && !tables.contains(&clean_table.to_string()) {
                    tables.push(clean_table.to_string());
                }
            }
        }

        serde_json::json!({
            "syntax_valid": operation != "UNKNOWN",
            "operation": operation,
            "tables": tables,
            "has_where_clause": upper.contains(" WHERE "),
            "is_destructive": is_destructive,
            "recommended_risk": if is_destructive { "critical" } else { "low" },
            "warning": if is_destructive {
                Some("High-risk or unrestricted mutation detected (DROP/TRUNCATE or DELETE without WHERE)")
            } else {
                None
            }
        })
    }
}

impl PluginRunner for SqlInspectorPlugin {
    fn manifest(&self) -> &PluginManifest {
        &self.manifest
    }

    fn execute(
        &self,
        tool_name: &str,
        args: serde_json::Value,
        host: &dyn HostApi,
    ) -> Result<serde_json::Value, PluginError> {
        if tool_name != "inspect_sql" {
            return Err(PluginError::ToolNotFound {
                plugin: self.manifest.id.clone(),
                tool: tool_name.to_string(),
            });
        }

        let query = args.get("query").and_then(|v| v.as_str()).unwrap_or("");
        host.log(&self.manifest, "info", &format!("Inspecting SQL query of {} chars", query.len()));

        let result = self.inspect_sql(query);
        Ok(result)
    }
}
