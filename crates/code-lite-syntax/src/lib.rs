//! 语法树(tree-sitter):每个打开的文档一份,Rust 里存着文本和语法树,编辑时增量重解析,
//! 界面按可见行取着色。
//!
//! - 文本按行存,**每行后面都有 `\n`**(含最后一行),这样「把第 s 行起的 k 行换成这些行」就是一段字节替换,没有边界情况。
//! - 编辑(`edit`)是同步的:改文本、把语法树的位置挪好,然后在 3 ms 的预算里试着增量重解析(敲一个字通常 1 ms 内);
//!   超时就交给后台线程,期间改动过的行标成「脏」,界面那几行先用 Dart 的逐行分词,其它行照用旧树(位置已挪好)。
//! - 第一次解析(打开文件)也在后台:7 千行约 30 ms,不卡界面;解析完之前界面全用 Dart 的分词。

pub mod grammar;
pub mod outline;

use std::ops::Range;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use streaming_iterator::StreamingIterator;
use tree_sitter::{InputEdit, ParseOptions, ParseState, Parser, Point, QueryCursor, Tree};

pub use grammar::{is_known, kind, NAMES};
use grammar::Grammar;

/// 编辑时同步重解析的时间预算,超过就交给后台。
const SYNC_BUDGET: Duration = Duration::from_millis(3);

pub struct Document {
    state: Mutex<State>,
}

struct State {
    name: String,
    grammar: Option<Arc<Grammar>>,
    parser: Option<Parser>,
    text: String,
    /// 每行起点的字节偏移,最后多一个 = text.len()。
    line_starts: Vec<usize>,
    /// 每次编辑 +1。
    version: u64,
    /// 每换一次语法树 +1(界面据此丢掉缓存的着色)。
    generation: u64,
    /// 已按编辑挪好位置的语法树;第一次解析完之前为 None。
    tree: Option<Tree>,
    /// 当前文本里语法树还没反映的字节范围(合并成一段)。
    dirty: Option<Range<usize>>,
    /// 后台在解析时又来的编辑:解析结果要补上这些,脏范围也只剩它们。
    later_edits: Vec<InputEdit>,
    later_dirty: Option<Range<usize>>,
    background: bool,
    closed: bool,
}

fn line_starts_of(text: &str) -> Vec<usize> {
    let mut v = Vec::with_capacity(text.len() / 32 + 2);
    v.push(0);
    for (i, b) in text.bytes().enumerate() {
        if b == b'\n' {
            v.push(i + 1);
        }
    }
    if *v.last().unwrap() != text.len() {
        v.push(text.len()); // 最后一行没有 \n(调用方应保证有,这里兜底)
    }
    v
}

/// 编辑之后,旧坐标里的一段挪到新坐标(落在被替换区域里的并到替换后的区域)。
fn shift(r: Range<usize>, e: &InputEdit) -> Range<usize> {
    let map = |p: usize| {
        if p <= e.start_byte {
            p
        } else if p >= e.old_end_byte {
            p - e.old_end_byte + e.new_end_byte
        } else {
            e.new_end_byte
        }
    };
    map(r.start)..map(r.end)
}

fn union(a: Option<Range<usize>>, b: Range<usize>) -> Range<usize> {
    match a {
        Some(a) => a.start.min(b.start)..a.end.max(b.end),
        None => b,
    }
}

impl Document {
    /// [text] 每行后面都带 `\n`。不认识的语法名返回 None。
    pub fn open(name: &str, text: String) -> Option<Arc<Document>> {
        if !is_known(name) {
            return None;
        }
        let line_starts = line_starts_of(&text);
        let doc = Arc::new(Document {
            state: Mutex::new(State {
                name: name.to_string(),
                grammar: None,
                parser: None,
                text,
                line_starts,
                version: 0,
                generation: 0,
                tree: None,
                dirty: None,
                later_edits: Vec::new(),
                later_dirty: None,
                background: true,
                closed: false,
            }),
        });
        let d = doc.clone();
        std::thread::spawn(move || d.background_parse());
        Some(doc)
    }

