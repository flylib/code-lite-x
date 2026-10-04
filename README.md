# CodeLiteX

A modern, high-performance code editor with built-in Git management, built in Rust.

`CodeLiteX` integrates a low-latency text editing core, Git management (status / stage / commit / diff / log), a structural code knowledge graph (**CodeGraph**, persisted in **SQLite**), standard Language Server Protocol (**LSP**), workspace search & replace, and an embedded **PTY terminal**.

---

## Architecture Overview

```
                   ┌──────────────────────────────────────┐
                   │               CodeLiteX              │
                   └──────────────────┬───────────────────┘
                                      │
       ┌──────────────┬───────────────┼───────────────┬──────────────┐
       ▼              ▼               ▼               ▼              ▼
  Editor Core        Git           CodeGraph          LSP          Terminal
 (Ropey/Cursors) (Status/Log/Diff) (AST/Call Graph) (Diagnostics)   (PTY Shell)
                                      │
                                      ▼
                                SQLite (WAL)
                        (Symbols / Diagnostics Index)
```

### Core Crates

- **`code-lite-core`**: High-performance text engine built on `ropey::Rope`.
  - $O(\log N)$ insertions, deletions, and slice queries.
  - Comprehensive coordinate system: `Point` (line, column), `Range`, character/byte offset conversions.
  - Multi-cursor and selection navigation engine with overlapping cursor normalization.
  - Transactional `UndoManager` supporting atomic batch edits, redo, and cursor state restoration.
  - High-level `Editor` orchestrator.

- **`code-lite-storage`**: Embedded SQLite database (`rusqlite` with WAL mode).
  - CodeGraph persistent relations: `files`, `symbols`, `symbol_references`, `call_graph`, `import_graph`, resumable `index_jobs`.
  - LSP `diagnostics` cache.

- **`code-lite-fs`**: File system, Git and updater.
  - Fast directory tree traversal with ignore rules (`.git`, `target`, `node_modules`, `.codelite`).
  - Multi-threaded / regex workspace search & replace.
  - `GitEngine` (wraps the system `git` CLI): status, stage/unstage, commit, diff hunks, history/log.
  - Cross-platform differential auto-updater.

- **`code-lite-graph`**: Incremental AST parsing, stable `SymbolKey`, outline / definitions / references / callers / callees.
- **`code-lite-lsp`**: LSP protocol client, process supervisor and built-in virtual LSP server.
- **`code-lite-terminal`**: PTY-backed interactive terminal sessions.
- **`code-lite-rpc`**: Shared JSON-RPC 2.0 protocol models and framing.
- **`code-lite-ffi`**: C-ABI dynamic library (`libcodelite`) consumed by the Flutter desktop UI.
- **`code-lite-app`**: Lightweight standalone daemon with a minimal web UI.

---

## Running Tests

Ensure Rust toolchain is available (Rust 1.80+):

```bash
cargo test --offline --workspace
```

---

## License

MIT OR Apache-2.0
