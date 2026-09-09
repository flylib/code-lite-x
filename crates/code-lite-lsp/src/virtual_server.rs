//! # Virtual LSP Server
//!
//! Provides a resilient, standalone in-process Language Server implementation
//! powered by Rust AST analysis (`syn`) and `CodeGraph`.
//!
//! Serves as both:
//! 1. A reliable, zero-external-dependency fallback when external LSP servers
//!    (`rust-analyzer`) are absent or offline.
//! 2. A high-fidelity test double for deterministic unit and integration tests.

use crate::protocol::*;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Clone)]
pub struct VirtualLspServer {
    /// In-memory open document cache (URI -> Content).
    documents: Arc<Mutex<HashMap<String, String>>>,
    /// Optional attached SQLite DiagnosticStore for persistent error logging.
    diag_store: Option<code_lite_storage::DiagnosticStore>,
}

impl VirtualLspServer {
    pub fn new() -> Self {
        Self {
            documents: Arc::new(Mutex::new(HashMap::new())),
            diag_store: None,
        }
    }

    pub fn with_diagnostic_store(mut self, store: code_lite_storage::DiagnosticStore) -> Self {
        self.diag_store = Some(store);
        self
    }

    // -----------------------------------------------------------------------
    // P2.1 Diagnostics: Real-time syntax & compile checking
    // -----------------------------------------------------------------------

    /// Analyzes document content and computes diagnostics.
    pub fn compute_diagnostics(&self, uri: &str, content: &str) -> Vec<Diagnostic> {
        let mut diags = Vec::new();

        // 1. Rust syntax validation using syn
        if uri.ends_with(".rs") {
            if let Err(syn_err) = syn::parse_file(content) {
                let span = syn_err.span();
                let start_line = span.start().line.saturating_sub(1) as u32;
                let start_col = span.start().column as u32;
                let end_line = span.end().line.saturating_sub(1) as u32;
                let end_col = (span.end().column as u32).max(start_col + 1);

                diags.push(Diagnostic {
                    range: Range::new(start_line, start_col, end_line, end_col),
                    severity: Some(DiagnosticSeverity::Error),
                    code: Some("rustc_syntax_err".to_string()),
                    source: Some("rustc".to_string()),
                    message: syn_err.to_string(),
                    related_information: None,
                });
            }
        }

        // 2. Unbalanced brackets check as general secondary diagnostic
        let mut stack = Vec::new();
        for (line_idx, line) in content.lines().enumerate() {
            for (col_idx, ch) in line.chars().enumerate() {
                match ch {
                    '{' | '(' | '[' => stack.push((ch, line_idx as u32, col_idx as u32)),
                    '}' | ')' | ']' => {
                        let expected = match ch {
                            '}' => '{',
                            ')' => '(',
                            ']' => '[',
                            _ => ' ',
                        };
                        if let Some((top, _, _)) = stack.pop() {
                            if top != expected {
                                diags.push(Diagnostic {
                                    range: Range::single_line(line_idx as u32, col_idx as u32, col_idx as u32 + 1),
                                    severity: Some(DiagnosticSeverity::Error),
                                    code: Some("bracket_mismatch".to_string()),
                                    source: Some("syntax".to_string()),
                                    message: format!("Mismatched closing bracket '{}', expected match for '{}'", ch, top),
                                    related_information: None,
                                });
                            }
                        } else {
                            diags.push(Diagnostic {
                                range: Range::single_line(line_idx as u32, col_idx as u32, col_idx as u32 + 1),
                                severity: Some(DiagnosticSeverity::Error),
                                code: Some("unmatched_bracket".to_string()),
                                source: Some("syntax".to_string()),
                                message: format!("Unmatched closing bracket '{}'", ch),
                                related_information: None,
                            });
                        }
                    }
                    _ => {}
                }
            }
        }

        // 3. Persist to SQLite if DiagnosticStore is attached
        if let Some(store) = &self.diag_store {
            let records: Vec<code_lite_storage::NewDiagnostic> = diags
                .iter()
                .map(|d| code_lite_storage::NewDiagnostic {
                    file_path: uri.to_string(),
                    severity: d.severity.map(|s| s as i32).unwrap_or(1),
                    line_start: d.range.start.line as usize,
                    col_start: d.range.start.character as usize,
                    line_end: d.range.end.line as usize,
                    col_end: d.range.end.character as usize,
                    code: d.code.clone(),
                    source: d.source.clone(),
                    message: d.message.clone(),
                })
                .collect();
            let _ = store.replace_file_diagnostics(uri, &records);
        }

        diags
    }

    // -----------------------------------------------------------------------
    // P2.2 Definition: Go to Definition
    // -----------------------------------------------------------------------

