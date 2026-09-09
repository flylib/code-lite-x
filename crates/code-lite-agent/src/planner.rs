use crate::llm::{ChatMessage, LlmProvider, StructuredOutputSchema};
use crate::permission::{PermissionPolicy, RiskLevel};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StepStatus {
    Pending,
    AwaitingApproval,
    Approved,
    Running,
    Success,
    Failed,
    RolledBack,
}

impl StepStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::AwaitingApproval => "awaiting_approval",
            Self::Approved => "approved",
            Self::Running => "running",
            Self::Success => "success",
            Self::Failed => "failed",
            Self::RolledBack => "rolled_back",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanStep {
    pub id: String,
    pub description: String,
    pub tool_name: String,
    pub args: serde_json::Value,
    pub risk_level: RiskLevel,
    pub status: StepStatus,
    pub op_id: Option<i64>,
    pub output: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Plan {
    pub id: String,
    pub session_id: String,
    pub task_id: String,
    pub user_prompt: String,
    pub steps: Vec<PlanStep>,
    pub current_step_index: usize,
    pub is_completed: bool,
    pub created_at: i64,
}

impl Plan {
    pub fn new(session_id: &str, task_id: &str, prompt: &str, steps: Vec<PlanStep>) -> Self {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        let id = format!("plan_{}_{}", task_id, now);

        Self {
            id,
            session_id: session_id.to_string(),
            task_id: task_id.to_string(),
            user_prompt: prompt.to_string(),
            steps,
            current_step_index: 0,
            is_completed: false,
            created_at: now,
        }
    }

    pub fn next_step(&mut self) -> Option<&mut PlanStep> {
        if self.current_step_index < self.steps.len() {
            let idx = self.current_step_index;
            Some(&mut self.steps[idx])
        } else {
            self.is_completed = true;
            None
        }
    }

    pub fn advance(&mut self) {
        self.current_step_index += 1;
        if self.current_step_index >= self.steps.len() {
            self.is_completed = true;
        }
    }
}

pub struct TaskPlanner {
    policy: PermissionPolicy,
}

impl TaskPlanner {
    pub fn new() -> Self {
        Self {
            policy: PermissionPolicy::new(),
        }
    }

    pub fn create_step(
        &self,
        id: &str,
        description: &str,
        tool_name: &str,
        args: serde_json::Value,
    ) -> PlanStep {
        let risk_level = self.policy.evaluate_risk(tool_name, &args);
        PlanStep {
            id: id.to_string(),
            description: description.to_string(),
            tool_name: tool_name.to_string(),
            args,
            risk_level,
            status: StepStatus::Pending,
            op_id: None,
            output: None,
            error: None,
        }
    }

    /// Formulates an engineering plan from a user prompt.
    pub fn plan_task(
        &self,
        session_id: &str,
        task_id: &str,
        prompt: &str,
        target_file: Option<&str>,
        target_symbol: Option<&str>,
        code_patch: Option<&str>,
    ) -> Plan {
        let mut steps = Vec::new();
        let prompt_lower = prompt.to_lowercase();

        if prompt_lower.contains("delete") || prompt_lower.contains("remove") {
            let file = target_file.unwrap_or("target_file.rs");
            steps.push(self.create_step(
                "step_1",
                &format!("Inspect file `{}` before deletion", file),
                "read_file",
                serde_json::json!({"path": file}),
            ));
            steps.push(self.create_step(
                "step_2",
                &format!("Delete file `{}` (Critical operation requiring confirmation)", file),
                "delete_file",
                serde_json::json!({"path": file}),
            ));
            steps.push(self.create_step(
                "step_3",
                "Verify workspace integrity via LSP diagnostics",
                "lsp_diagnostics",
                serde_json::json!({"path": file}),
            ));
        } else if let Some(patch) = code_patch {
            let file = target_file.unwrap_or("src/lib.rs");
            if let Some(sym) = target_symbol {
                steps.push(self.create_step(
                    "step_1",
                    &format!("Query CodeGraph context for `{}`", sym),
                    "get_code_context",
                    serde_json::json!({"symbol": sym}),
                ));
            } else {
                steps.push(self.create_step(
                    "step_1",
                    &format!("Read baseline content of `{}`", file),
                    "read_file",
                    serde_json::json!({"path": file}),
                ));
            }

            steps.push(self.create_step(
                "step_2",
                &format!("Apply code patch to `{}` with undo snapshot", file),
                "apply_patch",
                serde_json::json!({"path": file, "content": patch}),
            ));

            steps.push(self.create_step(
                "step_3",
                &format!("Verify syntax and types via LSP diagnostics for `{}`", file),
                "lsp_diagnostics",
                serde_json::json!({"path": file}),
            ));

            steps.push(self.create_step(
                "step_4",
                "Execute cargo check validation",
                "execute",
                serde_json::json!({"cmd": "cargo", "args": ["check"]}),
            ));
        } else {
            // General exploration/query plan
            let file = target_file.unwrap_or("src/main.rs");
            steps.push(self.create_step(
                "step_1",
                &format!("Inspect file `{}`", file),
                "read_file",
                serde_json::json!({"path": file}),
            ));
            steps.push(self.create_step(
                "step_2",
                &format!("Query LSP diagnostics for `{}`", file),
                "lsp_diagnostics",
                serde_json::json!({"path": file}),
            ));
        }

        Plan::new(session_id, task_id, prompt, steps)
    }

    /// Formulates an engineering plan using LLM structured output.
    /// Falls back to rule-based `plan_task` if model completion fails or returns malformed steps.
    pub fn plan_task_with_model(
        &self,
        provider: &dyn LlmProvider,
        session_id: &str,
        task_id: &str,
        prompt: &str,
        target_file: Option<&str>,
        target_symbol: Option<&str>,
        code_patch: Option<&str>,
    ) -> Plan {
        let schema = StructuredOutputSchema {
            name: "task_plan".to_string(),
            description: Some("Autonomous engineering plan for code modifications".to_string()),
            schema: serde_json::json!({
                "type": "object",
                "properties": {
                    "task": { "type": "string" },
                    "steps": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": { "type": "string" },
                                "description": { "type": "string" },
                                "tool_name": { "type": "string" },
                                "args": { "type": "object" }
                            },
                            "required": ["id", "description", "tool_name", "args"]
                        }
                    }
                },
                "required": ["steps"]
            }),
            strict: true,
        };

        let sys_prompt = "You are CodeLiteX Engineering Planner. Generate a sequence of actionable steps to fulfill the user request. Available tools: read_file, apply_patch, delete_file, execute_command, lsp_diagnostics, git_stage, rollback.";
        let user_prompt = format!(
            "Task: {}\nTarget File: {}\nTarget Symbol: {}\nCode Patch Provided: {}",
            prompt,
            target_file.unwrap_or("None"),
            target_symbol.unwrap_or("None"),
            code_patch.is_some()
        );

        let messages = vec![
            ChatMessage {
                role: "system".into(),
                content: sys_prompt.into(),
            },
            ChatMessage {
                role: "user".into(),
                content: user_prompt,
            },
        ];

        if let Ok(val) = provider.complete_structured(&messages, &schema) {
            if let Some(steps_array) = val.get("steps").and_then(|s| s.as_array()) {
                let mut steps = Vec::new();
                for (idx, step_obj) in steps_array.iter().enumerate() {
                    let fallback_id = format!("step_{}", idx + 1);
                    let id = step_obj
                        .get("id")
                        .and_then(|i| i.as_str())
                        .unwrap_or(&fallback_id);
                    let description = step_obj
                        .get("description")
                        .and_then(|d| d.as_str())
                        .unwrap_or("Execute tool");
                    let tool_name = step_obj
                        .get("tool_name")
                        .and_then(|t| t.as_str())
                        .unwrap_or("read_file");
                    let mut args = step_obj.get("args").cloned().unwrap_or(serde_json::json!({}));

                    if tool_name == "apply_patch" {
                        if let Some(patch) = code_patch {
                            args["content"] = serde_json::json!(patch);
                        }
                    }
                    if let Some(file) = target_file {
                        if tool_name == "apply_patch" || tool_name == "read_file" || args.get("path").is_none() {
                            args["path"] = serde_json::json!(file);
                        }
                    }

                    steps.push(self.create_step(id, description, tool_name, args));
                }

                if !steps.is_empty() {
                    return Plan::new(session_id, task_id, prompt, steps);
                }
            }
        }

        // Fallback to rule-based planner
        self.plan_task(
            session_id,
            task_id,
            prompt,
            target_file,
            target_symbol,
            code_patch,
        )
    }
}

impl Default for TaskPlanner {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::BuiltinRuleProvider;

    #[test]
    fn test_plan_task_with_model_fallback_and_structured() {
        let planner = TaskPlanner::new();
        let provider = BuiltinRuleProvider::new();

        let plan = planner.plan_task_with_model(
            &provider,
            "sess-1",
            "task-1",
            "Implement JWT validation in auth.rs",
            Some("src/auth.rs"),
            None,
            Some("// JWT code"),
        );

        assert_eq!(plan.session_id, "sess-1");
        assert_eq!(plan.task_id, "task-1");
        assert!(!plan.steps.is_empty());
        // Verify steps were parsed with evaluated risk levels
        assert!(plan.steps.iter().any(|s| s.tool_name == "apply_patch"));
    }
}

