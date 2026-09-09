use crate::position::{Point, Range};
use ropey::Rope;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum BufferError {
    #[error("Line index out of bounds: line {0}")]
    LineOutOfBounds(usize),
    #[error("Character index out of bounds: index {0}")]
    CharOutOfBounds(usize),
    #[error("Byte index out of bounds: index {0}")]
    ByteOutOfBounds(usize),
}

/// TextBuffer provides a high-performance text buffer based on Ropey.
/// Operations such as insertions and deletions at arbitrary positions are O(log N).
#[derive(Debug, Clone, Default)]
pub struct TextBuffer {
    rope: Rope,
}

impl TextBuffer {
    /// Creates an empty TextBuffer.
    pub fn new() -> Self {
        Self { rope: Rope::new() }
    }

    /// Creates a TextBuffer with the given initial content.
    pub fn from_str(text: &str) -> Self {
        Self {
            rope: Rope::from_str(text),
        }
    }

    /// Number of Unicode scalar values (chars) in the buffer.
    #[inline]
    pub fn len_chars(&self) -> usize {
        self.rope.len_chars()
    }

    /// Number of UTF-8 bytes in the buffer.
    #[inline]
    pub fn len_bytes(&self) -> usize {
        self.rope.len_bytes()
    }

    /// Number of lines in the buffer (always >= 1).
    #[inline]
    pub fn len_lines(&self) -> usize {
        self.rope.len_lines()
    }

