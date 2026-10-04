//! End-to-End Integration Test Pipeline
//!
//! Tests cross-layer integration from external caller perspective:
//! Workspace Init -> file.open (RPC) -> file.edit (RPC) -> file.undo / file.redo (RPC) -> Cleanup.
//! (Git 已迁到 Dart 的 GitService,LSP 已迁到 Flutter 侧,都不再经过 Rust。)

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
fn test_e2e_workspace_edit_undo_pipeline() {
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

        // 5. Step 3: file.undo via JSON-RPC -> 撤掉插入的注释
        // (撤销按换行分组,单次 undo 只回退注释那一组,不断言整段还原)
        let undo_req = CString::new(
            r#"{"jsonrpc":"2.0","id":3,"method":"file.undo","params":{"path":"src/main.rs"}}"#,
        )
        .unwrap();
        let undo_str = c_to_str(codelite_jsonrpc_call(ctx, undo_req.as_ptr()));
        let undo_val: Value = serde_json::from_str(&undo_str).expect("Valid JSON response");
        assert_eq!(undo_val["id"], 3);
        assert_eq!(undo_val["result"]["success"], true);
        assert!(!undo_val["result"]["content"]
            .as_str()
            .unwrap()
            .contains("// Optimized computation"));

        // 6. Step 4: file.redo via JSON-RPC -> 编辑重新生效
        let redo_req = CString::new(
            r#"{"jsonrpc":"2.0","id":4,"method":"file.redo","params":{"path":"src/main.rs"}}"#,
        )
        .unwrap();
        let redo_str = c_to_str(codelite_jsonrpc_call(ctx, redo_req.as_ptr()));
        let redo_val: Value = serde_json::from_str(&redo_str).expect("Valid JSON response");
        assert_eq!(redo_val["id"], 4);
        assert_eq!(redo_val["result"]["success"], true);
        assert!(redo_val["result"]["content"]
            .as_str()
            .unwrap()
            .contains("// Optimized computation"));

        // Rust 侧已无本地数据库,init 不应再在工作区里留下 .codelite/
        assert!(!temp_dir.join(".codelite").exists());

        // 7. Teardown
        codelite_destroy(ctx);
        let _ = fs::remove_dir_all(&temp_dir);
    }
}
