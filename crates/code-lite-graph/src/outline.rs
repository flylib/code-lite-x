use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OutlineNode {
    pub name: String,
    pub symbol_key: String,
    pub kind: String, // "struct", "function", "method", "enum", "trait", "class", "module", "field"
    pub signature: Option<String>,
    pub line_start: usize,
    pub col_start: usize,
    pub line_end: usize,
    pub col_end: usize,
    #[serde(default)]
    pub children: Vec<OutlineNode>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DefinitionLocation {
    pub file_path: String,
    pub symbol_key: String,
    pub name: String,
    pub kind: String,
    pub signature: Option<String>,
    pub line_start: usize,
    pub col_start: usize,
    pub line_end: usize,
    pub col_end: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ReferenceLocation {
    pub file_path: String,
    pub symbol_key: String,
    pub name: String,
    pub line: usize,
    pub caller_name: Option<String>,
}

/// Rich, focused context around a symbol specifically tailored for AI Agent reasoning.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CodeContext {
    pub symbol_key: String,
    pub name: String,
    pub kind: String,
    pub signature: Option<String>,
    pub definition_code: String,
    pub file_path: String,
    pub line_start: usize,
    pub line_end: usize,
    pub callers: Vec<String>,
    pub callees: Vec<String>,
    pub references: Vec<String>,
    pub imports: Vec<String>,
}
