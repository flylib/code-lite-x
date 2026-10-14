//! 内嵌终端:portable-pty 起一个常驻登录 shell,vt100 维护屏幕状态。
//!
//! UI 不解析 ANSI —— 它按 `seq` 轮询 [`PtySession::snapshot`],拿到的是已经排好版的
//! 单元格行(按样式切成 run)。这样 FFI 上只流动"屏幕",不流动字节流,
//! 光标移动、清屏、备用屏(vim/top)都由 vt100 处理。
//!
//! 这是给用户用的终端,不是 Agent 的执行通道:Agent 跑命令仍然只能走 ToolRuntime。

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use parking_lot::Mutex;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use serde_json::{json, Value};

/// 每个会话保留的回滚行数。
const SCROLLBACK_LINES: usize = 5000;

/// 单元格样式位。与 Dart 端 `terminal_view.dart` 的解码保持一致。
const ATTR_BOLD: u8 = 1;
const ATTR_ITALIC: u8 = 2;
const ATTR_UNDERLINE: u8 = 4;
const ATTR_INVERSE: u8 = 8;
const ATTR_DIM: u8 = 16;

/// 颜色编码成一个整数:-1 默认色,0..=255 调色板索引,`0x100_0000 | rgb` 真彩色。
fn encode_color(c: vt100::Color) -> i64 {
    match c {
        vt100::Color::Default => -1,
        vt100::Color::Idx(i) => i as i64,
        vt100::Color::Rgb(r, g, b) => 0x100_0000 | ((r as i64) << 16) | ((g as i64) << 8) | b as i64,
    }
}

/// 一段同样式、连续排布的文本。`c` 是起始列,UI 按列定位,不依赖字体宽度。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Run {
    pub c: u16,
    pub t: String,
    pub fg: i64,
    pub bg: i64,
    pub a: u8,
}

pub struct PtySession {
    parser: Arc<Mutex<vt100::Parser>>,
    writer: Mutex<Box<dyn Write + Send>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    child: Mutex<Box<dyn Child + Send + Sync>>,
    seq: Arc<AtomicU64>,
    alive: Arc<AtomicBool>,
    /// 上一次 [PtySession::frame] 发出去的画面(每行的指纹),下一帧只发变了的行。
    frame_cache: Mutex<Option<FrameCache>>,
}

impl PtySession {
    /// 在 `cwd` 下起用户的登录 shell(`$SHELL -l`,缺省 /bin/zsh)。
    ///
    /// 用登录 shell 是因为从 Finder 启动的 app 只有极简 PATH,
    /// 不走 `-l` 的话 cargo / brew 之类全都找不到。
    pub fn spawn(cwd: &Path, rows: u16, cols: u16) -> Result<Self, String> {
        let rows = rows.max(2);
        let cols = cols.max(10);
        let pair = native_pty_system()
            .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("openpty failed: {e}"))?;

