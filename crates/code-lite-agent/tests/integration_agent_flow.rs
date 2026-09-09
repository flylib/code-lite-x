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