    pub fn definition(&self, uri: &str, pos: Position) -> Vec<Location> {
        let docs = self.documents.lock();
        let content = match docs.get(uri) {
            Some(c) => c,
            None => return Vec::new(),
        };

        let word = match extract_word_at_pos(content, pos) {
            Some(w) => w,
            None => return Vec::new(),
        };

        let mut results = Vec::new();

        // Search for definition patterns: `fn word`, `struct word`, `enum word`, `let mut word`, `let word`
        for (idx, line) in content.lines().enumerate() {
            let patterns = [
                format!("fn {}", word),
                format!("struct {}", word),
                format!("enum {}", word),
                format!("trait {}", word),
                format!("type {}", word),
                format!("let {} ", word),
                format!("let mut {} ", word),
            ];

            for p in &patterns {
                if let Some(col_offset) = line.find(p) {
                    let word_offset = line[col_offset..].find(&word).unwrap_or(0);
                    let col_start = (col_offset + word_offset) as u32;
                    let col_end = col_start + word.len() as u32;

                    results.push(Location::new(
                        uri,
                        Range::single_line(idx as u32, col_start, col_end),
                    ));
                    break;
                }
            }
        }

        results
    }

    // -----------------------------------------------------------------------
    // P2.3 References: Find All References
    // -----------------------------------------------------------------------

    pub fn references(&self, uri: &str, pos: Position, _include_decl: bool) -> Vec<Location> {
        let docs = self.documents.lock();
        let content = match docs.get(uri) {
            Some(c) => c,
            None => return Vec::new(),
        };

        let word = match extract_word_at_pos(content, pos) {
            Some(w) => w,
            None => return Vec::new(),
        };

        let mut results = Vec::new();

        // Find all occurrences across all opened documents
        for (doc_uri, doc_content) in docs.iter() {
            for (line_idx, line) in doc_content.lines().enumerate() {
                let mut start_search = 0;
                while let Some(found_idx) = line[start_search..].find(&word) {
                    let actual_col = start_search + found_idx;
                    // Ensure full word boundary
                    let is_left_bound = actual_col == 0
                        || !line.chars().nth(actual_col - 1).unwrap_or(' ').is_alphanumeric()
                            && line.chars().nth(actual_col - 1).unwrap_or(' ') != '_';
                    let is_right_bound = (actual_col + word.len()) >= line.len()
                        || !line.chars().nth(actual_col + word.len()).unwrap_or(' ').is_alphanumeric()
                            && line.chars().nth(actual_col + word.len()).unwrap_or(' ') != '_';

                    if is_left_bound && is_right_bound {
                        results.push(Location::new(
                            doc_uri,
                            Range::single_line(
                                line_idx as u32,
                                actual_col as u32,
                                (actual_col + word.len()) as u32,
                            ),
                        ));
                    }
                    start_search = actual_col + word.len().max(1);
                    if start_search >= line.len() {
                        break;
                    }
                }
            }
        }

        results
    }

    // -----------------------------------------------------------------------
    // P2.4 Hover: Markdown Documentation & Type Info
    // -----------------------------------------------------------------------

    pub fn hover(&self, uri: &str, pos: Position) -> Option<Hover> {
        let docs = self.documents.lock();
        let content = docs.get(uri)?;
        let word = extract_word_at_pos(content, pos)?;

        // Search for declaration line of this word
        let mut hover_text = None;
        let mut hover_range = None;

        for (_line_idx, line) in content.lines().enumerate() {
            if line.contains(&format!("fn {}", word)) {
                hover_text = Some(format!(
                    "```rust\n{}\n```\n\n*CodeLiteX Language Service (Function Declaration)*",
                    line.trim()
                ));
                hover_range = Some(Range::single_line(
                    pos.line,
                    pos.character.saturating_sub(word.len() as u32 / 2),
                    pos.character + word.len() as u32 / 2,
                ));
                break;
            } else if line.contains(&format!("struct {}", word)) {
                hover_text = Some(format!(
                    "```rust\n{}\n```\n\n*CodeLiteX Language Service (Struct Type)*",
                    line.trim()
                ));
                break;
            } else if line.contains(&format!("enum {}", word)) {
                hover_text = Some(format!(
                    "```rust\n{}\n```\n\n*CodeLiteX Language Service (Enum Type)*",
                    line.trim()
                ));
                break;
            }
        }

        let text = hover_text.unwrap_or_else(|| {
            format!(
                "**Symbol**: `{}`\n\n*Language Service Symbol reference*",
                word
            )
        });

        Some(Hover::markdown(text, hover_range))
    }

