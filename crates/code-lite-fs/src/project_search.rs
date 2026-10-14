//! 全局搜索 / 替换(App 用的那份,经 FFI 交给 Dart)。
//!
//! 和 Dart 原实现(`workspace_fs_native.dart`)保持同样的结果:
//! - 跳过以 `.` 开头的目录 / 文件和 `target`、`node_modules`、`build`、`.dart_tool`;
//! - 前 512 字节有 NUL 的当二进制跳过;按 `\n`、`\r\n`、`\r` 分行;
//! - 列号是 UTF-16 下标(Dart 字符串的下标),相对未去空白的行;`line_snippet` 是去掉首尾空白的行;
//! - 整词用 ASCII 的 `\b`(Dart / JS 正则的 `\b` 也是 ASCII 的);
//! - 替换语法 `$1`、`${name}`、`$$`(Rust regex 原生)。
//!
//! 比 Dart 快在:先用整文件一次匹配挑出可能命中的文件(多数文件到这一步就跳过),
//! 文件按路径排好、分批并行(rayon);结果顺序固定,够了 `max_results` 就不再往下读。
//! 正则 Rust 编译不了(比如环视、反向引用)时返回 `status: unsupported`,由 Dart 那份接着做。

use rayon::prelude::*;
use regex::{Regex, RegexBuilder};
use serde::Deserialize;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

const SKIP_DIRS: [&str; 4] = ["target", "node_modules", "build", ".dart_tool"];
const DEFAULT_MAX_RESULTS: usize = 500;
/// 一批并行处理的文件数(批与批之间检查是否已经够了)。
const BATCH: usize = 256;

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SearchOptions {
    #[serde(default)]
    pub is_regex: bool,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default)]
    pub whole_word: bool,
    pub max_results: Option<usize>,
    pub file_extension: Option<String>,
}

struct Patterns {
    /// 逐行匹配用(和 Dart 一样不开多行)。
    line: Regex,
    /// 整文件预筛 / 替换用:多行 + CRLF,`^` `$` 在每行生效。
    file: Regex,
}

fn patterns(query: &str, o: &SearchOptions) -> Result<Patterns, String> {
    let p = if o.is_regex { query.to_string() } else { regex::escape(query) };
    let p = if o.whole_word { format!(r"(?-u:\b){p}(?-u:\b)") } else { p };
    let build = |multi: bool| {
        RegexBuilder::new(&p)
            .case_insensitive(!o.case_sensitive)
            .multi_line(multi)
            .crlf(multi)
            .size_limit(64 << 20)
            .build()
            .map_err(|e| e.to_string())
    };
    Ok(Patterns { line: build(false)?, file: build(true)? })
}

/// 要搜的文件(按路径排序,结果顺序固定)。
fn collect_files(root: &Path, ext: Option<&str>) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let name = e.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.') || SKIP_DIRS.contains(&name.as_ref()) {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(e.path());
            } else if ft.is_file() && ext.is_none_or(|x| name.ends_with(&format!(".{x}"))) {
                out.push(e.path());
            }
        }
    }
    out.sort();
    out
}

/// 读成文本;前 512 字节有 NUL 视为二进制。
fn read_text(path: &Path) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    if bytes[..bytes.len().min(512)].contains(&0) {
        return None;
    }
    Some(match String::from_utf8(bytes) {
        Ok(s) => s,
        Err(e) => String::from_utf8_lossy(e.as_bytes()).into_owned(),
    })
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root).unwrap_or(path).to_string_lossy().into_owned()
}

/// Dart `LineSplitter` 的分行:`\r\n`、`\n`、`\r`;末尾的换行不多出一个空行。
fn lines(text: &str) -> impl Iterator<Item = &str> {
    let b = text.as_bytes();
    let mut start = 0;
    let mut i = 0;
    std::iter::from_fn(move || {
        while i < b.len() {
            match b[i] {
                b'\n' => {
                    let line = &text[start..i];
                    i += 1;
                    start = i;
                    return Some(line);
                }
                b'\r' => {
                    let line = &text[start..i];
                    i += if b.get(i + 1) == Some(&b'\n') { 2 } else { 1 };
                    start = i;
                    return Some(line);
                }
                _ => i += 1,
            }
        }
        if start < b.len() {
            let line = &text[start..];
            start = b.len();
            return Some(line);
        }
        None
    })
}

