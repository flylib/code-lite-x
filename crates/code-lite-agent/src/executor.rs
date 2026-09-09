use crate::error::AgentError;
use crate::llm::{ChatMessage, LlmProvider};
use crate::observation::Observation;
use crate::permission::{ApprovalDecision, ApprovalManager, PermissionPolicy, RiskLevel};
use crate::planner::{Plan, StepStatus};
use crate::tool_runtime::ToolRuntime;
use code_lite_graph::CodeGraph;
use code_lite_lsp::LspClient;
use code_lite_storage::{MemoryStore, NewDecisionMemory, NewErrorMemory};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload")]
pub enum StepExecutionResult {
    Completed {
        step_id: String,
        output: String,
        op_id: Option<i64>,
    },
    SuspendedForApproval {
        request_id: String,
        risk_level: RiskLevel,
        tool_name: String,
    },
    SelfHealingRetry {
        step_id: String,
        attempt: usize,
        error_message: String,
    },
    FailedAndRolledBack {
        step_id: String,
        reason: String,
        rolled_back_count: usize,
    },
    AllCompleted,
}

pub struct PlanExecutor {
    runtime: ToolRuntime,
    approval_manager: ApprovalManager,
    policy: PermissionPolicy,
    graph: Option<Arc<dyn CodeGraph + Send + Sync>>,
    lsp: Option<Arc<LspClient>>,
    llm: Option<Arc<dyn LlmProvider>>,
    memory_store: Option<MemoryStore>,
    max_self_heal_attempts: usize,
}

impl PlanExecutor {
    pub fn new(
        runtime: ToolRuntime,
        approval_manager: ApprovalManager,
        graph: Option<Arc<dyn CodeGraph + Send + Sync>>,
        lsp: Option<Arc<LspClient>>,
    ) -> Self {
        Self {
            runtime,
            approval_manager,
            policy: PermissionPolicy::new(),
            graph,
            lsp,
            llm: None,
            memory_store: None,
            max_self_heal_attempts: 3,
        }
    }

    pub fn with_llm(mut self, llm: Arc<dyn LlmProvider>) -> Self {
        self.llm = Some(llm);
        self
    }

    pub fn with_memory_store(mut self, memory_store: MemoryStore) -> Self {
        self.memory_store = Some(memory_store);
        self
    }

    pub fn memory_store(&self) -> Option<&MemoryStore> {
        self.memory_store.as_ref()
    }

    pub fn runtime(&self) -> &ToolRuntime {
        &self.runtime
    }

    pub fn approval_manager(&self) -> &ApprovalManager {
        &self.approval_manager
    }

    pub fn policy(&self) -> &PermissionPolicy {
        &self.policy
    }

