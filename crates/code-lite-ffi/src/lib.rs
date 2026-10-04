//! # code-lite-ffi
//!
//! C-ABI dynamic library bindings (`libcodelite.dylib` / `libcodelite.so` / `codelite.dll`)
//! for CodeLiteX, exposing Rust Core capabilities to the Flutter UI Shell.

use code_lite_core::Editor;
use code_lite_storage::{Database, GraphStore};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;

pub mod generated;
pub mod handlers;

/// Opaque context holding all Rust Core subsystem handles.
pub struct CodeLiteContext {
    pub workspace_root: PathBuf,
    pub db: Database,
    pub graph_store: GraphStore,
    pub graph_engine: code_lite_graph::GraphEngine,
    pub diagnostic_store: code_lite_storage::DiagnosticStore,
    pub lsp_client: Mutex<Option<std::sync::Arc<code_lite_lsp::LspClient>>>,
    pub lsp_supervisor: Mutex<Option<std::sync::Arc<code_lite_lsp::ProcessSupervisor>>>,
    pub editors: Mutex<HashMap<String, Editor>>,
    /// 用户终端会话。随上下文销毁一起杀掉 shell(切换项目即关闭旧项目的终端)。
    pub terminals: code_lite_terminal::TerminalManager,
}

// ---------------------------------------------------------------------------
// Internal Helper Utilities
// ---------------------------------------------------------------------------

unsafe fn c_str_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        None
    } else {
        CStr::from_ptr(ptr).to_str().ok()
    }
}

fn str_to_c_char(s: &str) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

fn json_to_c_char<T: Serialize>(val: &T) -> *mut c_char {
    let json_str = serde_json::to_string(val).unwrap_or_else(|_| "{}".to_string());
    str_to_c_char(&json_str)
}

fn err_json(msg: &str) -> *mut c_char {
    let obj = serde_json::json!({
        "status": "error",
        "error": msg
    });
    json_to_c_char(&obj)
}

// ---------------------------------------------------------------------------
// 1. Lifecycle & Context Management
// ---------------------------------------------------------------------------

/// Initializes the CodeLiteX Rust Core context for a given workspace path.
/// Returns an opaque pointer to `CodeLiteContext`, or null on failure.
#[no_mangle]
pub unsafe extern "C" fn codelite_init(workspace_path: *const c_char) -> *mut CodeLiteContext {
    let path_str = match c_str_to_str(workspace_path) {
        Some(s) if !s.is_empty() => s,
        _ => ".",
    };

    let root = PathBuf::from(path_str);
    let db_path = root.join(".codelite").join("workspace.db");

    let db = match Database::open(&db_path) {
        Ok(d) => d,
        Err(_) => match Database::open_in_memory() {
            Ok(d) => d,
            Err(_) => return std::ptr::null_mut(),
        },
    };

    let graph_store = GraphStore::new(db.clone());
    let graph_engine = code_lite_graph::GraphEngine::new(graph_store.clone(), root.clone());
    let diagnostic_store = code_lite_storage::DiagnosticStore::new(db.clone());

    let v_server = code_lite_lsp::VirtualLspServer::new()
        .with_diagnostic_store(diagnostic_store.clone());
    let supervisor = code_lite_lsp::ProcessSupervisor::new(&root, v_server.clone());
    let lsp_supervisor = Mutex::new(Some(std::sync::Arc::new(supervisor)));
    let lsp_client = Mutex::new(Some(std::sync::Arc::new(code_lite_lsp::LspClient::new_virtual(v_server))));

    let ctx = Box::new(CodeLiteContext {
        workspace_root: root,
        db,
        graph_store,
        graph_engine,
        diagnostic_store,
        lsp_client,
        lsp_supervisor,
        editors: Mutex::new(HashMap::new()),
        terminals: code_lite_terminal::TerminalManager::new(),
    });

    Box::into_raw(ctx)
}

/// Frees the `CodeLiteContext` and all associated in-memory resources.
#[no_mangle]
pub unsafe extern "C" fn codelite_destroy(ctx: *mut CodeLiteContext) {
    if !ctx.is_null() {
        drop(Box::from_raw(ctx));
    }
}

/// Frees a string previously allocated by Rust and returned via FFI.
#[no_mangle]
pub unsafe extern "C" fn codelite_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// Allocates an uninitialized byte buffer of `len + 1` bytes for callers passing C strings.
#[no_mangle]
pub unsafe extern "C" fn codelite_string_alloc(len: usize) -> *mut c_char {
    let vec = vec![0u8; len + 1];
    let boxed = vec.into_boxed_slice();
    Box::into_raw(boxed) as *mut c_char
}

/// Frees a buffer allocated with `codelite_string_alloc`.
#[no_mangle]
pub unsafe extern "C" fn codelite_buffer_free(ptr: *mut c_char, len: usize) {
    if !ptr.is_null() {
        let slice = std::slice::from_raw_parts_mut(ptr as *mut u8, len + 1);
        drop(Box::from_raw(slice));
    }
}

/// Returns the C-ABI library version.
#[no_mangle]
pub extern "C" fn codelite_version() -> *const c_char {
    str_to_c_char(env!("CARGO_PKG_VERSION"))
}

/// Invokes a JSON-RPC 2.0 request against Rust Core subsystems.
/// Dispatches through the auto-generated type-safe routing table.
#[no_mangle]
pub unsafe extern "C" fn codelite_jsonrpc_call(
    ctx: *mut CodeLiteContext,
    request_json: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        let resp = code_lite_rpc::protocol::JsonRpcResponse::err(
            0,
            code_lite_rpc::protocol::error_codes::INTERNAL_ERROR,
            "Context pointer is null",
        );
        return json_to_c_char(&resp);
    }

    let req_str = match c_str_to_str(request_json) {
        Some(s) => s,
        None => {
            let resp = code_lite_rpc::protocol::JsonRpcResponse::err(
                0,
                code_lite_rpc::protocol::error_codes::PARSE_ERROR,
                "Invalid request JSON C string pointer",
            );
            return json_to_c_char(&resp);
        }
    };

    let req: code_lite_rpc::protocol::JsonRpcRequest = match serde_json::from_str(req_str) {
        Ok(r) => r,
        Err(e) => {
            let resp = code_lite_rpc::protocol::JsonRpcResponse::err(
                0,
                code_lite_rpc::protocol::error_codes::PARSE_ERROR,
                format!("JSON-RPC parse error: {}", e),
            );
            return json_to_c_char(&resp);
        }
    };

    let resp = generated::dispatch::dispatch_rpc(ctx, &req);
    json_to_c_char(&resp)
}

// ---------------------------------------------------------------------------
// 2. Workspace File Tree & Text Editor Operations
// ---------------------------------------------------------------------------

/// Scans the workspace directory tree and returns a hierarchical JSON representation.
#[no_mangle]
pub unsafe extern "C" fn codelite_workspace_scan(
    ctx: *mut CodeLiteContext,
    max_depth: usize,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let tree = code_lite_fs::WorkspaceTree::new(&ctx.workspace_root);
    match tree.scan(max_depth) {
        Ok(entry) => json_to_c_char(&entry),
        Err(e) => err_json(&format!("Scan failed: {}", e)),
    }
}