    pub fn close(&self) {
        self.state.lock().unwrap().closed = true;
    }

    pub fn line_count(&self) -> usize {
        self.state.lock().unwrap().line_starts.len() - 1
    }

    pub fn text(&self) -> String {
        self.state.lock().unwrap().text.clone()
    }

    /// `generation << 1 | 后台还在解析`。界面在后台解析期间轮询它,变了就重画。
    pub fn status(&self) -> u64 {
        let st = self.state.lock().unwrap();
        st.generation << 1 | st.background as u64
    }

    /// 把第 [start] 行起的 [old_count] 行换成 [new_text](每行带 `\n`)。
    pub fn edit(self: &Arc<Self>, start: usize, old_count: usize, new_text: &str) {
        let mut guard = self.state.lock().unwrap();
        let st = &mut *guard;
        let n = st.line_starts.len() - 1;
        let start = start.min(n);
        let end = (start + old_count).min(n);
        let sb = st.line_starts[start];
        let eb = st.line_starts[end];
        st.text.replace_range(sb..eb, new_text);
        st.line_starts = line_starts_of(&st.text);
        st.version += 1;
        let new_lines = new_text.bytes().filter(|&b| b == b'\n').count();
        let e = InputEdit {
            start_byte: sb,
            old_end_byte: eb,
            new_end_byte: sb + new_text.len(),
            start_position: Point::new(start, 0),
            old_end_position: Point::new(end, 0),
            new_end_position: Point::new(start + new_lines, 0),
        };
        if let Some(t) = st.tree.as_mut() {
            t.edit(&e);
        }
        let changed = sb..e.new_end_byte;
        st.dirty = Some(union(st.dirty.take().map(|r| shift(r, &e)), changed.clone()));
        if st.background {
            st.later_edits.push(e);
            st.later_dirty = Some(union(st.later_dirty.take().map(|r| shift(r, &e)), changed));
            return;
        }
        // 先在预算内同步试一下(敲一个字通常 1 ms 内),不行再交给后台
        if let (Some(parser), Some(tree)) = (st.parser.as_mut(), st.tree.as_ref()) {
            let t0 = Instant::now();
            let mut over_budget = |_: &ParseState| t0.elapsed() > SYNC_BUDGET;
            let bytes = st.text.as_bytes();
            let parsed = parser.parse_with_options(
                &mut |i, _| if i < bytes.len() { &bytes[i..] } else { &[] as &[u8] },
                Some(tree),
                Some(ParseOptions::new().progress_callback(&mut over_budget)),
            );
            match parsed {
                Some(t) => {
                    st.tree = Some(t);
                    st.dirty = None;
                    st.generation += 1;
                    return;
                }
                None => parser.reset(),
            }
        }
        st.background = true;
        st.later_edits.clear();
        st.later_dirty = None;
        let d = self.clone();
        drop(guard);
        std::thread::spawn(move || d.background_parse());
    }

    fn background_parse(&self) {
        // 语法(查询编译要几毫秒)在后台准备
        let name = self.state.lock().unwrap().name.clone();
        let Some(grammar) = grammar::get(&name) else {
            self.state.lock().unwrap().background = false;
            return;
        };
        let mut parser = Parser::new();
        if parser.set_language(&grammar.language).is_err() {
            self.state.lock().unwrap().background = false;
            return;
        }
        loop {
            let (text, old_tree, version) = {
                let mut st = self.state.lock().unwrap();
                if st.closed {
                    st.background = false;
                    return;
                }
                if st.grammar.is_none() {
                    let mut p = Parser::new();
                    let _ = p.set_language(&grammar.language);
                    st.grammar = Some(grammar.clone());
                    st.parser = Some(p);
                }
                st.later_edits.clear();
                st.later_dirty = None;
                (st.text.clone(), st.tree.clone(), st.version)
            };
            let parsed = parser.parse(&text, old_tree.as_ref());
            let mut st = self.state.lock().unwrap();
            if st.closed {
                st.background = false;
                return;
            }
            if let Some(mut t) = parsed {
                for e in &st.later_edits {
                    t.edit(e);
                }
                st.tree = Some(t);
                st.dirty = st.later_dirty.take();
                st.later_edits.clear();
                st.generation += 1;
            }
            if st.version == version {
                st.background = false;
                return;
            }
        }
    }