        let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into());
        let mut cmd = CommandBuilder::new(&shell);
        cmd.arg("-l");
        cmd.cwd(cwd);
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        cmd.env("TERM_PROGRAM", "CodeLiteX");
        // Finder 启动时没有 LANG,zsh 会把中文当成乱码字节处理。
        if std::env::var_os("LANG").is_none() {
            cmd.env("LANG", "en_US.UTF-8");
        }

        let child = pair.slave.spawn_command(cmd).map_err(|e| format!("spawn {shell} failed: {e}"))?;
        // slave 端交给子进程后父进程要关掉,否则 shell 退出时 reader 收不到 EOF。
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader().map_err(|e| format!("pty reader: {e}"))?;
        let writer = pair.master.take_writer().map_err(|e| format!("pty writer: {e}"))?;

        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, SCROLLBACK_LINES)));
        let seq = Arc::new(AtomicU64::new(1));
        let alive = Arc::new(AtomicBool::new(true));

        {
            let parser = parser.clone();
            let seq = seq.clone();
            let alive = alive.clone();
            std::thread::Builder::new()
                .name("codelite-pty-reader".into())
                .spawn(move || {
                    let mut buf = [0u8; 16 * 1024];
                    loop {
                        match reader.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                parser.lock().process(&buf[..n]);
                                seq.fetch_add(1, Ordering::Release);
                            }
                        }
                    }
                    alive.store(false, Ordering::Release);
                    seq.fetch_add(1, Ordering::Release);
                })
                .map_err(|e| format!("reader thread: {e}"))?;
        }

        Ok(Self {
            parser,
            writer: Mutex::new(writer),
            master: Mutex::new(pair.master),
            child: Mutex::new(child),
            seq,
            alive,
            frame_cache: Mutex::new(None),
        })
    }

    pub fn write(&self, data: &[u8]) -> Result<(), String> {
        let mut w = self.writer.lock();
        w.write_all(data).and_then(|_| w.flush()).map_err(|e| format!("pty write: {e}"))
    }

    pub fn resize(&self, rows: u16, cols: u16) -> Result<(), String> {
        let rows = rows.max(2);
        let cols = cols.max(10);
        self.master
            .lock()
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("pty resize: {e}"))?;
        self.parser.lock().screen_mut().set_size(rows, cols);
        self.seq.fetch_add(1, Ordering::Release);
        Ok(())
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    pub fn seq(&self) -> u64 {
        self.seq.load(Ordering::Acquire)
    }

    /// 当前屏幕。`since_seq` 与当前 seq 相同时只回 `unchanged`,
    /// 让 UI 能以高频轮询而不在空闲时反复序列化整屏。
    /// `scrollback` 是向上翻的行数(0 = 跟随底部),越界会被 vt100 夹到最大值。
    pub fn snapshot(&self, since_seq: Option<u64>, scrollback: usize) -> Value {
        let seq = self.seq();
        let alive = self.is_alive();
        if since_seq == Some(seq) {
            return json!({ "status": "ok", "unchanged": true, "seq": seq, "alive": alive });
        }

        let mut parser = self.parser.lock();
        let screen = parser.screen_mut();
        // 回滚缓冲里一共有多少行可翻(夹到最大值就是它):界面用它把选区记成绝对行号,翻页、来新输出都不丢
        screen.set_scrollback(usize::MAX);
        let history = screen.scrollback();
        screen.set_scrollback(scrollback);
        let offset = screen.scrollback();
        let screen = parser.screen();
        let (rows, cols) = screen.size();

        let lines: Vec<Vec<Run>> = (0..rows).map(|r| row_runs(screen, r, cols)).collect();
        // 自动折行的行:复制时和下一行接起来,不插换行
        let wrapped: Vec<bool> = (0..rows).map(|r| screen.row_wrapped(r)).collect();
        let (cur_r, cur_c) = screen.cursor_position();
        let result = json!({
            "status": "ok",
            "seq": seq,
            "alive": alive,
            "rows": lines,
            "size": [rows, cols],
            "cursor": [cur_r, cur_c],
            // 翻看历史时不画光标,否则光标会悬在旧内容上。
            "cursor_visible": !screen.hide_cursor() && offset == 0,
            "scrollback": offset,
            "history": history,
            "wrapped": wrapped,
            "app_cursor": screen.application_cursor(),
            "bracketed_paste": screen.bracketed_paste(),
            "alt_screen": screen.alternate_screen(),
        });
        // 视图偏移只服务这一次读取,复位后输出继续写在底部。
        parser.screen_mut().set_scrollback(0);
        result
    }

    /// 二进制画面帧(给界面每帧取画面用,格式见 [encode_frame]):和上一帧比只带变了的行。
    /// `since_seq` 等于当前 seq 时只回「没变」;界面手里的不是上一帧(`since_seq` 对不上)时发整屏。
    pub fn frame(&self, since_seq: Option<u64>, scrollback: usize) -> Vec<u8> {
        let seq = self.seq();
        let alive = self.is_alive();
        let mut parser = self.parser.lock();
        let mut cache = self.frame_cache.lock();
        encode_frame(&mut parser, &mut cache, seq, alive, since_seq, scrollback)
    }

    fn kill(&self) {
        let _ = self.child.lock().kill();
    }
}