/// Opens a file into the Rust text buffer, caching the `Editor` in memory.
#[no_mangle]
pub unsafe extern "C" fn codelite_file_open(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let rel = match c_str_to_str(rel_path) {
        Some(s) => s,
        None => return err_json("Invalid relative path pointer"),
    };

    let full_path = ctx.workspace_root.join(rel);
    let content = match std::fs::read_to_string(&full_path) {
        Ok(c) => c,
        Err(e) => return err_json(&format!("Failed to read file: {}", e)),
    };

    let mut editors = ctx.editors.lock();
    let mut editor = Editor::from_str(&content);
    editor.mark_saved();
    let line_count = editor.buffer().len_lines();
    editors.insert(rel.to_string(), editor);

    let result = serde_json::json!({
        "status": "ok",
        "path": rel,
        "content": content,
        "lines": line_count,
        "is_dirty": false,
    });
    json_to_c_char(&result)
}

#[derive(Deserialize)]
struct EditPayload {
    #[serde(rename = "type")]
    edit_type: String, // "insert", "delete", "replace_all"
    text: Option<String>,
}

/// Applies an edit to an open file buffer in the Rust TextBuffer.
#[no_mangle]
pub unsafe extern "C" fn codelite_file_edit(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
    edit_json: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let rel = match c_str_to_str(rel_path) {
        Some(s) => s,
        None => return err_json("Invalid relative path pointer"),
    };

    let edit_str = match c_str_to_str(edit_json) {
        Some(s) => s,
        None => return err_json("Invalid edit JSON pointer"),
    };

    let payload: EditPayload = match serde_json::from_str(edit_str) {
        Ok(p) => p,
        Err(e) => return err_json(&format!("Invalid edit JSON format: {}", e)),
    };

    let mut editors = ctx.editors.lock();
    let editor = match editors.get_mut(rel) {
        Some(e) => e,
        None => return err_json(&format!("File not open in editor: {}", rel)),
    };

    match payload.edit_type.as_str() {
        "insert" => {
            if let Some(text) = payload.text {
                editor.insert_text(&text);
            }
        }
        "delete" => {
            editor.delete_backward();
        }
        "replace_all" => {
            if let Some(text) = payload.text {
                *editor = Editor::from_str(&text);
            }
        }
        other => return err_json(&format!("Unknown edit type: {}", other)),
    }

    let result = serde_json::json!({
        "status": "ok",
        "path": rel,
        "content": editor.text(),
        "lines": editor.buffer().len_lines(),
        "can_undo": editor.can_undo(),
        "can_redo": editor.can_redo(),
        "is_dirty": editor.is_dirty(),
    });

    let current_content = editor.text();
    drop(editors);

    // Fast incremental indexing into CodeGraph and SQLite WAL
    let _ = ctx.graph_engine.index_file(rel, &current_content);

    json_to_c_char(&result)
}

/// Saves an open file buffer to disk, marking the editor history as clean (not dirty).
#[no_mangle]
pub unsafe extern "C" fn codelite_file_save(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let rel = match c_str_to_str(rel_path) {
        Some(s) => s,
        None => return err_json("Invalid relative path pointer"),
    };

    let full_path = if std::path::Path::new(rel).is_absolute() {
        std::path::PathBuf::from(rel)
    } else {
        ctx.workspace_root.join(rel)
    };

    let mut editors = ctx.editors.lock();
    let editor = match editors.get_mut(rel) {
        Some(e) => e,
        None => return err_json(&format!("File not open in editor: {}", rel)),
    };

    if let Err(e) = editor.save_to_file(&full_path) {
        return err_json(&format!("Failed to save file '{}': {}", rel, e));
    }

    let current_content = editor.text();
    drop(editors);

    // Re-index saved file in CodeGraph
    let _ = ctx.graph_engine.index_file(rel, &current_content);

    let result = serde_json::json!({
        "status": "ok",
        "path": rel,
        "is_dirty": false,
    });
    json_to_c_char(&result)
}

/// Sets the cursor position or selection in an open editor buffer.
#[no_mangle]
pub unsafe extern "C" fn codelite_file_cursor_set(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
    line: u32,
    col: u32,
    select: bool,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let rel = match c_str_to_str(rel_path) {
        Some(s) => s,
        None => return err_json("Invalid relative path pointer"),
    };

    let mut editors = ctx.editors.lock();
    let editor = match editors.get_mut(rel) {
        Some(e) => e,
        None => return err_json(&format!("File not open in editor: {}", rel)),
    };

    editor.set_cursor_point(code_lite_core::Point::new(line as usize, col as usize), select);
    let head = editor.cursors().primary().head();

    let result = serde_json::json!({
        "status": "ok",
        "path": rel,
        "line": head.row,
        "col": head.col,
    });
    json_to_c_char(&result)
}

/// Undoes the last edit via Rust `UndoManager`.
#[no_mangle]
pub unsafe extern "C" fn codelite_undo(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let rel = match c_str_to_str(rel_path) {
        Some(s) => s,
        None => return err_json("Invalid path"),
    };

    let mut editors = ctx.editors.lock();
    let editor = match editors.get_mut(rel) {
        Some(e) => e,
        None => return err_json("File not open"),
    };

    let success = editor.undo();
    let result = serde_json::json!({
        "status": "ok",
        "undone": success,
        "content": editor.text(),
        "can_undo": editor.can_undo(),
        "can_redo": editor.can_redo(),
        "is_dirty": editor.is_dirty(),
    });
    json_to_c_char(&result)
}

/// Redoes the undone edit via Rust `UndoManager`.
#[no_mangle]
pub unsafe extern "C" fn codelite_redo(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let rel = match c_str_to_str(rel_path) {
        Some(s) => s,
        None => return err_json("Invalid path"),
    };

    let mut editors = ctx.editors.lock();
    let editor = match editors.get_mut(rel) {
        Some(e) => e,
        None => return err_json("File not open"),
    };

    let success = editor.redo();
    let result = serde_json::json!({
        "status": "ok",
        "redone": success,
        "content": editor.text(),
        "can_undo": editor.can_undo(),
        "can_redo": editor.can_redo(),
        "is_dirty": editor.is_dirty(),
    });
    json_to_c_char(&result)
}

// ---------------------------------------------------------------------------
// 4. CodeGraph Metadata Inspection
// ---------------------------------------------------------------------------

/// Searches CodeGraph symbols stored in SQLite.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_symbols(
    ctx: *mut CodeLiteContext,
    query: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;

    let q = c_str_to_str(query).unwrap_or("");
    let symbols = if q.is_empty() {
        ctx.graph_store.find_symbols_by_name("").unwrap_or_default()
    } else {
        ctx.graph_store.find_symbols_by_name(q).unwrap_or_default()
    };
    json_to_c_char(&symbols)
}