    /// 第 [from, to) 行的着色(二进制,格式见 [encode])。
    pub fn highlight(&self, from: usize, to: usize) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let n = st.line_starts.len() - 1;
        let from = from.min(n);
        let to = to.clamp(from, n);
        let (Some(g), Some(tree)) = (st.grammar.as_ref(), st.tree.as_ref()) else {
            return header(false, st.generation, from, 0);
        };
        let sb = st.line_starts[from];
        let eb = st.line_starts[to];
        let text = st.text.as_bytes();

        // 收集捕获:(起, 止, 规则序号, 种类)
        let mut caps: Vec<(usize, usize, usize, u8)> = Vec::new();
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(sb..eb);
        let mut it = cursor.captures(&g.query, tree.root_node(), text);
        while let Some((m, i)) = it.next() {
            let c = m.captures[*i];
            if let Some(k) = g.kinds[c.index as usize] {
                let r = c.node.byte_range();
                if r.end > sb && r.start < eb && r.start < r.end {
                    caps.push((r.start, r.end, m.pattern_index, k));
                }
            }
        }
        // 外层先涂、里层盖上去;同一段只认一条规则(先写的或后写的,看语言)
        let last = g.last_wins;
        caps.sort_by(|a, b| {
            a.0.cmp(&b.0).then(b.1.cmp(&a.1)).then(if last { b.2.cmp(&a.2) } else { a.2.cmp(&b.2) })
        });
        caps.dedup_by(|b, a| a.0 == b.0 && a.1 == b.1);
        const NONE: u8 = u8::MAX;
        let mut paint = vec![NONE; eb - sb];
        for (s, e, _, k) in caps {
            let s = s.max(sb) - sb;
            let e = e.min(eb) - sb;
            paint[s..e].fill(k);
        }

        let mut out = header(true, st.generation, from, to - from);
        for line in from..to {
            let ls = st.line_starts[line];
            let le = st.line_starts[line + 1].saturating_sub(1).max(ls); // 去掉行尾 \n
            let is_dirty = st.dirty.as_ref().is_some_and(|d| d.start < st.line_starts[line + 1] && d.end > ls);
            out.push(is_dirty as u8);
            let count_at = out.len();
            out.extend_from_slice(&0u32.to_le_bytes());
            if is_dirty {
                continue;
            }
            let bytes = &text[ls..le];
            let ascii = bytes.is_ascii();
            let line_str = std::str::from_utf8(bytes).unwrap_or("");
            let mut count = 0u32;
            let mut i = 0;
            let mut col16 = 0usize; // i 处的 UTF-16 列
            while i < bytes.len() {
                let k = paint[ls - sb + i];
                let start16 = col16;
                let mut j = i;
                while j < bytes.len() && paint[ls - sb + j] == k {
                    j += 1;
                }
                // UTF-8 字节 → UTF-16 列
                if ascii {
                    col16 += j - i;
                } else {
                    // j 可能落在多字节字符中间(查询结果总是在字符边界,保险起见往后对齐)
                    while j < bytes.len() && !line_str.is_char_boundary(j) {
                        j += 1;
                    }
                    col16 += line_str[i..j].encode_utf16().count();
                }
                if k != NONE && k != kind::PLAIN {
                    out.extend_from_slice(&(start16 as u32).to_le_bytes());
                    out.extend_from_slice(&(col16 as u32).to_le_bytes());
                    out.push(k);
                    count += 1;
                }
                i = j;
            }
            out[count_at..count_at + 4].copy_from_slice(&count.to_le_bytes());
        }
        out
    }
}

