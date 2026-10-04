# CodeLiteX

A modern, high-performance code editor with built-in Git management, built in Rust.

`CodeLiteX` integrates a low-latency text editing core, Git management (status / stage / commit / diff / log), Language Server Protocol (**LSP**) support, workspace search & replace, and an embedded **PTY terminal**.

---

## Architecture Overview

```
                   ┌──────────────────────────────────────┐
                   │               CodeLiteX              │
                   └──────────────────┬───────────────────┘
                                      │
       ┌──────────────┬───────────────┼───────────────┐
       ▼              ▼               ▼               ▼
  Editor Core        Git             LSP          Terminal
 (Ropey/Cursors) (Status/Log/Diff) (Diagnostics)   (PTY Shell)
```

### Core Crates

- **`code-lite-core`**: High-performance text engine built on `ropey::Rope`.
  - $O(\log N)$ insertions, deletions, and slice queries.
  - Comprehensive coordinate system: `Point` (line, column), `Range`, character/byte offset conversions.
  - Multi-cursor and selection navigation engine with overlapping cursor normalization.
  - Transactional `UndoManager` supporting atomic batch edits, redo, and cursor state restoration.
  - High-level `Editor` orchestrator.

- **Git** lives in the Flutter app (`apps/code_lite_ui/lib/core/git/git_service.dart`): a pure Dart wrapper over the system `git` CLI — status, stage/unstage, commit, diff hunks, log/graph and history rewriting. The Rust core is being migrated to Dart module by module; Git was first.

- **LSP and file outline** live in the Flutter app (`apps/code_lite_ui/lib/core/lsp/`). The Rust core has no LSP client, code graph or local database.

- **`code-lite-fs`**: File system and updater.
  - Fast directory tree traversal with ignore rules (`.git`, `target`, `node_modules`, `.codelite`).
  - Multi-threaded / regex workspace search & replace.
  - Cross-platform differential auto-updater.

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
