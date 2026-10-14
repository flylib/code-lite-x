//! 项目文件索引 + 按文件名快速打开(IntelliJ 的 Go to File)。
//!
//! 文件清单常驻在 Rust(每个项目一份),第一次用时在后台线程里建,之后打字时在清单上做模糊匹配
//! (`nucleo-matcher`,编辑器 Helix 用的那个)。规则跟 IntelliJ:
//! - 没有 `/` 时只匹配文件名;有 `/` 时匹配相对路径(`admin/Ctrl` 这种);
//! - 空格分开的几段都要匹配上;大小写:全小写时不分,有大写时分(smart case);
//! - 分数高的在前,分数一样时路径短的在前。
//!
//! 清单只存相对路径字符串(100k 个文件约几 MB);匹配时用 rayon 分块并行。

use nucleo_matcher::pattern::{AtomKind, CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use rayon::prelude::*;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

/// 不进清单的目录(构建产物、版本库、IDE 自己的)。别的点目录(.github、.claude)照常收,IntelliJ 也是。
const SKIP_DIRS: [&str; 9] = [".git", "node_modules", "target", "build", ".dart_tool", ".gradle", ".idea", ".DS_Store", "out"];
/// 超大目录树的上限,防止误打开 `/` 之类把内存吃光。
const MAX_FILES: usize = 500_000;
const CHUNK: usize = 4096;

struct Entry {
    /// 相对路径,分隔符一律 `/`。
    rel: String,
    /// 文件名在 `rel` 里的起始字节下标。
    name_start: usize,
}

pub struct FileIndex {
    root: PathBuf,
    files: RwLock<Option<Arc<Vec<Entry>>>>,
    building: AtomicBool,
    /// 每建好一次加一(界面据此知道清单换了)。
    generation: AtomicU64,
}

impl FileIndex {
    pub fn new(root: impl Into<PathBuf>) -> Arc<Self> {
        Arc::new(Self { root: root.into(), files: RwLock::new(None), building: AtomicBool::new(false), generation: AtomicU64::new(0) })
    }

    /// 在后台线程里(重新)建清单;已经在建就不重复。建好之前查询用的是旧清单(或者「正在建」)。
    pub fn refresh(self: &Arc<Self>) {
        if self.building.swap(true, Ordering::AcqRel) {
            return;
        }
        let me = Arc::clone(self);
        let spawned = std::thread::Builder::new().name("codelite-file-index".into()).spawn(move || {
            let files = collect(&me.root);
            *me.files.write().unwrap() = Some(Arc::new(files));
            me.generation.fetch_add(1, Ordering::AcqRel);
            me.building.store(false, Ordering::Release);
        });
        if spawned.is_err() {
            self.building.store(false, Ordering::Release);
        }
    }

    /// 同步建好(测试用)。
    pub fn build_now(&self) {
        *self.files.write().unwrap() = Some(Arc::new(collect(&self.root)));
        self.generation.fetch_add(1, Ordering::AcqRel);
    }

    pub fn file_count(&self) -> Option<usize> {
        self.files.read().unwrap().as_ref().map(|f| f.len())
    }

    /// 模糊查找。返回 `{"status":"ok","ready","building","files","generation","results":[{"path","score","indices"}]}`,
    /// `indices` 是 `path` 里匹配上的字符(UTF-16 下标,Dart 直接拿来高亮)。清单还没建好时 `ready: false`、没有结果。
    pub fn query(&self, query: &str, limit: usize) -> Value {
        let files = self.files.read().unwrap().clone();
        let building = self.building.load(Ordering::Acquire);
        let generation = self.generation.load(Ordering::Acquire);
        let Some(files) = files else {
            return json!({ "status": "ok", "ready": false, "building": building, "files": 0, "generation": generation, "results": [] });
        };
        let q = query.trim();
        let results = if q.is_empty() { Vec::new() } else { find(&files, q, limit) };
        json!({
            "status": "ok", "ready": true, "building": building, "files": files.len(), "generation": generation,
            "results": results.into_iter().map(|(path, score, indices)| json!({ "path": path, "score": score, "indices": indices })).collect::<Vec<_>>(),
        })
    }
}

fn collect(root: &Path) -> Vec<Entry> {
    let mut out = Vec::new();
    let mut stack = vec![PathBuf::new()];
    while let Some(rel_dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(root.join(&rel_dir)) else { continue };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            let rel = rel_dir.join(&name);
            if ft.is_dir() {
                stack.push(rel);
            } else if ft.is_file() {
                let rel = rel.to_string_lossy().replace('\\', "/");
                let name_start = rel.len() - name.len();
                out.push(Entry { rel, name_start });
                if out.len() >= MAX_FILES {
                    out.sort_by(|a, b| a.rel.cmp(&b.rel));
                    return out;
                }
            }
        }
    }
    out.sort_by(|a, b| a.rel.cmp(&b.rel));
    out
}

