//! End-to-End Integration Test Pipeline
//!
//! Tests cross-layer integration from external caller perspective:
//! Workspace Init -> file.open (RPC) -> file.edit (RPC) -> lsp.diagnostics (RPC)
//! -> Agent Plan Task -> Medium-Risk Approval Suspension -> Approval Resolution
//! -> Step Execution -> Atomic Rollback -> Cleanup.

use codelite::*;
use serde_json::Value;
use std::ffi::{CStr, CString};
use std::fs;

unsafe fn c_to_str(ptr: *const std::ffi::c_char) -> String {
    assert!(!ptr.is_null(), "Pointer must not be null");
    let s = CStr::from_ptr(ptr).to_str().unwrap().to_string();
    codelite_string_free(ptr as *mut std::ffi::c_char);
    s
}

#[test]
fn test_e2e_workspace_edit_lsp_agent_approval_rollback_pipeline() {
    unsafe {
        // 1. Setup isolated temporary workspace
        let temp_dir = std::env::temp_dir().join(format!("codelite-e2e-{}", uuid::Uuid::new_v4()));
        let src_dir = temp_dir.join("src");
        fs::create_dir_all(&src_dir).expect("Create src directory");

        let main_file = src_dir.join("main.rs");
        let initial_code = "fn main() {\n    let answer = 42;\n    println!(\"{}\", answer);\n}\n";
        fs::write(&main_file, initial_code).expect("Write initial code");

        // Initialize Git repo in workspace
        let _ = std::process::Command::new("git")
            .arg("-C")
            .arg(&temp_dir)
            .arg("init")
            .output();

        // 2. Initialize CodeLite Context
        let root_c = CString::new(temp_dir.to_str().unwrap()).unwrap();
        let ctx = codelite_init(root_c.as_ptr());
        assert!(!ctx.is_null(), "codelite_init failed");

        // 3. Step 1: file.open via JSON-RPC
        let open_req = CString::new(
            r#"{"jsonrpc":"2.0","id":1,"method":"file.open","params":{"path":"src/main.rs"}}"#,
        )
        .unwrap();
        let open_resp = codelite_jsonrpc_call(ctx, open_req.as_ptr());
        let open_str = c_to_str(open_resp);
        let open_val: Value = serde_json::from_str(&open_str).expect("Valid JSON response");
        assert_eq!(open_val["jsonrpc"], "2.0");
        assert_eq!(open_val["id"], 1);
        assert_eq!(open_val["result"]["path"], "src/main.rs");
        assert_eq!(open_val["result"]["line_count"], 5);
        assert!(open_val["result"]["content"]
            .as_str()
            .unwrap()
            .contains("let answer = 42;"));

        // 4. Step 2: file.edit via JSON-RPC
        let edit_req = CString::new(
            r#"{"jsonrpc":"2.0","id":2,"method":"file.edit","params":{"path":"src/main.rs","range":{"start_line":1,"start_col":0,"end_line":1,"end_col":0},"new_text":"    // Optimized computation\n"}}"#,
        )
        .unwrap();
        let edit_resp = codelite_jsonrpc_call(ctx, edit_req.as_ptr());
        let edit_str = c_to_str(edit_resp);
        let edit_val: Value = serde_json::from_str(&edit_str).expect("Valid JSON response");
        assert_eq!(edit_val["id"], 2);
        assert_eq!(edit_val["result"]["success"], true);

        // 5. Step 3: lsp.diagnostics via JSON-RPC
        let diag_req = CString::new(
            r#"{"jsonrpc":"2.0","id":3,"method":"lsp.diagnostics","params":{"path":"src/main.rs"}}"#,
        )
        .unwrap();
        let diag_resp = codelite_jsonrpc_call(ctx, diag_req.as_ptr());
        let diag_str = c_to_str(diag_resp);
        let diag_val: Value = serde_json::from_str(&diag_str).expect("Valid JSON response");
        assert_eq!(diag_val["id"], 3);
        assert!(diag_val["result"]["diagnostics"].is_array());

        // 6. Step 4: Agent Plan Task
        let session_id = "e2e-session-001";
        let sess_c = CString::new(session_id).unwrap();
        let plan_params = CString::new(
            r#"{"prompt":"Add helper function in helper.rs","target_file":"src/helper.rs","code_patch":"pub fn helper() -> bool { true }\n"}"#,
        )
        .unwrap();
        let plan_resp = codelite_agent_plan_task(ctx, sess_c.as_ptr(), plan_params.as_ptr());
        let plan_str = c_to_str(plan_resp);
        let plan_val: Value = serde_json::from_str(&plan_str).expect("Valid plan response");
        assert_eq!(plan_val["status"], "ok");
        let plan_id = plan_val["plan"]["id"].as_str().unwrap();
        let plan_id_c = CString::new(plan_id).unwrap();

        // 7. Step 5: Execute Step 1 (Read Baseline - Low Risk -> Automatic Execution)
        let step1_resp = codelite_agent_execute_next_step(ctx, plan_id_c.as_ptr());
        let step1_str = c_to_str(step1_resp);
        let step1_val: Value = serde_json::from_str(&step1_str).expect("Valid step1 response");
        assert_eq!(step1_val["status"], "ok");
        assert_eq!(step1_val["result"]["type"], "Completed");

        // 8. Step 6: Execute Step 2 (Apply Patch - Medium Risk -> Suspended for Approval)
        let step2_resp = codelite_agent_execute_next_step(ctx, plan_id_c.as_ptr());
        let step2_str = c_to_str(step2_resp);
        let step2_val: Value = serde_json::from_str(&step2_str).expect("Valid step2 response");
        assert_eq!(step2_val["status"], "ok");
        assert_eq!(step2_val["result"]["type"], "SuspendedForApproval");

        let request_id = step2_val["result"]["payload"]["request_id"]
            .as_str()
            .unwrap();
        let request_id_c = CString::new(request_id).unwrap();

        // Verify ticket in pending approvals store
        let pending_resp = codelite_agent_get_pending_approvals(ctx, sess_c.as_ptr());
        let pending_str = c_to_str(pending_resp);
        let pending_val: Value = serde_json::from_str(&pending_str).expect("Valid pending list");
        assert_eq!(pending_val["status"], "ok");
        let approvals = pending_val["approvals"].as_array().expect("approvals array");
        assert!(approvals.len() >= 1);
        let ticket = approvals
            .iter()
            .find(|t| t["id"] == request_id)
            .expect("Found matching ticket");
        assert_eq!(ticket["tool_name"], "apply_patch");

        // 9. Step 7: Resolve Approval Ticket (User Confirms Action)
        let approve_resp = codelite_agent_approve_step(ctx, request_id_c.as_ptr(), true);
        let approve_str = c_to_str(approve_resp);
        let approve_val: Value = serde_json::from_str(&approve_str).expect("Valid approve response");
        assert_eq!(approve_val["status"], "ok");
        assert_eq!(approve_val["approved"], true);

        // Resume Step 2 Execution -> Now succeeds
        let step2_resume_resp = codelite_agent_execute_next_step(ctx, plan_id_c.as_ptr());
        let step2_resume_str = c_to_str(step2_resume_resp);
        let step2_resume_val: Value =
            serde_json::from_str(&step2_resume_str).expect("Valid step2 resume");
        assert_eq!(step2_resume_val["status"], "ok");
        assert_eq!(step2_resume_val["result"]["type"], "Completed");

        // Verify helper.rs exists and contains patch content
        let helper_path = temp_dir.join("src/helper.rs");
        assert!(helper_path.exists(), "helper.rs should be created");
        let helper_content = fs::read_to_string(&helper_path).unwrap();
        assert!(helper_content.contains("pub fn helper()"));

        // 10. Step 8: Atomic Rollback to Session Start
        let restore_resp = codelite_agent_restore_start(ctx, sess_c.as_ptr());
        let restore_str = c_to_str(restore_resp);
        let restore_val: Value = serde_json::from_str(&restore_str).expect("Valid restore response");
        assert_eq!(restore_val["status"], "ok");
        assert!(restore_val["reverted_count"].as_i64().unwrap() >= 1);

        // Verify helper.rs was atomically removed/reverted!
        assert!(
            !helper_path.exists(),
            "helper.rs should be deleted after restoring to session start"
        );

        // 11. Teardown
        codelite_destroy(ctx);
        let _ = fs::remove_dir_all(&temp_dir);
    }
}
