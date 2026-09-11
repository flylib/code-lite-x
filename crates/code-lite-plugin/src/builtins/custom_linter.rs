use crate::engine::PluginRunner;
use crate::error::PluginError;
use crate::host_api::HostApi;
use crate::manifest::{PluginManifest, PluginPermission, PluginToolSpec};

pub struct CustomLinterPlugin {
    manifest: PluginManifest,
}

impl CustomLinterPlugin {
    pub fn new() -> Self {
        Self {
            manifest: PluginManifest {
                id: "codelite.custom_linter".to_string(),
                name: "Custom Linter".to_string(),
                version: "0.1.0".to_string(),
                author: "CodeLiteX Core Team".to_string(),
                description: "Checks code files for line length limits, trailing whitespace, and unaddressed TODO/FIXME markers".to_string(),
                entrypoint: "builtin:custom_linter".to_string(),
                permissions: vec![PluginPermission::ReadBuffer, PluginPermission::Log],
                provided_tools: vec![
                    PluginToolSpec {
                        name: "lint_code".to_string(),
                        description: "Analyzes code text or target workspace file for style and formatting issues".to_string(),
                        input_schema: serde_json::json!({
                            "type": "object",
                            "properties": {
                                "file_path": { "type": "string", "description": "Optional relative path to read via host buffer" },
                                "content": { "type": "string", "description": "Optional raw code string to inspect directly" }
                            }
                        }),
                        risk_level: "low".to_string(),
                    }
                ],
            },
        }
    }

    fn lint_text(&self, text: &str) -> serde_json::Value {
        let mut violations = Vec::new();

        for (idx, line) in text.lines().enumerate() {
            let line_num = idx + 1;

            if line.len() > 120 {
                violations.push(serde_json::json!({
                    "line": line_num,
                    "rule": "max-line-length",
                    "message": format!("Line exceeds 120 characters (length: {})", line.len()),
                    "severity": "warning"
                }));
            }

            if line.ends_with(' ') || line.ends_with('\t') {
                violations.push(serde_json::json!({
                    "line": line_num,
                    "rule": "no-trailing-whitespace",
                    "message": "Line contains trailing whitespace",
                    "severity": "info"
                }));
            }

            if line.contains("TODO") || line.contains("FIXME") {
                violations.push(serde_json::json!({
                    "line": line_num,
                    "rule": "pending-task",
                    "message": "Unaddressed TODO or FIXME found in comment",
                    "severity": "info"
                }));
            }
        }

        serde_json::json!({
            "clean": violations.is_empty(),
            "violations_count": violations.len(),
            "violations": violations,
        })
    }
}

impl PluginRunner for CustomLinterPlugin {
    fn manifest(&self) -> &PluginManifest {
        &self.manifest
    }

    fn execute(
        &self,
        tool_name: &str,
        args: serde_json::Value,
        host: &dyn HostApi,
    ) -> Result<serde_json::Value, PluginError> {
        if tool_name != "lint_code" {
            return Err(PluginError::ToolNotFound {
                plugin: self.manifest.id.clone(),
                tool: tool_name.to_string(),
            });
        }

        let content = if let Some(raw) = args.get("content").and_then(|v| v.as_str()) {
            raw.to_string()
        } else if let Some(path) = args.get("file_path").and_then(|v| v.as_str()) {
            host.read_buffer(&self.manifest, path)?
        } else {
            return Err(PluginError::HostError("Either 'content' or 'file_path' must be provided".into()));
        };

        host.log(&self.manifest, "info", &format!("Linting code payload of {} lines", content.lines().count()));
        let report = self.lint_text(&content);
        Ok(report)
    }
}
