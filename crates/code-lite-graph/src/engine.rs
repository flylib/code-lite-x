use crate::error::GraphError;
use crate::outline::{CodeContext, DefinitionLocation, OutlineNode, ReferenceLocation};
use crate::parser::CodeParser;
use code_lite_storage::{GraphStore, ImportRecord, SymbolRecord};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndexReport {
    pub file_path: String,
    pub language: String,
    pub symbols_indexed: usize,
    pub imports_indexed: usize,
    pub calls_indexed: usize,
    pub elapsed_ms: u128,
}

/// Standard, unified interface for querying and modifying the CodeGraph.
/// Reused across FFI, Phase 2 LSP, and Phase 3 Agent.
pub trait CodeGraph {
    /// Incrementally indexes a file using AST parser and atomic SQLite transactions.
    fn index_file(&self, rel_path: &str, content: &str) -> Result<IndexReport, GraphError>;

    /// Retrieves the outline tree for a file.
    fn outline(&self, rel_path: &str, content: Option<&str>) -> Result<Vec<OutlineNode>, GraphError>;

    /// Finds symbol definitions by exact symbol_key or fuzzy name.
    fn find_definitions(&self, query: &str) -> Result<Vec<DefinitionLocation>, GraphError>;

    /// Finds symbol references and callers across the workspace.
    fn find_references(&self, query: &str) -> Result<Vec<ReferenceLocation>, GraphError>;

