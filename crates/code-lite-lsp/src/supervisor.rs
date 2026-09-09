//! # ProcessSupervisor
//!
//! Enterprise language server supervisor for CodeLiteX.
//!
//! Responsibilities:
//! 1. Binary auto-detection & language routing (`rust-analyzer`, `gopls`, `clangd`, `vtsls`, `dart`);
//! 2. Multi-instance lifecycle hosting & graceful fallback to `VirtualLspServer`;
//! 3. Open documents tracking (`open_documents`) for stateful replay;
//! 4. Crash self-healing with exponential backoff & automatic `textDocument/didOpen` replay;
//! 5. Concurrency architecture adhering strictly to D2: `std::thread` + `parking_lot`, no tokio.

use crate::client::LspClient;
use crate::protocol::*;
use crate::virtual_server::{replace_range_in_text, VirtualLspServer};
use anyhow::Result;
use parking_lot::{Mutex, RwLock};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Server runtime lifecycle state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ServerState {
    Running,
    Restarting,
    Failed,
    Stopped,
}

/// Configuration for launching an external language server process.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    pub language_id: String,
    pub command: String,
    pub args: Vec<String>,
}

/// Tracked open document state for replay across crashes and reconnects.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenDocument {
    pub uri: String,
    pub language_id: String,
    pub version: i32,
    pub text: String,
}

/// Managed language server instance.
pub struct ManagedServer {
    pub language_id: String,
    pub config: ServerConfig,
    pub is_virtual: bool,
    pub client: Arc<LspClient>,
    pub state: Arc<RwLock<ServerState>>,
    pub restart_count: Arc<AtomicU32>,
    pub last_crash_time: Arc<Mutex<Option<Instant>>>,
}

/// Status report for the language server supervisor.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupervisorStatus {
    pub active_servers: HashMap<String, ManagedServerStatus>,
    pub tracked_documents_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagedServerStatus {
    pub language_id: String,
    pub command: String,
    pub is_virtual: bool,
    pub state: ServerState,
    pub restart_count: u32,
    pub supports_incremental_sync: bool,
    pub supports_rename: bool,
}

/// Process supervisor orchestrating language server processes across the workspace.
pub struct ProcessSupervisor {
    workspace_root: PathBuf,
    servers: Arc<RwLock<HashMap<String, Arc<ManagedServer>>>>,
    open_documents: Arc<RwLock<HashMap<String, OpenDocument>>>,
    server_configs: Arc<RwLock<HashMap<String, ServerConfig>>>,
    fallback_client: Arc<LspClient>,
    auto_spawn_external: std::sync::atomic::AtomicBool,
}

