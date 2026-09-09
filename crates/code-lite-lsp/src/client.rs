//! # LspClient
//!
//! Client orchestrator supporting both external process-backed LSP servers (via stdio JSON-RPC)
//! and embedded Virtual LSP servers, exposing the 6 core cognitive capabilities:
//! Diagnostics -> Definition -> References -> Hover -> Completion -> Rename.

use crate::protocol::*;
use crate::transport::{FramedReader, FramedWriter};
use crate::virtual_server::VirtualLspServer;
use anyhow::{anyhow, Context, Result};
use parking_lot::{Condvar, Mutex, RwLock};
use std::collections::HashMap;
use std::io::{BufReader, BufWriter};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub type DiagnosticsCallback = Arc<dyn Fn(&str, &[Diagnostic]) + Send + Sync>;

enum Backend {
    Process {
        _child: Arc<Mutex<Child>>,
        writer: Arc<Mutex<FramedWriter<BufWriter<ChildStdin>>>>,
        pending_requests: Arc<Mutex<HashMap<u64, Arc<(Mutex<Option<Result<serde_json::Value>>>, Condvar)>>>>,
        _reader_thread: Option<JoinHandle<()>>,
    },
    Virtual(Arc<VirtualLspServer>),
}

pub struct LspClient {
    backend: Backend,
    next_id: AtomicU64,
    diagnostics_cache: Arc<RwLock<HashMap<String, Vec<Diagnostic>>>>,
    diagnostics_listener: Arc<RwLock<Option<DiagnosticsCallback>>>,
    is_running: Arc<AtomicBool>,
}

impl LspClient {
    // -----------------------------------------------------------------------
    // Constructors: Process Mode & Virtual In-Process Mode
    // -----------------------------------------------------------------------

    /// Creates an LSP client connected to a Virtual Language Server.
    pub fn new_virtual(server: VirtualLspServer) -> Self {
        Self {
            backend: Backend::Virtual(Arc::new(server)),
            next_id: AtomicU64::new(1),
            diagnostics_cache: Arc::new(RwLock::new(HashMap::new())),
            diagnostics_listener: Arc::new(RwLock::new(None)),
            is_running: Arc::new(AtomicBool::new(true)),
        }
    }