impl Drop for PtySession {
    fn drop(&mut self) {
        self.kill();
    }
}

/// 把一行切成同样式的 run。宽字符(中文等)单独成 run 并占两列,
/// 行尾默认样式的空白不输出。
fn row_runs(screen: &vt100::Screen, row: u16, cols: u16) -> Vec<Run> {
    let mut runs: Vec<Run> = Vec::new();
    // 上一个 run 是否是宽字符;宽字符不与相邻字符合并,保证列定位准确。
    let mut last_wide = false;
    let mut col = 0u16;
    while col < cols {
        let Some(cell) = screen.cell(row, col) else { break };
        if cell.is_wide_continuation() {
            col += 1;
            continue;
        }
        let mut a = 0u8;
        if cell.bold() { a |= ATTR_BOLD; }
        if cell.italic() { a |= ATTR_ITALIC; }
        if cell.underline() { a |= ATTR_UNDERLINE; }
        if cell.inverse() { a |= ATTR_INVERSE; }
        if cell.dim() { a |= ATTR_DIM; }
        let fg = encode_color(cell.fgcolor());
        let bg = encode_color(cell.bgcolor());
        let text = if cell.has_contents() { cell.contents() } else { " " };
        let wide = cell.is_wide();

        match runs.last_mut() {
            Some(last)
                if !wide
                    && !last_wide
                    && last.fg == fg
                    && last.bg == bg
                    && last.a == a
                    && !last.t.is_empty()
                    && last.c as usize + last.t.chars().count() == col as usize =>
            {
                last.t.push_str(text);
            }
            _ => runs.push(Run { c: col, t: text.to_string(), fg, bg, a }),
        }
        last_wide = wide;
        col += if wide { 2 } else { 1 };
    }

    // 去掉行尾"看不见"的部分:默认背景、无反色的空白。
    while let Some(last) = runs.last_mut() {
        if last.bg != -1 || last.a & (ATTR_INVERSE | ATTR_UNDERLINE) != 0 {
            break;
        }
        let trimmed = last.t.trim_end_matches(' ').len();
        if trimmed == 0 {
            runs.pop();
        } else {
            last.t.truncate(trimmed);
            break;
        }
    }
    runs
}

/// 按 id 管理多个终端会话(IntelliJ 的多个 Local 标签)。
#[derive(Default)]
pub struct TerminalManager {
    sessions: Mutex<HashMap<String, Arc<PtySession>>>,
    next_id: AtomicU64,
}

impl TerminalManager {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open(&self, cwd: &Path, rows: u16, cols: u16) -> Result<String, String> {
        let session = PtySession::spawn(cwd, rows, cols)?;
        let id = format!("term-{}", self.next_id.fetch_add(1, Ordering::Relaxed) + 1);
        self.sessions.lock().insert(id.clone(), Arc::new(session));
        Ok(id)
    }

    pub fn get(&self, id: &str) -> Option<Arc<PtySession>> {
        self.sessions.lock().get(id).cloned()
    }

    /// 关闭并杀掉 shell。会话不存在时也算成功(幂等)。
    pub fn close(&self, id: &str) {
        self.sessions.lock().remove(id);
    }

