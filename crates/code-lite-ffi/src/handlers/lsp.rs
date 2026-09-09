use crate::generated::types::{
    CompletionItem, CompletionList, DiagnosticItem, DiagnosticList, LspCompletionParams,
    LspDiagnosticsParams,
};
use crate::CodeLiteContext;

pub fn handle_completion(
    ctx: *mut CodeLiteContext,
    params: LspCompletionParams,
) -> Result<CompletionList, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        match client.completion(&params.path, params.line as u32, params.character as u32) {
            Ok(items) => {
                let mapped = items
                    .into_iter()
                    .map(|item| CompletionItem {
                        label: item.label,
                        kind: format!(
                            "{:?}",
                            item.kind
                                .unwrap_or(code_lite_lsp::protocol::CompletionItemKind::Text)
                        ),
                        detail: item.detail.unwrap_or_default(),
                        insert_text: item.insert_text.unwrap_or_default(),
                    })
                    .collect();
                Ok(CompletionList { items: mapped })
            }
            Err(e) => Err(format!("Completion failed: {}", e)),
        }
    } else {
        Ok(CompletionList { items: vec![] })
    }
}

pub fn handle_diagnostics(
    ctx: *mut CodeLiteContext,
    params: LspDiagnosticsParams,
) -> Result<DiagnosticList, String> {
    if ctx.is_null() {
        return Err("Context is null".into());
    }
    let ctx = unsafe { &*ctx };

    let mut items = Vec::new();

    let guard = ctx.lsp_client.lock();
    if let Some(client) = guard.as_ref() {
        for diag in client.get_diagnostics(&params.path) {
            items.push(DiagnosticItem {
                line: diag.range.start.line as i64,
                start_col: diag.range.start.character as i64,
                end_col: diag.range.end.character as i64,
                severity: format!(
                    "{:?}",
                    diag.severity
                        .unwrap_or(code_lite_lsp::protocol::DiagnosticSeverity::Information)
                ),
                message: diag.message,
            });
        }
    }

    if items.is_empty() {
        if let Ok(records) = ctx.diagnostic_store.get_diagnostics_by_file(&params.path) {
            for r in records {
                let sev_str = match r.severity {
                    1 => "Error",
                    2 => "Warning",
                    3 => "Information",
                    _ => "Hint",
                };
                items.push(DiagnosticItem {
                    line: r.line_start as i64,
                    start_col: r.col_start as i64,
                    end_col: r.col_end as i64,
                    severity: sev_str.into(),
                    message: r.message,
                });
            }
        }
    }

    Ok(DiagnosticList { diagnostics: items })
}
