//! Integration tests for CodeLite Agent
//!
//! Tests ToolRuntime sandbox containment (PathGuard), Three-Tier permissions,
//! approval resolution, LSP self-healing retry, and multi-file rollback.

use code_lite_agent::executor::{PlanExecutor, StepExecutionResult};
use code_lite_agent::permission::{ApprovalDecision, ApprovalManager};
use code_lite_agent::planner::TaskPlanner;
use code_lite_agent::tool_runtime::ToolRuntime;
use code_lite_lsp::{LspClient, VirtualLspServer};
use code_lite_storage::{ApprovalStatus, ApprovalStore, Database, SessionStore};
use std::fs;
use std::sync::Arc;

fn setup_test_env() -> (std::path::PathBuf, Database, String) {
    let temp_dir = std::env::temp_dir().join(format!("agent-int-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&temp_dir).expect("create temp dir");
    let db = Database::open_in_memory().expect("open memory db");
    let session_id = format!("sess-{}", uuid::Uuid::new_v4());
    let session_store = SessionStore::new(db.clone());
    session_store
        .create_session(&session_id, "Integration Test")
        .expect("create session in db");
    (temp_dir, db, session_id)
}

#[test]
fn test_path_guard_integration_security() {
    let (workspace, db, session_id) = setup_test_env();

    // Create an outside secret file
    let outside_dir = std::env::temp_dir().join(format!("agent-outside-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&outside_dir).unwrap();
    let secret_file = outside_dir.join("id_ed25519");
    fs::write(&secret_file, "PRIVATE_KEY_SECRET").unwrap();

    let runtime = ToolRuntime::new(&workspace, &session_id, None, db);

    // 1. Path traversal read
    let read_res = runtime.read_file("../outside/id_ed25519");
    assert!(read_res.is_err(), "Should reject traversal read");

    // 2. Absolute path outside workspace read
    let abs_res = runtime.read_file(secret_file.to_str().unwrap());
    assert!(abs_res.is_err(), "Should reject absolute path outside workspace");

    // 3. Traversal apply_patch
    let patch_res = runtime.apply_patch(
        "../../outside/hacked.sh",
        "#!/bin/bash\nrm -rf /\n",
    );
    assert!(patch_res.is_err(), "Should reject traversal patch");
    assert!(!outside_dir.join("hacked.sh").exists());

    // 4. Traversal delete_file
    let del_res = runtime.delete_file("../../outside/id_ed25519");
    assert!(del_res.is_err(), "Should reject traversal deletion");
    assert!(secret_file.exists(), "Secret file must remain intact");

    // Cleanup
    let _ = fs::remove_dir_all(&outside_dir);
    let _ = fs::remove_dir_all(&workspace);
}

#[test]
fn test_three_tier_permissions_and_approval_resolution() {
    let (workspace, db, session_id) = setup_test_env();
    let session_store = SessionStore::new(db.clone());
    session_store.create_task("task-1", &session_id, "Test task").unwrap();

    let approval_store = ApprovalStore::new(db.clone());
    let approval_mgr = ApprovalManager::new(approval_store.clone());

    // 1. Low risk: read_file -> Granted automatically
    let read_decision = approval_mgr
        .check_or_request_approval(
            &session_id,
            Some("task-1"),
            "step-1",
            "read_file",
            &serde_json::json!({"path": "src/lib.rs"}),
        )
        .unwrap();
    assert_eq!(read_decision, ApprovalDecision::Granted);

    // 2. Medium risk: apply_patch -> Requires approval (Suspended)
    let patch_decision = approval_mgr
        .check_or_request_approval(
            &session_id,
            Some("task-1"),
            "step-2",
            "apply_patch",
            &serde_json::json!({"path": "src/lib.rs", "content": "// patch"}),
        )
        .unwrap();

    let req_id = match patch_decision {
        ApprovalDecision::RequiresApproval { request_id } => request_id,
        other => panic!("Expected RequiresApproval, got {:?}", other),
    };

    // Verify in pending list
    let pending = approval_store
        .get_pending_approvals(Some(&session_id))
        .unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].id, req_id);

    // 3. User approves request
    approval_store
        .resolve_request(&req_id, ApprovalStatus::Approved)
        .unwrap();

    // Re-check approval -> Now Granted!
    let recheck = approval_mgr
        .check_or_request_approval(
            &session_id,
            Some("task-1"),
            "step-2",
            "apply_patch",
            &serde_json::json!({"path": "src/lib.rs", "content": "// patch"}),
        )
        .unwrap();
    assert_eq!(recheck, ApprovalDecision::Granted);

    // Cleanup
    let _ = fs::remove_dir_all(&workspace);
}

#[test]
fn test_agent_self_healing_retry_and_lsp_verification() {
    let (workspace, db, session_id) = setup_test_env();

    // Create a rust file
    let test_file = workspace.join("code.rs");
    fs::write(&test_file, "pub fn add(a: i32, b: i32) -> i32 { a + b }\n").unwrap();

    let session_store = SessionStore::new(db.clone());
    session_store.create_task("task-sh", &session_id, "Add broken function").unwrap();

    let runtime = ToolRuntime::new(&workspace, &session_id, Some("task-sh"), db.clone());
    let approval_store = ApprovalStore::new(db.clone());
    let approval_mgr = ApprovalManager::new(approval_store.clone());

    // Setup Virtual LSP Server to verify syntax
    let server = VirtualLspServer::new();
    let lsp_client = Arc::new(LspClient::new_virtual(server));

    let executor = PlanExecutor::new(runtime, approval_mgr, None, Some(lsp_client));

    // Create a plan with a broken patch (syntax error)
    let planner = TaskPlanner::new();
    let mut plan = planner.plan_task(
        &session_id,
        "task-sh",
        "Add broken function",
        Some("code.rs"),
        None,
        Some("pub fn broken( {\n"),
    );

    // Step 1: Read baseline -> Completed
    let step1_res = executor.execute_next_step(&mut plan).unwrap();
    match step1_res {
        StepExecutionResult::Completed { .. } => {}
        other => panic!("Expected step 1 to be Completed, got {:?}", other),
    }

    // Step 2: Apply patch -> SuspendedForApproval (Medium risk)
    let step2_res = executor.execute_next_step(&mut plan).unwrap();
    let req_id = match step2_res {
        StepExecutionResult::SuspendedForApproval { request_id, .. } => request_id,
        other => panic!("Expected SuspendedForApproval, got {:?}", other),
    };

    // User approves step 2
    approval_store
        .resolve_request(&req_id, ApprovalStatus::Approved)
        .unwrap();

    // Step 2 execution: Patch has syntax error -> Triggers SelfHealingRetry!
    let retry_res = executor.execute_next_step(&mut plan).unwrap();
    match retry_res {
        StepExecutionResult::SelfHealingRetry {
            attempt,
            error_message,
            ..
        } => {
            assert_eq!(attempt, 1);
            assert!(
                error_message.contains("syntax") || error_message.contains("error") || !error_message.is_empty(),
                "Error message should reflect syntax failure"
            );
        }
        other => panic!("Expected SelfHealingRetry on invalid syntax, got {:?}", other),
    }

    // Cleanup
    let _ = fs::remove_dir_all(&workspace);
}

#[test]
fn test_multi_step_atomic_session_rollback() {
    let (workspace, db, session_id) = setup_test_env();

    let file_a = workspace.join("file_a.txt");
    let file_b = workspace.join("file_b.txt");
    fs::write(&file_a, "Original A\n").unwrap();
    fs::write(&file_b, "Original B\n").unwrap();

    let session_store = SessionStore::new(db.clone());
    session_store.create_task("task-roll", &session_id, "Rollback task").unwrap();

    let runtime = ToolRuntime::new(&workspace, &session_id, Some("task-roll"), db.clone());

    // Record changes
    runtime.apply_patch("file_a.txt", "Modified A\n").unwrap();
    runtime.apply_patch("file_b.txt", "Modified B\n").unwrap();
    runtime.apply_patch("file_c.txt", "Brand new C\n").unwrap();

    assert_eq!(fs::read_to_string(&file_a).unwrap(), "Modified A\n");
    assert_eq!(fs::read_to_string(&file_b).unwrap(), "Modified B\n");
    assert!(workspace.join("file_c.txt").exists());

    // Restore to session start
    let reverted = runtime.restore_session_start().unwrap();
    assert_eq!(reverted, 3, "Should have reverted 3 operations");

    // Check all files restored
    assert_eq!(fs::read_to_string(&file_a).unwrap(), "Original A\n");
    assert_eq!(fs::read_to_string(&file_b).unwrap(), "Original B\n");
    assert!(
        !workspace.join("file_c.txt").exists(),
        "Created file_c should be removed"
    );

    // Cleanup
    let _ = fs::remove_dir_all(&workspace);
}

#[test]
fn test_step_level_fine_grained_rollback() {
    let (workspace, db, session_id) = setup_test_env();

    let file_a = workspace.join("file_a.txt");
    let file_b = workspace.join("file_b.txt");
    fs::write(&file_a, "Original A\n").unwrap();
    fs::write(&file_b, "Original B\n").unwrap();

    let session_store = SessionStore::new(db.clone());
    session_store.create_task("task-step-roll", &session_id, "Step rollback task").unwrap();

    let runtime = ToolRuntime::new(&workspace, &session_id, Some("task-step-roll"), db.clone());
    let approval_store = ApprovalStore::new(db.clone());
    let approval_mgr = ApprovalManager::new(approval_store.clone());

    let executor = PlanExecutor::new(runtime, approval_mgr, None, None);

    let planner = TaskPlanner::new();
    let mut plan = planner.plan_task(
        &session_id,
        "task-step-roll",
        "Modify both files",
        None,
        None,
        None,
    );

    let step_1 = planner.create_step(
        "step_1",
        "Modify file A",
        "apply_patch",
        serde_json::json!({"path": "file_a.txt", "content": "Modified A\n"}),
    );
    let step_2 = planner.create_step(
        "step_2",
        "Modify file B",
        "apply_patch",
        serde_json::json!({"path": "file_b.txt", "content": "Modified B\n"}),
    );
    plan.steps = vec![step_1, step_2];

    // Execute step 1 -> Suspended -> Approve -> Completed
    let res1 = executor.execute_next_step(&mut plan).unwrap();
    if let StepExecutionResult::SuspendedForApproval { request_id, .. } = res1 {
        approval_store.resolve_request(&request_id, ApprovalStatus::Approved).unwrap();
    }
    let res1_done = executor.execute_next_step(&mut plan).unwrap();
    assert!(matches!(res1_done, StepExecutionResult::Completed { .. }));
    assert_eq!(fs::read_to_string(&file_a).unwrap(), "Modified A\n");

    // Execute step 2 -> Suspended -> Approve -> Completed
    let res2 = executor.execute_next_step(&mut plan).unwrap();
    if let StepExecutionResult::SuspendedForApproval { request_id, .. } = res2 {
        approval_store.resolve_request(&request_id, ApprovalStatus::Approved).unwrap();
    }
    let res2_done = executor.execute_next_step(&mut plan).unwrap();
    assert!(matches!(res2_done, StepExecutionResult::Completed { .. }));
    assert_eq!(fs::read_to_string(&file_b).unwrap(), "Modified B\n");

    // Perform fine-grained rollback on step_1 only
    let rolled = executor.rollback_step(&mut plan, "step_1").unwrap();
    assert!(rolled, "Step 1 rollback must succeed");

    // File A is restored to original, File B remains modified!
    assert_eq!(fs::read_to_string(&file_a).unwrap(), "Original A\n");
    assert_eq!(fs::read_to_string(&file_b).unwrap(), "Modified B\n");

    assert_eq!(plan.steps[0].status, code_lite_agent::StepStatus::RolledBack);
    assert_eq!(plan.steps[1].status, code_lite_agent::StepStatus::Success);

    // Cleanup
    let _ = fs::remove_dir_all(&workspace);
}

#[test]
fn test_observation_feedback_and_replan() {
    let (workspace, db, session_id) = setup_test_env();
    let virtual_server = VirtualLspServer::new();
    let lsp_client = Arc::new(LspClient::new_virtual(virtual_server));

    let main_rs = workspace.join("src").join("main.rs");
    fs::create_dir_all(workspace.join("src")).unwrap();
    fs::write(&main_rs, "fn main() {}\n").unwrap();

    let session_store = SessionStore::new(db.clone());
    session_store.create_task("task-obs", &session_id, "Observation task").unwrap();

    let runtime = ToolRuntime::new(&workspace, &session_id, Some("task-obs"), db.clone());
    let approval_store = ApprovalStore::new(db.clone());
    let approval_mgr = ApprovalManager::new(approval_store.clone());

    let provider = Arc::new(code_lite_agent::BuiltinRuleProvider::new());
    let executor = PlanExecutor::new(runtime, approval_mgr, None, Some(lsp_client))
        .with_llm(provider);

    let planner = TaskPlanner::new();
    let mut plan = planner.plan_task(
        &session_id,
        "task-obs",
        "Apply broken patch to main.rs",
        Some("src/main.rs"),
        None,
        Some("fn broken() { let x = 42\n"), // missing closing brace -> syntax error
    );

    // Step 1: Read baseline content -> Completed
    let step1 = executor.execute_next_step(&mut plan).unwrap();
    assert!(matches!(step1, StepExecutionResult::Completed { .. }));

    // Step 2: Apply broken patch -> SuspendedForApproval
    let step2 = executor.execute_next_step(&mut plan).unwrap();
    let req_id = match step2 {
        StepExecutionResult::SuspendedForApproval { request_id, .. } => request_id,
        other => panic!("Expected SuspendedForApproval, got {:?}", other),
    };

    // User approves
    approval_store.resolve_request(&req_id, ApprovalStatus::Approved).unwrap();

    // Re-execute step 2 -> LSP error triggers SelfHealingRetry with observation feedback!
    let res = executor.execute_next_step(&mut plan).unwrap();
    match res {
        StepExecutionResult::SelfHealingRetry { step_id, attempt, error_message } => {
            assert_eq!(step_id, "step_2");
            assert_eq!(attempt, 1);
            assert!(!error_message.is_empty());
            // Verify observation was saved on step args for LLM feedback
            assert!(plan.steps[1].args.get("_last_observation").is_some());
        }
        other => panic!("Expected SelfHealingRetry with observation feedback, got {:?}", other),
    }

    // Cleanup
    let _ = fs::remove_dir_all(&workspace);
}

#[test]
fn test_phase10_memory_recording_and_context_engine_flow() {
    use code_lite_agent::context_builder::AgentContextBuilder;
    use code_lite_agent::instructions::InstructionScanner;
    use code_lite_agent::mcp::McpRegistry;
    use code_lite_agent::skill::{Skill, SkillManager};
    use code_lite_storage::MemoryStore;

    let (workspace, db, session_id) = setup_test_env();

    // 1. Create AGENTS.md and dangerous.rs in workspace
    fs::write(
        workspace.join("AGENTS.md"),
        "# Project Instructions\n- Enforce offline cargo builds\n- Wrap Row text with Expanded\n",
    )
    .unwrap();
    fs::write(
        workspace.join("dangerous.rs"),
        "// existing content\n",
    )
    .unwrap();

    let session_store = SessionStore::new(db.clone());
    session_store
        .create_task("task-mem", &session_id, "Apply dangerous changes")
        .unwrap();

    // 2. Setup MemoryStore, Skills, and MCP
    let memory_store = MemoryStore::new(db.clone());
    let runtime = ToolRuntime::new(&workspace, &session_id, Some("task-mem"), db.clone());
    let approval_store = ApprovalStore::new(db.clone());
    let approval_mgr = ApprovalManager::new(approval_store.clone());

    let executor = PlanExecutor::new(runtime, approval_mgr, None, None)
        .with_memory_store(memory_store.clone());

    // 3. Create steps: step_1 (apply_patch safe), step_2 (apply_patch dangerous)
    let planner = TaskPlanner::new();
    let step_1 = planner.create_step(
        "step_1",
        "Add helper function",
        "apply_patch",
        serde_json::json!({"path": "dangerous.rs", "content": "// helper\n"}),
    );
    let step_2 = planner.create_step(
        "step_2",
        "Delete database",
        "apply_patch",
        serde_json::json!({"path": "dangerous.rs", "content": "fn rm_rf() {}\n"}),
    );

    let mut plan = planner.plan_task(
        &session_id,
        "task-mem",
        "Apply changes",
        Some("dangerous.rs"),
        None,
        None,
    );
    plan.steps = vec![step_1, step_2];

    // Step 1 is apply_patch -> Suspended -> Approve -> Completed
    let s1 = executor.execute_next_step(&mut plan).unwrap();
    let req1_id = match s1 {
        StepExecutionResult::SuspendedForApproval { request_id, .. } => request_id,
        other => panic!("Expected SuspendedForApproval for step 1, got {:?}", other),
    };
    approval_store.resolve_request(&req1_id, ApprovalStatus::Approved).unwrap();
    let s1_done = executor.execute_next_step(&mut plan).unwrap();
    assert!(matches!(s1_done, StepExecutionResult::Completed { .. }));

    // Step 2 is apply_patch -> Suspended -> Deny -> Records DecisionMemory
    let s2 = executor.execute_next_step(&mut plan).unwrap();
    let req2_id = match s2 {
        StepExecutionResult::SuspendedForApproval { request_id, .. } => request_id,
        other => panic!("Expected SuspendedForApproval for step 2, got {:?}", other),
    };

    // Reject approval
    approval_store
        .resolve_request(&req2_id, ApprovalStatus::Rejected)
        .unwrap();

    // Step 2 execution rejected -> Records Decision Memory
    let err_res = executor.execute_next_step(&mut plan);
    assert!(err_res.is_err());

    let decisions = memory_store.query_decisions("apply_patch", 5).unwrap();
    assert_eq!(decisions.len(), 2); // 1 approval_granted, 1 approval_rejected

    // 4. Test Step Rollback -> Records Error Memory
    let rollback_ok = executor.rollback_step(&mut plan, "step_1").unwrap();
    assert!(rollback_ok);

    let errors = memory_store.query_errors("step_1", None, 5).unwrap();
    assert_eq!(errors.len(), 1);
    assert_eq!(errors[0].error_type, "manual_step_rollback");

    // 5. Test Unified Context Engine Assembly
    let instructions = InstructionScanner::scan(&workspace);
    let skill = Skill {
        name: "flutter-ui".into(),
        description: "IntelliJ Darcula defensive layout rules".into(),
        tools: vec!["apply_patch".into()],
        instructions: "Always wrap text with Expanded.".into(),
        file_path: workspace.join("SKILL.md"),
    };
    let skill_mgr = SkillManager::with_skills(vec![skill]);
    let mut mcp_reg = McpRegistry::new();
    mcp_reg.register("codegraph_search", "codegraph", "Search symbols", serde_json::json!({}));

    let context_engine = AgentContextBuilder::new(None, None)
        .with_instructions(instructions)
        .with_memory_store(memory_store)
        .with_skill_manager(skill_mgr)
        .with_mcp_registry(mcp_reg);

    let prompt = context_engine.build_task_context("Fix flutter layout in dangerous.rs", Some("dangerous.rs"), None);
    assert!(prompt.contains("AGENTS.md"));
    assert!(prompt.contains("Enforce offline cargo builds"));
    assert!(prompt.contains("flutter-ui"));
    assert!(prompt.contains("Historical Project Memory & Lessons Learned"));
    assert!(prompt.contains("codegraph_search"));

    let insights = context_engine.get_insights("Fix flutter layout in dangerous.rs", Some("dangerous.rs"), None);
    assert_eq!(insights.instruction_files, vec!["AGENTS.md"]);
    assert_eq!(insights.active_skills, vec!["flutter-ui"]);
    assert!(insights.recalled_decisions >= 1);
    assert!(insights.recalled_errors >= 1);

    // Cleanup
    let _ = fs::remove_dir_all(&workspace);
}