    pub fn len(&self) -> usize {
        self.sessions.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

// -----------------------------------------------------------------------------
// 二进制画面帧
// -----------------------------------------------------------------------------

/// 帧格式版本(改格式时加一,Dart 侧 `pty_frame.dart` 同步改)。
pub const FRAME_VERSION: u8 = 1;

pub const FRAME_UNCHANGED: u8 = 1;
pub const FRAME_FULL: u8 = 2;
pub const FRAME_ALIVE: u8 = 4;
pub const FRAME_CURSOR_VISIBLE: u8 = 8;
pub const FRAME_APP_CURSOR: u8 = 16;
pub const FRAME_BRACKETED_PASTE: u8 = 32;
pub const FRAME_ALT_SCREEN: u8 = 64;

/// 上一帧发出去的内容:它的 seq 和每行的指纹。
pub struct FrameCache {
    seq: u64,
    hashes: Vec<u64>,
}

/// 画一帧。小端字节序:
///
/// ```text
/// 头部  u8 版本, u8 标志(FRAME_*), u64 seq, u16 行数, u16 列数, u16 光标行, u16 光标列,
///       u32 回滚偏移, u32 可翻历史行数, u16 本帧带的行数
/// 每行  u16 行号, u8 是否自动折行, u16 run 个数,
///       每个 run:u16 起始列, i32 前景色, i32 背景色, u8 属性, u16 文字字节数, UTF-8 文字
/// ```
///
/// 和 [FrameCache] 里的上一帧比:`since_seq` 正是上一帧的 seq(界面手里就是上一帧)、行数没变时只带变了的行,
/// 否则带全部行(标志里有 FRAME_FULL)。`since_seq` 等于当前 seq 时只有头部(FRAME_UNCHANGED)。
pub fn encode_frame(
    parser: &mut vt100::Parser,
    cache: &mut Option<FrameCache>,
    seq: u64,
    alive: bool,
    since_seq: Option<u64>,
    scrollback: usize,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(4096);
    if since_seq == Some(seq) {
        out.push(FRAME_VERSION);
        out.push(FRAME_UNCHANGED | if alive { FRAME_ALIVE } else { 0 });
        out.extend_from_slice(&seq.to_le_bytes());
        out.extend_from_slice(&[0u8; 2 * 4 + 4 * 2 + 2]);
        return out;
    }

    let screen = parser.screen_mut();
    screen.set_scrollback(usize::MAX);
    let history = screen.scrollback();
    screen.set_scrollback(scrollback);
    let offset = screen.scrollback();
    let screen = parser.screen();
    let (rows, cols) = screen.size();
    let (cur_r, cur_c) = screen.cursor_position();

    let lines: Vec<(bool, Vec<Run>)> = (0..rows).map(|r| (screen.row_wrapped(r), row_runs(screen, r, cols))).collect();
    let hashes: Vec<u64> = lines.iter().map(|(w, runs)| row_hash(*w, runs)).collect();
    let diff_base = cache.as_ref().filter(|c| since_seq == Some(c.seq) && c.hashes.len() == hashes.len());
    let changed: Vec<usize> = match diff_base {
        Some(c) => (0..lines.len()).filter(|&i| c.hashes[i] != hashes[i]).collect(),
        None => (0..lines.len()).collect(),
    };

    let mut flags = 0u8;
    if diff_base.is_none() { flags |= FRAME_FULL; }
    if alive { flags |= FRAME_ALIVE; }
    // 翻看历史时不画光标,否则光标会悬在旧内容上
    if !screen.hide_cursor() && offset == 0 { flags |= FRAME_CURSOR_VISIBLE; }
    if screen.application_cursor() { flags |= FRAME_APP_CURSOR; }
    if screen.bracketed_paste() { flags |= FRAME_BRACKETED_PASTE; }
    if screen.alternate_screen() { flags |= FRAME_ALT_SCREEN; }

    out.push(FRAME_VERSION);
    out.push(flags);
    out.extend_from_slice(&seq.to_le_bytes());
    for v in [rows, cols, cur_r, cur_c] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&(offset.min(u32::MAX as usize) as u32).to_le_bytes());
    out.extend_from_slice(&(history.min(u32::MAX as usize) as u32).to_le_bytes());
    out.extend_from_slice(&(changed.len() as u16).to_le_bytes());
    for &i in &changed {
        let (wrapped, runs) = &lines[i];
        out.extend_from_slice(&(i as u16).to_le_bytes());
        out.push(*wrapped as u8);
        out.extend_from_slice(&(runs.len() as u16).to_le_bytes());
        for run in runs {
            out.extend_from_slice(&run.c.to_le_bytes());
            out.extend_from_slice(&(run.fg as i32).to_le_bytes());
            out.extend_from_slice(&(run.bg as i32).to_le_bytes());
            out.push(run.a);
            let bytes = run.t.as_bytes();
            let len = bytes.len().min(u16::MAX as usize);
            out.extend_from_slice(&(len as u16).to_le_bytes());
            out.extend_from_slice(&bytes[..len]);
        }
    }
    // 视图偏移只服务这一次读取,复位后输出继续写在底部
    parser.screen_mut().set_scrollback(0);
    *cache = Some(FrameCache { seq, hashes });
    out
}

fn row_hash(wrapped: bool, runs: &[Run]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    wrapped.hash(&mut h);
    for r in runs {
        (r.c, r.fg, r.bg, r.a, &r.t).hash(&mut h);
    }
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn wait_for(session: &PtySession, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let snap = session.snapshot(None, 0);
            let text: String = snap["rows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| {
                    row.as_array().unwrap().iter().map(|r| r["t"].as_str().unwrap().to_string()).collect::<String>()
                })
                .collect::<Vec<_>>()
                .join("\n");
            if text.contains(needle) {
                return text;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {needle:?}; screen:\n{text}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    #[test]
    fn shell_keeps_state_between_commands() {
        let dir = std::env::temp_dir().join(format!("clx_pty_{}", std::process::id()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        let mgr = TerminalManager::new();
        let id = mgr.open(&dir, 24, 80).unwrap();
        let s = mgr.get(&id).unwrap();

        // cd 与管道都要生效:这正是单次 exec 做不到的。
        s.write(b"cd sub && export CLX_MARK=pty_ok\r").unwrap();
        s.write(b"echo \"$CLX_MARK:$(basename $PWD)\" | tr a-z A-Z\r").unwrap();
        wait_for(&s, "PTY_OK:SUB");

        let seq = s.seq();
        assert_eq!(s.snapshot(Some(seq), 0)["unchanged"], true);

        s.write(b"exit\r").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while s.is_alive() {
            assert!(Instant::now() < deadline, "shell did not exit");
            std::thread::sleep(Duration::from_millis(50));
        }
        mgr.close(&id);
        assert!(mgr.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn runs_carry_color_and_column() {
        let mut p = vt100::Parser::new(2, 20, 0);
        p.process(b"ab\x1b[31mRED\x1b[0m  \xe4\xb8\xadx");
        let runs = row_runs(p.screen(), 0, 20);
        assert_eq!(runs[0], Run { c: 0, t: "ab".into(), fg: -1, bg: -1, a: 0 });
        assert_eq!(runs[1], Run { c: 2, t: "RED".into(), fg: 1, bg: -1, a: 0 });
        // 宽字符单独成 run,下一个字符从它之后两列开始。
        let wide = runs.iter().find(|r| r.t == "中").unwrap();
        let after = runs.iter().find(|r| r.t.ends_with('x')).unwrap();
        assert_eq!(after.c as usize + after.t.chars().count() - 1, wide.c as usize + 2);
    }

    #[test]
    fn scrollback_further_than_one_screen_shows_older_lines() {
        // 屏幕 5 行,写 50 行(底部一屏是 47..50 和光标所在的空行):往上翻 30 行(远超一屏)顶上是第 17 行,翻过头夹到最早
        let mut p = vt100::Parser::new(5, 20, 100);
        for i in 1..=50 {
            p.process(format!("line {i}\r\n").as_bytes());
        }
        let text = |p: &vt100::Parser| -> Vec<String> {
            (0..5)
                .map(|r| row_runs(p.screen(), r, 20).iter().map(|x| x.t.clone()).collect::<String>().trim().to_string())
                .collect()
        };
        p.screen_mut().set_scrollback(30);
        assert_eq!(p.screen().scrollback(), 30);
        assert_eq!(text(&p)[0], "line 17");
        p.screen_mut().set_scrollback(10_000);
        assert_eq!(text(&p)[0], "line 1");
    }

    #[test]
    fn snapshot_reports_history_and_wrapped_rows() {
        let mut p = vt100::Parser::new(3, 10, 100);
        for i in 1..=10 {
            p.process(format!("l{i}\r\n").as_bytes());
        }
        p.process(b"0123456789abc"); // 超过 10 列:折到下一行
        let screen = p.screen_mut();
        screen.set_scrollback(usize::MAX);
        assert_eq!(screen.scrollback(), 9, "12 行内容(10 行 + 折成两行的那一行)- 屏幕 3 行 = 9 行可翻");
        screen.set_scrollback(0);
        let s = p.screen();
        assert!(s.row_wrapped(1), "第一段被折行");
        assert!(!s.row_wrapped(2));
    }

    /// 从帧里读出:标志、带了哪些行(行号 → 文字)。
    fn read_frame(f: &[u8]) -> (u8, u64, Vec<(u16, String)>) {
        let u16_at = |o: usize| u16::from_le_bytes([f[o], f[o + 1]]);
        assert_eq!(f[0], FRAME_VERSION);
        let flags = f[1];
        let seq = u64::from_le_bytes(f[2..10].try_into().unwrap());
        let n = u16_at(26) as usize;
        let mut o = 28;
        let mut rows = Vec::new();
        for _ in 0..n {
            let idx = u16_at(o);
            let nruns = u16_at(o + 3) as usize;
            o += 5;
            let mut text = String::new();
            for _ in 0..nruns {
                let len = u16_at(o + 11) as usize;
                text.push_str(std::str::from_utf8(&f[o + 13..o + 13 + len]).unwrap());
                o += 13 + len;
            }
            rows.push((idx, text.trim_end().to_string()));
        }
        assert_eq!(o, f.len(), "帧长度和内容对得上");
        (flags, seq, rows)
    }

    #[test]
    fn frame_sends_full_screen_then_only_changed_rows() {
        let mut p = vt100::Parser::new(4, 20, 100);
        let mut cache = None;
        p.process(b"one\r\ntwo\r\n");
        let (flags, seq, rows) = read_frame(&encode_frame(&mut p, &mut cache, 5, true, None, 0));
        assert_eq!(seq, 5);
        assert!(flags & FRAME_FULL != 0 && flags & FRAME_ALIVE != 0 && flags & FRAME_CURSOR_VISIBLE != 0);
        assert_eq!(rows.len(), 4, "第一帧整屏");
        assert_eq!(rows[0], (0, "one".into()));

        // 没变:只有头部
        let unchanged = encode_frame(&mut p, &mut cache, 5, true, Some(5), 0);
        assert_eq!(unchanged.len(), 28);
        assert!(unchanged[1] & FRAME_UNCHANGED != 0);

        // 新输出只改了第 3 行:只带这一行
        p.process(b"three");
        let (flags, _, rows) = read_frame(&encode_frame(&mut p, &mut cache, 6, true, Some(5), 0));
        assert_eq!(flags & FRAME_FULL, 0);
        assert_eq!(rows, vec![(2, "three".to_string())]);

        // 界面手里的不是上一帧(seq 对不上,比如刚滚动 / 刚改大小):整屏
        let (flags, _, rows) = read_frame(&encode_frame(&mut p, &mut cache, 7, true, Some(3), 0));
        assert!(flags & FRAME_FULL != 0);
        assert_eq!(rows.len(), 4);
    }

    #[test]
    fn frame_wide_text_and_colors_survive_and_scrolling_shifts_rows() {
        let mut p = vt100::Parser::new(3, 30, 100);
        let mut cache = None;
        for i in 1..=6 {
            p.process(format!("\x1b[31mline {i} 中文\x1b[0m\r\n").as_bytes());
        }
        let f = encode_frame(&mut p, &mut cache, 1, false, None, 0);
        let (flags, _, rows) = read_frame(&f);
        assert_eq!(flags & FRAME_ALIVE, 0, "shell 退出了");
        assert_eq!(rows[0].1, "line 5 中文");
        // 往上翻 2 行:整屏都变了,偏移和可翻行数在头部
        let f = encode_frame(&mut p, &mut cache, 2, false, Some(1), 2);
        let (_, _, rows) = read_frame(&f);
        assert_eq!(rows[0].1, "line 3 中文");
        assert_eq!(u32::from_le_bytes(f[18..22].try_into().unwrap()), 2, "回滚偏移");
        assert_eq!(u32::from_le_bytes(f[22..26].try_into().unwrap()), 4, "可翻 4 行");
        assert_eq!(p.screen().scrollback(), 0, "读完复位到底部");
    }
}
