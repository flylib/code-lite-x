# CodeLiteX

A modern, high-performance, intelligent IDE and code editor engine built in Rust.

`CodeLiteX` integrates a low-latency text editing core, structural code knowledge graph (**CodeGraph**), transactional state and memory engine (**SQLite**), standard Language Server Protocol (**LSP**), and an autonomous **AI Coding Agent**.

---

## Architecture Overview

```
                   ┌──────────────────────────────────────┐
                   │               CodeLiteX              │
                   └──────────────────┬───────────────────┘
                                      │
       ┌──────────────┬───────────────┼───────────────┬──────────────┐
       ▼              ▼               ▼               ▼              ▼
  Editor Core     CodeGraph        SQLite            LSP          Terminal
 (Ropey/Cursors) (AST/Call Graph) (State/Memory)  (Diagnostics)   (PTY Shell)
       │              │               │               │              │
       └──────────────┴───────┬───────┴───────────────┴──────────────┘
                              ▼
                      AI Agent Engine
                              │
               ┌──────────────┴──────────────┐
               ▼                             ▼
      Graph-Aware Context            Reversible Operations
  (Call Chains & Impact Analysis)    (Patch Diff & Undo Rollback)
```

### Core Crates

- **`code-lite-core`**: High-performance text engine built on `ropey::Rope`.
  - $O(\log N)$ insertions, deletions, and slice queries.
  - Comprehensive coordinate system: `Point` (line, column), `Range`, character/byte offset conversions.
  - Multi-cursor and selection navigation engine with overlapping cursor normalization.
  - Transactional `UndoManager` supporting atomic batch edits, redo, and cursor state restoration.
  - High-level `Editor` orchestrator.

- **`code-lite-storage`**: Embedded SQLite database (`rusqlite` with WAL mode).
  - CodeGraph persistent relations: `files`, `symbols`, `symbol_references`, `call_graph`, `import_graph`.
  - State & Memory: `sessions`, `tasks`, and `operations`.
  - Atomic Rollback Engine: records before/after hashes and unified diff patches to revert agent edits safely.
  - Global Event Stream: records lifecycle events (`FileOpened`, `FileChanged`, `AgentEditedFile`, etc.).

- **`code-lite-fs`**: File system scanner and workspace tree.
  - Fast directory tree traversal with ignore rules (`.git`, `target`, `node_modules`, `.codelite`).
  - Metadata indexing preparation.

---

## Running Tests

Ensure Rust toolchain is available (Rust 1.80+):

```bash
cargo test --workspace
```

---

## License

MIT OR Apache-2.0
