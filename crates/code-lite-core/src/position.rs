use std::cmp::Ordering;

/// Point represents a 0-indexed position in a text buffer: (row, col).
/// `row` corresponds to the line number (0-indexed).
/// `col` corresponds to the character column in the line (0-indexed).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Point {
    pub row: usize,
    pub col: usize,
}

impl Point {
    #[inline]
    pub const fn new(row: usize, col: usize) -> Self {
        Self { row, col }
    }

    #[inline]
    pub const fn zero() -> Self {
        Self { row: 0, col: 0 }
    }
}

impl PartialOrd for Point {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Point {
    fn cmp(&self, other: &Self) -> Ordering {
        match self.row.cmp(&other.row) {
            Ordering::Equal => self.col.cmp(&other.col),
            ord => ord,
        }
    }
}

/// Range represents a span of text between two Points.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Range {
    pub start: Point,
    pub end: Point,
}

impl Range {
    #[inline]
    pub const fn new(start: Point, end: Point) -> Self {
        Self { start, end }
    }

    #[inline]
    pub const fn empty_at(point: Point) -> Self {
        Self {
            start: point,
            end: point,
        }
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.start == self.end
    }

    /// Returns a normalized range where start <= end.
    #[inline]
    pub fn normalized(&self) -> Self {
        if self.start <= self.end {
            *self
        } else {
            Self {
                start: self.end,
                end: self.start,
            }
        }
    }

    /// Checks if a point lies within the normalized range (inclusive of start, exclusive of end,
    /// or inclusive of both if range is empty).
    pub fn contains(&self, point: Point) -> bool {
        let norm = self.normalized();
        if norm.is_empty() {
            norm.start == point
        } else {
            norm.start <= point && point < norm.end
        }
    }

    /// Checks if two ranges overlap.
    pub fn overlaps(&self, other: &Range) -> bool {
        let a = self.normalized();
        let b = other.normalized();
        a.start < b.end && b.start < a.end
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_point_ordering() {
        let p1 = Point::new(1, 5);
        let p2 = Point::new(1, 10);
        let p3 = Point::new(2, 0);

        assert!(p1 < p2);
        assert!(p2 < p3);
        assert!(p1 < p3);
    }

    #[test]
    fn test_range_normalized() {
        let r1 = Range::new(Point::new(2, 0), Point::new(1, 5));
        let norm = r1.normalized();
        assert_eq!(norm.start, Point::new(1, 5));
        assert_eq!(norm.end, Point::new(2, 0));
    }

    #[test]
    fn test_range_contains_and_overlaps() {
        let r = Range::new(Point::new(1, 0), Point::new(1, 10));
        assert!(r.contains(Point::new(1, 0)));
        assert!(r.contains(Point::new(1, 5)));
        assert!(!r.contains(Point::new(1, 10)));
        assert!(!r.contains(Point::new(0, 5)));

        let r2 = Range::new(Point::new(1, 5), Point::new(1, 15));
        assert!(r.overlaps(&r2));

        let r3 = Range::new(Point::new(1, 10), Point::new(1, 20));
        assert!(!r.overlaps(&r3));
    }
}
