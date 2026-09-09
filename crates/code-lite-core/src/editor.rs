use crate::buffer::TextBuffer;
use crate::cursor::{Cursor, CursorSet};
use crate::history::{Edit, Transaction, UndoManager};
use crate::position::{Point, Range};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Movement {
    Left,
    Right,
    Up,
    Down,
    LineStart,
    LineEnd,
}

/// High-level Editor coordinating text buffer, cursors, and undo/redo history.
#[derive(Debug, Clone)]
pub struct Editor {
    buffer: TextBuffer,
    cursors: CursorSet,
    history: UndoManager,
}

impl Default for Editor {
    fn default() -> Self {
        Self::new()
    }
}

impl Editor {
    pub fn new() -> Self {
        Self {
            buffer: TextBuffer::new(),
            cursors: CursorSet::default(),
            history: UndoManager::default(),
        }
    }

    pub fn from_str(content: &str) -> Self {
        Self {
            buffer: TextBuffer::from_str(content),
            cursors: CursorSet::default(),
            history: UndoManager::default(),
        }
    }

    #[inline]
    pub fn buffer(&self) -> &TextBuffer {
        &self.buffer
    }

    #[inline]
    pub fn cursors(&self) -> &CursorSet {
        &self.cursors
    }

    #[inline]
    pub fn cursors_mut(&mut self) -> &mut CursorSet {
        &mut self.cursors
    }

    #[inline]
    pub fn text(&self) -> String {
        self.buffer.to_string()
    }

    #[inline]
    pub fn is_dirty(&self) -> bool {
        self.history.is_dirty()
    }

    #[inline]
    pub fn mark_saved(&mut self) {
        self.history.mark_saved();
    }

    pub fn can_undo(&self) -> bool {
        self.history.can_undo()
    }

    pub fn can_redo(&self) -> bool {
        self.history.can_redo()
    }

    /// Sets the primary cursor point. If `select` is true, extends current selection anchor.
    pub fn set_cursor_point(&mut self, point: Point, select: bool) {
        let max_row = self.buffer.len_lines().saturating_sub(1);
        let clamped_row = point.row.min(max_row);
        let max_col = self.buffer.line_len_chars(clamped_row).unwrap_or(0);
        let clamped_point = Point::new(clamped_row, point.col.min(max_col));

        for cursor in self.cursors.cursors_mut() {
            cursor.move_to(clamped_point, select);
        }
        self.cursors.normalize();
    }

    /// Sets the primary selection with explicit anchor and head.
    pub fn set_selection(&mut self, anchor: Point, head: Point) {
        let max_row = self.buffer.len_lines().saturating_sub(1);
        let a_row = anchor.row.min(max_row);
        let a_col = anchor.col.min(self.buffer.line_len_chars(a_row).unwrap_or(0));
        let h_row = head.row.min(max_row);
        let h_col = head.col.min(self.buffer.line_len_chars(h_row).unwrap_or(0));

        self.cursors = CursorSet::new(vec![Cursor::with_selection(
            Point::new(a_row, a_col),
            Point::new(h_row, h_col),
        )]);
    }

    /// Saves the current buffer text to the specified file path and marks history as clean.
    pub fn save_to_file(&mut self, path: &std::path::Path) -> std::io::Result<()> {
        std::fs::write(path, self.text())?;
        self.mark_saved();
        Ok(())
    }

    /// Navigates the cursors.
    pub fn move_cursor(&mut self, movement: Movement, select: bool) {
        for cursor in self.cursors.cursors_mut() {
            match movement {
                Movement::Left => cursor.move_left(&self.buffer, select),
                Movement::Right => cursor.move_right(&self.buffer, select),
                Movement::Up => cursor.move_up(&self.buffer, select),
                Movement::Down => cursor.move_down(&self.buffer, select),
                Movement::LineStart => cursor.move_to_line_start(select),
                Movement::LineEnd => cursor.move_to_line_end(&self.buffer, select),
            }
        }
        self.cursors.normalize();
    }

