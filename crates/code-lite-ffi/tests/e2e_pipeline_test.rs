//! End-to-End Integration Test Pipeline
//!
//! Tests cross-layer integration from external caller perspective:
//! Workspace Init -> file.open (RPC) -> file.edit (RPC) -> lsp.diagnostics (RPC) -> Cleanup.
//! (Git 已迁到 Dart 的 GitService,不再经过 Rust。)

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
fn test_e2e_workspace_edit_lsp_pipeline() {
    unsafe {
        // 1. Setup isolated temporary workspace
        let temp_dir = std::env::temp_dir().join(format!("codelite-e2e-{}", uuid::Uuid::new_v4()));
        let src_dir = temp_dir.join("src");
        fs::create_dir_all(&src_dir).expect("Create src directory");

        let main_file = src_dir.join("main.rs");
        let initial_code = "fn main() {\n    let answer = 42;\n    println!(\"{}\", answer);\n}\n";
        fs::write(&main_file, initial_code).expect("Write initial code");

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

        // 7. Teardown
        codelite_destroy(ctx);
        let _ = fs::remove_dir_all(&temp_dir);
    }
}
