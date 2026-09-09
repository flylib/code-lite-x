//! # code-lite-core
//!
//! High-performance text editing engine for CodeLiteX.
//!
//! Provides Ropey-based text buffers, coordinate mapping, multi-cursor navigation,
//! and transactional undo/redo history.

pub mod buffer;
pub mod cursor;
pub mod editor;
pub mod history;
pub mod position;
pub mod syntax;

pub use buffer::{BufferError, TextBuffer};
pub use cursor::{Cursor, CursorSet, Selection};
pub use editor::{Editor, Movement};
pub use history::{Edit, Transaction, UndoManager};
pub use position::{Point, Range};
pub use syntax::{get_viewport_tokens, LineTokenizer, LineTokens, SyntaxToken, TokenType};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
