//! 项目目录的文件监视(macOS 上是 FSEvents,经 `notify`)。
//!
//! 事件先在 Rust 里过一遍:构建产物、版本库、IDE 目录(`target/`、`node_modules/`、`.git/` ……,
//! 见 [crate::file_index::skipped])和编辑器的临时文件直接丢掉 —— mvn 编译一次会有成千上万个事件,
//! 不该一个个交给界面。剩下的按路径攒着(同一路径只记一次),界面隔一会儿来取一批([ProjectWatcher::poll]):
//! 取的时候看磁盘分出「改了 / 新建 / 删掉」,顺手就地更新 Go to File 的文件清单。

use crate::file_index::{files_under, skipped, FileIndex};
use notify::event::{EventKind, ModifyKind};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const CREATED: u8 = 1;
const REMOVED: u8 = 2;
const MODIFIED: u8 = 4;
const RENAMED: u8 = 8;

/// 一批里攒的路径超过这么多(切大分支、解压):不再逐个记,界面整体重来。
const MAX_PENDING: usize = 20_000;

#[derive(Default)]
struct Pending {
    paths: HashMap<String, u8>,
    overflow: bool,
}

pub struct ProjectWatcher {
    root: PathBuf,
    pending: Arc<Mutex<Pending>>,
    _watcher: RecommendedWatcher,
}

/// 编辑器 / 本应用的临时文件:不算项目里的文件。
fn temporary(rel: &str) -> bool {
    let name = rel.rsplit('/').next().unwrap_or(rel);
    name.contains(".codelite-save-")
        || name.ends_with('~')
        || name.ends_with(".swp")
        || name.ends_with(".swx")
        || name.starts_with(".#")
        || name == "4913"
        || name == ".DS_Store"
}