    /// Inserts text at each cursor position / replaces selections.
    pub fn insert_text(&mut self, text: &str) {
        let cursors_before = self.cursors.clone();
        let mut edits = Vec::new();
        let mut new_cursors = Vec::new();

        // Process from bottom-right to top-left to preserve range validity
        let mut sorted_cursors: Vec<Cursor> = self.cursors.cursors().to_vec();
        sorted_cursors.sort_by(|a, b| b.range().start.cmp(&a.range().start));

        for cursor in sorted_cursors {
            let range = cursor.range();
            let (old_text, new_end) = self.buffer.replace(range, text);
            edits.push(Edit::new(range, old_text, text.to_string()));
            new_cursors.push(Cursor::new(new_end));
        }

        // Restore chronological order for transaction
        edits.reverse();
        new_cursors.reverse();

        self.cursors = CursorSet::new(new_cursors);
        let tx = Transaction::new(
            edits,
            cursors_before,
            self.cursors.clone(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0),
        );
        self.history.push(tx);
    }

    /// Handles Backspace (deletes backwards or deletes current selection).
    pub fn delete_backward(&mut self) {
        let cursors_before = self.cursors.clone();
        let mut edits = Vec::new();
        let mut new_cursors = Vec::new();

        let mut sorted_cursors: Vec<Cursor> = self.cursors.cursors().to_vec();
        sorted_cursors.sort_by(|a, b| b.range().start.cmp(&a.range().start));

        for mut cursor in sorted_cursors {
            let delete_range = if cursor.is_empty() {
                let head = cursor.head();
                if head == Point::zero() {
                    new_cursors.push(cursor);
                    continue;
                }
                cursor.move_left(&self.buffer, false);
                Range::new(cursor.head(), head)
            } else {
                cursor.range()
            };

            let deleted = self.buffer.delete(delete_range);
            edits.push(Edit::new(delete_range, deleted, String::new()));
            new_cursors.push(Cursor::new(delete_range.start));
        }

        edits.reverse();
        new_cursors.reverse();

        if !edits.is_empty() {
            self.cursors = CursorSet::new(new_cursors);
            let tx = Transaction::new(
                edits,
                cursors_before,
                self.cursors.clone(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as u64)
                    .unwrap_or(0),
            );
            self.history.push(tx);
        }
    }

    /// Undoes the last edit transaction.
    pub fn undo(&mut self) -> bool {
        if let Some(restored_cursors) = self.history.undo(&mut self.buffer) {
            self.cursors = restored_cursors;
            true
        } else {
            false
        }
    }

    /// Redoes the last undone edit transaction.
    pub fn redo(&mut self) -> bool {
        if let Some(restored_cursors) = self.history.redo(&mut self.buffer) {
            self.cursors = restored_cursors;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_editor_typing_and_backspace() {
        let mut editor = Editor::new();
        editor.insert_text("hello");
        assert_eq!(editor.text(), "hello");
        assert_eq!(editor.cursors().primary().head(), Point::new(0, 5));

        editor.delete_backward();
        assert_eq!(editor.text(), "hell");
        assert_eq!(editor.cursors().primary().head(), Point::new(0, 4));

        // Undo
        editor.undo();
        assert_eq!(editor.text(), "hello");

        editor.undo();
        assert_eq!(editor.text(), "");

        // Redo
        editor.redo();
        assert_eq!(editor.text(), "hello");
    }

    #[test]
    fn test_editor_dirty_and_cursor_selection() {
        let mut editor = Editor::from_str("line 1\nline 2\nline 3");
        assert!(!editor.is_dirty());

        // Set cursor position
        editor.set_cursor_point(Point::new(1, 4), false);
        assert_eq!(editor.cursors().primary().head(), Point::new(1, 4));

        // Set selection
        editor.set_selection(Point::new(0, 0), Point::new(0, 4));
        assert_eq!(editor.cursors().primary().anchor(), Point::new(0, 0));
        assert_eq!(editor.cursors().primary().head(), Point::new(0, 4));

        // Insert text replaces selection and marks dirty
        editor.insert_text("first");
        assert!(editor.text().starts_with("first"));
        assert!(editor.is_dirty());

        // Mark saved
        editor.mark_saved();
        assert!(!editor.is_dirty());

        // Undo makes it dirty relative to save checkpoint
        editor.undo();
        assert!(editor.is_dirty());

        // Redo brings it back to the save checkpoint -> clean!
        editor.redo();
        assert!(!editor.is_dirty());
    }
}
