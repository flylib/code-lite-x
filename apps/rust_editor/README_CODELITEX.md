# CodeLiteX Rust Editor

This directory contains the Lapce v0.4.6 Rust desktop editor baseline for the
CodeLiteX Rust rewrite. It is a separate Cargo workspace; the existing Flutter
application and root Cargo workspace remain unchanged during this migration.

The upstream Lapce source revision is `b012cef466741528f338879fa708355217fc40bd`.
Git dependencies are stored under `vendor/lapce-git/` at the exact revisions
listed in [`vendor/lapce-git/UPSTREAM_REVISIONS.md`](vendor/lapce-git/UPSTREAM_REVISIONS.md).
Their upstream Git sources are patched to local paths so this workspace can
build offline without relying on Cargo's Git checkout cache.

Build from this directory with the repository's pinned toolchain and offline
dependency cache:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --offline --locked
```

The upstream `README.md`, `LICENSE`, and other attribution and license files
are retained. CodeLiteX-specific changes and migration work should be recorded
separately from imported Lapce source where practical.