impl ProjectWatcher {
    pub fn start(root: &Path) -> Result<Self, String> {
        // FSEvents 报的是解析过符号链接的路径(/private/var/… 对 /var/…):两种前缀都认
        let roots: Vec<PathBuf> = {
            let mut v = vec![root.to_path_buf()];
            if let Ok(c) = root.canonicalize() {
                if c != root {
                    v.push(c);
                }
            }
            v
        };
        let pending = Arc::new(Mutex::new(Pending::default()));
        let sink = pending.clone();
        let prefixes = roots.clone();
        let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let mut p = sink.lock().unwrap();
            let event = match res {
                Ok(e) => e,
                Err(_) => {
                    p.overflow = true; // 丢了事件(比如 FSEvents 要求重扫):整体重来
                    return;
                }
            };
            if event.need_rescan() {
                p.overflow = true;
                return;
            }
            let flag = match event.kind {
                EventKind::Create(_) => CREATED,
                EventKind::Remove(_) => REMOVED,
                EventKind::Modify(ModifyKind::Name(_)) => RENAMED,
                EventKind::Modify(_) => MODIFIED,
                EventKind::Access(_) => return,
                _ => MODIFIED | RENAMED,
            };
            for path in &event.paths {
                let Some(rel) = prefixes.iter().find_map(|r| path.strip_prefix(r).ok()) else { continue };
                let rel = rel.to_string_lossy().replace('\\', "/");
                if rel.is_empty() || skipped(&rel) || temporary(&rel) {
                    continue;
                }
                if p.overflow {
                    continue;
                }
                *p.paths.entry(rel).or_insert(0) |= flag;
                if p.paths.len() > MAX_PENDING {
                    p.paths.clear();
                    p.overflow = true;
                }
            }
        })
        .map_err(|e| format!("watch: {e}"))?;
        watcher.watch(root, RecursiveMode::Recursive).map_err(|e| format!("watch {}: {e}", root.display()))?;
        Ok(Self { root: root.to_path_buf(), pending, _watcher: watcher })
    }

    /// 取走攒下的变化。返回
    /// `{"status":"ok","changed":[...],"created":[...],"removed":[...],"structure":bool,"overflow":bool}`(相对路径):
    /// `changed` 是内容改了的已有文件,`structure` 表示有文件 / 目录新建或删掉(文件树要刷新)。
    /// `overflow` 时三个列表都空,调用方整体重来(文件清单这边已经在后台重扫)。
    pub fn poll(&self, index: Option<&Arc<FileIndex>>) -> Value {
        let (paths, overflow) = {
            let mut p = self.pending.lock().unwrap();
            (std::mem::take(&mut p.paths), std::mem::replace(&mut p.overflow, false))
        };
        if overflow {
            if let Some(i) = index {
                i.refresh();
            }
            return json!({ "status": "ok", "changed": [], "created": [], "removed": [], "structure": true, "overflow": true });
        }
        let (mut changed, mut created, mut removed) = (Vec::new(), Vec::new(), Vec::new());
        let mut structure = false;
        let mut keys: Vec<_> = paths.into_iter().collect();
        keys.sort();
        for (rel, flags) in keys {
            match fs::symlink_metadata(self.root.join(&rel)) {
                Ok(m) if m.is_dir() => {
                    if flags & (CREATED | RENAMED) != 0 && !index.is_some_and(|i| i.contains_dir(&rel)) {
                        // 新出现的目录(mkdir、整个目录挪进来):里面的文件一次收进来
                        structure = true;
                        created.extend(files_under(&self.root, &rel).into_iter().filter(|f| !temporary(f)));
                    }
                }
                Ok(m) if m.is_file() => match index.and_then(|i| i.contains(&rel)) {
                    Some(true) => changed.push(rel),
                    Some(false) => {
                        structure = true;
                        created.push(rel);
                    }
                    // 清单还没建好:按事件类型猜
                    None if flags & (CREATED | RENAMED) != 0 => {
                        structure = true;
                        created.push(rel);
                    }
                    None => changed.push(rel),
                },
                Ok(_) => {} // 符号链接等:不管
                Err(_) => {
                    // 不在了:清单里有它(文件或目录)才算删掉;建了又删的临时东西忽略
                    let known = index.map(|i| i.contains(&rel) == Some(true) || i.contains_dir(&rel));
                    if known.unwrap_or(flags & CREATED == 0) {
                        structure = true;
                        removed.push(rel);
                    }
                }
            }
        }
        if let Some(i) = index {
            i.apply(&created, &removed);
        }
        json!({ "status": "ok", "changed": changed, "created": created, "removed": removed, "structure": structure, "overflow": false })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn tmp() -> PathBuf {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let d = std::env::temp_dir().join(format!("clx_watch_{}_{n}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d.canonicalize().unwrap()
    }

    /// 反复取,直到 [done] 满足(FSEvents 有几十毫秒延迟),把每批合起来返回。
    fn poll_until(w: &ProjectWatcher, idx: &Arc<FileIndex>, done: impl Fn(&[Value]) -> bool) -> Vec<Value> {
        let start = Instant::now();
        let mut all = Vec::new();
        while start.elapsed() < Duration::from_secs(5) {
            all.push(w.poll(Some(idx)));
            if done(&all) {
                return all;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        all
    }

    fn has(batches: &[Value], key: &str, rel: &str) -> bool {
        batches.iter().any(|b| b[key].as_array().unwrap().iter().any(|v| v == rel))
    }

    #[test]
    fn classifies_changes_skips_build_output_and_updates_the_index() {
        let root = tmp();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("src/A.java"), "a").unwrap();
        fs::write(root.join("old.txt"), "x").unwrap();
        let idx = FileIndex::new(&root);
        idx.build_now();
        let w = ProjectWatcher::start(&root).unwrap();
        std::thread::sleep(Duration::from_millis(300)); // FSEvents 起来

        fs::write(root.join("src/A.java"), "changed").unwrap();
        fs::write(root.join("src/B.java"), "new").unwrap();
        fs::remove_file(root.join("old.txt")).unwrap();
        fs::create_dir_all(root.join("target/classes")).unwrap();
        fs::write(root.join("target/classes/A.class"), "junk").unwrap();
        fs::write(root.join("src/A.java.codelite-save-123"), "tmp").unwrap();
        fs::remove_file(root.join("src/A.java.codelite-save-123")).unwrap();
        fs::create_dir_all(root.join("docs/sub")).unwrap();
        fs::write(root.join("docs/sub/new.md"), "m").unwrap();

        let b = poll_until(&w, &idx, |b| has(b, "changed", "src/A.java") && has(b, "created", "src/B.java") && has(b, "removed", "old.txt") && has(b, "created", "docs/sub/new.md"));
        assert!(has(&b, "changed", "src/A.java"), "{b:?}");
        assert!(has(&b, "created", "src/B.java"));
        assert!(has(&b, "removed", "old.txt"));
        assert!(has(&b, "created", "docs/sub/new.md"), "新目录里的文件一起收进来");
        assert!(b.iter().any(|x| x["structure"] == true));
        let all = format!("{b:?}");
        assert!(!all.contains("target"), "构建产物不报");
        assert!(!all.contains("codelite-save"), "保存用的临时文件不报");

        // 文件清单就地跟上(没有重扫)
        assert_eq!(idx.contains("src/B.java"), Some(true));
        assert_eq!(idx.contains("old.txt"), Some(false));
        assert_eq!(idx.contains("docs/sub/new.md"), Some(true));
        assert_eq!(idx.contains("target/classes/A.class"), Some(false));

        // 删掉整个目录:下面的文件都从清单里去掉
        fs::remove_dir_all(root.join("docs")).unwrap();
        poll_until(&w, &idx, |_| idx.contains("docs/sub/new.md") == Some(false));
        assert_eq!(idx.contains("docs/sub/new.md"), Some(false));
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn index_apply_keeps_order_and_handles_big_batches() {
        let root = tmp();
        fs::write(root.join("b.txt"), "").unwrap();
        let idx = FileIndex::new(&root);
        idx.build_now();
        idx.apply(&["a.txt".into(), "c/d.txt".into()], &[]);
        let many: Vec<String> = (0..300).map(|i| format!("gen/f{i:03}.txt")).collect();
        idx.apply(&many, &["b.txt".into()]);
        assert_eq!(idx.file_count(), Some(302));
        assert_eq!(idx.contains("gen/f150.txt"), Some(true));
        assert_eq!(idx.contains("b.txt"), Some(false));
        idx.apply(&[], &["gen".into()]);
        assert_eq!(idx.file_count(), Some(2));
        let q = idx.query("d", 5);
        assert_eq!(q["results"][0]["path"], "c/d.txt");
        fs::remove_dir_all(&root).unwrap();
    }
}