    /// Whether the buffer is completely empty.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.rope.len_chars() == 0
    }

    /// Returns the length in chars of the specified line (including newline characters if present).
    pub fn line_len_chars(&self, line: usize) -> Result<usize, BufferError> {
        if line >= self.len_lines() {
            return Err(BufferError::LineOutOfBounds(line));
        }
        Ok(self.rope.line(line).len_chars())
    }

    /// Returns the length in chars of the specified line excluding trailing newline characters (`\n` or `\r\n`).
    pub fn line_len_without_newline(&self, line: usize) -> Result<usize, BufferError> {
        if line >= self.len_lines() {
            return Err(BufferError::LineOutOfBounds(line));
        }
        let line_slice = self.rope.line(line);
        let mut len = line_slice.len_chars();
        if len > 0 && line_slice.char(len - 1) == '\n' {
            len -= 1;
            if len > 0 && line_slice.char(len - 1) == '\r' {
                len -= 1;
            }
        }
        Ok(len)
    }

    /// Returns the end point of the document.
    pub fn end_point(&self) -> Point {
        let total_lines = self.len_lines();
        if total_lines == 0 {
            return Point::zero();
        }
        let last_line = total_lines - 1;
        let col = self.line_len_without_newline(last_line).unwrap_or(0);
        Point::new(last_line, col)
    }

    /// Converts a Point (row, col) to a 0-indexed char offset.
    /// If the point exceeds the line length, it clamps to the end of the line.
    pub fn point_to_char_idx(&self, point: Point) -> usize {
        let total_lines = self.len_lines();
        if total_lines == 0 {
            return 0;
        }

        let line = point.row.min(total_lines - 1);
        let line_char_start = self.rope.line_to_char(line);
        let line_len = self.line_len_without_newline(line).unwrap_or(0);
        let col = point.col.min(line_len);

        line_char_start + col
    }

    /// Converts a 0-indexed char offset to a Point (row, col).
    pub fn char_idx_to_point(&self, char_idx: usize) -> Point {
        let clamped = char_idx.min(self.len_chars());
        let row = self.rope.char_to_line(clamped);
        let line_char_start = self.rope.line_to_char(row);
        let col = clamped - line_char_start;
        Point::new(row, col)
    }

    /// Converts a Point (row, col) to a UTF-8 byte offset.
    pub fn point_to_byte_idx(&self, point: Point) -> usize {
        let char_idx = self.point_to_char_idx(point);
        self.rope.char_to_byte(char_idx)
    }

    /// Converts a UTF-8 byte offset to a Point (row, col).
    pub fn byte_idx_to_point(&self, byte_idx: usize) -> Point {
        let clamped = byte_idx.min(self.len_bytes());
        let char_idx = self.rope.byte_to_char(clamped);
        self.char_idx_to_point(char_idx)
    }

    /// Returns the full text of a given line as String, without trailing newline.
    pub fn line_text(&self, line: usize) -> Result<String, BufferError> {
        if line >= self.len_lines() {
            return Err(BufferError::LineOutOfBounds(line));
        }
        let line_slice = self.rope.line(line);
        let mut s = line_slice.to_string();
        if s.ends_with('\n') {
            s.pop();
            if s.ends_with('\r') {
                s.pop();
            }
        }
        Ok(s)
    }

    /// Extracts a substring corresponding to a Range.
    pub fn slice(&self, range: Range) -> String {
        let norm = range.normalized();
        let start_char = self.point_to_char_idx(norm.start);
        let end_char = self.point_to_char_idx(norm.end);

        if start_char >= end_char {
            return String::new();
        }

        self.rope.slice(start_char..end_char).to_string()
    }

    /// Inserts text at the specified Point.
    /// Returns the new Point immediately following the inserted text.
    pub fn insert(&mut self, point: Point, text: &str) -> Point {
        let char_idx = self.point_to_char_idx(point);
        self.rope.insert(char_idx, text);
        let new_char_idx = char_idx + text.chars().count();
        self.char_idx_to_point(new_char_idx)
    }

    /// Deletes text within the specified Range.
    /// Returns the deleted text.
    pub fn delete(&mut self, range: Range) -> String {
        let norm = range.normalized();
        let start_char = self.point_to_char_idx(norm.start);
        let end_char = self.point_to_char_idx(norm.end);

        if start_char >= end_char {
            return String::new();
        }

        let deleted = self.rope.slice(start_char..end_char).to_string();
        self.rope.remove(start_char..end_char);
        deleted
    }

    /// Replaces text in the given Range with new text.
    /// Returns a tuple of (deleted_text, new_end_point).
    pub fn replace(&mut self, range: Range, text: &str) -> (String, Point) {
        let norm = range.normalized();
        let start_char = self.point_to_char_idx(norm.start);
        let end_char = self.point_to_char_idx(norm.end);

        let deleted = if start_char < end_char {
            let del = self.rope.slice(start_char..end_char).to_string();
            self.rope.remove(start_char..end_char);
            del
        } else {
            String::new()
        };

        self.rope.insert(start_char, text);
        let new_end_char = start_char + text.chars().count();
        let new_end_point = self.char_idx_to_point(new_end_char);

        (deleted, new_end_point)
    }

    /// Converts the entire buffer to a String.
    pub fn to_string(&self) -> String {
        self.rope.to_string()
    }

    /// Internal reference to the underlying Ropey Rope.
    #[inline]
    pub fn rope(&self) -> &Rope {
        &self.rope
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_buffer_basic_operations() {
        let mut buf = TextBuffer::from_str("fn main() {\n    println!(\"Hello\");\n}");
        assert_eq!(buf.len_lines(), 3);
        assert_eq!(buf.line_text(0).unwrap(), "fn main() {");
        assert_eq!(buf.line_text(1).unwrap(), "    println!(\"Hello\");");
        assert_eq!(buf.line_text(2).unwrap(), "}");

        // Insertion
        let p = Point::new(1, 4);
        let next_p = buf.insert(p, "// log\n    ");
        assert_eq!(next_p, Point::new(2, 4));
        assert_eq!(buf.len_lines(), 4);

        // Deletion
        let del = buf.delete(Range::new(Point::new(1, 4), Point::new(2, 4)));
        assert_eq!(del, "// log\n    ");
        assert_eq!(buf.len_lines(), 3);
    }

    #[test]
    fn test_buffer_coordinates_mapping() {
        let buf = TextBuffer::from_str("Hello\nWorld\nRust");
        assert_eq!(buf.point_to_char_idx(Point::new(0, 0)), 0);
        assert_eq!(buf.point_to_char_idx(Point::new(0, 5)), 5);
        assert_eq!(buf.point_to_char_idx(Point::new(1, 0)), 6);
        assert_eq!(buf.point_to_char_idx(Point::new(1, 5)), 11);
        assert_eq!(buf.point_to_char_idx(Point::new(2, 0)), 12);

        assert_eq!(buf.char_idx_to_point(0), Point::new(0, 0));
        assert_eq!(buf.char_idx_to_point(5), Point::new(0, 5));
        assert_eq!(buf.char_idx_to_point(6), Point::new(1, 0));
        assert_eq!(buf.char_idx_to_point(12), Point::new(2, 0));
    }

    #[test]
    fn test_buffer_slice_and_replace() {
        let mut buf = TextBuffer::from_str("let x = 42;");
        let (old, new_end) = buf.replace(Range::new(Point::new(0, 8), Point::new(0, 10)), "100");
        assert_eq!(old, "42");
        assert_eq!(new_end, Point::new(0, 11));
        assert_eq!(buf.to_string(), "let x = 100;");
    }
}