impl Document {
    /// 从第 [from, to) 行开始的折叠范围:`(起始行, 结束行)`,隐藏的是 起始行+1 ..= 结束行。
    /// 同一行开始的只留最大的那段。格式:头部 = 是否有语法树(u8)、3 字节填充、generation(u32)、段数(u32);每段两个 u32。小端。
    pub fn folds(&self, from: usize, to: usize) -> Vec<u8> {
        let st = self.state.lock().unwrap();
        let n = st.line_starts.len() - 1;
        let from = from.min(n);
        let to = to.clamp(from, n);
        let mut out = vec![0u8; 12];
        out[4..8].copy_from_slice(&(st.generation as u32).to_le_bytes());
        let (Some(g), Some(tree)) = (st.grammar.as_ref(), st.tree.as_ref()) else {
            return out;
        };
        out[0] = 1;
        let text = st.text.as_bytes();
        let names = g.folds.capture_names();
        let mut best: std::collections::BTreeMap<usize, usize> = Default::default();
        let mut cursor = QueryCursor::new();
        // 往前多看一行:Python 的语句块从上一行(冒号那行)算起
        cursor.set_byte_range(st.line_starts[from.saturating_sub(1)]..st.line_starts[to]);
        let mut it = cursor.captures(&g.folds, tree.root_node(), text);
        // 每行第一个非空白字符的字节列(判断连续注释是不是独占一行)
        let indent = |row: usize| {
            let ls = st.line_starts[row.min(n)];
            text[ls..].iter().take_while(|&&b| b == b' ' || b == b'\t').count()
        };
        while let Some((m, i)) = it.next() {
            let c = m.captures[*i];
            let node = c.node;
            let (start, end) = match names[c.index as usize] {
                "fold.header" => match node.prev_sibling() {
                    Some(p) => (p.start_position().row, node.end_position().row),
                    None => (node.start_position().row, node.end_position().row),
                },
                "fold.group" => {
                    // 只从一组的第一个开始:前一个兄弟是同类、而且紧挨着(下一行)就跳过
                    let own_line = |x: tree_sitter::Node| x.start_position().column == indent(x.start_position().row);
                    if !own_line(node) {
                        continue;
                    }
                    if let Some(p) = node.prev_sibling() {
                        if p.kind() == node.kind() && p.end_position().row + 1 >= node.start_position().row && own_line(p) {
                            continue;
                        }
                    }
                    let mut last = node;
                    while let Some(nx) = last.next_sibling() {
                        if nx.kind() == node.kind() && nx.start_position().row <= last.end_position().row + 1 && own_line(nx) {
                            last = nx;
                        } else {
                            break;
                        }
                    }
                    (node.start_position().row, last.end_position().row)
                }
                _ => (node.start_position().row, node.end_position().row),
            };
            // 结尾正好在下一行行首(节点包含了换行)时,结束行退一行
            let end = if end > start && node.end_position().column == 0 { end - 1 } else { end };
            if end > start && start >= from && start < to {
                let e = best.entry(start).or_insert(end);
                *e = (*e).max(end);
            }
        }
        out[8..12].copy_from_slice(&(best.len() as u32).to_le_bytes());
        for (s, e) in best {
            out.extend_from_slice(&(s as u32).to_le_bytes());
            out.extend_from_slice(&(e as u32).to_le_bytes());
        }
        out
    }
}

/// 头部 16 字节:版本 1、是否有语法树、2 字节填充、generation(u32)、起始行(u32)、行数(u32)。
/// 每行:是否脏(u8)、token 数(u32),每个 token:起止 UTF-16 列(u32 ×2)、种类(u8)。小端。
fn header(ready: bool, generation: u64, from: usize, count: usize) -> Vec<u8> {
    let mut v = Vec::with_capacity(16 + count * 32);
    v.extend_from_slice(&[1, ready as u8, 0, 0]);
    v.extend_from_slice(&(generation as u32).to_le_bytes());
    v.extend_from_slice(&(from as u32).to_le_bytes());
    v.extend_from_slice(&(count as u32).to_le_bytes());
    v
}

#[cfg(test)]
mod tests;