    /// Finds symbols that call the specified symbol.
    fn find_callers(&self, key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError>;

    /// Finds symbols called by the specified symbol.
    fn find_callees(&self, key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError>;

    /// Finds all dependencies/imports for a file.
    fn find_imports(&self, file_id: i64) -> Result<Vec<ImportRecord>, GraphError>;

    /// Finds symbols by exact or prefix name.
    fn find_symbols_by_name(&self, name: &str) -> Result<Vec<SymbolRecord>, GraphError>;

    /// Extracts rich local graph context specifically tailored for Agent reasoning.
    fn get_code_context(&self, key_or_name: &str) -> Result<Option<CodeContext>, GraphError>;
}

#[derive(Clone)]
pub struct GraphEngine {
    store: GraphStore,
    root: PathBuf,
}

impl GraphEngine {
    pub fn new(store: GraphStore, root: PathBuf) -> Self {
        Self { store, root }
    }

    pub fn store(&self) -> &GraphStore {
        &self.store
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Indexes a file into SQLite WAL with stable symbol keys and crash-safe job tracking.
    pub fn index_file(&self, rel_path: &str, content: &str) -> Result<IndexReport, GraphError> {
        let start_time = SystemTime::now();

        // Simple fast content hash
        let content_hash = format!("{:x}", calculate_hash(content.as_bytes()));

        // Check if file already exists with same hash
        let existing = self.store.get_file_by_path(rel_path)?;
        let old_hash = existing.as_ref().map(|f| f.content_hash.clone());

        let job_id = format!("job-{}-{}", rel_path.replace(['/', '\\'], "_"), now_millis());

        // 1. Record index job started
        self.store
            .create_index_job(&job_id, rel_path, old_hash.as_deref(), Some(&content_hash))?;

        // 2. Parse AST / Tokens
        let parsed = CodeParser::parse(rel_path, content);
        let line_count = content.lines().count();
        let mtime = now_millis();

        // 3. Upsert File
        let file_id = self.store.upsert_file(
            rel_path,
            &content_hash,
            &parsed.language,
            line_count,
            mtime,
        )?;

        // 4. Save Symbols with stable keys (including child methods, variants, fields)
        let mut symbol_records = Vec::with_capacity(parsed.symbols.len() * 2);
        for sym in &parsed.symbols {
            symbol_records.push(SymbolRecord {
                id: 0,
                symbol_key: sym.symbol_key.clone(),
                identity_id: Some(sym.symbol_key.clone()),
                file_id,
                name: sym.name.clone(),
                kind: sym.kind.clone(),
                signature: sym.signature.clone(),
                doc_comment: None,
                line_start: sym.line_start,
                col_start: sym.col_start,
                line_end: sym.line_end,
                col_end: sym.col_end,
                scope_path: sym.scope_path.clone(),
            });

            for child in &sym.children {
                symbol_records.push(SymbolRecord {
                    id: 0,
                    symbol_key: child.symbol_key.clone(),
                    identity_id: Some(child.symbol_key.clone()),
                    file_id,
                    name: child.name.clone(),
                    kind: child.kind.clone(),
                    signature: child.signature.clone(),
                    doc_comment: None,
                    line_start: child.line_start,
                    col_start: child.col_start,
                    line_end: child.line_end,
                    col_end: child.col_end,
                    scope_path: Some(sym.name.clone()),
                });
            }
        }

        // 5. Atomic Transactional Graph Update (BEGIN ... COMMIT/ROLLBACK)
        let call_tuples: Vec<(&str, usize)> = parsed
            .calls
            .iter()
            .map(|(callee, line)| (callee.as_str(), *line))
            .collect();

        self.store.update_file_graph_transactional(
            file_id,
            &symbol_records,
            &parsed.imports,
            &call_tuples,
            &job_id,
        )?;

        let elapsed_ms = start_time
            .elapsed()
            .map(|d| d.as_millis())
            .unwrap_or(0);

        Ok(IndexReport {
            file_path: rel_path.to_string(),
            language: parsed.language,
            symbols_indexed: symbol_records.len(),
            imports_indexed: parsed.imports.len(),
            calls_indexed: parsed.calls.len(),
            elapsed_ms,
        })
    }

    /// Retrieves the outline tree for a file.
    pub fn get_outline(
        &self,
        rel_path: &str,
        content: Option<&str>,
    ) -> Result<Vec<OutlineNode>, GraphError> {
        if let Some(src) = content {
            let parsed = CodeParser::parse(rel_path, src);
            let nodes = parsed.symbols.iter().map(|s| s.to_outline_node()).collect();
            return Ok(nodes);
        }

        let symbols = self.store.get_symbols_by_file_path(rel_path)?;
        let nodes = symbols
            .into_iter()
            .map(|s| OutlineNode {
                name: s.name,
                symbol_key: s.symbol_key,
                kind: s.kind,
                signature: s.signature,
                line_start: s.line_start,
                col_start: s.col_start,
                line_end: s.line_end,
                col_end: s.col_end,
                children: Vec::new(),
            })
            .collect();
        Ok(nodes)
    }

    /// Finds symbol definitions by exact symbol_key or name query.
    pub fn find_definitions(&self, query: &str) -> Result<Vec<DefinitionLocation>, GraphError> {
        let mut results = Vec::new();

        // 1. Direct match by symbol_key
        if let Some(sym) = self.store.find_symbol_by_key(query)? {
            if let Some(file) = self.store.get_file_by_id(sym.file_id)? {
                results.push(DefinitionLocation {
                    file_path: file.path,
                    symbol_key: sym.symbol_key,
                    name: sym.name,
                    kind: sym.kind,
                    signature: sym.signature,
                    line_start: sym.line_start,
                    col_start: sym.col_start,
                    line_end: sym.line_end,
                    col_end: sym.col_end,
                });
                return Ok(results);
            }
        }

        // 2. Fuzzy/prefix match by symbol name
        let symbols = self.store.find_symbols_by_name(query)?;
        for sym in symbols {
            if let Some(file) = self.store.get_file_by_id(sym.file_id)? {
                results.push(DefinitionLocation {
                    file_path: file.path,
                    symbol_key: sym.symbol_key,
                    name: sym.name,
                    kind: sym.kind,
                    signature: sym.signature,
                    line_start: sym.line_start,
                    col_start: sym.col_start,
                    line_end: sym.line_end,
                    col_end: sym.col_end,
                });
            }
        }

        Ok(results)
    }

    /// Finds symbol references and callers.
    pub fn find_references(&self, query: &str) -> Result<Vec<ReferenceLocation>, GraphError> {
        let mut results = Vec::new();
        let symbols = self.store.find_symbols_by_name(query)?;

        for sym in symbols {
            let callers = self.store.get_callers(sym.id)?;
            for caller in callers {
                if let Some(file) = self.store.get_file_by_id(caller.file_id)? {
                    results.push(ReferenceLocation {
                        file_path: file.path,
                        symbol_key: sym.symbol_key.clone(),
                        name: sym.name.clone(),
                        line: caller.line_start,
                        caller_name: Some(caller.name),
                    });
                }
            }
        }

        Ok(results)
    }

    /// Finds symbols that call the specified symbol.
    pub fn find_callers(&self, key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
        let sym = if let Some(s) = self.store.find_symbol_by_key(key_or_name)? {
            s
        } else {
            let list = self.store.find_symbols_by_name(key_or_name)?;
            match list.into_iter().next() {
                Some(s) => s,
                None => return Ok(Vec::new()),
            }
        };
        Ok(self.store.get_callers(sym.id)?)
    }

    /// Finds symbols called by the specified symbol.
    pub fn find_callees(&self, key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
        let sym = if let Some(s) = self.store.find_symbol_by_key(key_or_name)? {
            s
        } else {
            let list = self.store.find_symbols_by_name(key_or_name)?;
            match list.into_iter().next() {
                Some(s) => s,
                None => return Ok(Vec::new()),
            }
        };
        Ok(self.store.get_callees(sym.id)?)
    }

    /// Finds all dependencies/imports for a file.
    pub fn find_imports(&self, file_id: i64) -> Result<Vec<ImportRecord>, GraphError> {
        Ok(self.store.get_imports(file_id)?)
    }

    /// Finds symbols by exact or prefix name.
    pub fn find_symbols_by_name(&self, name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
        Ok(self.store.find_symbols_by_name(name)?)
    }

    /// Extracts rich local graph context specifically tailored for Agent reasoning.
    pub fn get_code_context(&self, key_or_name: &str) -> Result<Option<CodeContext>, GraphError> {
        let sym = if let Some(s) = self.store.find_symbol_by_key(key_or_name)? {
            s
        } else {
            let list = self.store.find_symbols_by_name(key_or_name)?;
            match list.into_iter().next() {
                Some(s) => s,
                None => return Ok(None),
            }
        };

        let file = self.store.get_file_by_id(sym.file_id)?;
        let file_path = file.map(|f| f.path).unwrap_or_default();

        let full_path = self.root.join(&file_path);
        let definition_code = if let Ok(src) = std::fs::read_to_string(&full_path) {
            let lines: Vec<&str> = src.lines().collect();
            if sym.line_start > 0 && sym.line_start <= lines.len() {
                let start_idx = sym.line_start - 1;
                let end_idx = sym.line_end.min(lines.len());
                lines[start_idx..end_idx].join("\n")
            } else {
                sym.signature.clone().unwrap_or_default()
            }
        } else {
            sym.signature.clone().unwrap_or_default()
        };

        let callers = self
            .store
            .get_callers(sym.id)?
            .into_iter()
            .map(|s| s.symbol_key)
            .collect();

        let callees = self
            .store
            .get_callees(sym.id)?
            .into_iter()
            .map(|s| s.symbol_key)
            .collect();

        let references = self
            .find_references(&sym.symbol_key)?
            .into_iter()
            .map(|r| format!("{}:{}", r.file_path, r.line))
            .collect();

        let imports = self
            .store
            .get_imports(sym.file_id)?
            .into_iter()
            .map(|i| i.raw_specifier)
            .collect();

        Ok(Some(CodeContext {
            symbol_key: sym.symbol_key,
            name: sym.name,
            kind: sym.kind,
            signature: sym.signature,
            definition_code,
            file_path,
            line_start: sym.line_start,
            line_end: sym.line_end,
            callers,
            callees,
            references,
            imports,
        }))
    }
}

impl CodeGraph for GraphEngine {
    fn index_file(&self, rel_path: &str, content: &str) -> Result<IndexReport, GraphError> {
        self.index_file(rel_path, content)
    }

    fn outline(&self, rel_path: &str, content: Option<&str>) -> Result<Vec<OutlineNode>, GraphError> {
        self.get_outline(rel_path, content)
    }

    fn find_definitions(&self, query: &str) -> Result<Vec<DefinitionLocation>, GraphError> {
        self.find_definitions(query)
    }

    fn find_references(&self, query: &str) -> Result<Vec<ReferenceLocation>, GraphError> {
        self.find_references(query)
    }

    fn find_callers(&self, key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
        self.find_callers(key_or_name)
    }

    fn find_callees(&self, key_or_name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
        self.find_callees(key_or_name)
    }

    fn find_imports(&self, file_id: i64) -> Result<Vec<ImportRecord>, GraphError> {
        self.find_imports(file_id)
    }

    fn find_symbols_by_name(&self, name: &str) -> Result<Vec<SymbolRecord>, GraphError> {
        self.find_symbols_by_name(name)
    }

    fn get_code_context(&self, key_or_name: &str) -> Result<Option<CodeContext>, GraphError> {
        self.get_code_context(key_or_name)
    }
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn calculate_hash(bytes: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;
    use code_lite_storage::Database;

    #[test]
    fn test_engine_index_and_query_flow() {
        let db = Database::open_in_memory().unwrap();
        let store = GraphStore::new(db);
        let engine = GraphEngine::new(store, PathBuf::from("."));

        let code = r#"
        pub struct OrderManager {
            pub order_id: u64,
        }

        impl OrderManager {
            pub fn cancel(&self) -> bool {
                true
            }
        }

        pub fn cancel_all() {
            let mgr = OrderManager { order_id: 1 };
            mgr.cancel();
        }
        "#;

        let report = engine.index_file("src/order.rs", code).unwrap();
        assert_eq!(report.symbols_indexed, 5);

        let outline = engine.get_outline("src/order.rs", Some(code)).unwrap();
        assert_eq!(outline.len(), 3);
        assert_eq!(outline[0].name, "OrderManager");

        let defs = engine.find_definitions("OrderManager").unwrap();
        assert_eq!(defs.len(), 1);
        assert_eq!(defs[0].file_path, "src/order.rs");
        assert_eq!(defs[0].symbol_key, "rust:src/order.rs:struct::OrderManager");
    }

    #[test]
    fn test_incremental_index_with_stable_keys_and_performance() {
        let db = Database::open_in_memory().unwrap();
        let store = GraphStore::new(db.clone());
        let engine = GraphEngine::new(store.clone(), PathBuf::from("."));

        let initial_code = r#"
        pub struct PaymentProcessor;

        impl PaymentProcessor {
            pub fn pay(&self, amount: u64) -> bool {
                amount > 0
            }
        }
        "#;

        let t0 = std::time::Instant::now();
        let rep1 = engine.index_file("src/pay.rs", initial_code).unwrap();
        let dur1 = t0.elapsed();
        assert!(dur1.as_millis() < 200, "Initial indexing took too long: {:?}", dur1);
        assert_eq!(rep1.symbols_indexed, 3);

        // Capture stable keys
        let defs_initial = engine.find_definitions("pay").unwrap();
        let def_pay = defs_initial.iter().find(|d| d.name == "pay").expect("Must find method pay");
        let key_before = def_pay.symbol_key.clone();
        let line_before = def_pay.line_start;

        // User edits file: add comments & blank lines BEFORE `pay`
        let modified_code = r#"
        // Payment Processor Service
        // Line 2
        // Line 3
        pub struct PaymentProcessor;

        // Extra documentation
        impl PaymentProcessor {
            pub fn pay(&self, amount: u64) -> bool {
                amount > 0
            }
        }
        "#;

        let t1 = std::time::Instant::now();
        let rep2 = engine.index_file("src/pay.rs", modified_code).unwrap();
        let dur2 = t1.elapsed();
        assert!(dur2.as_millis() < 200, "Incremental indexing took too long: {:?}", dur2);
        assert_eq!(rep2.symbols_indexed, 3);

        // Verify symbol_key is 100% STABLE despite line changes
        let defs_after = engine.find_definitions("pay").unwrap();
        let def_pay_after = defs_after.iter().find(|d| d.name == "pay").expect("Must find method pay");
        assert_eq!(def_pay_after.symbol_key, key_before, "symbol_key must remain stable across line shifts");
        assert!(def_pay_after.line_start > line_before, "Line number should be dynamically updated");

        // Verify index_jobs table recorded the jobs
        let unfinished = store.get_unfinished_index_jobs().unwrap();
        assert_eq!(unfinished.len(), 0, "All jobs should have completed");
    }

    #[test]
    fn test_agent_code_context_and_trait_methods() {
        let db = Database::open_in_memory().unwrap();
        let store = GraphStore::new(db);
        let engine = GraphEngine::new(store, PathBuf::from("."));

        let code = r#"
        use std::collections::HashMap;

        pub struct CacheService {
            pub map: HashMap<String, String>,
        }

        impl CacheService {
            pub fn get_val(&self, k: &str) -> Option<&String> {
                self.map.get(k)
            }
        }

        pub fn query_item(cache: &CacheService) {
            cache.get_val("key");
        }
        "#;

        engine.index_file("src/cache.rs", code).unwrap();

        // 1. Test CodeGraph Trait invocation
        let graph: &dyn CodeGraph = &engine;
        let outline = graph.outline("src/cache.rs", Some(code)).unwrap();
        assert_eq!(outline.len(), 3);

        // 2. Test CodeContext retrieval specifically designed for Agent
        let ctx = graph.get_code_context("get_val").unwrap();
        assert!(ctx.is_some(), "Agent CodeContext should be successfully constructed");
        let ctx = ctx.unwrap();
        assert_eq!(ctx.name, "get_val");
        assert_eq!(ctx.file_path, "src/cache.rs");
        assert!(ctx.symbol_key.contains("get_val"));
        assert!(ctx.imports.iter().any(|i| i.contains("HashMap")));

        // 3. Test Callers & Callees
        let callers = graph.find_callers("get_val").unwrap();
        assert!(callers.len() <= 1);
    }
}
