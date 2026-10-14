//! 按行差分(Commit 差异、PR 差异、三方合并共用),经 FFI 交给 Dart 的 `line_diff.dart`。
//!
//! 用 `imara-diff` 的 histogram 算法(gitoxide / Helix 用的那个),再按行做滑动调整(改动块对齐到更自然的位置)。
//! 原来 Dart 的 Myers 实现回溯时每一步都复制整个状态数组:内存是「改动数 × 总行数」,
//! 2 万行改 2000 处要 2.4 GB、2 万行整体改写要 24 秒;这里内存只和行数有关。

use imara_diff::{Algorithm, Diff, InternedInput, TokenSource};

struct LineList<'a>(&'a [&'a [u8]]);

impl<'a> TokenSource for LineList<'a> {
    type Token = &'a [u8];
    type Tokenizer = std::iter::Copied<std::slice::Iter<'a, &'a [u8]>>;

    fn tokenize(&self) -> Self::Tokenizer {
        self.0.iter().copied()
    }

    fn estimate_tokens(&self) -> u32 {
        self.0.len() as u32
    }
}

/// [a] 改成 [b] 的各段改动 `(a_start, a_end, b_start, b_end)`(左闭右开),按位置排序,相邻两段之间至少隔一行没变的。
pub fn line_hunks(a: &[&[u8]], b: &[&[u8]]) -> Vec<[u32; 4]> {
    let input = InternedInput::new(LineList(a), LineList(b));
    let mut diff = Diff::compute(Algorithm::Histogram, &input);
    diff.postprocess_lines(&input);
    diff.hunks().map(|h| [h.before.start, h.before.end, h.after.start, h.after.end]).collect()
}

/// 把 `\n` 连起来的 [count] 行拆回来(`count == 0` 是没有行;一行空串也是一行)。
pub fn split_joined(data: &[u8], count: u32) -> Vec<&[u8]> {
    if count == 0 {
        return Vec::new();
    }
    data.split(|&c| c == b'\n').collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(s: &[&'static str]) -> Vec<&'static [u8]> {
        s.iter().map(|l| l.as_bytes()).collect()
    }

    #[test]
    fn hunks_cover_inserts_deletes_and_modifications() {
        let a = lines(&["a", "b", "c", "d", "e"]);
        let b = lines(&["a", "B", "c", "e", "f"]);
        assert_eq!(line_hunks(&a, &b), vec![[1, 2, 1, 2], [3, 4, 3, 3], [5, 5, 4, 5]]);
        assert_eq!(line_hunks(&[], &lines(&["x"])), vec![[0, 0, 0, 1]]);
        assert_eq!(line_hunks(&lines(&["x"]), &[]), vec![[0, 1, 0, 0]]);
        assert!(line_hunks(&a, &a).is_empty());
    }

    #[test]
    fn joined_lines_round_trip_including_empty_lines() {
        assert!(split_joined(b"", 0).is_empty());
        assert_eq!(split_joined(b"", 1), vec![b"" as &[u8]]);
        assert_eq!(split_joined(b"a\n\nb", 3), vec![b"a" as &[u8], b"", b"b"]);
    }

    #[test]
    fn a_full_rewrite_of_a_big_file_is_fast() {
        let a: Vec<String> = (0..50_000).map(|i| format!("    private String field{i} = compute({i});")).collect();
        let b: Vec<String> = a.iter().map(|l| format!("{l} // reformatted")).collect();
        let (a, b): (Vec<&[u8]>, Vec<&[u8]>) = (a.iter().map(|s| s.as_bytes()).collect(), b.iter().map(|s| s.as_bytes()).collect());
        let t = std::time::Instant::now();
        let h = line_hunks(&a, &b);
        assert_eq!(h, vec![[0, 50_000, 0, 50_000]]);
        assert!(t.elapsed().as_secs() < 5, "原来 Dart 要一分钟以上");
    }
}