fn utf16_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

fn search_file(root: &Path, path: &Path, pats: &Patterns, limit: usize) -> Vec<Value> {
    let Some(text) = read_text(path) else { return Vec::new() };
    if !pats.file.is_match(&text) {
        return Vec::new();
    }
    let rel = relative(root, path);
    let mut out = Vec::new();
    'lines: for (n, line) in lines(&text).enumerate() {
        for m in pats.line.find_iter(line) {
            if out.len() >= limit {
                break 'lines;
            }
            out.push(json!({
                "file_path": rel,
                "line_number": n + 1,
                "col_start": utf16_len(&line[..m.start()]),
                "col_end": utf16_len(&line[..m.end()]),
                "line_snippet": line.trim(),
            }));
        }
    }
    out
}

/// 全局搜索。返回 `{"status":"ok","query","total","matches":[...]}`;
/// 正则 Rust 不支持时 `{"status":"unsupported","error"}`(调用方换别的实现)。
pub fn search(root: &Path, query: &str, opts: &SearchOptions) -> Value {
    if query.is_empty() {
        return json!({ "status": "ok", "query": query, "total": 0, "matches": [] });
    }
    let pats = match patterns(query, opts) {
        Ok(p) => p,
        Err(e) => return json!({ "status": "unsupported", "error": e }),
    };
    let max = opts.max_results.unwrap_or(DEFAULT_MAX_RESULTS);
    let files = collect_files(root, opts.file_extension.as_deref());
    let mut matches: Vec<Value> = Vec::new();
    for batch in files.chunks(BATCH) {
        if matches.len() >= max {
            break;
        }
        let left = max - matches.len();
        let found: Vec<Vec<Value>> = batch.par_iter().map(|p| search_file(root, p, &pats, left)).collect();
        for f in found {
            matches.extend(f);
            if matches.len() >= max {
                break;
            }
        }
    }
    matches.truncate(max);
    json!({ "status": "ok", "query": query, "total": matches.len(), "matches": matches })
}

/// 全局替换:所有命中的文件里所有匹配都换掉。返回 `{"status":"ok","replaced_count"}`。
/// 不是合法 UTF-8 的文件不动(不能把它的字节写坏)。
pub fn replace(root: &Path, query: &str, replacement: &str, opts: &SearchOptions) -> Value {
    if query.is_empty() {
        return json!({ "status": "ok", "replaced_count": 0 });
    }
    let pats = match patterns(query, opts) {
        Ok(p) => p,
        Err(e) => return json!({ "status": "unsupported", "error": e }),
    };
    let files = collect_files(root, opts.file_extension.as_deref());
    let results: Vec<Result<usize, String>> = files
        .par_iter()
        .map(|path| {
            let Ok(bytes) = fs::read(path) else { return Ok(0) };
            if bytes[..bytes.len().min(512)].contains(&0) {
                return Ok(0);
            }
            let Ok(text) = String::from_utf8(bytes) else { return Ok(0) };
            let n = pats.file.find_iter(&text).count();
            if n == 0 {
                return Ok(0);
            }
            let updated = pats.file.replace_all(&text, replacement);
            if updated == text {
                return Ok(0);
            }
            fs::write(path, updated.as_bytes()).map_err(|e| format!("{}: {e}", relative(root, path)))?;
            Ok(n)
        })
        .collect();
    let mut count = 0;
    for r in results {
        match r {
            Ok(n) => count += n,
            Err(e) => return json!({ "status": "error", "error": format!("Replace failed: {e}") }),
        }
    }
    json!({ "status": "ok", "replaced_count": count })
}