    // -----------------------------------------------------------------------
    // P2.5 Completion: Smart Code Completion Candidates
    // -----------------------------------------------------------------------

    pub fn completion(&self, uri: &str, _pos: Position) -> Vec<CompletionItem> {
        let mut items = Vec::new();

        // 1. Common language keywords
        let keywords = [
            "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "match",
            "if", "else", "return", "use", "mod", "async", "await", "self", "Self",
            "where", "type", "const", "static", "for", "in", "while", "loop",
        ];

        for kw in keywords {
            items.push(CompletionItem::new(kw, CompletionItemKind::Keyword));
        }

        // 2. Extract identifiers in opened documents
        let docs = self.documents.lock();
        if let Some(content) = docs.get(uri) {
            let mut seen = std::collections::HashSet::new();
            for word in content.split(|c: char| !c.is_alphanumeric() && c != '_') {
                if word.len() > 1 && !seen.contains(word) && !keywords.contains(&word) {
                    seen.insert(word.to_string());
                    let kind = if word.starts_with(|c: char| c.is_uppercase()) {
                        CompletionItemKind::Class
                    } else {
                        CompletionItemKind::Variable
                    };
                    items.push(CompletionItem::new(word, kind));
                }
            }
        }

        // Sort by label
        items.sort_by(|a, b| a.label.cmp(&b.label));
        items
    }

    // -----------------------------------------------------------------------
    // P2.6 Rename: Workspace-wide atomic refactoring
    // -----------------------------------------------------------------------

    pub fn rename(&self, uri: &str, pos: Position, new_name: &str) -> Option<WorkspaceEdit> {
        let refs = self.references(uri, pos, true);
        if refs.is_empty() {
            return None;
        }

        let mut file_edits: HashMap<String, Vec<TextEdit>> = HashMap::new();
        for loc in refs {
            file_edits
                .entry(loc.uri)
                .or_default()
                .push(TextEdit::new(loc.range, new_name));
        }

        Some(WorkspaceEdit::from_changes(file_edits))
    }

    // -----------------------------------------------------------------------
    // Document Lifecycle Management
    // -----------------------------------------------------------------------

    pub fn open_document(&self, uri: &str, content: &str) -> Vec<Diagnostic> {
        self.documents
            .lock()
            .insert(uri.to_string(), content.to_string());
        self.compute_diagnostics(uri, content)
    }

    pub fn update_document(&self, uri: &str, content: &str) -> Vec<Diagnostic> {
        self.documents
            .lock()
            .insert(uri.to_string(), content.to_string());
        self.compute_diagnostics(uri, content)
    }

    /// Applies an incremental change (replacing a Range with new text) and recomputes diagnostics.
    pub fn apply_incremental_change(&self, uri: &str, range: Range, new_text: &str) -> Vec<Diagnostic> {
        let mut docs = self.documents.lock();
        let current = docs.get(uri).cloned().unwrap_or_default();
        let updated = replace_range_in_text(&current, range, new_text);
        docs.insert(uri.to_string(), updated.clone());
        drop(docs);
        self.compute_diagnostics(uri, &updated)
    }

    pub fn get_document(&self, uri: &str) -> Option<String> {
        self.documents.lock().get(uri).cloned()
    }

    pub fn close_document(&self, uri: &str) {
        self.documents.lock().remove(uri);
        if let Some(store) = &self.diag_store {
            let _ = store.clear_file_diagnostics(uri);
        }
    }
}

/// Replaces a slice defined by Range (line, column) within content.
pub fn replace_range_in_text(content: &str, range: Range, replacement: &str) -> String {
    let mut current_line = 0u32;
    let mut current_col = 0u32;
    let mut start_byte = None;
    let mut end_byte = None;

    for (byte_idx, ch) in content.char_indices() {
        if start_byte.is_none() && current_line == range.start.line && current_col == range.start.character {
            start_byte = Some(byte_idx);
        }
        if end_byte.is_none() && current_line == range.end.line && current_col == range.end.character {
            end_byte = Some(byte_idx);
        }

        if ch == '\n' {
            if start_byte.is_none() && current_line == range.start.line && current_col <= range.start.character {
                start_byte = Some(byte_idx);
            }
            if end_byte.is_none() && current_line == range.end.line && current_col <= range.end.character {
                end_byte = Some(byte_idx);
            }
            current_line += 1;
            current_col = 0;
        } else {
            current_col += 1;
        }
    }

    if start_byte.is_none() && (current_line > range.start.line || (current_line == range.start.line && current_col >= range.start.character)) {
        start_byte = Some(content.len());
    }
    if end_byte.is_none() && (current_line > range.end.line || (current_line == range.end.line && current_col >= range.end.character)) {
        end_byte = Some(content.len());
    }

    let start = start_byte.unwrap_or(content.len()).min(content.len());
    let end = end_byte.unwrap_or(content.len()).min(content.len()).max(start);

    let mut result = String::with_capacity(start + replacement.len() + (content.len() - end));
    result.push_str(&content[..start]);
    result.push_str(replacement);
    result.push_str(&content[end..]);
    result
}

