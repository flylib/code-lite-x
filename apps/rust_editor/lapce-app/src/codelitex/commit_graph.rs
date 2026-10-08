//! Lanes of the commit graph, the way IntelliJ and gitk draw it. A port of the Flutter
//! version's `layoutCommitGraph`, so both editors lay a history out identically.
//!
//! The commits come ordered so that a child is always listed before its parents. The layout
//! keeps, per lane, which commit it is waiting for; a lane keeps its position once assigned
//! (it is only reused after it frees up), so lines that pass straight through stay vertical.
//! A parent that is not in the list (filtered out, or beyond the loaded page) ends its line
//! at the bottom of the row.

/// One segment of a row. Heights are fractions of the row: 0 top, 0.5 the commit's dot, 1 bottom.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GraphLine {
    pub from_lane: usize,
    pub from_y: f64,
    pub to_lane: usize,
    pub to_y: f64,
    pub color: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GraphRow {
    /// The lane the commit's dot sits on.
    pub lane: usize,
    pub color: usize,
    pub lines: Vec<GraphLine>,
    /// Lanes used by this row; the commit text starts after them.
    pub width: usize,
}

pub fn layout_commit_graph<'a>(
    commits: impl IntoIterator<Item = (&'a str, &'a [String])>,
) -> Vec<GraphRow> {
    let mut lanes: Vec<Option<&str>> = Vec::new();
    let mut lane_color: Vec<usize> = Vec::new();
    let mut next_color = 0;
    let mut rows = Vec::new();

    let allocate = |lanes: &mut Vec<Option<&str>>,
                    lane_color: &mut Vec<usize>,
                    avoid: Option<usize>| {
        if let Some(i) = (0..lanes.len()).find(|&i| lanes[i].is_none() && Some(i) != avoid) {
            return i;
        }
        lanes.push(None);
        lane_color.push(0);
        lanes.len() - 1
    };

    for (hash, parents) in commits {
        let mut lines: Vec<GraphLine> = Vec::new();
        let line = |from_lane, from_y, to_lane, to_y, color| GraphLine { from_lane, from_y, to_lane, to_y, color };

        let incoming: Vec<usize> = (0..lanes.len()).filter(|&i| lanes[i] == Some(hash)).collect();
        let node = match incoming.first() {
            Some(&n) => n,
            None => {
                let n = allocate(&mut lanes, &mut lane_color, None);
                lane_color[n] = next_color;
                next_color += 1;
                n
            }
        };
        let color = lane_color[node];

        // upper half: lanes waiting for this commit run into its dot; the others pass through
        for &i in &incoming {
            lines.push(line(i, 0.0, node, 0.5, lane_color[i]));
        }
        for i in 0..lanes.len() {
            if lanes[i].is_some() && lanes[i] != Some(hash) {
                lines.push(line(i, 0.0, i, 1.0, lane_color[i]));
            }
        }
        for &i in &incoming {
            lanes[i] = None;
        }

        // lower half: the dot connects to the lanes of its parents (or opens new ones)
        for (k, parent) in parents.iter().map(String::as_str).enumerate() {
            let existing = lanes.iter().position(|l| *l == Some(parent));
            if let Some(ex) = existing {
                if k == 0 && ex > node && lanes[node].is_none() {
                    // the first parent already waits on a lane to the right: fold that lane
                    // into this one so the first-parent chain (the trunk) is not pushed aside
                    lanes[node] = Some(parent);
                    lanes[ex] = None;
                    if let Some(i) = lines
                        .iter()
                        .position(|l| l.from_lane == ex && l.to_lane == ex && l.from_y == 0.0)
                    {
                        lines[i] = line(ex, 0.0, node, 1.0, lane_color[ex]);
                    }
                    lines.push(line(node, 0.5, node, 1.0, lane_color[node]));
                } else {
                    lines.push(line(node, 0.5, ex, 1.0, lane_color[ex]));
                }
                continue;
            }
            let target = if k == 0 && lanes[node].is_none() {
                node // the first parent keeps this lane and its colour
            } else {
                let t = allocate(&mut lanes, &mut lane_color, Some(node));
                lane_color[t] = next_color;
                next_color += 1;
                t
            };
            lanes[target] = Some(parent);
            lines.push(line(node, 0.5, target, 1.0, lane_color[target]));
        }

        while lanes.last() == Some(&None) {
            lanes.pop();
            lane_color.pop();
        }

        let width = lines.iter().fold(node + 1, |w, l| w.max(l.from_lane + 1).max(l.to_lane + 1));
        rows.push(GraphRow { lane: node, color, lines, width });
    }
    rows
}

/// The IntelliJ palette, golden trunk first.
pub const GRAPH_PALETTE: [(u8, u8, u8); 8] = [
    (0xD4, 0xA8, 0x4B),
    (0x5C, 0x9D, 0xE8),
    (0x59, 0xA8, 0x69),
    (0xC7, 0x7D, 0xBB),
    (0xE0, 0x7B, 0x53),
    (0x3F, 0xB4, 0xB4),
    (0xB4, 0xA0, 0xE5),
    (0xDB, 0x58, 0x60),
];

pub fn graph_color(index: usize) -> (u8, u8, u8) {
    GRAPH_PALETTE[index % GRAPH_PALETTE.len()]
}

/// Horizontal distance between lanes, in pixels.
pub const LANE_WIDTH: f64 = 14.0;

/// x of a lane's centre inside the graph cell.
pub fn lane_x(lane: usize) -> f64 {
    LANE_WIDTH / 2.0 + lane as f64 * LANE_WIDTH + 4.0
}