/// FFI 入口:`{"op":"search"|"replace","root","query","replacement","options":{...}}` → 结果 JSON。
pub fn handle(request: &str) -> Value {
    #[derive(Deserialize)]
    struct Req {
        op: String,
        root: String,
        query: String,
        #[serde(default)]
        replacement: String,
        #[serde(default)]
        options: SearchOptions,
    }
    let req: Req = match serde_json::from_str(request) {
        Ok(r) => r,
        Err(e) => return json!({ "status": "error", "error": format!("bad request: {e}") }),
    };
    let root = Path::new(&req.root);
    match req.op.as_str() {
        "search" => search(root, &req.query, &req.options),
        "replace" => replace(root, &req.query, &req.replacement, &req.options),
        other => json!({ "status": "error", "error": format!("unknown op {other}") }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 每个测试一个独立的临时目录。测试并行跑,只用时间戳会撞名(macOS 的时钟只到微秒),
    /// 撞了之后一个测试的清理会删掉另一个的文件,所以再加一个计数。
    fn tmp() -> PathBuf {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let d = std::env::temp_dir().join(format!("clx_ps_{}_{n}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }
    fn write(root: &Path, rel: &str, text: &str) {
        let p = root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    #[test]
    fn same_results_as_the_dart_version() {
        let r = tmp();
        write(&r, "src/lib.rs", "pub fn calculate_price(qty: i32) -> i32 { qty * 10 }\n");
        write(&r, "README.md", "# Price Service\nCalculate price accurately.\n");
        let o = |j: Value| serde_json::from_value::<SearchOptions>(j).unwrap();
        assert_eq!(search(&r, "calculate", &o(json!({"whole_word": true})))["total"], 1);
        let partial = search(&r, "price", &o(json!({})));
        assert_eq!(partial["total"], 3);
        let first = &partial["matches"][2];
        assert_eq!(first["file_path"], "src/lib.rs", "按路径排序:README.md 的两处在前");
        assert_eq!(first["col_start"], 17);
        assert_eq!(replace(&r, "price", "amount", &o(json!({})))["replaced_count"], 3);
        assert!(fs::read_to_string(r.join("README.md")).unwrap().contains("# amount Service"));
        fs::remove_dir_all(&r).unwrap();
    }

    #[test]
    fn utf16_columns_crlf_lines_anchors_and_limits() {
        let r = tmp();
        write(&r, "a.txt", "  中文 needle\r\nneedle at start\rlast needle");
        let o = |j: Value| serde_json::from_value::<SearchOptions>(j).unwrap();
        let res = search(&r, "needle", &o(json!({})));
        assert_eq!(res["total"], 3);
        let m = &res["matches"];
        assert_eq!((m[0]["line_number"].clone(), m[0]["col_start"].clone(), m[0]["col_end"].clone()), (json!(1), json!(5), json!(11)));
        assert_eq!(m[0]["line_snippet"], "中文 needle");
        assert_eq!(m[2]["line_number"], 3, "\\r 单独也算换行");
        assert_eq!(search(&r, "^needle", &o(json!({"is_regex": true})))["total"], 1, "^ 是行首(CRLF 也认)");
        assert_eq!(search(&r, "needle$", &o(json!({"is_regex": true})))["total"], 2);
        assert_eq!(search(&r, "needle", &o(json!({"max_results": 2})))["total"], 2);
        assert_eq!(search(&r, r"(?<=a)b", &o(json!({"is_regex": true})))["status"], "unsupported", "环视交给 Dart");
        fs::remove_dir_all(&r).unwrap();
    }

    #[test]
    fn skips_hidden_build_and_binary_and_keeps_non_utf8_files_intact() {
        let r = tmp();
        write(&r, "src/main.rs", "needle\n");
        write(&r, ".hidden/x.rs", "needle\n");
        write(&r, "build/out.txt", "needle\n");
        fs::write(r.join("blob.bin"), b"needle\0\x01").unwrap();
        fs::write(r.join("latin1.txt"), b"needle caf\xe9\n").unwrap();
        let res = search(&r, "needle", &SearchOptions::default());
        let paths: Vec<_> = res["matches"].as_array().unwrap().iter().map(|m| m["file_path"].as_str().unwrap().to_string()).collect();
        assert_eq!(paths, vec!["latin1.txt", "src/main.rs"]);
        let rep = replace(&r, "needle", "x", &SearchOptions::default());
        assert_eq!(rep["replaced_count"], 1, "latin1.txt 不是 UTF-8,不改");
        assert_eq!(fs::read(r.join("latin1.txt")).unwrap(), b"needle caf\xe9\n");
        fs::remove_dir_all(&r).unwrap();
    }
}
