//! # code-lite-ffi
//!
//! C-ABI dynamic library bindings (`libcodelite.dylib` / `libcodelite.so` / `codelite.dll`)
//! for CodeLiteX, exposing Rust Core capabilities to the Flutter UI Shell.

use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;


/// Rust Core 剩下的上下文:编辑器内核、Git、搜索、LSP 都已迁到 Dart,
/// 这里只剩终端(PTY)。
pub struct CodeLiteContext {
    pub workspace_root: PathBuf,
    /// 用户终端会话。随上下文销毁一起杀掉 shell(切换项目即关闭旧项目的终端)。
    pub terminals: code_lite_terminal::TerminalManager,
    /// 项目文件索引(按根目录;Go to File 用)。随上下文一起释放。
    pub indexes: std::sync::Mutex<std::collections::HashMap<String, std::sync::Arc<code_lite_fs::file_index::FileIndex>>>,
}

impl CodeLiteContext {
    /// [root] 的文件索引;第一次要时建一个并在后台开始扫。
    fn index(&self, root: &str) -> std::sync::Arc<code_lite_fs::file_index::FileIndex> {
        let mut map = self.indexes.lock().unwrap();
        if let Some(i) = map.get(root) {
            return i.clone();
        }
        let i = code_lite_fs::file_index::FileIndex::new(root);
        i.refresh();
        map.insert(root.to_string(), i.clone());
        i
    }
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

    // 纯内存上下文:不再在工作区下创建 .codelite/workspace.db(图谱与 LSP 缓存已移除)
    let ctx = Box::new(CodeLiteContext {
        workspace_root: PathBuf::from(path_str),
        terminals: code_lite_terminal::TerminalManager::new(),
        indexes: Default::default(),
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

// ---------------------------------------------------------------------------
// 2. Terminal
// ---------------------------------------------------------------------------

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

/// 在后台(重新)扫 [root] 的文件清单(打开 Go to File 时调,让清单跟上磁盘)。建好之前查询用旧清单。
#[no_mangle]
pub unsafe extern "C" fn codelite_index_refresh(ctx: *mut CodeLiteContext, root: *const c_char) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let Some(root) = c_str_to_str(root) else { return err_json("Invalid root") };
    (*ctx).index(root).refresh();
    json_to_c_char(&serde_json::json!({ "status": "ok" }))
}

/// 按文件名模糊查找(见 `code_lite_fs::file_index`):返回前 [limit] 个,带匹配字符的下标(UTF-16)。
/// 很快(几千个文件 < 1 ms,两万个 < 3 ms),界面线程直接调。清单还没建好时 `ready: false`。
#[no_mangle]
pub unsafe extern "C" fn codelite_index_query(
    ctx: *mut CodeLiteContext,
    root: *const c_char,
    query: *const c_char,
    limit: u32,
) -> *const c_char {
    if ctx.is_null() {
        return err_json("Context is null");
    }
    let (Some(root), Some(query)) = (c_str_to_str(root), c_str_to_str(query)) else { return err_json("Invalid argument") };
    json_to_c_char(&(*ctx).index(root).query(query, limit as usize))
}

/// 全局搜索 / 替换(见 `code_lite_fs::project_search`)。
/// 请求:`{"op":"search"|"replace","root","query","replacement","options":{...}}`;返回结果 JSON,用 [codelite_string_free] 释放。
/// 不用上下文、不碰共享状态,可以在任意线程(Dart 的后台 isolate)里调;内部用多线程并行。
#[no_mangle]
pub unsafe extern "C" fn codelite_search(request: *const c_char) -> *const c_char {
    let Some(req) = c_str_to_str(request) else { return err_json("Invalid request") };
    json_to_c_char(&code_lite_fs::project_search::handle(req))
}

/// 二进制画面帧(格式见 `code_lite_terminal::encode_frame`):和上一帧比只带变了的行。
/// 长度写进 `out_len`;返回的缓冲用 [codelite_bytes_free] 还回来。会话不存在时返回空指针。
#[no_mangle]
pub unsafe extern "C" fn codelite_pty_frame(
    ctx: *mut CodeLiteContext,
    id: *const c_char,
    since_seq: i64,
    scrollback: u32,
    out_len: *mut usize,
) -> *mut u8 {
    if !out_len.is_null() {
        *out_len = 0;
    }
    if ctx.is_null() || out_len.is_null() {
        return std::ptr::null_mut();
    }
    let Some(id) = c_str_to_str(id) else { return std::ptr::null_mut() };
    let Some(s) = (*ctx).terminals.get(id) else { return std::ptr::null_mut() };
    let since = if since_seq < 0 { None } else { Some(since_seq as u64) };
    let boxed = s.frame(since, scrollback as usize).into_boxed_slice();
    *out_len = boxed.len();
    Box::into_raw(boxed) as *mut u8
}

/// 释放 Rust 返回的字节缓冲(`codelite_pty_frame` 等),`len` 是当时拿到的长度。
#[no_mangle]
pub unsafe extern "C" fn codelite_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
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
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn test_ffi_lifecycle_and_terminal_exec() {
        unsafe {
            let root = CString::new(".").unwrap();
            let ctx = codelite_init(root.as_ptr());
            assert!(!ctx.is_null());

            let ver_ptr = codelite_version();
            assert_eq!(CStr::from_ptr(ver_ptr).to_str().unwrap(), "0.1.0");
            codelite_string_free(ver_ptr as *mut c_char);

            let cmd = CString::new("sh").unwrap();
            let args = CString::new(r#"["-c", "echo hello_codelitex"]"#).unwrap();
            let term_ptr = codelite_terminal_exec(ctx, cmd.as_ptr(), args.as_ptr());
            let term_str = CStr::from_ptr(term_ptr).to_str().unwrap();
            assert!(term_str.contains("\"status\":\"ok\""));
            assert!(term_str.contains("hello_codelitex"));
            codelite_string_free(term_ptr as *mut c_char);

            codelite_destroy(ctx);
        }
    }
}