    /// Spawns an external LSP process (e.g. `rust-analyzer` or `clangd`) over stdio JSON-RPC.
    pub fn spawn_process(cmd: &str, args: &[&str], root_path: &Path) -> Result<Self> {
        let mut child = Command::new(cmd)
            .args(args)
            .current_dir(root_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("Failed to spawn LSP process '{}'", cmd))?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("Failed to capture LSP stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("Failed to capture LSP stdout"))?;

        let writer = Arc::new(Mutex::new(FramedWriter::new(BufWriter::new(stdin))));
        let pending: Arc<Mutex<HashMap<u64, Arc<(Mutex<Option<Result<serde_json::Value>>>, Condvar)>>>> =
            Arc::new(Mutex::new(HashMap::new()));
        let diags_cache = Arc::new(RwLock::new(HashMap::new()));
        let diags_listener: Arc<RwLock<Option<DiagnosticsCallback>>> = Arc::new(RwLock::new(None));
        let running = Arc::new(AtomicBool::new(true));

        // Background reader thread
        let reader_pending = Arc::clone(&pending);
        let reader_diags = Arc::clone(&diags_cache);
        let reader_listener = Arc::clone(&diags_listener);
        let reader_running = Arc::clone(&running);

        let reader_thread = thread::spawn(move || {
            let mut framed_reader = FramedReader::new(BufReader::new(stdout));
            while reader_running.load(Ordering::Relaxed) {
                match framed_reader.read_message() {
                    Ok(Some(raw_json)) => {
                        Self::dispatch_message(
                            &raw_json,
                            &reader_pending,
                            &reader_diags,
                            &reader_listener,
                        );
                    }
                    Ok(None) => break, // EOF
                    Err(_) => break,
                }
            }
        });

        let client = Self {
            backend: Backend::Process {
                _child: Arc::new(Mutex::new(child)),
                writer,
                pending_requests: pending,
                _reader_thread: Some(reader_thread),
            },
            next_id: AtomicU64::new(1),
            diagnostics_cache: diags_cache,
            diagnostics_listener: diags_listener,
            is_running: running,
        };

        // Send LSP initialize handshake
        let init_params = serde_json::json!({
            "processId": std::process::id(),
            "rootUri": format!("file://{}", root_path.to_string_lossy()),
            "capabilities": {
                "textDocument": {
                    "publishDiagnostics": { "relatedInformation": true },
                    "definition": { "dynamicRegistration": true },
                    "references": { "dynamicRegistration": true },
                    "hover": { "contentFormat": ["markdown", "plaintext"] },
                    "completion": { "completionItem": { "snippetSupport": true } },
                    "rename": { "prepareSupport": true }
                }
            }
        });

        let _ = client.send_request("initialize", Some(init_params));
        let _ = client.send_notification("initialized", Some(serde_json::json!({})));

        Ok(client)
    }

    // -----------------------------------------------------------------------
    // P2.1 Diagnostics: Retrieve, Cache, and Subscribe
    // -----------------------------------------------------------------------

    /// Sets a listener callback invoked whenever new diagnostics are published.
    pub fn set_diagnostics_listener<F>(&self, listener: F)
    where
        F: Fn(&str, &[Diagnostic]) + Send + Sync + 'static,
    {
        *self.diagnostics_listener.write() = Some(Arc::new(listener));
    }

    /// Retrieves cached diagnostics for a given document URI.
    pub fn get_diagnostics(&self, uri: &str) -> Vec<Diagnostic> {
        self.diagnostics_cache
            .read()
            .get(uri)
            .cloned()
            .unwrap_or_default()
    }

    /// Retrieves all diagnostics currently cached across the workspace.
    pub fn get_all_diagnostics(&self) -> HashMap<String, Vec<Diagnostic>> {
        self.diagnostics_cache.read().clone()
    }

    /// Checks if a file currently has any blocking compilation/syntax errors.
    pub fn has_errors(&self, uri: &str) -> bool {
        self.get_diagnostics(uri)
            .iter()
            .any(|d| d.severity == Some(DiagnosticSeverity::Error))
    }

    // -----------------------------------------------------------------------
    // P2.2 Definition: Jump to Definition
    // -----------------------------------------------------------------------

    pub fn goto_definition(&self, uri: &str, line: u32, character: u32) -> Result<Vec<Location>> {
        match &self.backend {
            Backend::Virtual(server) => Ok(server.definition(uri, Position::new(line, character))),
            Backend::Process { .. } => {
                let params = DefinitionParams::new(uri, line, character);
                let res = self.send_request("textDocument/definition", Some(serde_json::to_value(params)?))?;
                if res.is_null() {
                    return Ok(Vec::new());
                }
                if let Ok(loc) = serde_json::from_value::<Location>(res.clone()) {
                    return Ok(vec![loc]);
                }
                let locs: Vec<Location> = serde_json::from_value(res).unwrap_or_default();
                Ok(locs)
            }
        }
    }

    // -----------------------------------------------------------------------
    // P2.3 References: Find All Call/Usage Sites
    // -----------------------------------------------------------------------

    pub fn find_references(
        &self,
        uri: &str,
        line: u32,
        character: u32,
        include_decl: bool,
    ) -> Result<Vec<Location>> {
        match &self.backend {
            Backend::Virtual(server) => {
                Ok(server.references(uri, Position::new(line, character), include_decl))
            }
            Backend::Process { .. } => {
                let params = ReferenceParams::new(uri, line, character, include_decl);
                let res = self.send_request("textDocument/references", Some(serde_json::to_value(params)?))?;
                let locs: Vec<Location> = serde_json::from_value(res).unwrap_or_default();
                Ok(locs)
            }
        }
    }

    // -----------------------------------------------------------------------
    // P2.4 Hover: Markdown Documentation & Type Signature
    // -----------------------------------------------------------------------

    pub fn hover(&self, uri: &str, line: u32, character: u32) -> Result<Option<Hover>> {
        match &self.backend {
            Backend::Virtual(server) => Ok(server.hover(uri, Position::new(line, character))),
            Backend::Process { .. } => {
                let params = HoverParams::new(uri, line, character);
                let res = self.send_request("textDocument/hover", Some(serde_json::to_value(params)?))?;
                if res.is_null() {
                    return Ok(None);
                }
                let hover: Option<Hover> = serde_json::from_value(res).ok();
                Ok(hover)
            }
        }
    }

    // -----------------------------------------------------------------------
    // P2.5 Completion: Candidate Suggestions
    // -----------------------------------------------------------------------

    pub fn completion(&self, uri: &str, line: u32, character: u32) -> Result<Vec<CompletionItem>> {
        match &self.backend {
            Backend::Virtual(server) => Ok(server.completion(uri, Position::new(line, character))),
            Backend::Process { .. } => {
                let params = CompletionParams::new(uri, line, character);
                let res = self.send_request("textDocument/completion", Some(serde_json::to_value(params)?))?;
                if res.is_null() {
                    return Ok(Vec::new());
                }
                if let Ok(list) = serde_json::from_value::<CompletionList>(res.clone()) {
                    return Ok(list.items);
                }
                let items: Vec<CompletionItem> = serde_json::from_value(res).unwrap_or_default();
                Ok(items)
            }
        }
    }

    // -----------------------------------------------------------------------
    // P2.6 Rename: Workspace-wide Atomic Refactoring
    // -----------------------------------------------------------------------

    pub fn rename(&self, uri: &str, line: u32, character: u32, new_name: &str) -> Result<Option<WorkspaceEdit>> {
        match &self.backend {
            Backend::Virtual(server) => Ok(server.rename(uri, Position::new(line, character), new_name)),
            Backend::Process { .. } => {
                let params = RenameParams {
                    text_document: TextDocumentIdentifier::new(uri),
                    position: Position::new(line, character),
                    new_name: new_name.to_string(),
                };
                let res = self.send_request("textDocument/rename", Some(serde_json::to_value(params)?))?;
                if res.is_null() {
                    return Ok(None);
                }
                let edit: Option<WorkspaceEdit> = serde_json::from_value(res).ok();
                Ok(edit)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Document Synchronization & Lifecycle
    // -----------------------------------------------------------------------

    pub fn did_open(&self, uri: &str, language_id: &str, text: &str) -> Result<Vec<Diagnostic>> {
        match &self.backend {
            Backend::Virtual(server) => {
                let diags = server.open_document(uri, text);
                self.diagnostics_cache.write().insert(uri.to_string(), diags.clone());
                if let Some(listener) = self.diagnostics_listener.read().as_ref() {
                    listener(uri, &diags);
                }
                Ok(diags)
            }
            Backend::Process { .. } => {
                let params = DidOpenTextDocumentParams {
                    text_document: TextDocumentItem {
                        uri: uri.to_string(),
                        language_id: language_id.to_string(),
                        version: 1,
                        text: text.to_string(),
                    },
                };
                self.send_notification("textDocument/didOpen", Some(serde_json::to_value(params)?))?;
                Ok(self.get_diagnostics(uri))
            }
        }
    }

    pub fn did_change(&self, uri: &str, version: i32, text: &str) -> Result<Vec<Diagnostic>> {
        match &self.backend {
            Backend::Virtual(server) => {
                let diags = server.update_document(uri, text);
                self.diagnostics_cache.write().insert(uri.to_string(), diags.clone());
                if let Some(listener) = self.diagnostics_listener.read().as_ref() {
                    listener(uri, &diags);
                }
                Ok(diags)
            }
            Backend::Process { .. } => {
                let params = DidChangeTextDocumentParams {
                    text_document: VersionedTextDocumentIdentifier {
                        uri: uri.to_string(),
                        version,
                    },
                    content_changes: vec![TextDocumentContentChangeEvent {
                        range: None,
                        text: text.to_string(),
                    }],
                };
                self.send_notification("textDocument/didChange", Some(serde_json::to_value(params)?))?;
                Ok(self.get_diagnostics(uri))
            }
        }
    }

    pub fn did_close(&self, uri: &str) {
        if let Backend::Virtual(server) = &self.backend {
            server.close_document(uri);
        }
        self.diagnostics_cache.write().remove(uri);
    }

    pub fn shutdown(&self) {
        self.is_running.store(false, Ordering::Relaxed);
        let _ = self.send_request("shutdown", None);
        let _ = self.send_notification("exit", None);
    }

    // -----------------------------------------------------------------------
    // Internal JSON-RPC Machinery
    // -----------------------------------------------------------------------

    fn send_request(&self, method: &str, params: Option<serde_json::Value>) -> Result<serde_json::Value> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = JsonRpcRequest::new(id, method, params);

        match &self.backend {
            Backend::Virtual(_) => Err(anyhow!("Virtual backend handles high-level methods directly")),
            Backend::Process {
                writer,
                pending_requests,
                ..
            } => {
                let cond_pair = Arc::new((Mutex::new(None), Condvar::new()));
                pending_requests.lock().insert(id, Arc::clone(&cond_pair));

                let req_json = serde_json::to_string(&req)?;
                writer.lock().write_message(&req_json)?;

                // Wait with 5-second timeout
                let (lock, cvar) = &*cond_pair;
                let mut guard = lock.lock();
                let timeout = Duration::from_secs(5);
                let wait_result = cvar.wait_for(&mut guard, timeout);

                pending_requests.lock().remove(&id);

                if wait_result.timed_out() {
                    return Err(anyhow!("LSP request '{}' (id: {}) timed out", method, id));
                }

                match guard.take() {
                    Some(res) => res,
                    None => Err(anyhow!("No response received for request {}", id)),
                }
            }
        }
    }

    fn send_notification(&self, method: &str, params: Option<serde_json::Value>) -> Result<()> {
        let notif = JsonRpcNotification::new(method, params);
        if let Backend::Process { writer, .. } = &self.backend {
            let notif_json = serde_json::to_string(&notif)?;
            writer.lock().write_message(&notif_json)?;
        }
        Ok(())
    }

    fn dispatch_message(
        raw_json: &str,
        pending_requests: &Mutex<HashMap<u64, Arc<(Mutex<Option<Result<serde_json::Value>>>, Condvar)>>>,
        diagnostics_cache: &RwLock<HashMap<String, Vec<Diagnostic>>>,
        diagnostics_listener: &RwLock<Option<DiagnosticsCallback>>,
    ) {
        if let Ok(resp) = serde_json::from_str::<JsonRpcResponse>(raw_json) {
            if let Some(pair) = pending_requests.lock().remove(&resp.id) {
                let (lock, cvar) = &*pair;
                let mut guard = lock.lock();
                if let Some(err) = resp.error {
                    *guard = Some(Err(anyhow!("LSP error {}: {}", err.code, err.message)));
                } else {
                    *guard = Some(Ok(resp.result.unwrap_or(serde_json::Value::Null)));
                }
                cvar.notify_all();
            }
            return;
        }

        if let Ok(notif) = serde_json::from_str::<JsonRpcNotification>(raw_json) {
            if notif.method == "textDocument/publishDiagnostics" {
                if let Some(params_val) = notif.params {
                    if let Ok(params) = serde_json::from_value::<PublishDiagnosticsParams>(params_val) {
                        diagnostics_cache
                            .write()
                            .insert(params.uri.clone(), params.diagnostics.clone());
                        if let Some(listener) = diagnostics_listener.read().as_ref() {
                            listener(&params.uri, &params.diagnostics);
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lsp_client_virtual_workflow() {
        let server = VirtualLspServer::new();
        let client = LspClient::new_virtual(server);

        let code = r#"
pub struct Engine {
    pub power: u32,
}

impl Engine {
    pub fn start(&self) {
        println!("Running");
    }
}

fn run_engine() {
    let eng = Engine { power: 100 };
    eng.start();
}
"#;

        let uri = "file:///workspace/src/engine.rs";

        // 1. Diagnostics (P2.1)
        let diags = client.did_open(uri, "rust", code).unwrap();
        assert!(diags.is_empty(), "Valid code should have zero diagnostics");
        assert!(!client.has_errors(uri));

        // 2. Definition (P2.2)
        // Click on `start` at line 13, col 9
        let defs = client.goto_definition(uri, 13, 9).unwrap();
        assert!(!defs.is_empty(), "Should navigate to definition of start");

        // 3. References (P2.3)
        // References for `Engine` at line 1, col 12
        let refs = client.find_references(uri, 1, 12, true).unwrap();
        assert!(refs.len() >= 3, "Should find Engine declaration, impl, and usage");

        // 4. Hover (P2.4)
        let hover = client.hover(uri, 1, 12).unwrap();
        assert!(hover.is_some());
        let md = hover.unwrap().contents.to_markdown();
        assert!(md.contains("struct Engine"));

        // 5. Completion (P2.5)
        let comps = client.completion(uri, 14, 9).unwrap();
        assert!(comps.iter().any(|c| c.label == "start"));
        assert!(comps.iter().any(|c| c.label == "Engine"));

        // 6. Rename (P2.6)
        let edit = client.rename(uri, 1, 12, "SuperEngine").unwrap();
        assert!(edit.is_some());
        let changes = edit.unwrap().changes.unwrap();
        assert!(changes.contains_key(uri));
    }
}
