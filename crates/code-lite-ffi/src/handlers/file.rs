use crate::generated::types::{
    FileContent, FileEditParams, FileEditResult, FileOpenParams, FileRedoParams, FileUndoParams,
    UndoRedoResult,
};
use crate::CodeLiteContext;
use code_lite_core::Editor;
use std::path::Path;

pub fn handle_open(ctx: *mut CodeLiteContext, params: FileOpenParams) -> Result<FileContent, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let full_path = if Path::new(&params.path).is_absolute() {
        std::path::PathBuf::from(&params.path)
    } else {
        ctx.workspace_root.join(&params.path)
    };

    let content = std::fs::read_to_string(&full_path)
        .map_err(|e| format!("Failed to read file '{}': {}", params.path, e))?;

    let mut editors = ctx.editors.lock();
    let mut editor = Editor::from_str(&content);
    editor.mark_saved();
    let line_count = editor.buffer().len_lines() as i64;
    editors.insert(params.path.clone(), editor);

    let _ = ctx.event_store.log(
        None,
        "FileOpened",
        &serde_json::json!({ "path": params.path, "source": "jsonrpc" }),
    );

    Ok(FileContent {
        path: params.path,
        content,
        line_count,
        version: 1,
    })
}

pub fn handle_edit(ctx: *mut CodeLiteContext, params: FileEditParams) -> Result<FileEditResult, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let mut editors = ctx.editors.lock();
    let editor = editors
        .get_mut(&params.path)
        .ok_or_else(|| format!("File not open in editor: {}", params.path))?;

    editor.insert_text(&params.new_text);
    let content = editor.text();
    let version = editor.buffer().len_lines() as i64;
    drop(editors);

    let _ = ctx.graph_engine.index_file(&params.path, &content);

    let diag_count = {
        let guard = ctx.lsp_client.lock();
        if let Some(client) = guard.as_ref() {
            client.get_diagnostics(&params.path).len() as i64
        } else {
            0
        }
    };

    Ok(FileEditResult {
        success: true,
        version,
        diagnostics_count: diag_count,
    })
}

pub fn handle_undo(ctx: *mut CodeLiteContext, params: FileUndoParams) -> Result<UndoRedoResult, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let mut editors = ctx.editors.lock();
    let editor = editors
        .get_mut(&params.path)
        .ok_or_else(|| format!("File not open in editor: {}", params.path))?;

    let success = editor.undo();
    let content = editor.text();
    let version = editor.buffer().len_lines() as i64;

    Ok(UndoRedoResult {
        success,
        version,
        content,
    })
}

pub fn handle_redo(ctx: *mut CodeLiteContext, params: FileRedoParams) -> Result<UndoRedoResult, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let mut editors = ctx.editors.lock();
    let editor = editors
        .get_mut(&params.path)
        .ok_or_else(|| format!("File not open in editor: {}", params.path))?;

    let success = editor.redo();
    let content = editor.text();
    let version = editor.buffer().len_lines() as i64;

    Ok(UndoRedoResult {
        success,
        version,
        content,
    })
}