/// Indexes a file into CodeGraph and SQLite WAL.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_index_file(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(rel_path) {
        Some(p) => p,
        None => return err_json("Invalid relative path"),
    };

    let full_path = ctx.workspace_root.join(path);
    let content = match std::fs::read_to_string(&full_path) {
        Ok(c) => c,
        Err(e) => return err_json(&format!("Failed to read file: {}", e)),
    };

    match ctx.graph_engine.index_file(path, &content) {
        Ok(report) => {
            let result = serde_json::json!({
                "status": "ok",
                "report": report,
            });
            json_to_c_char(&result)
        }
        Err(e) => err_json(&format!("Indexing failed: {}", e)),
    }
}

/// Retrieves the symbol outline tree for a file.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_query_outline(
    ctx: *mut CodeLiteContext,
    rel_path: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(rel_path) {
        Some(p) => p,
        None => return err_json("Invalid relative path"),
    };

    let content = {
        let editors = ctx.editors.lock();
        editors.get(path).map(|e| e.buffer().to_string())
    };

    match ctx.graph_engine.get_outline(path, content.as_deref()) {
        Ok(outline) => json_to_c_char(&outline),
        Err(e) => err_json(&format!("Outline query failed: {}", e)),
    }
}

/// Finds definitions for a symbol by symbol_key or name.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_find_definition(
    ctx: *mut CodeLiteContext,
    query: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let q = match c_str_to_str(query) {
        Some(s) => s,
        None => return err_json("Invalid query string"),
    };

    match ctx.graph_engine.find_definitions(q) {
        Ok(defs) => json_to_c_char(&defs),
        Err(e) => err_json(&format!("Find definition failed: {}", e)),
    }
}

/// Finds references and callers for a symbol.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_find_references(
    ctx: *mut CodeLiteContext,
    query: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let q = match c_str_to_str(query) {
        Some(s) => s,
        None => return err_json("Invalid query string"),
    };

    match ctx.graph_engine.find_references(q) {
        Ok(refs) => json_to_c_char(&refs),
        Err(e) => err_json(&format!("Find references failed: {}", e)),
    }
}

/// Retrieves rich local graph context (definition, callers, callees) around a symbol.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_get_context(
    ctx: *mut CodeLiteContext,
    key_or_name: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let q = match c_str_to_str(key_or_name) {
        Some(s) => s,
        None => return err_json("Invalid symbol query string"),
    };

    match ctx.graph_engine.get_code_context(q) {
        Ok(Some(context)) => json_to_c_char(&context),
        Ok(None) => err_json(&format!("Symbol not found: {}", q)),
        Err(e) => err_json(&format!("Get code context failed: {}", e)),
    }
}

/// Finds symbols calling the target symbol.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_find_callers(
    ctx: *mut CodeLiteContext,
    key_or_name: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let q = match c_str_to_str(key_or_name) {
        Some(s) => s,
        None => return err_json("Invalid symbol query string"),
    };

    match ctx.graph_engine.find_callers(q) {
        Ok(callers) => json_to_c_char(&callers),
        Err(e) => err_json(&format!("Find callers failed: {}", e)),
    }
}

/// Finds symbols called by the target symbol.
#[no_mangle]
pub unsafe extern "C" fn codelite_graph_find_callees(
    ctx: *mut CodeLiteContext,
    key_or_name: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let q = match c_str_to_str(key_or_name) {
        Some(s) => s,
        None => return err_json("Invalid symbol query string"),
    };

    match ctx.graph_engine.find_callees(q) {
        Ok(callees) => json_to_c_char(&callees),
        Err(e) => err_json(&format!("Find callees failed: {}", e)),
    }
}

// ---------------------------------------------------------------------------
// 8. LSP (Language Server Protocol) Cognitive Services
// ---------------------------------------------------------------------------

/// Switches or restarts the LSP client with an external binary if specified,
/// or falls back to the built-in VirtualLspServer.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_init_server(
    ctx: *mut CodeLiteContext,
    cmd: *const c_char,
    args_json: *const c_char,
) -> bool {
    if ctx.is_null() {
        return false;
    }
    let ctx = &*ctx;

    let cmd_str = c_str_to_str(cmd);
    if let Some(cmd) = cmd_str {
        if !cmd.trim().is_empty() {
            let args_vec: Vec<String> = if let Some(raw_args) = c_str_to_str(args_json) {
                serde_json::from_str(raw_args).unwrap_or_default()
            } else {
                Vec::new()
            };
            let args_slices: Vec<&str> = args_vec.iter().map(|s| s.as_str()).collect();

            if let Some(supervisor) = ctx.lsp_supervisor.lock().as_ref() {
                supervisor.set_server_config("rust", cmd, &args_slices);
            }

            if let Ok(client) = code_lite_lsp::LspClient::spawn_process(cmd, &args_slices, &ctx.workspace_root) {
                *ctx.lsp_client.lock() = Some(std::sync::Arc::new(client));
                return true;
            }
        }
    }

    // Fallback to Virtual LSP
    let v_server = code_lite_lsp::VirtualLspServer::new()
        .with_diagnostic_store(ctx.diagnostic_store.clone());
    *ctx.lsp_client.lock() = Some(std::sync::Arc::new(code_lite_lsp::LspClient::new_virtual(v_server)));
    true
}

