//! # code-lite-agent
//!
//! AI Agent Cognitive Closed Loop and Three-Tier Permission Gateway for CodeLiteX.
//!
//! Enforces:
//! 1. Tool Runtime as the single gated gateway (no direct FS or unmonitored shell).
//! 2. Three-Tier Permission Policy (Low: auto, Medium: auto+undo, Critical: UI approval).
//! 3. Cognitive Closed Loop: CodeGraph Context -> Plan -> Tool -> LSP Verify -> Self-Healing / Rollback.

pub mod context_builder;
pub mod error;
pub mod executor;
pub mod fim;
pub mod instructions;
pub mod llm;
pub mod mcp;
pub mod multi_file;
pub mod observation;
pub mod permission;
pub mod planner;
pub mod skill;
pub mod tool_runtime;

pub use context_builder::{AgentContextBuilder, ContextInsights};
pub use error::{AgentError, ToolError};
pub use executor::{PlanExecutor, StepExecutionResult};
pub use fim::{FimContext, FimEngine};
pub use instructions::{DiscoveredInstruction, InstructionScanner, ProjectInstructions};
pub use llm::{
    BuiltinRuleProvider, ChatCompletion, ChatMessage, LlmProvider, LlmToolCall,
    LlmToolDefinition, OpenAiCompatibleProvider, OpenAiConfig, StreamToken,
    StructuredOutputSchema, ThinkingStreamParser,
};
pub use mcp::{McpRegistry, McpToolDefinition};
pub use multi_file::{FilePatchTarget, MultiFilePlanSummary, MultiFilePlanner};
pub use observation::Observation;
pub use permission::{ApprovalDecision, ApprovalManager, PermissionPolicy, RiskLevel};
pub use planner::{Plan, PlanStep, StepStatus, TaskPlanner};
pub use skill::{Skill, SkillFrontmatter, SkillManager};
pub use tool_runtime::{ExecutionResult, ToolRuntime};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_lite_graph::engine::GraphEngine;
    use code_lite_lsp::VirtualLspServer;
    use code_lite_storage::{ApprovalStore, Database, SessionStore};
    use std::fs;
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn setup_test_env() -> (std::path::PathBuf, Database, ToolRuntime, PlanExecutor) {
        let db = Database::open_in_memory().unwrap();
        let session_store = SessionStore::new(db.clone());
        let approval_store = ApprovalStore::new(db.clone());

        session_store
            .create_session("sess-agent-test", "Agent Test Session")
            .unwrap();
        session_store
            .create_task("task-agent-test", "sess-agent-test", "Test agent execution")
            .unwrap();

        let temp_dir = std::env::temp_dir().join(format!(
            "agent_test_{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&temp_dir).unwrap();

        let runtime = ToolRuntime::new(
            &temp_dir,
            "sess-agent-test",
            Some("task-agent-test"),
            db.clone(),
        );
        let approval_mgr = ApprovalManager::new(approval_store);

        let graph_store = code_lite_storage::GraphStore::new(db.clone());
        let graph_engine = Arc::new(GraphEngine::new(graph_store, temp_dir.clone()));
        let virtual_server = VirtualLspServer::new();
        let lsp_client = Arc::new(code_lite_lsp::LspClient::new_virtual(virtual_server));

        let executor = PlanExecutor::new(
            ToolRuntime::new(
                &temp_dir,
                "sess-agent-test",
                Some("task-agent-test"),
                db.clone(),
            ),
            approval_mgr,
            Some(graph_engine),
            Some(lsp_client),
        );

        (temp_dir, db, runtime, executor)
    }

    #[test]
    fn test_agent_low_and_medium_risk_flow_with_lsp_verify() {
        let (temp_dir, _db, _runtime, executor) = setup_test_env();

        let valid_rust_code = "pub fn add(a: i32, b: i32) -> i32 { a + b }\n";
        let planner = TaskPlanner::new();
        let mut plan = planner.plan_task(
            "sess-agent-test",
            "task-agent-test",
            "Add math function",
            Some("src/math.rs"),
            None,
            Some(valid_rust_code),
        );

        // Step 1: Read baseline (Low risk -> Auto-approved)
        let res1 = executor.execute_next_step(&mut plan).unwrap();
        match res1 {
            StepExecutionResult::Completed { step_id, .. } => assert_eq!(step_id, "step_1"),
            _ => panic!("Expected completed step 1"),
        }

        // Step 2: Apply patch (Medium risk -> Suspends for approval, then executes with snapshot & LSP verify)
        let res2_pending = executor.execute_next_step(&mut plan).unwrap();
        let req_id = match res2_pending {
            StepExecutionResult::SuspendedForApproval {
                request_id,
                risk_level,
                tool_name,
            } => {
                assert_eq!(risk_level, RiskLevel::Medium);
                assert_eq!(tool_name, "apply_patch");
                request_id
            }
            _ => panic!("Expected SuspendedForApproval for Medium risk apply_patch"),
        };

        // User approves Medium risk patch
        let approved = executor.approval_manager().approve(&req_id).unwrap();
        assert!(approved);

        // Resume execution of Step 2 -> Completed
        let res2 = executor.execute_next_step(&mut plan).unwrap();
        match res2 {
            StepExecutionResult::Completed { step_id, op_id, .. } => {
                assert_eq!(step_id, "step_2");
                assert!(op_id.is_some());
            }
            _ => panic!("Expected completed step 2 after approval"),
        }

        // Step 3: LSP diagnostics verify (Low risk -> Clean)
        let res3 = executor.execute_next_step(&mut plan).unwrap();
        match res3 {
            StepExecutionResult::Completed { step_id, .. } => assert_eq!(step_id, "step_3"),
            _ => panic!("Expected completed step 3"),
        }

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_agent_critical_permission_suspension_and_user_approval() {
        let (temp_dir, _db, runtime, executor) = setup_test_env();

        // Write a sensitive file
        runtime
            .apply_patch("config/production.json", "{\"key\":\"secret\"}")
            .unwrap();

        let planner = TaskPlanner::new();
        let mut plan = planner.plan_task(
            "sess-agent-test",
            "task-agent-test",
            "Delete production config",
            Some("config/production.json"),
            None,
            None,
        );

        // Step 1: Read file (Low risk -> Succeeds)
        let res1 = executor.execute_next_step(&mut plan).unwrap();
        match res1 {
            StepExecutionResult::Completed { step_id, .. } => assert_eq!(step_id, "step_1"),
            _ => panic!("Expected completed step 1"),
        }

        // Step 2: Delete file (Critical risk -> SUSPENDS for user approval!)
        let res2 = executor.execute_next_step(&mut plan).unwrap();
        let req_id = match res2 {
            StepExecutionResult::SuspendedForApproval {
                request_id,
                risk_level,
                tool_name,
            } => {
                assert_eq!(risk_level, RiskLevel::Critical);
                assert_eq!(tool_name, "delete_file");
                request_id
            }
            _ => panic!("Expected SuspendedForApproval"),
        };

        // Ensure file still exists before user confirmation
        assert!(temp_dir.join("config/production.json").exists());

        // User approves the request in UI
        let approved = executor.approval_manager().approve(&req_id).unwrap();
        assert!(approved);

        // Re-execute Step 2 -> now proceeds and deletes!
        let res2_after = executor.execute_next_step(&mut plan).unwrap();
        match res2_after {
            StepExecutionResult::Completed { step_id, op_id, .. } => {
                assert_eq!(step_id, "step_2");
                assert!(op_id.is_some());
            }
            _ => panic!("Expected completed step 2 after approval"),
        }

        // File is now deleted
        assert!(!temp_dir.join("config/production.json").exists());

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_agent_self_healing_retry_and_rollback_on_invalid_syntax() {
        let (temp_dir, _db, runtime, executor) = setup_test_env();

        // Baseline file
        let baseline = "pub fn healthy() -> bool { true }\n";
        runtime.apply_patch("src/syntax_test.rs", baseline).unwrap();

        let broken_code = "fn broken_syntax( { let x = ; }\n";
        let planner = TaskPlanner::new();
        let mut plan = planner.plan_task(
            "sess-agent-test",
            "task-agent-test",
            "Break syntax",
            Some("src/syntax_test.rs"),
            None,
            Some(broken_code),
        );

        // Step 1: Read baseline
        let res1 = executor.execute_next_step(&mut plan).unwrap();
        match res1 {
            StepExecutionResult::Completed { step_id, .. } => assert_eq!(step_id, "step_1"),
            _ => panic!("Expected completed step 1"),
        }

        // Step 2: Apply broken patch -> Suspends for approval first
        let res2_pending = executor.execute_next_step(&mut plan).unwrap();
        let req_id = match res2_pending {
            StepExecutionResult::SuspendedForApproval {
                request_id,
                risk_level,
                tool_name,
            } => {
                assert_eq!(risk_level, RiskLevel::Medium);
                assert_eq!(tool_name, "apply_patch");
                request_id
            }
            other => panic!("Expected SuspendedForApproval, got {:?}", other),
        };
        assert!(executor.approval_manager().approve(&req_id).unwrap());

        // Step 2 attempt 1 triggers SelfHealingRetry
        let res2_1 = executor.execute_next_step(&mut plan).unwrap();
        match res2_1 {
            StepExecutionResult::SelfHealingRetry { attempt, .. } => assert_eq!(attempt, 1),
            other => panic!("Expected SelfHealingRetry attempt 1, got {:?}", other),
        }

        // Step 2 attempt 2
        let res2_2 = executor.execute_next_step(&mut plan).unwrap();
        match res2_2 {
            StepExecutionResult::SelfHealingRetry { attempt, .. } => assert_eq!(attempt, 2),
            other => panic!("Expected SelfHealingRetry attempt 2, got {:?}", other),
        }

        // Step 2 attempt 3
        let res2_3 = executor.execute_next_step(&mut plan).unwrap();
        match res2_3 {
            StepExecutionResult::SelfHealingRetry { attempt, .. } => assert_eq!(attempt, 3),
            other => panic!("Expected SelfHealingRetry attempt 3, got {:?}", other),
        }

        // Step 2 attempt 4 -> Quota exhausted, triggers atomic rollback!
        let res2_4 = executor.execute_next_step(&mut plan).unwrap();
        match res2_4 {
            StepExecutionResult::FailedAndRolledBack {
                step_id,
                rolled_back_count,
                ..
            } => {
                assert_eq!(step_id, "step_2");
                assert!(rolled_back_count >= 1);
            }
            other => panic!("Expected FailedAndRolledBack, got {:?}", other),
        }

        // Workspace file is atomically restored to baseline!
        let restored_content = fs::read_to_string(temp_dir.join("src/syntax_test.rs")).unwrap();
        assert_eq!(restored_content, baseline);

        let _ = fs::remove_dir_all(&temp_dir);
    }
}