/// Extracts alphanumeric + '_' identifier under the target Position.
fn extract_word_at_pos(content: &str, pos: Position) -> Option<String> {
    let line = content.lines().nth(pos.line as usize)?;
    let col = pos.character as usize;
    if col > line.len() {
        return None;
    }

    let chars: Vec<char> = line.chars().collect();
    let mut start = col.min(chars.len().saturating_sub(1));
    while start > 0 && (chars[start - 1].is_alphanumeric() || chars[start - 1] == '_') {
        start -= 1;
    }

    let mut end = col.min(chars.len());
    while end < chars.len() && (chars[end].is_alphanumeric() || chars[end] == '_') {
        end += 1;
    }

    if start < end {
        Some(chars[start..end].iter().collect())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_diagnostics_syntax_error() {
        let server = VirtualLspServer::new();
        let bad_code = "fn broken( { let x = 1; ";
        let diags = server.open_document("src/broken.rs", bad_code);
        assert!(!diags.is_empty(), "Should detect syntax error in broken Rust code");
        assert_eq!(diags[0].severity, Some(DiagnosticSeverity::Error));
    }

    #[test]
    fn test_diagnostics_clean_code() {
        let server = VirtualLspServer::new();
        let clean_code = "fn valid() { let _x = 42; }";
        let diags = server.open_document("src/valid.rs", clean_code);
        assert!(diags.is_empty(), "Clean Rust code should have zero diagnostics");
    }

    #[test]
    fn test_definition_and_references() {
        let server = VirtualLspServer::new();
        let code = r#"
fn greet(name: &str) {
    println!("{}", name);
}

fn main() {
    greet("CodeLiteX");
}
"#;
        server.open_document("src/main.rs", code);

        // Click on `greet` at line 6, col 5
        let defs = server.definition("src/main.rs", Position::new(6, 5));
        assert_eq!(defs.len(), 1);
        assert_eq!(defs[0].range.start.line, 1);

        // References for `greet`
        let refs = server.references("src/main.rs", Position::new(1, 4), true);
        assert_eq!(refs.len(), 2, "Should find declaration and call site of greet");
    }

    #[test]
    fn test_hover_and_completion() {
        let server = VirtualLspServer::new();
        let code = "struct User { id: u64 }\nfn main() { let u = User { id: 1 }; }";
        server.open_document("src/model.rs", code);

        // Hover over `User`
        let hover = server.hover("src/model.rs", Position::new(0, 8)).unwrap();
        assert!(hover.contents.to_markdown().contains("struct User"));

        // Completion
        let comps = server.completion("src/model.rs", Position::new(1, 10));
        assert!(comps.iter().any(|c| c.label == "struct"));
        assert!(comps.iter().any(|c| c.label == "User"));
    }

    #[test]
    fn test_rename_workspace_edit() {
        let server = VirtualLspServer::new();
        let code = "fn compute() -> i32 { 42 }\nfn test() { let a = compute(); }";
        server.open_document("src/lib.rs", code);

        let edit = server.rename("src/lib.rs", Position::new(0, 5), "calculate").unwrap();
        let changes = edit.changes.unwrap();
        let file_edits = changes.get("src/lib.rs").unwrap();
        assert_eq!(file_edits.len(), 2);
        assert_eq!(file_edits[0].new_text, "calculate");
        assert_eq!(file_edits[1].new_text, "calculate");
    }

    #[test]
    fn test_incremental_document_update() {
        let server = VirtualLspServer::new();
        let code = "fn add(a: i32, b: i32) -> i32 {\n    a + b\n}";
        let uri = "src/math.rs";
        server.open_document(uri, code);

        // Replace `a + b` (line 1, col 4 to 9) with `a * b`
        let diags = server.apply_incremental_change(uri, Range::new(1, 4, 1, 9), "a * b");
        assert!(diags.is_empty());
        let current = server.get_document(uri).unwrap();
        assert!(current.contains("a * b"));
        assert!(!current.contains("a + b"));

        // Introduce a syntax error incrementally: replace `*` with invalid token `@@@`
        let diags_err = server.apply_incremental_change(uri, Range::new(1, 6, 1, 7), "@@@");
        assert!(!diags_err.is_empty(), "Syntax error must be detected after incremental change");
    }
}