/// Most lanes a row's graph cell shows. With a filter on (author, text, paths…) the parents
/// of many commits are not in the list, their lanes never close, and a row can need hundreds;
/// that must not push the commit text out of the window.
pub const MAX_GRAPH_LANES: usize = 16;

/// Width of the graph cell of a row.
pub fn graph_width(row: &GraphRow) -> f64 {
    row.width.min(MAX_GRAPH_LANES) as f64 * LANE_WIDTH + 8.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout(commits: &[(&str, &[&str])]) -> Vec<GraphRow> {
        let owned: Vec<(String, Vec<String>)> = commits
            .iter()
            .map(|(h, ps)| (h.to_string(), ps.iter().map(|p| p.to_string()).collect()))
            .collect();
        layout_commit_graph(owned.iter().map(|(h, ps)| (h.as_str(), ps.as_slice())))
    }

    fn count(row: &GraphRow, f: impl Fn(&GraphLine) -> bool) -> usize {
        row.lines.iter().filter(|l| f(l)).count()
    }

    #[test]
    fn linear_history_stays_on_one_lane_with_one_color() {
        let rows = layout(&[("c", &["b"]), ("b", &["a"]), ("a", &[])]);
        assert_eq!(rows.iter().map(|r| r.lane).collect::<Vec<_>>(), [0, 0, 0]);
        assert_eq!(rows.iter().map(|r| r.color).collect::<std::collections::HashSet<_>>().len(), 1);
        assert!(rows.iter().all(|r| r.width == 1));
        // the middle row: one line in from above, one line out to the parent
        assert_eq!(count(&rows[1], |l| l.from_y == 0.0 && l.to_y == 0.5), 1);
        assert_eq!(count(&rows[1], |l| l.from_y == 0.5 && l.to_y == 1.0), 1);
        // a root commit has nothing below it
        assert_eq!(count(&rows[2], |l| l.from_y == 0.5), 0);
    }

    #[test]
    fn branch_and_merge_use_a_second_lane_and_converge() {
        //   m      (merge of x and f)
        //   |\
        //   x f
        //   |/
        //   base
        let rows = layout(&[("m", &["x", "f"]), ("f", &["base"]), ("x", &["base"]), ("base", &[])]);
        assert_eq!(rows[0].lane, 0);
        assert_eq!(rows[0].width, 2, "the merge opens a second lane below it");
        assert_eq!(rows[1].lane, 1, "f is on the second lane");
        assert_eq!(rows[2].lane, 0, "x stays on the trunk");
        assert_eq!(rows[3].lane, 0, "base stays on the trunk: the first-parent chain is not pushed right");
        // f's lane runs diagonally into the trunk on x's row; base gets one line from straight above
        assert_eq!(count(&rows[2], |l| l.from_lane == 1 && l.from_y == 0.0 && l.to_lane == 0 && l.to_y == 1.0), 1);
        assert_eq!(count(&rows[3], |l| l.to_y == 0.5), 1);
        assert_eq!(rows[3].width, 1);
        assert_ne!(rows[1].color, rows[0].color);
    }

    #[test]
    fn parents_missing_from_the_page_do_not_break_the_layout() {
        let rows = layout(&[("b", &["zzz"]), ("a", &["yyy"])]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].lane, 0);
        assert_eq!(rows[1].lane, 1, "a is not on b's parent chain, so it opens a new lane");
    }

    #[test]
    fn a_freed_lane_is_reused_by_the_next_unrelated_commit() {
        // two roots, then an unrelated commit: lane 1 frees up after `r2` and is reused
        let rows = layout(&[("r1", &[]), ("r2", &[]), ("r3", &[])]);
        assert_eq!(rows.iter().map(|r| r.lane).collect::<Vec<_>>(), [0, 0, 0]);
    }

    #[test]
    fn an_octopus_merge_opens_one_lane_per_extra_parent() {
        let rows = layout(&[("m", &["a", "b", "c"]), ("a", &[]), ("b", &[]), ("c", &[])]);
        assert_eq!(rows[0].width, 3);
        assert_eq!(rows[1].lane, 0);
        assert_eq!(rows[2].lane, 1);
        assert_eq!(rows[3].lane, 2);
    }

    #[test]
    fn widths_and_positions_match_the_flutter_drawing() {
        let rows = layout(&[("m", &["x", "f"]), ("f", &[]), ("x", &[])]);
        assert_eq!(graph_width(&rows[0]), 2.0 * 14.0 + 8.0);
        assert_eq!(lane_x(0), 11.0);
        assert_eq!(lane_x(1), 25.0);
        assert_eq!(graph_color(8), graph_color(0), "the palette wraps");
    }

    #[test]
    fn a_row_with_hundreds_of_open_lanes_gets_a_bounded_cell() {
        // every commit's parent is missing (as after filtering by author): lanes pile up
        let hashes: Vec<String> = (0..60).map(|i| format!("c{i}")).collect();
        let parents: Vec<Vec<String>> = (0..60).map(|i| vec![format!("missing{i}")]).collect();
        let rows = layout_commit_graph(hashes.iter().zip(&parents).map(|(h, p)| (h.as_str(), p.as_slice())));
        let widest = rows.iter().map(|r| r.width).max().unwrap();
        assert!(widest > MAX_GRAPH_LANES, "the layout itself is unchanged: {widest}");
        assert!(rows.iter().all(|r| graph_width(r) <= MAX_GRAPH_LANES as f64 * LANE_WIDTH + 8.0));
    }
}