    /// Executes the next available pending step in the Plan.
    pub fn execute_next_step(&self, plan: &mut Plan) -> Result<StepExecutionResult, AgentError> {
        if plan.current_step_index >= plan.steps.len() {
            plan.is_completed = true;
            return Ok(StepExecutionResult::AllCompleted);
        }

        let idx = plan.current_step_index;
        let step = &mut plan.steps[idx];

        // 1. Permission & Approval Gating
        let decision = self.approval_manager.check_or_request_approval(
            &plan.session_id,
            Some(&plan.task_id),
            &step.id,
            &step.tool_name,
            &step.args,
        )?;

        match decision {
            ApprovalDecision::RequiresApproval { request_id } => {
                step.status = StepStatus::AwaitingApproval;
                return Ok(StepExecutionResult::SuspendedForApproval {
                    request_id,
                    risk_level: step.risk_level,
                    tool_name: step.tool_name.clone(),
                });
            }
            ApprovalDecision::Denied { reason } => {
                step.status = StepStatus::Failed;
                step.error = Some(reason.clone());
                if let Some(ref store) = self.memory_store {
                    let path_tag = step.args.get("path").and_then(|v| v.as_str()).unwrap_or("");
                    let _ = store.record_decision(&NewDecisionMemory {
                        session_id: Some(plan.session_id.clone()),
                        decision_type: "approval_rejected".into(),
                        subject: step.tool_name.clone(),
                        detail: format!("User denied approval for step `{}` on `{}`: {}", step.id, path_tag, reason),
                        context_tags: Some(format!("approval,denied,{}", path_tag)),
                    });
                }
                return Err(AgentError::ApprovalRejected(reason));
            }
            ApprovalDecision::Granted => {
                step.status = StepStatus::Running;
                if let Some(ref store) = self.memory_store {
                    let path_tag = step.args.get("path").and_then(|v| v.as_str()).unwrap_or("");
                    let _ = store.record_decision(&NewDecisionMemory {
                        session_id: Some(plan.session_id.clone()),
                        decision_type: "approval_granted".into(),
                        subject: step.tool_name.clone(),
                        detail: format!("Approval granted for step `{}` on `{}` with tool `{}`", step.id, path_tag, step.tool_name),
                        context_tags: Some(format!("approval,granted,{}", path_tag)),
                    });
                }
            }
        }

        // 2. Dispatch Tool execution
        let mut step_op_id: Option<i64> = None;
        let output_str = match step.tool_name.as_str() {
            "read_file" => {
                let path = step
                    .args
                    .get("path")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                self.runtime.read_file(path)?
            }
            "search_symbol" => {
                let query = step
                    .args
                    .get("query")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let syms = self.runtime.search_symbol(query)?;
                serde_json::to_string(&syms)?
            }
            "get_code_context" => {
                let sym = step
                    .args
                    .get("symbol")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                if let Some(ref g) = self.graph {
                    let ctx = self.runtime.get_code_context(g.as_ref(), sym)?;
                    serde_json::to_string(&ctx)?
                } else {
                    format!("CodeGraph not available for symbol query `{}`", sym)
                }
            }
            "apply_patch" => {
                let path = step
                    .args
                    .get("path")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                let content = step
                    .args
                    .get("content")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default()
                    .to_string();
                let op_id = self.runtime.apply_patch(&path, &content)?;
                step_op_id = Some(op_id);
                step.op_id = Some(op_id);

                // --- 3. Cognitive Closed Loop: Verify & Self-Healing ---
                if let Some(ref lsp) = self.lsp {
                    let uri = format!(
                        "file://{}",
                        self.runtime.workspace_root.join(&path).to_string_lossy()
                    );
                    let _ = lsp.did_change(&uri, 1, &content);
                    let diags = lsp.get_diagnostics(&uri);

                    let errors: Vec<_> = diags
                        .into_iter()
                        .filter(|d| d.severity == Some(code_lite_lsp::DiagnosticSeverity::Error))
                        .collect();

                    if !errors.is_empty() {
                        let err_msg = errors
                            .iter()
                            .map(|e| e.message.clone())
                            .collect::<Vec<_>>()
                            .join("; ");

                        let observation = Observation::new_failure(
                            &step.id,
                            "apply_patch",
                            &err_msg,
                            errors.clone(),
                        );

                        // Check self-healing retry quota
                        let attempt = step
                            .args
                            .get("_attempt")
                            .and_then(|v| v.as_u64())
                            .unwrap_or(0) as usize
                            + 1;

                        let base_op_id = step
                            .args
                            .get("_base_op_id")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(op_id);

                        if attempt <= self.max_self_heal_attempts {
                            step.status = StepStatus::Pending;
                            step.error = Some(format!("LSP error: {}", err_msg));
                            step.args["_attempt"] = serde_json::json!(attempt);
                            step.args["_base_op_id"] = serde_json::json!(base_op_id);
                            step.args["_last_observation"] =
                                serde_json::to_value(&observation).unwrap_or_default();

                            // Observation Feedback Loop: Request LLM to repair patch with diagnostic reflection
                            if let Some(ref llm) = self.llm {
                                let reflection = observation.format_for_reflection();
                                let repair_prompt = format!(
                                    "The patch applied to `{}` failed with the following diagnostics:\n{}\nOriginal attempted content:\n{}\nPlease fix all errors and output the corrected, complete valid code without explanations or markdown fences.",
                                    path,
                                    reflection,
                                    content
                                );
                                let messages = vec![ChatMessage {
                                    role: "user".into(),
                                    content: repair_prompt,
                                }];
                                if let Ok(comp) = llm.complete(&messages, None) {
                                    let cleaned =
                                        crate::fim::FimEngine::clean_completion(&comp.content);
                                    if !cleaned.trim().is_empty() {
                                        step.args["content"] = serde_json::json!(cleaned);
                                    }
                                }
                            }

                            return Ok(StepExecutionResult::SelfHealingRetry {
                                step_id: step.id.clone(),
                                attempt,
                                error_message: err_msg,
                            });
                        } else {
                            // Retry quota exhausted -> Atomic Rollback!
                            let reverted = self.runtime.rollback_to_step(base_op_id - 1)?;
                            step.status = StepStatus::RolledBack;
                            step.error = Some(format!(
                                "Self-healing exhausted. Automatically rolled back: {}",
                                err_msg
                            ));
                            if let Some(ref store) = self.memory_store {
                                let _ = store.record_error(&NewErrorMemory {
                                    session_id: Some(plan.session_id.clone()),
                                    error_type: "rollback".into(),
                                    target_path: Some(path.clone()),
                                    error_summary: err_msg.clone(),
                                    lesson_learned: format!(
                                        "Self-healing exhausted after {} attempts on `{}`. Rolled back to avoid invalid syntax/diagnostics: {}",
                                        self.max_self_heal_attempts, path, err_msg
                                    ),
                                    context_snippet: Some(content.chars().take(500).collect()),
                                });
                            }
                            return Ok(StepExecutionResult::FailedAndRolledBack {
                                step_id: step.id.clone(),
                                reason: err_msg,
                                rolled_back_count: reverted,
                            });
                        }
                    }
                }

                format!("Patch applied successfully (operation_id: {})", op_id)
            }
            "delete_file" => {
                let path = step
                    .args
                    .get("path")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let op_id = self.runtime.delete_file(path)?;
                step_op_id = Some(op_id);
                step.op_id = Some(op_id);
                format!("File deleted with undo snapshot (operation_id: {})", op_id)
            }
            "execute" => {
                let cmd = step
                    .args
                    .get("cmd")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let raw_args = step
                    .args
                    .get("args")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                let args: Vec<&str> = raw_args.iter().filter_map(|v| v.as_str()).collect();

                let res = self.runtime.execute(cmd, &args)?;
                if !res.success {
                    step.status = StepStatus::Failed;
                    step.error = Some(res.stderr.clone());
                    if let Some(ref store) = self.memory_store {
                        let _ = store.record_error(&NewErrorMemory {
                            session_id: Some(plan.session_id.clone()),
                            error_type: "command_failure".into(),
                            target_path: None,
                            error_summary: res.stderr.clone(),
                            lesson_learned: format!("Execution of `{}` failed: {}", cmd, res.stderr),
                            context_snippet: Some(format!("cmd: {}, args: {:?}", cmd, args)),
                        });
                    }
                    return Err(crate::error::ToolError::ExecutionFailed(res.stderr).into());
                }
                res.stdout
            }
            "rollback_to_step" => {
                let target_op = step
                    .args
                    .get("target_op_id")
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);
                let count = self.runtime.rollback_to_step(target_op)?;
                format!("Successfully rolled back {} operations", count)
            }
            "lsp_diagnostics" => {
                let path = step
                    .args
                    .get("path")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                if let Some(ref lsp) = self.lsp {
                    let diags = self.runtime.lsp_diagnostics(lsp.as_ref(), path)?;
                    serde_json::to_string(&diags)?
                } else {
                    "LSP client not configured".to_string()
                }
            }
            "session_diff" => self.runtime.session_diff()?,
            _ => {
                return Err(crate::error::ToolError::PermissionDenied(format!(
                    "Unsupported tool '{}'",
                    step.tool_name
                ))
                .into());
            }
        };

