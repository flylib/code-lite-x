//! # LSP 3.17 Protocol Specification Types & JSON-RPC 2.0 Structures
//!
//! Strongly-typed, lightweight data models covering Diagnostics, Definition,
//! References, Hover, Completion, Rename, and Document Sync without external bloat.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// 1. Core Position & Range
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Position {
    /// Zero-based line index.
    pub line: u32,
    /// Zero-based character offset (UTF-16 code units or UTF-8 columns).
    pub character: u32,
}

impl Position {
    pub fn new(line: u32, character: u32) -> Self {
        Self { line, character }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Range {
    pub start: Position,
    pub end: Position,
}

impl Range {
    pub fn new(start_line: u32, start_col: u32, end_line: u32, end_col: u32) -> Self {
        Self {
            start: Position::new(start_line, start_col),
            end: Position::new(end_line, end_col),
        }
    }

    pub fn single_line(line: u32, start_col: u32, end_col: u32) -> Self {
        Self::new(line, start_col, line, end_col)
    }

    /// Checks if a position is within this range (inclusive start, exclusive end).
    pub fn contains(&self, pos: &Position) -> bool {
        if pos.line < self.start.line || pos.line > self.end.line {
            return false;
        }
        if pos.line == self.start.line && pos.character < self.start.character {
            return false;
        }
        if pos.line == self.end.line && pos.character > self.end.character {
            return false;
        }
        true
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Location {
    pub uri: String,
    pub range: Range,
}

impl Location {
    pub fn new(uri: impl Into<String>, range: Range) -> Self {
        Self {
            uri: uri.into(),
            range,
        }
    }
}

// ---------------------------------------------------------------------------
// 2. Diagnostics (Priority 1)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "u32", into = "u32")]
pub enum DiagnosticSeverity {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,
}

impl From<u32> for DiagnosticSeverity {
    fn from(val: u32) -> Self {
        match val {
            1 => Self::Error,
            2 => Self::Warning,
            3 => Self::Information,
            4 => Self::Hint,
            _ => Self::Error,
        }
    }
}

impl From<DiagnosticSeverity> for u32 {
    fn from(sev: DiagnosticSeverity) -> Self {
        sev as u32
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosticRelatedInformation {
    pub location: Location,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Diagnostic {
    pub range: Range,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub severity: Option<DiagnosticSeverity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub related_information: Option<Vec<DiagnosticRelatedInformation>>,
}

impl Diagnostic {
    pub fn error(range: Range, message: impl Into<String>) -> Self {
        Self {
            range,
            severity: Some(DiagnosticSeverity::Error),
            code: None,
            source: Some("lsp".to_string()),
            message: message.into(),
            related_information: None,
        }
    }

    pub fn warning(range: Range, message: impl Into<String>) -> Self {
        Self {
            range,
            severity: Some(DiagnosticSeverity::Warning),
            code: None,
            source: Some("lsp".to_string()),
            message: message.into(),
            related_information: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishDiagnosticsParams {
    pub uri: String,
    pub diagnostics: Vec<Diagnostic>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<i32>,
}

// ---------------------------------------------------------------------------
// 3. Document Identifiers & Sync
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextDocumentIdentifier {
    pub uri: String,
}

impl TextDocumentIdentifier {
    pub fn new(uri: impl Into<String>) -> Self {
        Self { uri: uri.into() }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct VersionedTextDocumentIdentifier {
    pub uri: String,
    pub version: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextDocumentItem {
    pub uri: String,
    #[serde(rename = "languageId")]
    pub language_id: String,
    pub version: i32,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DidOpenTextDocumentParams {
    #[serde(rename = "textDocument")]
    pub text_document: TextDocumentItem,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextDocumentContentChangeEvent {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<Range>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "rangeLength")]
    pub range_length: Option<u32>,
    pub text: String,
}

impl TextDocumentContentChangeEvent {
    pub fn full(text: impl Into<String>) -> Self {
        Self {
            range: None,
            range_length: None,
            text: text.into(),
        }
    }

    pub fn incremental(range: Range, range_length: Option<u32>, text: impl Into<String>) -> Self {
        Self {
            range: Some(range),
            range_length,
            text: text.into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DidChangeTextDocumentParams {
    #[serde(rename = "textDocument")]
    pub text_document: VersionedTextDocumentIdentifier,
    #[serde(rename = "contentChanges")]
    pub content_changes: Vec<TextDocumentContentChangeEvent>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "u32", into = "u32")]
pub enum TextDocumentSyncKind {
    None = 0,
    Full = 1,
    Incremental = 2,
}

impl From<u32> for TextDocumentSyncKind {
    fn from(val: u32) -> Self {
        match val {
            0 => Self::None,
            1 => Self::Full,
            2 => Self::Incremental,
            _ => Self::Full,
        }
    }
}

impl From<TextDocumentSyncKind> for u32 {
    fn from(k: TextDocumentSyncKind) -> Self {
        k as u32
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum TextDocumentSyncCapability {
    Kind(TextDocumentSyncKind),
    Options(TextDocumentSyncOptions),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TextDocumentSyncOptions {
    #[serde(skip_serializing_if = "Option::is_none", rename = "openClose")]
    pub open_close: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub change: Option<TextDocumentSyncKind>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ServerCapabilities {
    #[serde(skip_serializing_if = "Option::is_none", rename = "textDocumentSync")]
    pub text_document_sync: Option<TextDocumentSyncCapability>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "hoverProvider")]
    pub hover_provider: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "completionProvider")]
    pub completion_provider: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "definitionProvider")]
    pub definition_provider: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "referencesProvider")]
    pub references_provider: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "renameProvider")]
    pub rename_provider: Option<serde_json::Value>,
}

impl ServerCapabilities {
    pub fn sync_kind(&self) -> TextDocumentSyncKind {
        match &self.text_document_sync {
            Some(TextDocumentSyncCapability::Kind(k)) => *k,
            Some(TextDocumentSyncCapability::Options(opts)) => {
                opts.change.unwrap_or(TextDocumentSyncKind::Full)
            }
            None => TextDocumentSyncKind::None,
        }
    }

    pub fn supports_incremental_sync(&self) -> bool {
        self.sync_kind() == TextDocumentSyncKind::Incremental
    }

    pub fn supports_rename(&self) -> bool {
        match &self.rename_provider {
            Some(serde_json::Value::Bool(b)) => *b,
            Some(serde_json::Value::Object(_)) => true,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InitializeResult {
    pub capabilities: ServerCapabilities,
    #[serde(skip_serializing_if = "Option::is_none", rename = "serverInfo")]
    pub server_info: Option<ServerInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerInfo {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

// ---------------------------------------------------------------------------
// 4. Definition & References (Priority 2 & 3)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextDocumentPositionParams {
    #[serde(rename = "textDocument")]
    pub text_document: TextDocumentIdentifier,
    pub position: Position,
}

impl TextDocumentPositionParams {
    pub fn new(uri: impl Into<String>, line: u32, character: u32) -> Self {
        Self {
            text_document: TextDocumentIdentifier::new(uri),
            position: Position::new(line, character),
        }
    }
}

pub type DefinitionParams = TextDocumentPositionParams;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReferenceContext {
    #[serde(rename = "includeDeclaration")]
    pub include_declaration: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReferenceParams {
    #[serde(rename = "textDocument")]
    pub text_document: TextDocumentIdentifier,
    pub position: Position,
    pub context: ReferenceContext,
}

impl ReferenceParams {
    pub fn new(uri: impl Into<String>, line: u32, character: u32, include_declaration: bool) -> Self {
        Self {
            text_document: TextDocumentIdentifier::new(uri),
            position: Position::new(line, character),
            context: ReferenceContext { include_declaration },
        }
    }
}

// ---------------------------------------------------------------------------
// 5. Hover (Priority 4)
// ---------------------------------------------------------------------------

pub type HoverParams = TextDocumentPositionParams;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MarkupContent {
    pub kind: String, // "markdown" or "plaintext"
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum HoverContents {
    Scalar(String),
    Markup(MarkupContent),
    Array(Vec<HoverContents>),
}

impl HoverContents {
    /// Flattens arbitrary LSP hover contents into a clean markdown string.
    pub fn to_markdown(&self) -> String {
        match self {
            HoverContents::Scalar(s) => s.clone(),
            HoverContents::Markup(m) => m.value.clone(),
            HoverContents::Array(arr) => arr
                .iter()
                .map(|item| item.to_markdown())
                .collect::<Vec<_>>()
                .join("\n\n"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Hover {
    pub contents: HoverContents,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<Range>,
}

impl Hover {
    pub fn markdown(text: impl Into<String>, range: Option<Range>) -> Self {
        Self {
            contents: HoverContents::Markup(MarkupContent {
                kind: "markdown".to_string(),
                value: text.into(),
            }),
            range,
        }
    }
}

// ---------------------------------------------------------------------------
// 6. Completion (Priority 5)
// ---------------------------------------------------------------------------

pub type CompletionParams = TextDocumentPositionParams;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "u32", into = "u32")]
pub enum CompletionItemKind {
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25,
}

impl From<u32> for CompletionItemKind {
    fn from(val: u32) -> Self {
        match val {
            1 => Self::Text,
            2 => Self::Method,
            3 => Self::Function,
            4 => Self::Constructor,
            5 => Self::Field,
            6 => Self::Variable,
            7 => Self::Class,
            8 => Self::Interface,
            9 => Self::Module,
            10 => Self::Property,
            11 => Self::Unit,
            12 => Self::Value,
            13 => Self::Enum,
            14 => Self::Keyword,
            15 => Self::Snippet,
            16 => Self::Color,
            17 => Self::File,
            18 => Self::Reference,
            19 => Self::Folder,
            20 => Self::EnumMember,
            21 => Self::Constant,
            22 => Self::Struct,
            23 => Self::Event,
            24 => Self::Operator,
            25 => Self::TypeParameter,
            _ => Self::Text,
        }
    }
}

impl From<CompletionItemKind> for u32 {
    fn from(k: CompletionItemKind) -> Self {
        k as u32
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CompletionItem {
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<CompletionItemKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub documentation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "insertText")]
    pub insert_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "sortText")]
    pub sort_text: Option<String>,
}

impl CompletionItem {
    pub fn new(label: impl Into<String>, kind: CompletionItemKind) -> Self {
        Self {
            label: label.into(),
            kind: Some(kind),
            detail: None,
            documentation: None,
            insert_text: None,
            sort_text: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletionList {
    #[serde(rename = "isIncomplete")]
    pub is_incomplete: bool,
    pub items: Vec<CompletionItem>,
}

// ---------------------------------------------------------------------------
// 7. Rename & WorkspaceEdit (Priority 6)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextEdit {
    pub range: Range,
    #[serde(rename = "newText")]
    pub new_text: String,
}

impl TextEdit {
    pub fn new(range: Range, new_text: impl Into<String>) -> Self {
        Self {
            range,
            new_text: new_text.into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextDocumentEdit {
    #[serde(rename = "textDocument")]
    pub text_document: VersionedTextDocumentIdentifier,
    pub edits: Vec<TextEdit>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct WorkspaceEdit {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub changes: Option<HashMap<String, Vec<TextEdit>>>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "documentChanges")]
    pub document_changes: Option<Vec<TextDocumentEdit>>,
}

impl WorkspaceEdit {
    pub fn from_changes(changes: HashMap<String, Vec<TextEdit>>) -> Self {
        Self {
            changes: Some(changes),
            document_changes: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenameParams {
    #[serde(rename = "textDocument")]
    pub text_document: TextDocumentIdentifier,
    pub position: Position,
    #[serde(rename = "newName")]
    pub new_name: String,
}

// ---------------------------------------------------------------------------
// 8. JSON-RPC 2.0 Base Protocol Envelopes
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: u64,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

impl JsonRpcRequest {
    pub fn new(id: u64, method: impl Into<String>, params: Option<serde_json::Value>) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            method: method.into(),
            params,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

impl JsonRpcResponse {
    pub fn success(id: u64, result: serde_json::Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: u64, code: i64, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(JsonRpcError {
                code,
                message: message.into(),
                data: None,
            }),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcNotification {
    pub jsonrpc: String,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

impl JsonRpcNotification {
    pub fn new(method: impl Into<String>, params: Option<serde_json::Value>) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            method: method.into(),
            params,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_range_contains() {
        let range = Range::new(10, 5, 10, 25);
        assert!(range.contains(&Position::new(10, 5)));
        assert!(range.contains(&Position::new(10, 15)));
        assert!(range.contains(&Position::new(10, 25)));
        assert!(!range.contains(&Position::new(10, 4)));
        assert!(!range.contains(&Position::new(10, 26)));
        assert!(!range.contains(&Position::new(9, 10)));
    }

    #[test]
    fn test_diagnostic_serialization() {
        let diag = Diagnostic::error(Range::new(1, 0, 1, 10), "Syntax error");
        let json = serde_json::to_string(&diag).unwrap();
        let deserialized: Diagnostic = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.message, "Syntax error");
        assert_eq!(deserialized.severity, Some(DiagnosticSeverity::Error));
    }

    #[test]
    fn test_hover_contents_markdown() {
        let hover = Hover::markdown("```rust\nfn main()\n```", Some(Range::new(0, 0, 0, 7)));
        let md = hover.contents.to_markdown();
        assert!(md.contains("fn main()"));
    }

    #[test]
    fn test_server_capabilities_parsing() {
        // Test with integer textDocumentSync (e.g. 2 = Incremental)
        let json_int = serde_json::json!({
            "capabilities": {
                "textDocumentSync": 2,
                "renameProvider": true,
                "hoverProvider": true
            },
            "serverInfo": {
                "name": "rust-analyzer",
                "version": "1.0.0"
            }
        });
        let res: InitializeResult = serde_json::from_value(json_int).unwrap();
        assert_eq!(res.capabilities.sync_kind(), TextDocumentSyncKind::Incremental);
        assert!(res.capabilities.supports_incremental_sync());
        assert!(res.capabilities.supports_rename());
        assert_eq!(res.server_info.unwrap().name, "rust-analyzer");

        // Test with object textDocumentSync
        let json_obj = serde_json::json!({
            "capabilities": {
                "textDocumentSync": {
                    "openClose": true,
                    "change": 2
                },
                "renameProvider": { "prepareProvider": true }
            }
        });
        let res_obj: InitializeResult = serde_json::from_value(json_obj).unwrap();
        assert!(res_obj.capabilities.supports_incremental_sync());
        assert!(res_obj.capabilities.supports_rename());
    }

    #[test]
    fn test_incremental_change_event() {
        let event = TextDocumentContentChangeEvent::incremental(
            Range::new(1, 4, 1, 10),
            Some(6),
            "replacement",
        );
        assert_eq!(event.range, Some(Range::new(1, 4, 1, 10)));
        assert_eq!(event.range_length, Some(6));
        assert_eq!(event.text, "replacement");

        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"rangeLength\":6"));
    }
}
