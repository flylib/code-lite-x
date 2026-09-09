use code_lite_core::Editor;
use code_lite_storage::{
    Database, EventStore, GraphStore, OperationStore, SessionStore, StorageError, SymbolRecord,
};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[allow(dead_code)]
pub struct AppState {
    pub workspace_root: PathBuf,
    pub db: Database,
    pub event_store: EventStore,
    pub op_store: OperationStore,
    pub graph_store: GraphStore,
    pub session_store: SessionStore,
    pub editors: Mutex<HashMap<String, Editor>>,
}

impl AppState {
    pub fn new<P: AsRef<Path>>(workspace_root: P) -> Result<Self, StorageError> {
        let root = workspace_root.as_ref().to_path_buf();
        let db_path = root.join(".codelite").join("workspace.db");
        let db = Database::open(&db_path)?;

        let event_store = EventStore::new(db.clone());
        let op_store = OperationStore::new(db.clone());
        let graph_store = GraphStore::new(db.clone());
        let session_store = SessionStore::new(db.clone());

        // Log application startup
        let _ = event_store.log(
            None,
            "WorkspaceOpened",
            &serde_json::json!({
                "root": root.to_string_lossy()
            }),
        );

        let state = Self {
            workspace_root: root,
            db,
            event_store,
            op_store,
            graph_store,
            session_store,
            editors: Mutex::new(HashMap::new()),
        };

        state.initial_scan_and_index();
        Ok(state)
    }

    /// Performs an initial scan of the workspace and indexes sample Rust symbols.
    fn initial_scan_and_index(&self) {
        let tree = code_lite_fs::WorkspaceTree::new(&self.workspace_root);
        if let Ok(files) = tree.list_files() {
            for file_path in files {
                let relative = file_path
                    .strip_prefix(&self.workspace_root)
                    .unwrap_or(&file_path)
                    .to_string_lossy()
                    .to_string();

                if let Ok(content) = std::fs::read_to_string(&file_path) {
                    let hash = format!("{:x}", content.len());
                    let line_count = content.lines().count();
                    let lang = if relative.ends_with(".rs") {
                        "rust"
                    } else if relative.ends_with(".toml") {
                        "toml"
                    } else {
                        "text"
                    };

                    if let Ok(file_id) = self.graph_store.upsert_file(
                        &relative,
                        &hash,
                        lang,
                        line_count,
                        1000,
                    ) {
                        // Extract symbols for Rust files
                        if lang == "rust" {
                            let mut symbols = Vec::new();
                            for (idx, line) in content.lines().enumerate() {
                                let trimmed = line.trim_start();
                                if trimmed.starts_with("pub fn ") || trimmed.starts_with("fn ") {
                                    let name_part = trimmed
                                        .trim_start_matches("pub fn ")
                                        .trim_start_matches("fn ");
                                    if let Some(name) = name_part.split('(').next() {
                                        let clean_name = name.trim();
                                        symbols.push(SymbolRecord {
                                            id: 0,
                                            symbol_key: format!("{}:{}:function::{}", lang, relative, clean_name),
                                            identity_id: None,
                                            file_id,
                                            name: clean_name.to_string(),
                                            kind: "function".to_string(),
                                            signature: Some(trimmed.to_string()),
                                            doc_comment: None,
                                            line_start: idx,
                                            col_start: 0,
                                            line_end: idx,
                                            col_end: trimmed.len(),
                                            scope_path: Some(relative.clone()),
                                        });
                                    }
                                } else if trimmed.starts_with("pub struct ") || trimmed.starts_with("struct ") {
                                    let name_part = trimmed
                                        .trim_start_matches("pub struct ")
                                        .trim_start_matches("struct ");
                                    if let Some(name) = name_part.split_whitespace().next() {
                                        let clean_name = name.trim();
                                        symbols.push(SymbolRecord {
                                            id: 0,
                                            symbol_key: format!("{}:{}:struct::{}", lang, relative, clean_name),
                                            identity_id: None,
                                            file_id,
                                            name: clean_name.to_string(),
                                            kind: "struct".to_string(),
                                            signature: Some(trimmed.to_string()),
                                            doc_comment: None,
                                            line_start: idx,
                                            col_start: 0,
                                            line_end: idx,
                                            col_end: trimmed.len(),
                                            scope_path: Some(relative.clone()),
                                        });
                                    }
                                }
                            }
                            if !symbols.is_empty() {
                                let _ = self.graph_store.save_symbols(file_id, &symbols);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Gets or loads an Editor for the specified relative file path.
    pub fn get_or_load_editor(&self, rel_path: &str) -> Result<String, std::io::Error> {
        let mut editors = self.editors.lock();
        if let Some(editor) = editors.get(rel_path) {
            return Ok(editor.text());
        }

        let full_path = self.workspace_root.join(rel_path);
        let content = std::fs::read_to_string(&full_path)?;
        let editor = Editor::from_str(&content);
        editors.insert(rel_path.to_string(), editor);

        let _ = self.event_store.log(
            None,
            "FileOpened",
            &serde_json::json!({ "path": rel_path }),
        );

        Ok(content)
    }
}