impl ProcessSupervisor {
    /// Creates a new ProcessSupervisor rooted at workspace_root.
    pub fn new(workspace_root: impl Into<PathBuf>, fallback_virtual: VirtualLspServer) -> Self {
        Self {
            workspace_root: workspace_root.into(),
            servers: Arc::new(RwLock::new(HashMap::new())),
            open_documents: Arc::new(RwLock::new(HashMap::new())),
            server_configs: Arc::new(RwLock::new(HashMap::new())),
            fallback_client: Arc::new(LspClient::new_virtual(fallback_virtual)),
            auto_spawn_external: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Builder pattern to configure automatic external process detection and spawning.
    pub fn with_auto_spawn(self, enabled: bool) -> Self {
        self.auto_spawn_external.store(enabled, Ordering::SeqCst);
        self
    }

    /// Dynamically enable or disable automatic external server detection.
    pub fn enable_auto_spawn(&self, enabled: bool) {
        self.auto_spawn_external.store(enabled, Ordering::SeqCst);
    }

    /// Checks if automatic external server detection is enabled.
    pub fn is_auto_spawn_enabled(&self) -> bool {
        self.auto_spawn_external.load(Ordering::SeqCst)
    }

    /// Normalizes language identifiers (e.g. "rs" -> "rust", "ts" -> "typescript").
    pub fn normalize_language_id(lang: &str) -> &'static str {
        match lang.to_lowercase().as_str() {
            "rust" | "rs" => "rust",
            "go" | "golang" => "go",
            "c" | "cpp" | "cxx" | "h" | "hpp" => "cpp",
            "typescript" | "ts" | "tsx" => "typescript",
            "javascript" | "js" | "jsx" => "javascript",
            "dart" => "dart",
            _ => "unknown",
        }
    }

    /// Detects candidate binary and arguments for a normalized language.
    pub fn default_command_for_language(lang: &str) -> Option<(&'static str, Vec<&'static str>)> {
        match Self::normalize_language_id(lang) {
            "rust" => Some(("rust-analyzer", vec![])),
            "go" => Some(("gopls", vec![])),
            "cpp" => Some(("clangd", vec![])),
            "typescript" | "javascript" => {
                if find_binary_on_path("vtsls").is_some() {
                    Some(("vtsls", vec!["--stdio"]))
                } else {
                    Some(("typescript-language-server", vec!["--stdio"]))
                }
            }
            "dart" => {
                if find_binary_on_path("dart").is_some() {
                    Some(("dart", vec!["language-server"]))
                } else {
                    Some(("dart_analysis_server", vec![]))
                }
            }
            _ => None,
        }
    }

    /// Explicitly registers or overrides a command configuration for a language.
    pub fn set_server_config(&self, language: &str, command: &str, args: &[&str]) {
        let norm = Self::normalize_language_id(language).to_string();
        self.server_configs.write().insert(
            norm.clone(),
            ServerConfig {
                language_id: norm,
                command: command.to_string(),
                args: args.iter().map(|s| s.to_string()).collect(),
            },
        );
    }

    /// Retrieves or spawns the language server for a given language.
    pub fn get_or_spawn(&self, language: &str) -> Result<Arc<ManagedServer>> {
        let norm = Self::normalize_language_id(language).to_string();

        // 1. Fast path: check existing healthy server
        {
            let servers = self.servers.read();
            if let Some(managed) = servers.get(&norm) {
                if managed.client.is_alive() {
                    return Ok(Arc::clone(managed));
                }
            }
        }

        // 2. Slow path: write lock and spawn / self-heal
        let mut servers = self.servers.write();
        if let Some(managed) = servers.get(&norm).cloned() {
            if managed.client.is_alive() {
                return Ok(managed);
            }
            // Crash self-healing path
            return self.self_heal_server(&norm, &managed, &mut servers);
        }

        // 3. New server initialization path
        let managed = self.spawn_server_instance(&norm, 0)?;
        servers.insert(norm, Arc::clone(&managed));
        Ok(managed)
    }

    /// Spawns a new server instance (either external process or VirtualLspServer fallback).
    fn spawn_server_instance(&self, norm_lang: &str, restart_count: u32) -> Result<Arc<ManagedServer>> {
        let config = self
            .server_configs
            .read()
            .get(norm_lang)
            .cloned()
            .or_else(|| {
                if self.auto_spawn_external.load(Ordering::SeqCst) {
                    Self::default_command_for_language(norm_lang).map(|(cmd, args)| ServerConfig {
                        language_id: norm_lang.to_string(),
                        command: cmd.to_string(),
                        args: args.iter().map(|s| s.to_string()).collect(),
                    })
                } else {
                    None
                }
            });

        let mut spawned_client = None;
        let mut is_virtual = false;
        let final_config = if let Some(cfg) = config {
            if let Some(_bin_path) = find_binary_on_path(&cfg.command) {
                let args_slices: Vec<&str> = cfg.args.iter().map(|s| s.as_str()).collect();
                match LspClient::spawn_process(&cfg.command, &args_slices, &self.workspace_root) {
                    Ok(client) => {
                        spawned_client = Some(Arc::new(client));
                    }
                    Err(_) => {
                        // Process launch failed, fallback to Virtual
                        is_virtual = true;
                    }
                }
            } else {
                is_virtual = true;
            }
            cfg
        } else {
            is_virtual = true;
            ServerConfig {
                language_id: norm_lang.to_string(),
                command: "virtual".to_string(),
                args: vec![],
            }
        };

        let client = match spawned_client {
            Some(c) => c,
            None => {
                is_virtual = true;
                Arc::clone(&self.fallback_client)
            }
        };

        Ok(Arc::new(ManagedServer {
            language_id: norm_lang.to_string(),
            config: final_config,
            is_virtual,
            client,
            state: Arc::new(RwLock::new(ServerState::Running)),
            restart_count: Arc::new(AtomicU32::new(restart_count)),
            last_crash_time: Arc::new(Mutex::new(None)),
        }))
    }

    /// Performs exponential backoff restart and replays all tracked open documents.
    fn self_heal_server(
        &self,
        norm_lang: &str,
        old_managed: &Arc<ManagedServer>,
        servers: &mut HashMap<String, Arc<ManagedServer>>,
    ) -> Result<Arc<ManagedServer>> {
        *old_managed.state.write() = ServerState::Restarting;
        let restarts = old_managed.restart_count.fetch_add(1, Ordering::SeqCst) + 1;
        *old_managed.last_crash_time.lock() = Some(Instant::now());

        // Exponential backoff: base 50ms, doubling up to max 2000ms
        let backoff_shift = restarts.min(6);
        let delay_ms = (50u64 * (1 << backoff_shift)).min(2000);
        std::thread::sleep(Duration::from_millis(delay_ms));

        // Spawn replacement instance
        let new_managed = self.spawn_server_instance(norm_lang, restarts)?;

        // Replay all tracked open documents belonging to this language
        let docs = self.open_documents.read();
        for doc in docs.values() {
            if Self::normalize_language_id(&doc.language_id) == norm_lang {
                let _ = new_managed.client.did_open(&doc.uri, &doc.language_id, &doc.text);
            }
        }

        servers.insert(norm_lang.to_string(), Arc::clone(&new_managed));
        Ok(new_managed)
    }

    /// Forces a restart of the language server for the given language.
    pub fn restart_server(&self, language: &str) -> Result<()> {
        let norm = Self::normalize_language_id(language);
        let mut servers = self.servers.write();
        let old = servers.remove(norm);
        if let Some(old_managed) = old {
            old_managed.client.shutdown();
        }
        let new_managed = self.spawn_server_instance(norm, 0)?;

        // Replay open documents
        let docs = self.open_documents.read();
        for doc in docs.values() {
            if Self::normalize_language_id(&doc.language_id) == norm {
                let _ = new_managed.client.did_open(&doc.uri, &doc.language_id, &doc.text);
            }
        }

        servers.insert(norm.to_string(), new_managed);
        Ok(())
    }

    // -----------------------------------------------------------------------
    // High-Level Document Lifecycle & Synchronization
    // -----------------------------------------------------------------------

    /// Opens a document, records it in the open documents registry, and routes to the language server.
    pub fn did_open(&self, uri: &str, language_id: &str, text: &str) -> Result<Vec<Diagnostic>> {
        let norm = Self::normalize_language_id(language_id);
        let managed = self.get_or_spawn(norm)?;

        // Track in registry
        self.open_documents.write().insert(
            uri.to_string(),
            OpenDocument {
                uri: uri.to_string(),
                language_id: language_id.to_string(),
                version: 1,
                text: text.to_string(),
            },
        );

        // Keep fallback client in sync
        let _ = self.fallback_client.did_open(uri, language_id, text);

        match managed.client.did_open(uri, language_id, text) {
            Ok(diags) => Ok(diags),
            Err(e) => {
                if !managed.is_virtual {
                    *managed.state.write() = ServerState::Failed;
                    self.fallback_client.did_open(uri, language_id, text)
                } else {
                    Err(e)
                }
            }
        }
    }

    /// Full document synchronization. Updates tracked content and forwards to language server.
    pub fn did_change(&self, uri: &str, version: i32, text: &str) -> Result<Vec<Diagnostic>> {
        let lang = {
            let mut docs = self.open_documents.write();
            if let Some(doc) = docs.get_mut(uri) {
                doc.version = version;
                doc.text = text.to_string();
                doc.language_id.clone()
            } else {
                "unknown".to_string()
            }
        };

        let _ = self.fallback_client.did_change(uri, version, text);

        let managed = self.get_or_spawn(&lang)?;
        match managed.client.did_change(uri, version, text) {
            Ok(diags) => Ok(diags),
            Err(e) => {
                if !managed.is_virtual {
                    *managed.state.write() = ServerState::Failed;
                    self.fallback_client.did_change(uri, version, text)
                } else {
                    Err(e)
                }
            }
        }
    }

    /// Incremental document synchronization. Applies edit to tracked buffer and forwards to language server.
    pub fn did_change_incremental(
        &self,
        uri: &str,
        version: i32,
        range: Range,
        range_length: Option<u32>,
        new_text: &str,
    ) -> Result<Vec<Diagnostic>> {
        let lang = {
            let mut docs = self.open_documents.write();
            if let Some(doc) = docs.get_mut(uri) {
                doc.version = version;
                doc.text = replace_range_in_text(&doc.text, range, new_text);
                doc.language_id.clone()
            } else {
                "unknown".to_string()
            }
        };

        let _ = self.fallback_client.did_change_incremental(uri, version, range, range_length, new_text);

        let managed = self.get_or_spawn(&lang)?;
        match managed.client.did_change_incremental(uri, version, range, range_length, new_text) {
            Ok(diags) => Ok(diags),
            Err(e) => {
                if !managed.is_virtual {
                    *managed.state.write() = ServerState::Failed;
                    self.fallback_client.did_change_incremental(uri, version, range, range_length, new_text)
                } else {
                    Err(e)
                }
            }
        }
    }

    /// Closes a document, removing it from tracking.
    pub fn did_close(&self, uri: &str) {
        let lang = {
            let mut docs = self.open_documents.write();
            docs.remove(uri).map(|d| d.language_id)
        };

        self.fallback_client.did_close(uri);

        if let Some(lang) = lang {
            if let Ok(managed) = self.get_or_spawn(&lang) {
                managed.client.did_close(uri);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Cognitive Queries
    // -----------------------------------------------------------------------

    fn get_server_for_uri(&self, uri: &str) -> Result<Arc<ManagedServer>> {
        let lang = {
            let docs = self.open_documents.read();
            docs.get(uri).map(|d| d.language_id.clone())
        };

        let lang = lang.unwrap_or_else(|| {
            if uri.ends_with(".rs") {
                "rust".to_string()
            } else if uri.ends_with(".go") {
                "go".to_string()
            } else if uri.ends_with(".c") || uri.ends_with(".cpp") || uri.ends_with(".h") {
                "cpp".to_string()
            } else if uri.ends_with(".dart") {
                "dart".to_string()
            } else if uri.ends_with(".ts") || uri.ends_with(".tsx") {
                "typescript".to_string()
            } else if uri.ends_with(".js") || uri.ends_with(".jsx") {
                "javascript".to_string()
            } else {
                "unknown".to_string()
            }
        });

        self.get_or_spawn(&lang)
    }

    pub fn goto_definition(&self, uri: &str, line: u32, col: u32) -> Result<Vec<Location>> {
        if let Ok(managed) = self.get_server_for_uri(uri) {
            if let Ok(defs) = managed.client.goto_definition(uri, line, col) {
                if !defs.is_empty() {
                    return Ok(defs);
                }
            }
        }
        self.fallback_client.goto_definition(uri, line, col)
    }

    pub fn find_references(&self, uri: &str, line: u32, col: u32, include_decl: bool) -> Result<Vec<Location>> {
        if let Ok(managed) = self.get_server_for_uri(uri) {
            if let Ok(refs) = managed.client.find_references(uri, line, col, include_decl) {
                if !refs.is_empty() {
                    return Ok(refs);
                }
            }
        }
        self.fallback_client.find_references(uri, line, col, include_decl)
    }

    pub fn hover(&self, uri: &str, line: u32, col: u32) -> Result<Option<Hover>> {
        if let Ok(managed) = self.get_server_for_uri(uri) {
            if let Ok(Some(h)) = managed.client.hover(uri, line, col) {
                return Ok(Some(h));
            }
        }
        self.fallback_client.hover(uri, line, col)
    }

    pub fn completion(&self, uri: &str, line: u32, col: u32) -> Result<Vec<CompletionItem>> {
        if let Ok(managed) = self.get_server_for_uri(uri) {
            if let Ok(items) = managed.client.completion(uri, line, col) {
                if !items.is_empty() {
                    return Ok(items);
                }
            }
        }
        self.fallback_client.completion(uri, line, col)
    }

    pub fn rename(&self, uri: &str, line: u32, col: u32, new_name: &str) -> Result<Option<WorkspaceEdit>> {
        if let Ok(managed) = self.get_server_for_uri(uri) {
            if let Ok(Some(edit)) = managed.client.rename(uri, line, col, new_name) {
                return Ok(Some(edit));
            }
        }
        self.fallback_client.rename(uri, line, col, new_name)
    }

    pub fn get_diagnostics(&self, uri: &str) -> Vec<Diagnostic> {
        if let Ok(managed) = self.get_server_for_uri(uri) {
            let diags = managed.client.get_diagnostics(uri);
            if !diags.is_empty() {
                return diags;
            }
        }
        self.fallback_client.get_diagnostics(uri)
    }

    pub fn server_capabilities(&self, language_id: &str) -> Option<ServerCapabilities> {
        let norm = Self::normalize_language_id(language_id);
        let servers = self.servers.read();
        servers.get(norm).and_then(|m| m.client.server_capabilities())
    }

    /// Produces a comprehensive status report of all managed language servers.
    pub fn status(&self) -> SupervisorStatus {
        let servers = self.servers.read();
        let mut active = HashMap::new();

        for (lang, managed) in servers.iter() {
            active.insert(
                lang.clone(),
                ManagedServerStatus {
                    language_id: lang.clone(),
                    command: managed.config.command.clone(),
                    is_virtual: managed.is_virtual,
                    state: *managed.state.read(),
                    restart_count: managed.restart_count.load(Ordering::Relaxed),
                    supports_incremental_sync: managed.client.supports_incremental_sync(),
                    supports_rename: managed.client.supports_rename(),
                },
            );
        }

        SupervisorStatus {
            active_servers: active,
            tracked_documents_count: self.open_documents.read().len(),
        }
    }

    /// Shuts down all running servers gracefully.
    pub fn shutdown_all(&self) {
        let servers = self.servers.read();
        for managed in servers.values() {
            managed.client.shutdown();
            *managed.state.write() = ServerState::Stopped;
        }
    }
}

/// Cross-platform, non-blocking binary lookup on the PATH environment variable.
pub fn find_binary_on_path(binary: &str) -> Option<PathBuf> {
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join(binary);
            if candidate.is_file() {
                return Some(candidate);
            }
            #[cfg(windows)]
            {
                let candidate_exe = dir.join(format!("{}.exe", binary));
                if candidate_exe.is_file() {
                    return Some(candidate_exe);
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_language_normalization_and_commands() {
        assert_eq!(ProcessSupervisor::normalize_language_id("rs"), "rust");
        assert_eq!(ProcessSupervisor::normalize_language_id("Rust"), "rust");
        assert_eq!(ProcessSupervisor::normalize_language_id("golang"), "go");
        assert_eq!(ProcessSupervisor::normalize_language_id("tsx"), "typescript");
        assert_eq!(ProcessSupervisor::normalize_language_id("dart"), "dart");

        let rust_cmd = ProcessSupervisor::default_command_for_language("rust").unwrap();
        assert_eq!(rust_cmd.0, "rust-analyzer");

        let go_cmd = ProcessSupervisor::default_command_for_language("go").unwrap();
        assert_eq!(go_cmd.0, "gopls");

        let cpp_cmd = ProcessSupervisor::default_command_for_language("cpp").unwrap();
        assert_eq!(cpp_cmd.0, "clangd");
    }

    #[test]
    fn test_supervisor_virtual_fallback_and_lifecycle() {
        let supervisor = ProcessSupervisor::new(
            "/workspace",
            VirtualLspServer::new(),
        );

        let code = "fn add(a: i32, b: i32) -> i32 { a + b }";
        let uri = "file:///workspace/src/lib.rs";

        // did_open
        let diags = supervisor.did_open(uri, "rust", code).unwrap();
        assert!(diags.is_empty());

        let status = supervisor.status();
        assert_eq!(status.tracked_documents_count, 1);
        assert!(status.active_servers.contains_key("rust"));

        let rust_status = &status.active_servers["rust"];
        assert_eq!(rust_status.state, ServerState::Running);
        assert!(rust_status.supports_incremental_sync);
        assert!(rust_status.supports_rename);

        // Incremental edit
        let diags_inc = supervisor
            .did_change_incremental(uri, 2, Range::new(0, 32, 0, 37), Some(5), "a * b")
            .unwrap();
        assert!(diags_inc.is_empty());

        // Cognitive queries
        let hover = supervisor.hover(uri, 0, 3).unwrap();
        assert!(hover.is_some());

        let defs = supervisor.goto_definition(uri, 0, 3).unwrap();
        assert!(!defs.is_empty());

        // did_close
        supervisor.did_close(uri);
        let status_after = supervisor.status();
        assert_eq!(status_after.tracked_documents_count, 0);
    }

    #[test]
    fn test_supervisor_crash_self_healing_simulation() {
        let supervisor = ProcessSupervisor::new(
            "/workspace",
            VirtualLspServer::new(),
        );

        let uri = "file:///workspace/src/main.rs";
        let code = "fn main() { println!(\"Hello\"); }";
        supervisor.did_open(uri, "rust", code).unwrap();

        // Simulate server failure by shutting down active server
        let managed = supervisor.get_or_spawn("rust").unwrap();
        managed.client.shutdown();
        assert!(!managed.client.is_alive());

        // Next call will trigger self-healing and document replay!
        let diags = supervisor.did_change_incremental(
            uri,
            2,
            Range::new(0, 22, 0, 27),
            Some(5),
            "World",
        ).unwrap();
        assert!(diags.is_empty());

        let status = supervisor.status();
        let rust_status = &status.active_servers["rust"];
        assert_eq!(rust_status.state, ServerState::Running);
        assert_eq!(rust_status.restart_count, 1, "Must have restarted once");
        assert_eq!(status.tracked_documents_count, 1, "Tracked document must be preserved");
    }

    #[test]
    fn test_auto_spawn_flag_and_config() {
        let supervisor = ProcessSupervisor::new(
            "/workspace",
            VirtualLspServer::new(),
        );

        assert!(!supervisor.is_auto_spawn_enabled());
        supervisor.enable_auto_spawn(true);
        assert!(supervisor.is_auto_spawn_enabled());

        supervisor.set_server_config("rust", "nonexistent-server-bin", &["--foo"]);
        let managed = supervisor.get_or_spawn("rust").unwrap();
        // Since binary does not exist, it falls back to virtual server
        assert!(managed.is_virtual);
        assert_eq!(*managed.state.read(), ServerState::Running);
    }
}
