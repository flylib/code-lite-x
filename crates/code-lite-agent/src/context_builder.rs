use code_lite_graph::CodeGraph;
use code_lite_lsp::{DiagnosticSeverity, LspClient};
use std::sync::Arc;

/// AgentContextBuilder unifies CodeGraph semantic topology and LSP diagnostics
/// into a high-density, token-efficient context prompt for the AI Agent.
#[derive(Clone)]
pub struct AgentContextBuilder {
    graph: Option<Arc<dyn CodeGraph + Send + Sync>>,
    lsp: Option<Arc<LspClient>>,
}

impl AgentContextBuilder {
    pub fn new(
        graph: Option<Arc<dyn CodeGraph + Send + Sync>>,
        lsp: Option<Arc<LspClient>>,
    ) -> Self {
        Self { graph, lsp }
    }

    /// Generates a concise context block for a specific symbol including AST definition,
    /// caller hierarchy, and callees.
    pub fn build_symbol_context(&self, symbol_name_or_key: &str) -> Option<String> {
        let graph = self.graph.as_ref()?;
        let ctx = graph.get_code_context(symbol_name_or_key).ok()??;

        let mut output = String::new();
        output.push_str(&format!("### Symbol: {} ({})\n", ctx.name, ctx.kind));
        output.push_str(&format!("File: {}:{}-{}\n", ctx.file_path, ctx.line_start, ctx.line_end));
        if let Some(sig) = &ctx.signature {
            output.push_str(&format!("Signature: `{}`\n", sig));
        }

        output.push_str("\n#### Definition Slice:\n```rust\n");
        output.push_str(&ctx.definition_code);
        output.push_str("\n```\n");

        if !ctx.callers.is_empty() {
            output.push_str("\n#### Callers (Upstream Dependents):\n");
            for c in &ctx.callers {
                output.push_str(&format!("- `{}`\n", c));
            }
        }

        if !ctx.callees.is_empty() {
            output.push_str("\n#### Callees (Downstream Invocations):\n");
            for c in &ctx.callees {
                output.push_str(&format!("- `{}`\n", c));
            }
        }

        if !ctx.references.is_empty() {
            output.push_str("\n#### References Count: ");
            output.push_str(&format!("{}\n", ctx.references.len()));
        }

        Some(output)
    }

    /// Extracts active compilation errors and warnings for a file via LSP.
    pub fn build_file_diagnostics(&self, file_uri_or_path: &str) -> Vec<String> {
        let lsp = match &self.lsp {
            Some(client) => client,
            None => return Vec::new(),
        };

        let uri = if file_uri_or_path.starts_with("file://") {
            file_uri_or_path.to_string()
        } else {
            format!("file://{}", file_uri_or_path)
        };

        let diags = lsp.get_diagnostics(&uri);
        diags
            .into_iter()
            .map(|d| {
                let sev = match d.severity {
                    Some(DiagnosticSeverity::Error) => "[ERROR]",
                    Some(DiagnosticSeverity::Warning) => "[WARN]",
                    Some(DiagnosticSeverity::Information) => "[INFO]",
                    Some(DiagnosticSeverity::Hint) => "[HINT]",
                    None => "[DIAG]",
                };
                format!(
                    "{} L{}:{}: {}",
                    sev,
                    d.range.start.line + 1,
                    d.range.start.character + 1,
                    d.message
                )
            })
            .collect()
    }

    /// Builds a full context prompt injecting symbol knowledge and current diagnostics.
    pub fn build_prompt_context(
        &self,
        focus_file: Option<&str>,
        focus_symbol: Option<&str>,
    ) -> String {
        let mut sections = Vec::new();

        if let Some(sym) = focus_symbol {
            if let Some(sym_ctx) = self.build_symbol_context(sym) {
                sections.push(sym_ctx);
            }
        }

        if let Some(file) = focus_file {
            let diags = self.build_file_diagnostics(file);
            if !diags.is_empty() {
                let mut d_sec = format!("### Active LSP Diagnostics for `{}`:\n", file);
                for d in diags {
                    d_sec.push_str(&format!("- {}\n", d));
                }
                sections.push(d_sec);
            }
        }

        if sections.is_empty() {
            "No specific code context loaded.".to_string()
        } else {
            sections.join("\n---\n")
        }
    }
}
