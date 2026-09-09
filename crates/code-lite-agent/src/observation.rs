use serde::{Deserialize, Serialize};

/// Unified Observation recording the outcome, output, error, and diagnostics of a Plan step.
/// Enables the cognitive closed loop where failure observations feedback into LLM re-planning.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Observation {
    pub step_id: String,
    pub tool_name: String,
    pub success: bool,
    pub output: Option<String>,
    pub error: Option<String>,
    pub lsp_diagnostics: Vec<code_lite_lsp::Diagnostic>,
}

impl Observation {
    pub fn new_success(step_id: &str, tool_name: &str, output: &str) -> Self {
        Self {
            step_id: step_id.to_string(),
            tool_name: tool_name.to_string(),
            success: true,
            output: Some(output.to_string()),
            error: None,
            lsp_diagnostics: Vec::new(),
        }
    }

    pub fn new_failure(
        step_id: &str,
        tool_name: &str,
        error: &str,
        diagnostics: Vec<code_lite_lsp::Diagnostic>,
    ) -> Self {
        Self {
            step_id: step_id.to_string(),
            tool_name: tool_name.to_string(),
            success: false,
            output: None,
            error: Some(error.to_string()),
            lsp_diagnostics: diagnostics,
        }
    }

    /// Formats the observation as a structured diagnostic reflection prompt for LLM self-healing.
    pub fn format_for_reflection(&self) -> String {
        let mut msg = format!(
            "Failed step `{}` using tool `{}`:\nError: {}\n",
            self.step_id,
            self.tool_name,
            self.error.as_deref().unwrap_or("Execution error")
        );
        if !self.lsp_diagnostics.is_empty() {
            msg.push_str("LSP Compiler / Type Diagnostics:\n");
            for d in &self.lsp_diagnostics {
                msg.push_str(&format!(
                    " - Line {}:{}: {}\n",
                    d.range.start.line + 1,
                    d.range.start.character + 1,
                    d.message
                ));
            }
        }
        msg
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_lite_lsp::{Diagnostic, DiagnosticSeverity, Position, Range};

    #[test]
    fn test_observation_format_reflection() {
        let diag = Diagnostic {
            range: Range {
                start: Position { line: 10, character: 4 },
                end: Position { line: 10, character: 15 },
            },
            severity: Some(DiagnosticSeverity::Error),
            code: None,
            source: Some("rustc".into()),
            message: "cannot find value `unknown_var` in this scope".into(),
            related_information: None,
        };

        let obs = Observation::new_failure(
            "step_2",
            "apply_patch",
            "LSP diagnostics returned 1 error",
            vec![diag],
        );

        let reflection = obs.format_for_reflection();
        assert!(reflection.contains("Failed step `step_2`"));
        assert!(reflection.contains("cannot find value `unknown_var`"));
        assert!(reflection.contains("Line 11:5"));
    }
}
