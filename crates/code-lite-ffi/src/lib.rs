//! # code-lite-ffi
//!
//! C-ABI dynamic library bindings (`libcodelite.dylib` / `libcodelite.so` / `codelite.dll`)
//! for CodeLiteX, exposing Rust Core capabilities to the Flutter UI Shell.

use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;


/// Rust Core 剩下的上下文:编辑器内核、Git、搜索、LSP 都已迁到 Dart,
/// 这里只剩终端(PTY)与自动更新,随 Dart 迁移继续收缩。
pub struct CodeLiteContext {
    pub workspace_root: PathBuf,
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

    // 纯内存上下文:不再在工作区下创建 .codelite/workspace.db(图谱与 LSP 缓存已移除)
    let ctx = Box::new(CodeLiteContext {
        workspace_root: PathBuf::from(path_str),
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
