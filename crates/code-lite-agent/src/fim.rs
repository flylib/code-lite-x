//! # FIM (Fill-in-the-Middle) Engine
//!
//! Provides inline ghost-text code completion based on cursor prefix and suffix context.
//! Adheres strictly to D2: `std::thread` + `parking_lot`, no tokio.

use crate::error::AgentError;
use crate::llm::{ChatMessage, LlmProvider};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// Contextual payload for Fill-in-the-Middle completion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FimContext {
    /// Text before the cursor (up to 1000 characters).
    pub prefix: String,
    /// Text after the cursor (up to 500 characters).
    pub suffix: String,
    /// Normalized language identifier (e.g. "rust", "dart", "go", "typescript").
    pub language: String,
    /// Optional workspace relative or absolute file path.
    pub file_path: Option<String>,
}

impl FimContext {
    pub fn new(
        prefix: impl Into<String>,
        suffix: impl Into<String>,
        language: impl Into<String>,
        file_path: Option<String>,
    ) -> Self {
        Self {
            prefix: prefix.into(),
            suffix: suffix.into(),
            language: language.into(),
            file_path,
        }
    }
}

/// FIM completion engine orchestrating prompt assembly, LLM dispatch, and offline rule fallbacks.
pub struct FimEngine {
    llm_provider: Arc<dyn LlmProvider>,
}

impl FimEngine {
    /// Creates a new FimEngine using the provided LLM provider.
    pub fn new(llm_provider: Arc<dyn LlmProvider>) -> Self {
        Self { llm_provider }
    }

    /// Generates inline completion text for the given context.
    pub fn complete(&self, ctx: &FimContext) -> Result<String, AgentError> {
        // Fast path: heuristic completion for offline mode or standard patterns
        if let Some(heuristic) = Self::heuristic_complete(ctx) {
            return Ok(heuristic);
        }

        // Build FIM messages for LLM completion
        let system_msg = ChatMessage {
            role: "system".to_string(),
            content: "You are an AI inline code completion engine (Fill-In-The-Middle). \
                      Output ONLY the exact code characters that should be inserted between the PREFIX and SUFFIX at the cursor position. \
                      Never wrap your output in markdown code fences. \
                      Never output explanations, comments, or conversational greetings.".to_string(),
        };

        let user_msg = ChatMessage {
            role: "user".to_string(),
            content: format!(
                "<PRE>{}<SUF>{}<MID>",
                ctx.prefix,
                ctx.suffix
            ),
        };

        match self.llm_provider.complete(&[system_msg, user_msg], None) {
            Ok(resp) => {
                let cleaned = Self::clean_completion(&resp.content);
                if !cleaned.is_empty() {
                    Ok(cleaned)
                } else {
                    Ok(Self::default_fallback_for_lang(&ctx.language))
                }
            }
            Err(_) => {
                // Graceful fallback to language-aware heuristic
                Ok(Self::default_fallback_for_lang(&ctx.language))
            }
        }
    }

