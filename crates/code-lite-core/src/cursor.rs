use crate::buffer::TextBuffer;
use crate::position::{Point, Range};

/// Selection represents a contiguous span of text selected by a cursor.
/// `anchor` is the point where the selection started.
/// `head` is the moving active point (the caret).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Selection {
    pub anchor: Point,
    pub head: Point,
}

impl Selection {
    #[inline]
    pub fn point(p: Point) -> Self {
        Self {
            anchor: p,
            head: p,
        }
    }

    #[inline]
    pub fn new(anchor: Point, head: Point) -> Self {
        Self { anchor, head }
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.anchor == self.head
    }

    /// Converts to an ordered Range where start <= end.
    #[inline]
    pub fn range(&self) -> Range {
        if self.anchor <= self.head {
            Range::new(self.anchor, self.head)
        } else {
            Range::new(self.head, self.anchor)
        }
    }

    #[inline]
    pub fn is_reversed(&self) -> bool {
        self.head < self.anchor
    }
}

/// A Cursor contains the active selection and navigation state like `preferred_col`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Cursor {
    pub selection: Selection,
    pub preferred_col: Option<usize>,
}

impl Cursor {
    pub fn new(point: Point) -> Self {
        Self {
            selection: Selection::point(point),
            preferred_col: Some(point.col),
        }
    }

    pub fn with_selection(anchor: Point, head: Point) -> Self {
        Self {
            selection: Selection::new(anchor, head),
            preferred_col: Some(head.col),
        }
    }

    #[inline]
    pub fn head(&self) -> Point {
        self.selection.head
    }

    #[inline]
    pub fn anchor(&self) -> Point {
        self.selection.anchor
    }

    #[inline]
    pub fn range(&self) -> Range {
        self.selection.range()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.selection.is_empty()
    }

    /// Moves the cursor to a specific point. If `select` is true, keeps anchor.
    pub fn move_to(&mut self, point: Point, select: bool) {
        if select {
            self.selection.head = point;
        } else {
            self.selection = Selection::point(point);
        }
        self.preferred_col = Some(point.col);
    }

    /// Moves cursor one character left.
    pub fn move_left(&mut self, buffer: &TextBuffer, select: bool) {
        if !select && !self.is_empty() {
            let start = self.range().start;
            self.move_to(start, false);
            return;
        }

        let head = self.head();
        if head.col > 0 {
            self.move_to(Point::new(head.row, head.col - 1), select);
        } else if head.row > 0 {
            let prev_row = head.row - 1;
            let line_len = buffer.line_len_without_newline(prev_row).unwrap_or(0);
            self.move_to(Point::new(prev_row, line_len), select);
        }
    }

    /// Moves cursor one character right.
    pub fn move_right(&mut self, buffer: &TextBuffer, select: bool) {
        if !select && !self.is_empty() {
            let end = self.range().end;
            self.move_to(end, false);
            return;
        }

        let head = self.head();
        let cur_line_len = buffer.line_len_without_newline(head.row).unwrap_or(0);

        if head.col < cur_line_len {
            self.move_to(Point::new(head.row, head.col + 1), select);
        } else if head.row + 1 < buffer.len_lines() {
            self.move_to(Point::new(head.row + 1, 0), select);
        }
    }

    /// Moves cursor one line up, preserving `preferred_col`.
    pub fn move_up(&mut self, buffer: &TextBuffer, select: bool) {
        let head = self.head();
        if head.row == 0 {
            self.move_to(Point::zero(), select);
            return;
        }

        let target_row = head.row - 1;
        let line_len = buffer.line_len_without_newline(target_row).unwrap_or(0);
        let pref = self.preferred_col.unwrap_or(head.col);
        let target_col = pref.min(line_len);

        let new_point = Point::new(target_row, target_col);
        if select {
            self.selection.head = new_point;
        } else {
            self.selection = Selection::point(new_point);
        }
        self.preferred_col = Some(pref);
    }

    /// Moves cursor one line down, preserving `preferred_col`.
    pub fn move_down(&mut self, buffer: &TextBuffer, select: bool) {
        let head = self.head();
        let total_lines = buffer.len_lines();
        if head.row + 1 >= total_lines {
            let end = buffer.end_point();
            self.move_to(end, select);
            return;
        }

        let target_row = head.row + 1;
        let line_len = buffer.line_len_without_newline(target_row).unwrap_or(0);
        let pref = self.preferred_col.unwrap_or(head.col);
        let target_col = pref.min(line_len);

        let new_point = Point::new(target_row, target_col);
        if select {
            self.selection.head = new_point;
        } else {
            self.selection = Selection::point(new_point);
        }
        self.preferred_col = Some(pref);
    }

    /// Moves cursor to the start of the current line.
    pub fn move_to_line_start(&mut self, select: bool) {
        self.move_to(Point::new(self.head().row, 0), select);
    }

    /// Moves cursor to the end of the current line.
    pub fn move_to_line_end(&mut self, buffer: &TextBuffer, select: bool) {
        let row = self.head().row;
        let line_len = buffer.line_len_without_newline(row).unwrap_or(0);
        self.move_to(Point::new(row, line_len), select);
    }

