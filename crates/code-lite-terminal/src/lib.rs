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
        screen.set_scrollback(scrollback);
        let offset = screen.scrollback();
        let screen = parser.screen();
        let (rows, cols) = screen.size();

        let lines: Vec<Vec<Run>> = (0..rows).map(|r| row_runs(screen, r, cols)).collect();
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
            "app_cursor": screen.application_cursor(),
            "bracketed_paste": screen.bracketed_paste(),
            "alt_screen": screen.alternate_screen(),
        });
        // 视图偏移只服务这一次读取,复位后输出继续写在底部。
        parser.screen_mut().set_scrollback(0);
        result
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
}