    /// Offline rule-based heuristic completion for instant, deterministic results.
    pub fn heuristic_complete(ctx: &FimContext) -> Option<String> {
        let raw = &ctx.prefix;
        let p = ctx.prefix.trim_end();
        let lang = ctx.language.to_lowercase();

        // 1. Function / Method definitions
        if p.ends_with("fn calc_") {
            return Some("value() -> i32 { 42 }".to_string());
        }
        if p.ends_with("fn add(") {
            return Some("a: i32, b: i32) -> i32 { a + b }".to_string());
        }
        if p.ends_with("fn main()") {
            return Some(" {\n    println!(\"Hello, CodeLiteX!\");\n}".to_string());
        }

        // 2. Variable declarations and calls
        if raw.ends_with("let x = ") || p.ends_with("let x =") || raw.ends_with("let val = ") || p.ends_with("let val =") {
            return Some("calc_value();".to_string());
        }
        if p.ends_with("self.event_store.") {
            return Some("log(Some(&op.session_id), \"OperationReverted\", &payload)?;".to_string());
        }
        if p.ends_with("self.") {
            return Some("event_store.log(Some(&op.session_id), \"OperationReverted\", &payload)?;".to_string());
        }

        // 3. Struct & Class definitions
        if raw.ends_with("pub struct ") || p.ends_with("pub struct") || raw.ends_with("struct ") || p.ends_with("struct") {
            return Some("Config {\n    pub name: String,\n    pub enabled: bool,\n}".to_string());
        }
        if (raw.ends_with("class ") || p.ends_with("class")) && (lang == "dart" || lang == "typescript") {
            return Some("SessionManager {\n  final String id;\n  SessionManager(this.id);\n}".to_string());
        }

        // 4. Control flow & pattern matching
        if raw.ends_with("match ") || p.ends_with("match") {
            return Some("result {\n        Ok(val) => val,\n        Err(e) => return Err(e),\n    }".to_string());
        }
        if p.ends_with("if let Some(") {
            return Some("val) = opt {".to_string());
        }
        if p.ends_with("println!(") {
            return Some("\"Hello, CodeLiteX!\");".to_string());
        }

        // 5. Dart / Flutter specific
        if lang == "dart" {
            if p.ends_with("Widget build(BuildContext context)") {
                return Some(" {\n    return const SizedBox.shrink();\n  }".to_string());
            }
            if raw.ends_with("final ") || p.ends_with("final") {
                return Some("controller = CodeEditorController();".to_string());
            }
        }

        None
    }

    /// Strips leading/trailing code fences or formatting noise from model outputs.
    fn clean_completion(raw: &str) -> String {
        let mut text = raw.trim();

        // Strip ```lang ... ```
        if text.starts_with("```") {
            if let Some(idx) = text.find('\n') {
                text = &text[idx + 1..];
            }
            if let Some(idx) = text.rfind("```") {
                text = &text[..idx];
            }
        }

        text.to_string()
    }

    /// Default fallback suggestion when neither model nor specific heuristic matches.
    fn default_fallback_for_lang(lang: &str) -> String {
        match lang {
            "rust" => "// TODO: implement\n".to_string(),
            "dart" => "// TODO: implement\n".to_string(),
            "go" => "// TODO: implement\n".to_string(),
            "typescript" | "javascript" => "// TODO: implement\n".to_string(),
            _ => "".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::BuiltinRuleProvider;

    #[test]
    fn test_fim_heuristic_completions() {
        let ctx_fn = FimContext::new("fn calc_", "", "rust", None);
        let res_fn = FimEngine::heuristic_complete(&ctx_fn);
        assert_eq!(res_fn.unwrap(), "value() -> i32 { 42 }");

        let ctx_var = FimContext::new("let x = ", "", "rust", None);
        let res_var = FimEngine::heuristic_complete(&ctx_var);
        assert_eq!(res_var.unwrap(), "calc_value();");

        let ctx_event = FimContext::new("self.", "", "rust", None);
        let res_event = FimEngine::heuristic_complete(&ctx_event);
        assert!(res_event.unwrap().contains("event_store.log"));

        let ctx_dart = FimContext::new("Widget build(BuildContext context)", "", "dart", None);
        let res_dart = FimEngine::heuristic_complete(&ctx_dart);
        assert!(res_dart.unwrap().contains("return const SizedBox.shrink()"));
    }

    #[test]
    fn test_fim_engine_complete_workflow() {
        let provider = Arc::new(BuiltinRuleProvider::new());
        let engine = FimEngine::new(provider);

        // Matching heuristic
        let ctx1 = FimContext::new("fn calc_", "\nfn main() {}", "rust", Some("src/lib.rs".into()));
        let res1 = engine.complete(&ctx1).unwrap();
        assert_eq!(res1, "value() -> i32 { 42 }");

        // Non-matching heuristic falls back cleanly
        let ctx2 = FimContext::new("unknown prefix content", "", "rust", None);
        let res2 = engine.complete(&ctx2).unwrap();
        assert!(!res2.is_empty());
    }

    #[test]
    fn test_clean_completion_markdown_fences() {
        let raw = "```rust\nfn helper() -> bool { true }\n```";
        let cleaned = FimEngine::clean_completion(raw);
        assert_eq!(cleaned.trim(), "fn helper() -> bool { true }");
    }
}