/// Notifies LSP that a document was opened, computing and returning its diagnostics.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_did_open(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    language: *const c_char,
    content: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };
    let lang = c_str_to_str(language).unwrap_or("rust");
    let text = c_str_to_str(content).unwrap_or("");

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.did_open(path, lang, text) {
            Ok(diags) => return json_to_c_char(&diags),
            Err(e) => return err_json(&format!("LSP did_open error: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.did_open(path, lang, text) {
            Ok(diags) => json_to_c_char(&diags),
            Err(e) => err_json(&format!("LSP did_open error: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Notifies LSP of document changes (full replacement), returning updated diagnostics.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_did_change(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    version: i32,
    content: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };
    let text = c_str_to_str(content).unwrap_or("");

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.did_change(path, version, text) {
            Ok(diags) => return json_to_c_char(&diags),
            Err(e) => return err_json(&format!("LSP did_change error: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.did_change(path, version, text) {
            Ok(diags) => json_to_c_char(&diags),
            Err(e) => err_json(&format!("LSP did_change error: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Notifies LSP of incremental document changes (Range replacement), returning updated diagnostics.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_did_change_incremental(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    version: i32,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
    new_content: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };
    let text = c_str_to_str(new_content).unwrap_or("");
    let range = code_lite_lsp::Range::new(start_line, start_col, end_line, end_col);

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.did_change_incremental(path, version, range, None, text) {
            Ok(diags) => return json_to_c_char(&diags),
            Err(e) => return err_json(&format!("LSP did_change_incremental error: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.did_change_incremental(path, version, range, None, text) {
            Ok(diags) => json_to_c_char(&diags),
            Err(e) => err_json(&format!("LSP did_change_incremental error: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Retrieves current diagnostics for a file.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_get_diagnostics(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        let diags = supervisor.get_diagnostics(path);
        if !diags.is_empty() {
            return json_to_c_char(&diags);
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        let diags = client.get_diagnostics(path);
        if !diags.is_empty() {
            return json_to_c_char(&diags);
        }
    }

    // Secondary fallback: SQLite DiagnosticStore
    match ctx.diagnostic_store.get_diagnostics_by_file(path) {
        Ok(records) => json_to_c_char(&records),
        Err(e) => err_json(&format!("Query diagnostics failed: {}", e)),
    }
}

/// Jumps to definition of the symbol at the specified line and column.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_goto_definition(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    line: u32,
    col: u32,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.goto_definition(path, line, col) {
            Ok(defs) => return json_to_c_char(&defs),
            Err(e) => return err_json(&format!("Goto definition failed: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.goto_definition(path, line, col) {
            Ok(defs) => json_to_c_char(&defs),
            Err(e) => err_json(&format!("Goto definition failed: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Finds all references of the symbol at the specified line and column.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_find_references(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    line: u32,
    col: u32,
    include_decl: bool,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.find_references(path, line, col, include_decl) {
            Ok(refs) => return json_to_c_char(&refs),
            Err(e) => return err_json(&format!("Find references failed: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.find_references(path, line, col, include_decl) {
            Ok(refs) => json_to_c_char(&refs),
            Err(e) => err_json(&format!("Find references failed: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Retrieves hover documentation & type annotations for the symbol at line and column.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_hover(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    line: u32,
    col: u32,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.hover(path, line, col) {
            Ok(hover) => return json_to_c_char(&hover),
            Err(e) => return err_json(&format!("Hover failed: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.hover(path, line, col) {
            Ok(hover) => json_to_c_char(&hover),
            Err(e) => err_json(&format!("Hover failed: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Requests smart completion candidates at line and column.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_completion(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    line: u32,
    col: u32,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.completion(path, line, col) {
            Ok(items) => return json_to_c_char(&items),
            Err(e) => return err_json(&format!("Completion failed: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.completion(path, line, col) {
            Ok(items) => json_to_c_char(&items),
            Err(e) => err_json(&format!("Completion failed: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Calculates workspace-wide rename edits.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_rename(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    line: u32,
    col: u32,
    new_name: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };
    let name = match c_str_to_str(new_name) {
        Some(s) => s,
        None => return err_json("Invalid new_name"),
    };

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        match supervisor.rename(path, line, col, name) {
            Ok(edit) => return json_to_c_char(&edit),
            Err(e) => return err_json(&format!("Rename failed: {}", e)),
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.rename(path, line, col, name) {
            Ok(edit) => json_to_c_char(&edit),
            Err(e) => err_json(&format!("Rename failed: {}", e)),
        }
    } else {
        err_json("LSP client not initialized")
    }
}

/// Returns the server capabilities JSON for a given language.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_server_capabilities(
    ctx: *mut CodeLiteContext,
    language: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let lang = c_str_to_str(language).unwrap_or("rust");

    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        if let Some(caps) = supervisor.server_capabilities(lang) {
            return json_to_c_char(&caps);
        }
    }

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        if let Some(caps) = client.server_capabilities() {
            return json_to_c_char(&caps);
        }
    }

    err_json("Server capabilities unavailable")
}

/// Returns the supervisor status report JSON.
#[no_mangle]
pub unsafe extern "C" fn codelite_lsp_supervisor_status(
    ctx: *mut CodeLiteContext,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let sup_guard = ctx.lsp_supervisor.lock();
    if let Some(supervisor) = sup_guard.as_ref() {
        let status = supervisor.status();
        json_to_c_char(&status)
    } else {
        err_json("Supervisor not initialized")
    }
}

// ---------------------------------------------------------------------------
// Phase 4: Viewport Tokens, Search/Replace, & Terminal Execution
// ---------------------------------------------------------------------------

/// calc_values viewport-virtualized syntax tokens for high performance line streaming.
#[no_mangle]
pub unsafe extern "C" fn codelite_get_viewport_tokens(
    ctx: *mut CodeLiteContext,
    file_path: *const c_char,
    start_line: u32,
    end_line: u32,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let path = match c_str_to_str(file_path) {
        Some(s) => s,
        None => return err_json("Invalid file_path"),
    };

    let editors = ctx.editors.lock();
    let tokens = if let Some(editor) = editors.get(path) {
        code_lite_core::syntax::get_viewport_tokens(
            editor.buffer(),
            start_line as usize,
            end_line as usize,
        )
    } else {
        let full_path = ctx.workspace_root.join(path);
        match std::fs::read_to_string(&full_path) {
            Ok(content) => {
                let buf = code_lite_core::TextBuffer::from_str(&content);
                code_lite_core::syntax::get_viewport_tokens(
                    &buf,
                    start_line as usize,
                    end_line as usize,
                )
            }
            Err(e) => return err_json(&format!("Failed to read file: {}", e)),
        }
    };

    let res = serde_json::json!({
        "status": "ok",
        "file_path": path,
        "start_line": start_line,
        "end_line": end_line,
        "lines": tokens,
    });
    json_to_c_char(&res)
}

/// Searches the workspace using the high-performance search engine.
#[no_mangle]
pub unsafe extern "C" fn codelite_search_workspace(
    ctx: *mut CodeLiteContext,
    query: *const c_char,
    options_json: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let query_str = match c_str_to_str(query) {
        Some(s) => s,
        None => return err_json("Invalid query"),
    };

    let opts: code_lite_fs::SearchOptions = if let Some(raw_opts) = c_str_to_str(options_json) {
        serde_json::from_str(raw_opts).unwrap_or_default()
    } else {
        code_lite_fs::SearchOptions::default()
    };

    let searcher = code_lite_fs::WorkspaceSearcher::new(&ctx.workspace_root);
    match searcher.search(query_str, &opts) {
        Ok(matches) => {
            let total = matches.len();
            let res = serde_json::json!({
                "status": "ok",
                "query": query_str,
                "total": total,
                "matches": matches,
            });
            json_to_c_char(&res)
        }
        Err(e) => err_json(&format!("Search failed: {}", e)),
    }
}

/// Replaces occurrences across the workspace.
#[no_mangle]
pub unsafe extern "C" fn codelite_replace_workspace(
    ctx: *mut CodeLiteContext,
    query: *const c_char,
    replacement: *const c_char,
    options_json: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let query_str = match c_str_to_str(query) {
        Some(s) => s,
        None => return err_json("Invalid query"),
    };
    let repl_str = match c_str_to_str(replacement) {
        Some(s) => s,
        None => return err_json("Invalid replacement"),
    };

    let opts: code_lite_fs::SearchOptions = if let Some(raw_opts) = c_str_to_str(options_json) {
        serde_json::from_str(raw_opts).unwrap_or_default()
    } else {
        code_lite_fs::SearchOptions::default()
    };

    let searcher = code_lite_fs::WorkspaceSearcher::new(&ctx.workspace_root);
    match searcher.replace_all(query_str, repl_str, &opts) {
        Ok(count) => {
            let res = serde_json::json!({
                "status": "ok",
                "replaced_count": count,
            });
            json_to_c_char(&res)
        }
        Err(e) => err_json(&format!("Replace failed: {}", e)),
    }
}

/// Executes a command in the workspace directory (simulated interactive terminal output).
#[no_mangle]
pub unsafe extern "C" fn codelite_terminal_exec(
    ctx: *mut CodeLiteContext,
    cmd: *const c_char,
    args_json: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    let cmd_str = match c_str_to_str(cmd) {
        Some(s) => s,
        None => return err_json("Invalid cmd"),
    };

    let args_vec: Vec<String> = if let Some(raw_args) = c_str_to_str(args_json) {
        serde_json::from_str(raw_args).unwrap_or_default()
    } else {
        Vec::new()
    };
    let args_slices: Vec<&str> = args_vec.iter().map(|s| s.as_str()).collect();

    let output = match std::process::Command::new(cmd_str)
        .args(&args_slices)
        .current_dir(&ctx.workspace_root)
        .output()
    {
        Ok(out) => out,
        Err(e) => return err_json(&format!("Failed to execute command: {}", e)),
    };

    let exit_code = output.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    let result = serde_json::json!({
        "status": "ok",
        "exit_code": exit_code,
        "stdout": stdout,
        "stderr": stderr,
        "success": output.status.success(),
    });

    json_to_c_char(&result)
}

// --- 交互式终端(PTY)。与上面的单次 exec 不同:shell 常驻,cd / 环境变量 / 交互程序都保留。

/// 在工作区根目录起一个登录 shell。返回 `{"status":"ok","id":"term-1"}`。
#[no_mangle]
pub unsafe extern "C" fn codelite_pty_open(ctx: *mut CodeLiteContext, rows: u16, cols: u16) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let ctx = &*ctx;
    match ctx.terminals.open(&ctx.workspace_root, rows, cols) {
        Ok(id) => json_to_c_char(&serde_json::json!({ "status": "ok", "id": id })),
        Err(e) => err_json(&e),
    }
}

/// 把用户按键(已编码为终端字节序列的 UTF-8 文本)写进 shell。
#[no_mangle]
pub unsafe extern "C" fn codelite_pty_write(
    ctx: *mut CodeLiteContext,
    id: *const c_char,
    data: *const c_char,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let (Some(id), Some(data)) = (c_str_to_str(id), c_str_to_str(data)) else {
        return err_json("Invalid id or data");
    };
    match (*ctx).terminals.get(id) {
        Some(s) => match s.write(data.as_bytes()) {
            Ok(()) => json_to_c_char(&serde_json::json!({ "status": "ok" })),
            Err(e) => err_json(&e),
        },
        None => err_json("No such terminal session"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn codelite_pty_resize(
    ctx: *mut CodeLiteContext,
    id: *const c_char,
    rows: u16,
    cols: u16,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let Some(id) = c_str_to_str(id) else { return err_json("Invalid id") };
    match (*ctx).terminals.get(id) {
        Some(s) => match s.resize(rows, cols) {
            Ok(()) => json_to_c_char(&serde_json::json!({ "status": "ok" })),
            Err(e) => err_json(&e),
        },
        None => err_json("No such terminal session"),
    }
}

/// 读取屏幕。`since_seq < 0` 表示强制全量;等于当前 seq 时只回 `unchanged`。
#[no_mangle]
pub unsafe extern "C" fn codelite_pty_snapshot(
    ctx: *mut CodeLiteContext,
    id: *const c_char,
    since_seq: i64,
    scrollback: u32,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let Some(id) = c_str_to_str(id) else { return err_json("Invalid id") };
    match (*ctx).terminals.get(id) {
        Some(s) => {
            let since = if since_seq < 0 { None } else { Some(since_seq as u64) };
            json_to_c_char(&s.snapshot(since, scrollback as usize))
        }
        None => err_json("No such terminal session"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn codelite_pty_close(ctx: *mut CodeLiteContext, id: *const c_char) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let Some(id) = c_str_to_str(id) else { return err_json("Invalid id") };
    (*ctx).terminals.close(id);
    json_to_c_char(&serde_json::json!({ "status": "ok" }))
}

// ---------------------------------------------------------------------------
// Phase 11: Cross-platform Differential Auto-Updater C-ABI
// ---------------------------------------------------------------------------

/// Checks for available updates against the remote/local manifest JSON (Phase 11).
#[no_mangle]
pub unsafe extern "C" fn codelite_updater_check(
    _ctx: *mut CodeLiteContext,
    current_version: *const c_char,
    manifest_json: *const c_char,
    platform: *const c_char,
) -> *const c_char {
    let cur_ver = match c_str_to_str(current_version) {
        Some(s) => s,
        None => return err_json("current_version is required"),
    };
    let manifest = match c_str_to_str(manifest_json) {
        Some(s) => s,
        None => return err_json("manifest_json is required"),
    };
    let forced_platform = c_str_to_str(platform).map(code_lite_fs::updater::PlatformKind::from_str_name);

    match code_lite_fs::updater::UpdaterEngine::check_update(cur_ver, manifest, forced_platform) {
        Ok(result) => {
            let mut val = serde_json::to_value(&result).unwrap_or(serde_json::Value::Null);
            if let serde_json::Value::Object(ref mut map) = val {
                map.insert("status".to_string(), serde_json::json!("ok"));
                map.insert("result".to_string(), serde_json::to_value(&result).unwrap());
            }
            json_to_c_char(&val)
        }
        Err(e) => err_json(&e.to_string()),
    }
}

/// Stages an artifact into a temporary directory after verifying its SHA256 checksum (Phase 11).
#[no_mangle]
pub unsafe extern "C" fn codelite_updater_stage(
    _ctx: *mut CodeLiteContext,
    staging_dir: *const c_char,
    file_name: *const c_char,
    content: *const c_char,
    expected_sha256: *const c_char,
) -> *const c_char {
    let s_dir = match c_str_to_str(staging_dir) {
        Some(s) => std::path::Path::new(s),
        None => return err_json("staging_dir is required"),
    };
    let f_name = match c_str_to_str(file_name) {
        Some(s) => s,
        None => return err_json("file_name is required"),
    };
    let cont = match c_str_to_str(content) {
        Some(s) => s.as_bytes(),
        None => return err_json("content is required"),
    };
    let sha = match c_str_to_str(expected_sha256) {
        Some(s) => s,
        None => return err_json("expected_sha256 is required"),
    };

    match code_lite_fs::updater::UpdaterEngine::stage_artifact(s_dir, f_name, cont, sha) {
        Ok(path) => {
            let res = serde_json::json!({
                "status": "ok",
                "staged_path": path.to_string_lossy(),
                "sha256": sha,
                "verified": true,
            });
            json_to_c_char(&res)
        }
        Err(e) => err_json(&e.to_string()),
    }
}

/// Applies a staged update according to OS strategy (Phase 11).
/// On macOS, produces atomic bundle swap script.
/// On Linux/Windows, executes atomic component delta with backup & rollback.
#[no_mangle]
pub unsafe extern "C" fn codelite_updater_apply(
    _ctx: *mut CodeLiteContext,
    staging_dir: *const c_char,
    target_dir: *const c_char,
    files_json: *const c_char,
    platform: *const c_char,
) -> *const c_char {
    let s_dir = match c_str_to_str(staging_dir) {
        Some(s) => std::path::Path::new(s),
        None => return err_json("staging_dir is required"),
    };
    let t_dir = match c_str_to_str(target_dir) {
        Some(s) => std::path::Path::new(s),
        None => return err_json("target_dir is required"),
    };
    let plat_str = c_str_to_str(platform).unwrap_or("macos");
    let plat = code_lite_fs::updater::PlatformKind::from_str_name(plat_str);

    match plat {
        code_lite_fs::updater::PlatformKind::Macos => {
            let script = code_lite_fs::updater::UpdaterEngine::generate_macos_swap_script(s_dir, t_dir);
            let res = serde_json::json!({
                "status": "ok",
                "strategy": "app_bundle_delta",
                "swap_script": script,
            });
            json_to_c_char(&res)
        }
        code_lite_fs::updater::PlatformKind::Linux | code_lite_fs::updater::PlatformKind::Windows => {
            let files: Vec<String> = match c_str_to_str(files_json) {
                Some(s) => serde_json::from_str(s).unwrap_or_default(),
                None => Vec::new(),
            };
            match code_lite_fs::updater::UpdaterEngine::apply_component_delta(s_dir, t_dir, &files) {
                Ok(report) => {
                    let res = serde_json::json!({
                        "status": "ok",
                        "strategy": "component_delta",
                        "report": report,
                    });
                    json_to_c_char(&res)
                }
                Err(e) => err_json(&e.to_string()),
            }
        }
        code_lite_fs::updater::PlatformKind::Unknown => {
            err_json("Unknown platform for updater apply")
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn test_ffi_lifecycle_and_editor_undo_redo() {
        unsafe {
            let root = CString::new(".").unwrap();
            let ctx = codelite_init(root.as_ptr());
            assert!(!ctx.is_null());

            // Version
            let ver_ptr = codelite_version();
            let ver = CStr::from_ptr(ver_ptr).to_str().unwrap();
            assert_eq!(ver, "0.1.0");
            codelite_string_free(ver_ptr as *mut c_char);

            // Workspace scan
            let scan_ptr = codelite_workspace_scan(ctx, 3);
            let scan_str = CStr::from_ptr(scan_ptr).to_str().unwrap();
            assert!(scan_str.contains("Cargo.toml") || scan_str.contains("src"));
            codelite_string_free(scan_ptr as *mut c_char);

            // Open file
            let test_doc_rel = "test_ffi_editor.txt";
            let test_doc_full = (*ctx).workspace_root.join(test_doc_rel);
            std::fs::write(&test_doc_full, "initial content\n").unwrap();

            let path = CString::new(test_doc_rel).unwrap();
            let open_ptr = codelite_file_open(ctx, path.as_ptr());
            let open_str = CStr::from_ptr(open_ptr).to_str().unwrap();
            assert!(open_str.contains("initial content"));
            assert!(open_str.contains("\"is_dirty\":false"));
            codelite_string_free(open_ptr as *mut c_char);

            // Cursor set (Phase 7)
            let cur_ptr = codelite_file_cursor_set(ctx, path.as_ptr(), 0, 5, false);
            let cur_str = CStr::from_ptr(cur_ptr).to_str().unwrap();
            assert!(cur_str.contains("\"col\":5"));
            codelite_string_free(cur_ptr as *mut c_char);

            // Edit file
            let edit_json = CString::new(r#"{"type":"insert","text":"// comment\n"}"#).unwrap();
            let edit_ptr = codelite_file_edit(ctx, path.as_ptr(), edit_json.as_ptr());
            let edit_str = CStr::from_ptr(edit_ptr).to_str().unwrap();
            assert!(edit_str.contains("// comment"));
            assert!(edit_str.contains("\"is_dirty\":true"));
            codelite_string_free(edit_ptr as *mut c_char);

            // Undo edit -> restores clean state
            let undo_ptr = codelite_undo(ctx, path.as_ptr());
            let undo_str = CStr::from_ptr(undo_ptr).to_str().unwrap();
            assert!(undo_str.contains("\"undone\":true"));
            assert!(undo_str.contains("\"is_dirty\":false"));
            codelite_string_free(undo_ptr as *mut c_char);

            // Redo edit -> dirty again
            let redo_ptr = codelite_redo(ctx, path.as_ptr());
            let redo_str = CStr::from_ptr(redo_ptr).to_str().unwrap();
            assert!(redo_str.contains("\"redone\":true"));
            assert!(redo_str.contains("\"is_dirty\":true"));
            codelite_string_free(redo_ptr as *mut c_char);

            // Save file (Phase 7) -> clean state
            let save_ptr = codelite_file_save(ctx, path.as_ptr());
            let save_str = CStr::from_ptr(save_ptr).to_str().unwrap();
            assert!(save_str.contains("\"is_dirty\":false"));
            codelite_string_free(save_ptr as *mut c_char);
            let _ = std::fs::remove_file(&test_doc_full);

            // CodeGraph Outline & Definition
            let outline_ptr = codelite_graph_query_outline(ctx, path.as_ptr());
            let outline_str = CStr::from_ptr(outline_ptr).to_str().unwrap();
            assert!(!outline_str.is_empty());
            codelite_string_free(outline_ptr as *mut c_char);

            let def_query = CString::new("workspace").unwrap();
            let def_ptr = codelite_graph_find_definition(ctx, def_query.as_ptr());
            let def_str = CStr::from_ptr(def_ptr).to_str().unwrap();
            assert!(!def_str.is_empty());
            codelite_string_free(def_ptr as *mut c_char);

            // LSP Test Suite (6 capabilities)
            let lsp_file = CString::new("src/sample.rs").unwrap();
            let lsp_lang = CString::new("rust").unwrap();
            let lsp_content = CString::new("fn calc_value() -> i32 { 42 }\nfn main() { let x = calc_value(); }").unwrap();

            // 1. Diagnostics (P2.1)
            let diags_ptr = codelite_lsp_did_open(ctx, lsp_file.as_ptr(), lsp_lang.as_ptr(), lsp_content.as_ptr());
            let diags_str = CStr::from_ptr(diags_ptr).to_str().unwrap();
            assert_eq!(diags_str, "[]");
            codelite_string_free(diags_ptr as *mut c_char);

            // 2. Definition (P2.2)
            let lsp_def_ptr = codelite_lsp_goto_definition(ctx, lsp_file.as_ptr(), 1, 23);
            let lsp_def_str = CStr::from_ptr(lsp_def_ptr).to_str().unwrap();
            assert!(lsp_def_str.contains("src/sample.rs"));
            codelite_string_free(lsp_def_ptr as *mut c_char);

            // 3. References (P2.3)
            let refs_ptr = codelite_lsp_find_references(ctx, lsp_file.as_ptr(), 0, 5, true);
            let refs_str = CStr::from_ptr(refs_ptr).to_str().unwrap();
            assert!(refs_str.contains("src/sample.rs"));
            codelite_string_free(refs_ptr as *mut c_char);

            // 4. Hover (P2.4)
            let hover_ptr = codelite_lsp_hover(ctx, lsp_file.as_ptr(), 0, 5);
            let hover_str = CStr::from_ptr(hover_ptr).to_str().unwrap();
            assert!(hover_str.contains("fn calc_value"));
            codelite_string_free(hover_ptr as *mut c_char);

            // 5. Completion (P2.5)
            let comp_ptr = codelite_lsp_completion(ctx, lsp_file.as_ptr(), 1, 20);
            let comp_str = CStr::from_ptr(comp_ptr).to_str().unwrap();
            assert!(comp_str.contains("calc_value"));
            codelite_string_free(comp_ptr as *mut c_char);

            // 6. Rename (P2.6)
            let new_name = CString::new("calculate").unwrap();
            let rename_ptr = codelite_lsp_rename(ctx, lsp_file.as_ptr(), 0, 5, new_name.as_ptr());
            let rename_str = CStr::from_ptr(rename_ptr).to_str().unwrap();
            assert!(rename_str.contains("calculate"));
            codelite_string_free(rename_ptr as *mut c_char);

            // 7. Incremental Sync (Phase 8.1)
            let inc_text = CString::new("100").unwrap();
            let inc_diags_ptr = codelite_lsp_did_change_incremental(
                ctx,
                lsp_file.as_ptr(),
                2,
                0, 25, 0, 27,
                inc_text.as_ptr(),
            );
            let inc_diags_str = CStr::from_ptr(inc_diags_ptr).to_str().unwrap();
            assert_eq!(inc_diags_str, "[]");
            codelite_string_free(inc_diags_ptr as *mut c_char);

            // 8. Server Capabilities (Phase 8.1)
            let caps_ptr = codelite_lsp_server_capabilities(ctx, lsp_lang.as_ptr());
            let caps_str = CStr::from_ptr(caps_ptr).to_str().unwrap();
            assert!(caps_str.contains("textDocumentSync"));
            codelite_string_free(caps_ptr as *mut c_char);

            // 9. Supervisor Status (Phase 8.1)
            let status_ptr = codelite_lsp_supervisor_status(ctx);
            let status_str = CStr::from_ptr(status_ptr).to_str().unwrap();
            assert!(status_str.contains("tracked_documents_count"));
            assert!(status_str.contains("rust"));
            codelite_string_free(status_ptr as *mut c_char);

            // Phase 4: Viewport Tokens, Workspace Search & Replace
            let p4_rel = "test_tmp_phase4.rs";
            let p4_full = (*ctx).workspace_root.join(p4_rel);
            let s_tag = format!("sym_{}", "phase4_target_uniq");
            let r_tag = format!("sym_{}", "phase4_replacement_uniq");
            std::fs::write(&p4_full, format!("fn {}() -> i32 {{ 42 }}\nfn main() {{ let x = {}(); }}\n", s_tag, s_tag)).unwrap();
            let p4_c = CString::new(p4_rel).unwrap();

            let vp_ptr = codelite_get_viewport_tokens(ctx, p4_c.as_ptr(), 0, 5);
            let vp_str = CStr::from_ptr(vp_ptr).to_str().unwrap();
            assert!(vp_str.contains("\"status\":\"ok\""));
            assert!(vp_str.contains("lines"));
            codelite_string_free(vp_ptr as *mut c_char);

            // Phase 4: Workspace Search
            let search_q = CString::new(s_tag.as_str()).unwrap();
            let search_opts = CString::new(r#"{"case_sensitive":false,"whole_word":true}"#).unwrap();
            let search_ptr = codelite_search_workspace(ctx, search_q.as_ptr(), search_opts.as_ptr());
            let search_str = CStr::from_ptr(search_ptr).to_str().unwrap();
            assert!(search_str.contains("\"status\":\"ok\""));
            assert!(search_str.contains(p4_rel));
            codelite_string_free(search_ptr as *mut c_char);

            // Phase 4: Workspace Replace
            let repl_target = CString::new(s_tag.as_str()).unwrap();
            let repl_value = CString::new(r_tag.as_str()).unwrap();
            let repl_ptr = codelite_replace_workspace(ctx, repl_target.as_ptr(), repl_value.as_ptr(), search_opts.as_ptr());
            let repl_str = CStr::from_ptr(repl_ptr).to_str().unwrap();
            assert!(repl_str.contains("\"status\":\"ok\""));
            assert!(repl_str.contains("\"replaced_count\":2"));
            codelite_string_free(repl_ptr as *mut c_char);

            let _ = std::fs::remove_file(&p4_full);

            // Phase 4: Terminal Execution
            let cmd = CString::new("sh").unwrap();
            let args = CString::new(r#"["-c", "echo hello_codelitex"]"#).unwrap();
            let term_ptr = codelite_terminal_exec(ctx, cmd.as_ptr(), args.as_ptr());
            let term_str = CStr::from_ptr(term_ptr).to_str().unwrap();
            assert!(term_str.contains("\"status\":\"ok\""));
            assert!(term_str.contains("hello_codelitex"));
            codelite_string_free(term_ptr as *mut c_char);

            // Destroy
            codelite_destroy(ctx);
        }
    }

    #[test]
    fn test_jsonrpc_call_all_methods() {
        unsafe {
            let temp_dir = std::env::temp_dir().join(format!("codelite-rpc-test-{}", uuid::Uuid::new_v4()));
            let _ = std::fs::create_dir_all(&temp_dir);
            let p_c = CString::new(temp_dir.to_str().unwrap()).unwrap();
            let ctx = codelite_init(p_c.as_ptr());
            assert!(!ctx.is_null());

            // 1. Test error handling: null context
            let req_ping = CString::new(r#"{"jsonrpc":"2.0","id":1,"method":"unknown.method"}"#).unwrap();
            let null_resp_ptr = codelite_jsonrpc_call(std::ptr::null_mut(), req_ping.as_ptr());
            let null_resp_str = CStr::from_ptr(null_resp_ptr).to_str().unwrap();
            assert!(null_resp_str.contains("-32603")); // INTERNAL_ERROR
            codelite_string_free(null_resp_ptr as *mut c_char);

            // 2. Test unknown method
            let unk_resp_ptr = codelite_jsonrpc_call(ctx, req_ping.as_ptr());
            let unk_resp_str = CStr::from_ptr(unk_resp_ptr).to_str().unwrap();
            assert!(unk_resp_str.contains("-32601")); // METHOD_NOT_FOUND
            codelite_string_free(unk_resp_ptr as *mut c_char);

            // 3. Test invalid json
            let invalid_json = CString::new("not valid json").unwrap();
            let bad_ptr = codelite_jsonrpc_call(ctx, invalid_json.as_ptr());
            let bad_str = CStr::from_ptr(bad_ptr).to_str().unwrap();
            assert!(bad_str.contains("-32700")); // PARSE_ERROR
            codelite_string_free(bad_ptr as *mut c_char);

            // 4. Test file.open
            let test_file = temp_dir.join("sample.rs");
            std::fs::write(&test_file, "fn main() {\n    println!(\"Hello\");\n}\n").unwrap();
            let open_req = CString::new(r#"{"jsonrpc":"2.0","id":2,"method":"file.open","params":{"path":"sample.rs"}}"#).unwrap();
            let open_ptr = codelite_jsonrpc_call(ctx, open_req.as_ptr());
            let open_str = CStr::from_ptr(open_ptr).to_str().unwrap();
            assert!(open_str.contains("\"result\":{"));
            assert!(open_str.contains("\"line_count\":4"));
            assert!(open_str.contains("println!"));
            codelite_string_free(open_ptr as *mut c_char);

            // 5. Test file.edit
            let edit_req = CString::new(r#"{"jsonrpc":"2.0","id":3,"method":"file.edit","params":{"path":"sample.rs","range":{"start_line":0,"start_col":0,"end_line":0,"end_col":0},"new_text":"// Added comment\n"}}"#).unwrap();
            let edit_ptr = codelite_jsonrpc_call(ctx, edit_req.as_ptr());
            let edit_str = CStr::from_ptr(edit_ptr).to_str().unwrap();
            assert!(edit_str.contains("\"success\":true"));
            codelite_string_free(edit_ptr as *mut c_char);

            // 6. Test file.undo
            let undo_req = CString::new(r#"{"jsonrpc":"2.0","id":4,"method":"file.undo","params":{"path":"sample.rs"}}"#).unwrap();
            let undo_ptr = codelite_jsonrpc_call(ctx, undo_req.as_ptr());
            let undo_str = CStr::from_ptr(undo_ptr).to_str().unwrap();
            assert!(undo_str.contains("\"success\":true"));
            codelite_string_free(undo_ptr as *mut c_char);

            // 7. Test file.redo
            let redo_req = CString::new(r#"{"jsonrpc":"2.0","id":5,"method":"file.redo","params":{"path":"sample.rs"}}"#).unwrap();
            let redo_ptr = codelite_jsonrpc_call(ctx, redo_req.as_ptr());
            let redo_str = CStr::from_ptr(redo_ptr).to_str().unwrap();
            assert!(redo_str.contains("\"success\":true"));
            codelite_string_free(redo_ptr as *mut c_char);

            // 8. Test lsp.completion & lsp.diagnostics
            let comp_req = CString::new(r#"{"jsonrpc":"2.0","id":6,"method":"lsp.completion","params":{"path":"sample.rs","line":1,"character":5}}"#).unwrap();
            let comp_ptr = codelite_jsonrpc_call(ctx, comp_req.as_ptr());
            let comp_str = CStr::from_ptr(comp_ptr).to_str().unwrap();
            assert!(comp_str.contains("\"items\":["));
            codelite_string_free(comp_ptr as *mut c_char);

            let diag_req = CString::new(r#"{"jsonrpc":"2.0","id":7,"method":"lsp.diagnostics","params":{"path":"sample.rs"}}"#).unwrap();
            let diag_ptr = codelite_jsonrpc_call(ctx, diag_req.as_ptr());
            let diag_str = CStr::from_ptr(diag_ptr).to_str().unwrap();
            assert!(diag_str.contains("\"diagnostics\":["));
            codelite_string_free(diag_ptr as *mut c_char);


            codelite_destroy(ctx);
            let _ = std::fs::remove_dir_all(&temp_dir);
        }
    }

    #[test]
    fn test_phase11_ffi_updater_flow() {
        unsafe {
            let temp_dir = std::env::temp_dir().join(format!("codelite_ffi_updater_test_{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)));
            std::fs::create_dir_all(&temp_dir).unwrap();
            let c_dir = CString::new(temp_dir.to_str().unwrap()).unwrap();
            let ctx = codelite_init(c_dir.as_ptr());
            assert!(!ctx.is_null());

            let cur_ver = CString::new("0.1.0").unwrap();
            let manifest_str = r#"{
                "version": "0.2.0",
                "release_date": "2026-09-10",
                "release_notes": "Phase 11: Cross-platform release",
                "platforms": {
                    "macos": {
                        "strategy": "app_bundle_delta",
                        "artifacts": [
                            {
                                "target_name": "CodeLiteX.app.zip",
                                "target_path": ".",
                                "url": "https://releases.codelitex.org/macos/CodeLiteX-0.2.0.zip",
                                "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                "size_bytes": 10485760
                            }
                        ]
                    },
                    "linux": {
                        "strategy": "component_delta",
                        "artifacts": [
                            {
                                "target_name": "libcodelite.so",
                                "target_path": "lib/libcodelite.so",
                                "url": "https://releases.codelitex.org/linux/libcodelite.so",
                                "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                "size_bytes": 7340032
                            }
                        ]
                    }
                }
            }"#;
            let manifest_c = CString::new(manifest_str).unwrap();
            let plat_macos = CString::new("macos").unwrap();
            let plat_linux = CString::new("linux").unwrap();

            // 1. Check update (macOS)
            let check_ptr = codelite_updater_check(ctx, cur_ver.as_ptr(), manifest_c.as_ptr(), plat_macos.as_ptr());
            let check_str = CStr::from_ptr(check_ptr).to_str().unwrap();
            assert!(check_str.contains("\"status\":\"ok\""));
            assert!(check_str.contains("\"has_update\":true"));
            assert!(check_str.contains("\"app_bundle_delta\""));
            codelite_string_free(check_ptr as *mut c_char);

            // 2. Stage artifact
            let stage_dir = temp_dir.join("staging");
            let stage_dir_c = CString::new(stage_dir.to_str().unwrap()).unwrap();
            let file_name_c = CString::new("libcodelite.so").unwrap();
            let content_c = CString::new("abc").unwrap();
            let sha_c = CString::new("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad").unwrap();

            let stage_ptr = codelite_updater_stage(ctx, stage_dir_c.as_ptr(), file_name_c.as_ptr(), content_c.as_ptr(), sha_c.as_ptr());
            let stage_str = CStr::from_ptr(stage_ptr).to_str().unwrap();
            assert!(stage_str.contains("\"status\":\"ok\""));
            assert!(stage_str.contains("libcodelite.so"));
            codelite_string_free(stage_ptr as *mut c_char);

            // 3. Apply Linux component delta
            let install_dir = temp_dir.join("install");
            let install_dir_c = CString::new(install_dir.to_str().unwrap()).unwrap();
            let files_c = CString::new("[\"libcodelite.so\"]").unwrap();

            let apply_ptr = codelite_updater_apply(ctx, stage_dir_c.as_ptr(), install_dir_c.as_ptr(), files_c.as_ptr(), plat_linux.as_ptr());
            let apply_str = CStr::from_ptr(apply_ptr).to_str().unwrap();
            assert!(apply_str.contains("\"status\":\"ok\""));
            assert!(apply_str.contains("\"component_delta\""));
            codelite_string_free(apply_ptr as *mut c_char);

            codelite_destroy(ctx);
            let _ = std::fs::remove_dir_all(&temp_dir);
        }
    }
}