    /// Selects the word currently under the cursor.
    pub fn select_word(&mut self, buffer: &TextBuffer) {
        let head = self.head();
        if let Ok(line_text) = buffer.line_text(head.row) {
            let chars: Vec<char> = line_text.chars().collect();
            if chars.is_empty() {
                return;
            }

            let col = head.col.min(chars.len());
            let is_word_char = |c: char| c.is_alphanumeric() || c == '_';

            // Find word start
            let mut start_col = if col < chars.len() && is_word_char(chars[col]) {
                col
            } else if col > 0 && is_word_char(chars[col - 1]) {
                col - 1
            } else {
                col
            };

            while start_col > 0 && is_word_char(chars[start_col - 1]) {
                start_col -= 1;
            }

            // Find word end
            let mut end_col = col;
            while end_col < chars.len() && is_word_char(chars[end_col]) {
                end_col += 1;
            }

            if start_col < end_col {
                self.selection = Selection::new(
                    Point::new(head.row, start_col),
                    Point::new(head.row, end_col),
                );
                self.preferred_col = Some(end_col);
            }
        }
    }
}

/// A set of multiple cursors supporting concurrent editing across multiple positions.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct CursorSet {
    cursors: Vec<Cursor>,
}

impl Default for CursorSet {
    fn default() -> Self {
        Self {
            cursors: vec![Cursor::new(Point::zero())],
        }
    }
}

impl CursorSet {
    pub fn single(point: Point) -> Self {
        Self {
            cursors: vec![Cursor::new(point)],
        }
    }

    pub fn new(cursors: Vec<Cursor>) -> Self {
        let mut set = Self {
            cursors: if cursors.is_empty() {
                vec![Cursor::new(Point::zero())]
            } else {
                cursors
            },
        };
        set.normalize();
        set
    }

    pub fn primary(&self) -> &Cursor {
        &self.cursors[0]
    }

    pub fn primary_mut(&mut self) -> &mut Cursor {
        &mut self.cursors[0]
    }

    pub fn cursors(&self) -> &[Cursor] {
        &self.cursors
    }

    pub fn cursors_mut(&mut self) -> &mut [Cursor] {
        &mut self.cursors
    }

    pub fn len(&self) -> usize {
        self.cursors.len()
    }

    pub fn is_empty(&self) -> bool {
        self.cursors.is_empty()
    }

    pub fn add_cursor(&mut self, cursor: Cursor) {
        self.cursors.push(cursor);
        self.normalize();
    }

    /// Sorts cursors by starting position and merges any overlapping ranges.
    pub fn normalize(&mut self) {
        if self.cursors.len() <= 1 {
            return;
        }

        self.cursors
            .sort_by(|a, b| a.range().start.cmp(&b.range().start));

        let mut merged: Vec<Cursor> = Vec::with_capacity(self.cursors.len());

        for cursor in self.cursors.drain(..) {
            if let Some(last) = merged.last_mut() {
                if last.range().overlaps(&cursor.range()) || last.head() == cursor.head() {
                    let combined_start = last.range().start.min(cursor.range().start);
                    let combined_end = last.range().end.max(cursor.range().end);
                    last.selection = Selection::new(combined_start, combined_end);
                    last.preferred_col = Some(combined_end.col);
                    continue;
                }
            }
            merged.push(cursor);
        }

        self.cursors = merged;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cursor_navigation() {
        let buf = TextBuffer::from_str("line 1\nshort\nlonger line 3");
        let mut cursor = Cursor::new(Point::zero());

        cursor.move_right(&buf, false);
        assert_eq!(cursor.head(), Point::new(0, 1));

        cursor.move_to_line_end(&buf, false);
        assert_eq!(cursor.head(), Point::new(0, 6));

        cursor.move_down(&buf, false);
        assert_eq!(cursor.head(), Point::new(1, 5)); // clamped to "short" length

        cursor.move_down(&buf, false);
        assert_eq!(cursor.head(), Point::new(2, 6)); // preferred col remembered!
    }

    #[test]
    fn test_multi_cursor_normalize() {
        let set = CursorSet::new(vec![
            Cursor::new(Point::new(1, 5)),
            Cursor::new(Point::new(0, 2)),
            Cursor::new(Point::new(1, 5)), // duplicate
        ]);

        assert_eq!(set.len(), 2);
        assert_eq!(set.cursors()[0].head(), Point::new(0, 2));
        assert_eq!(set.cursors()[1].head(), Point::new(1, 5));
    }

    #[test]
    fn test_select_word() {
        let buf = TextBuffer::from_str("let user_id = 42;");
        let mut cursor = Cursor::new(Point::new(0, 6)); // on "user_id"
        cursor.select_word(&buf);

        assert_eq!(cursor.range().start, Point::new(0, 4));
        assert_eq!(cursor.range().end, Point::new(0, 11));
        assert_eq!(buf.slice(cursor.range()), "user_id");
    }
}