fn find(files: &[Entry], query: &str, limit: usize) -> Vec<(String, u32, Vec<usize>)> {
    // 有 `/` 才看整个路径,否则只看文件名(IntelliJ 的 Go to File)
    let by_path = query.contains('/');
    let pattern = Pattern::new(query, CaseMatching::Smart, Normalization::Smart, AtomKind::Fuzzy);
    let config = || {
        let mut c = Config::DEFAULT;
        if by_path {
            c.set_match_paths();
        } else {
            c.prefer_prefix = true; // 文件名开头就对上的排前面
        }
        c
    };
    fn target(e: &Entry, by_path: bool) -> &str {
        if by_path { e.rel.as_str() } else { &e.rel[e.name_start..] }
    }

    let mut hits: Vec<(usize, u32)> = files
        .par_chunks(CHUNK)
        .enumerate()
        .flat_map_iter(|(chunk, entries)| {
            let mut matcher = Matcher::new(config());
            let mut buf = Vec::new();
            let mut out = Vec::new();
            for (i, e) in entries.iter().enumerate() {
                if let Some(score) = pattern.score(Utf32Str::new(target(e, by_path), &mut buf), &mut matcher) {
                    out.push((chunk * CHUNK + i, score));
                }
            }
            out
        })
        .collect();
    hits.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| files[a.0].rel.len().cmp(&files[b.0].rel.len())).then_with(|| files[a.0].rel.cmp(&files[b.0].rel)));
    hits.truncate(limit);

    let mut matcher = Matcher::new(config());
    let mut buf = Vec::new();
    hits.into_iter()
        .map(|(i, score)| {
            let e = &files[i];
            let mut idx = Vec::new();
            pattern.indices(Utf32Str::new(target(e, by_path), &mut buf), &mut matcher, &mut idx);
            idx.sort_unstable();
            idx.dedup();
            // 字符下标(相对文件名或路径)→ 整个路径里的 UTF-16 下标
            let offset_chars = if by_path { 0 } else { e.rel[..e.name_start].chars().count() };
            let utf16: Vec<usize> = {
                let mut map = Vec::with_capacity(e.rel.len());
                let mut u = 0;
                for ch in e.rel.chars() {
                    map.push(u);
                    u += ch.len_utf16();
                }
                idx.iter().filter_map(|&c| map.get(offset_chars + c as usize).copied()).collect()
            };
            (e.rel.clone(), score, utf16)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(files: &[&str]) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "clx_idx_{}_{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        for f in files {
            let p = d.join(f);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, "x").unwrap();
        }
        d
    }

    fn paths(v: &Value) -> Vec<String> {
        v["results"].as_array().unwrap().iter().map(|r| r["path"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn file_name_matching_like_intellij() {
        let root = tree(&[
            "admin-service/src/main/java/com/bcp/admin/controller/SeaTunnelMigrationGroupController.java",
            "admin-service/src/main/java/com/bcp/admin/service/MigrationService.java",
            "admin-api/pom.xml",
            "pom.xml",
            "docs/migration.md",
            ".github/workflows/ci.yml",
            "target/classes/Junk.class",
            "node_modules/x/index.js",
            ".git/HEAD",
        ]);
        let idx = FileIndex::new(&root);
        assert_eq!(idx.query("pom", 10)["ready"], false, "还没建");
        idx.build_now();
        assert_eq!(idx.file_count(), Some(6), "target / node_modules / .git 不收,.github 收");

        let r = idx.query("stmgc", 10);
        assert_eq!(paths(&r)[0], "admin-service/src/main/java/com/bcp/admin/controller/SeaTunnelMigrationGroupController.java");
        // 高亮下标落在文件名上
        let path = paths(&r)[0].clone();
        let name_at = path.rfind('/').unwrap() + 1;
        let first = r["results"][0]["indices"][0].as_u64().unwrap() as usize;
        assert_eq!(&path[first..first + 1], "S");
        assert!(first >= name_at);

        assert_eq!(paths(&idx.query("pom", 10)), vec!["pom.xml", "admin-api/pom.xml"], "分数一样时路径短的在前");
        assert!(paths(&idx.query("admin", 10)).is_empty(), "没有 / 时只看文件名:目录名里的 admin 不算");
        assert_eq!(paths(&idx.query("admin-api/pom", 10)), vec!["admin-api/pom.xml"], "有 / 时看路径");
        // 空格分开的每段都要对上(模糊:s-e-r-v 也能在 ...GroupController.java 里凑出来,但排在后面)
        assert_eq!(paths(&idx.query("mig serv", 10))[0], "admin-service/src/main/java/com/bcp/admin/service/MigrationService.java");
        assert!(paths(&idx.query("mig xyz", 10)).is_empty());
        assert_eq!(paths(&idx.query("ci", 10))[0], ".github/workflows/ci.yml");
        assert!(paths(&idx.query("Migration", 10)).iter().all(|p| !p.ends_with("migration.md")), "有大写时区分大小写");
        assert!(idx.query("", 10)["results"].as_array().unwrap().is_empty());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn background_refresh_and_utf16_indices() {
        let root = tree(&["文档/说明.md", "a/Ünïcode.txt"]);
        let idx = FileIndex::new(&root);
        idx.refresh();
        for _ in 0..200 {
            if idx.file_count().is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(idx.file_count(), Some(2));
        let r = idx.query("说明", 10);
        assert_eq!(r["results"][0]["indices"], json!([3, 4]), "文档/ 占 3 个 UTF-16 单元");
        let r = idx.query("code", 10);
        assert_eq!(r["results"][0]["path"], "a/Ünïcode.txt");
        assert_eq!(r["results"][0]["indices"], json!([5, 6, 7, 8]), "a / Ü n ï 占 0..4");
        fs::remove_dir_all(&root).unwrap();
    }
}