        // 4. Record Step Completion
        let step_id = step.id.clone();
        step.status = StepStatus::Success;
        step.output = Some(output_str.clone());
        plan.advance();

        Ok(StepExecutionResult::Completed {
            step_id,
            output: output_str,
            op_id: step_op_id,
        })
    }

    /// Rolls back a specific completed step by its step_id without reverting subsequent valid steps.
    pub fn rollback_step(&self, plan: &mut Plan, step_id: &str) -> Result<bool, AgentError> {
        for step in &mut plan.steps {
            if step.id == step_id {
                if let Some(op_id) = step.op_id {
                    self.runtime.rollback_step(op_id)?;
                    step.status = StepStatus::RolledBack;
                    if let Some(ref store) = self.memory_store {
                        let _ = store.record_error(&NewErrorMemory {
                            session_id: Some(plan.session_id.clone()),
                            error_type: "manual_step_rollback".into(),
                            target_path: step.args.get("path").and_then(|v| v.as_str()).map(|s| s.to_string()),
                            error_summary: format!("Step `{}` ({}) was manually rolled back", step.id, step.tool_name),
                            lesson_learned: format!("Operation from step `{}` ({}) was reverted by rollback request", step.id, step.tool_name),
                            context_snippet: Some(format!("Step args: {}", step.args)),
                        });
                    }
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }
}
