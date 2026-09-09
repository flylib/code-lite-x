use crate::buffer::TextBuffer;
use crate::cursor::CursorSet;
use crate::position::{Point, Range};

/// A single atomic text modification.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Edit {
    pub range: Range,
    pub old_text: String,
    pub new_text: String,
}

impl Edit {
    pub fn new(range: Range, old_text: String, new_text: String) -> Self {
        Self {
            range,
            old_text,
            new_text,
        }
    }
}

/// A collection of atomic edits executed as a single logical transaction
/// (e.g. typing a character across multiple cursors, refactoring, or pasting).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Transaction {
    pub edits: Vec<Edit>,
    pub cursors_before: CursorSet,
    pub cursors_after: CursorSet,
    pub timestamp_ms: u64,
}

impl Transaction {
    pub fn new(
        edits: Vec<Edit>,
        cursors_before: CursorSet,
        cursors_after: CursorSet,
        timestamp_ms: u64,
    ) -> Self {
        Self {
            edits,
            cursors_before,
            cursors_after,
            timestamp_ms,
        }
    }
}

/// Transactional Undo/Redo manager maintaining editing history.
#[derive(Debug, Clone)]
pub struct UndoManager {
    undo_stack: Vec<Transaction>,
    redo_stack: Vec<Transaction>,
    max_history: usize,
    saved_undo_count: usize,
}

impl Default for UndoManager {
    fn default() -> Self {
        Self::new(1000)
    }
}

impl UndoManager {
    pub fn new(max_history: usize) -> Self {
        Self {
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            max_history,
            saved_undo_count: 0,
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    pub fn undo_count(&self) -> usize {
        self.undo_stack.len()
    }

    pub fn redo_count(&self) -> usize {
        self.redo_stack.len()
    }

    /// Marks the current history position as saved/clean.
    pub fn mark_saved(&mut self) {
        self.saved_undo_count = self.undo_stack.len();
    }

    /// Returns whether the buffer has unsaved changes compared to the last saved checkpoint.
    pub fn is_dirty(&self) -> bool {
        self.undo_stack.len() != self.saved_undo_count
    }

    /// Pushes a completed transaction to the undo stack, clearing the redo stack.
    pub fn push(&mut self, transaction: Transaction) {
        if self.undo_stack.len() >= self.max_history {
            self.undo_stack.remove(0);
            self.saved_undo_count = self.saved_undo_count.saturating_sub(1);
        }
        self.undo_stack.push(transaction);
        self.redo_stack.clear();
    }

    /// Reverts the most recent transaction on the buffer.
    /// Returns the restored `CursorSet` if undo was applied.
    pub fn undo(&mut self, buffer: &mut TextBuffer) -> Option<CursorSet> {
        let tx = self.undo_stack.pop()?;

        // Revert edits in reverse order
        for edit in tx.edits.iter().rev() {
            let start_point = edit.range.start;
            // The range currently occupied by new_text starts at edit.range.start
            let new_text_lines = edit.new_text.lines().count().max(1) - 1;
            let end_col = if new_text_lines == 0 {
                start_point.col + edit.new_text.chars().count()
            } else {
                edit.new_text.lines().last().map_or(0, |l| l.chars().count())
            };
            let current_range = Range::new(
                start_point,
                Point::new(start_point.row + new_text_lines, end_col),
            );

            buffer.replace(current_range, &edit.old_text);
        }

        let restored_cursors = tx.cursors_before.clone();
        self.redo_stack.push(tx);
        Some(restored_cursors)
    }

    /// Re-applies the most recently undone transaction on the buffer.
    /// Returns the restored `CursorSet` if redo was applied.
    pub fn redo(&mut self, buffer: &mut TextBuffer) -> Option<CursorSet> {
        let tx = self.redo_stack.pop()?;

        // Apply edits in original order
        for edit in &tx.edits {
            buffer.replace(edit.range, &edit.new_text);
        }

        let restored_cursors = tx.cursors_after.clone();
        self.undo_stack.push(tx);
        Some(restored_cursors)
    }

    pub fn clear(&mut self) {
        self.undo_stack.clear();
        self.redo_stack.clear();
        self.saved_undo_count = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_undo_redo_cycle() {
        let mut buf = TextBuffer::from_str("hello");
        let mut history = UndoManager::default();

        let initial_cursors = CursorSet::single(Point::new(0, 5));
        let next_cursors = CursorSet::single(Point::new(0, 11));

        // Operation: insert " world"
        let edit = Edit::new(
            Range::new(Point::new(0, 5), Point::new(0, 5)),
            "".to_string(),
            " world".to_string(),
        );
        buf.replace(edit.range, &edit.new_text);
        assert_eq!(buf.to_string(), "hello world");

        let tx = Transaction::new(vec![edit], initial_cursors.clone(), next_cursors, 100);
        history.push(tx);

        assert!(history.can_undo());
        assert!(!history.can_redo());

        // Undo
        let undone_cursors = history.undo(&mut buf).unwrap();
        assert_eq!(buf.to_string(), "hello");
        assert_eq!(undone_cursors, initial_cursors);
        assert!(!history.can_undo());
        assert!(history.can_redo());

        // Redo
        let redone_cursors = history.redo(&mut buf).unwrap();
        assert_eq!(buf.to_string(), "hello world");
        assert_eq!(redone_cursors.primary().head(), Point::new(0, 11));
    }

    #[test]
    fn test_dirty_state_tracking() {
        let mut buf = TextBuffer::from_str("line 1");
        let mut history = UndoManager::default();

        // Initially clean
        assert!(!history.is_dirty());

        let edit = Edit::new(
            Range::new(Point::new(0, 6), Point::new(0, 6)),
            "".to_string(),
            "\nline 2".to_string(),
        );
        buf.replace(edit.range, &edit.new_text);
        let tx = Transaction::new(
            vec![edit],
            CursorSet::single(Point::new(0, 6)),
            CursorSet::single(Point::new(1, 6)),
            100,
        );
        history.push(tx);

        // Dirty after edit
        assert!(history.is_dirty());

        // Undo restores clean state
        let _ = history.undo(&mut buf);
        assert!(!history.is_dirty());

        // Redo makes it dirty again
        let _ = history.redo(&mut buf);
        assert!(history.is_dirty());

        // Save checkpoint marks it clean
        history.mark_saved();
        assert!(!history.is_dirty());

        // Undo past the save checkpoint makes it dirty
        let _ = history.undo(&mut buf);
        assert!(history.is_dirty());
    }
}
