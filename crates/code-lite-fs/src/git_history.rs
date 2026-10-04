//! Git Log 工具窗口的后端:提交历史查询、提交详情、以及改写历史的写操作
//! (cherry-pick / revert / reset / reword / fixup / squash / drop / 交互式 rebase / 推送到指定提交)。
//!
//! 全部基于系统 `git` CLI。改写历史统一走「脚本化 rebase」:预先生成 todo,
//! 通过 `GIT_SEQUENCE_EDITOR` 覆盖 git 生成的 todo,失败一律 `--abort`,绝不把仓库留在半途状态。

use crate::git::{command_failed, GitEngine, GitError};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// 空树对象(SHA-1 仓库),用于根提交与「无父提交」之间的 diff。
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
/// 字段分隔用 \x1f、记录分隔用 \x1e:提交标题里出现 tab / 换行 / 任意 unicode 都不会串行。
const LOG_FORMAT: &str = "--format=%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s";
const DEFAULT_LOG_LIMIT: usize = 500;

// ---------------------------------------------------------------------------
// 数据模型(字段名即 FFI JSON 契约)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RefKind {
    Head,
    Local,
    Remote,
    Tag,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitRef {
    pub name: String,
    pub kind: RefKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogCommit {
    pub hash: String,
    pub parents: Vec<String>,
    pub author: String,
    pub email: String,
    /// 作者时间(unix 秒)
    pub time: i64,
    pub subject: String,
    pub refs: Vec<GitRef>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryFileChange {
    pub path: String,
    /// 仅重命名 / 复制时有值;其余序列化为 null
    pub old_path: Option<String>,
    /// 单字母:A / M / D / R / C / T(R/C 的相似度分数已去掉)
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalBranch {
    pub name: String,
    pub hash: String,
    pub upstream: Option<String>,
    pub current: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteBranch {
    pub name: String,
    pub remote: String,
    pub short: String,
    pub hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TagInfo {
    pub name: String,
    pub hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BranchesResult {
    pub current: Option<String>,
    pub head: String,
    pub detached: bool,
    pub local: Vec<LocalBranch>,
    pub remote: Vec<RemoteBranch>,
    pub tags: Vec<TagInfo>,
}

/// `git.log` 的查询参数;缺省字段全部按「不过滤」处理。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct LogQuery {
    pub text: Option<String>,
    #[serde(deserialize_with = "null_as_default")]
    pub regex: bool,
    #[serde(deserialize_with = "null_as_default")]
    pub match_case: bool,
    pub branch: Option<String>,
    pub author: Option<String>,
    pub since: Option<i64>,
    #[serde(deserialize_with = "null_as_default")]
    pub paths: Vec<String>,
    pub limit: Option<i64>,
    pub skip: Option<i64>,
}

/// UI 侧可能显式传 null,与缺省同等对待。
fn null_as_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogResult {
    pub commits: Vec<LogCommit>,
    pub head: String,
    pub has_more: bool,
    /// 仓库部分损坏时 git 会输出一部分提交后才报错:保留已读到的提交,这里带上报错原文。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommitDetails {
    pub hash: String,
    pub parents: Vec<String>,
    pub author: String,
    pub email: String,
    pub author_time: i64,
    pub committer: String,
    pub commit_time: i64,
    pub message: String,
    pub refs: Vec<GitRef>,
    pub files: Vec<HistoryFileChange>,
    pub pushed: bool,
    pub is_head: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileAtRevision {
    pub content: String,
    pub binary: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RebasePlanEntry {
    pub hash: String,
    pub subject: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RebasePlan {
    /// None 表示计划从根提交开始(`rebase --root`)
    pub base: Option<String>,
    pub entries: Vec<RebasePlanEntry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RebaseAction {
    Pick,
    Reword,
    Squash,
    Fixup,
    Drop,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RebaseEntry {
    pub hash: String,
    pub action: RebaseAction,
    #[serde(default)]
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushTarget {
    pub remote: String,
    pub branch: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetMode {
    Soft,
    Mixed,
    Hard,
}

impl ResetMode {
    pub fn parse(mode: &str) -> Result<Self, GitError> {
        match mode {
            "soft" => Ok(Self::Soft),
            "mixed" => Ok(Self::Mixed),
            "hard" => Ok(Self::Hard),
            other => Err(msg(format!("不支持的 reset 模式: {}", other))),
        }
    }

    fn flag(self) -> &'static str {
        match self {
            Self::Soft => "--soft",
            Self::Mixed => "--mixed",
            Self::Hard => "--hard",
        }
    }
}

fn msg<S: Into<String>>(s: S) -> GitError {
    GitError::Message(s.into())
}

// ---------------------------------------------------------------------------
// 读操作
// ---------------------------------------------------------------------------

impl GitEngine {
    /// 分支 / 远程分支 / 标签总览。
    pub fn branches(&self) -> Result<BranchesResult, GitError> {
        let head = self.head_hash();
        let current = self.current_branch_name();
        let detached = current.is_none();

        let raw = self.run_git(&[
            "for-each-ref",
            "--format=%(refname)%1f%(objectname)%1f%(upstream:short)%1f%(HEAD)%1f%(*objectname)%1f%(symref)",
            "refs/heads",
            "refs/remotes",
            "refs/tags",
        ])?;

        let mut result = BranchesResult {
            current,
            head,
            detached,
            local: Vec::new(),
            remote: Vec::new(),
            tags: Vec::new(),
        };

        for line in raw.lines() {
            let f: Vec<&str> = line.split('\x1f').collect();
            if f.len() < 6 {
                continue;
            }
            let (refname, hash, upstream, is_head, peeled, symref) = (f[0], f[1], f[2], f[3], f[4], f[5]);
            if let Some(name) = refname.strip_prefix("refs/heads/") {
                result.local.push(LocalBranch {
                    name: name.to_string(),
                    hash: hash.to_string(),
                    upstream: non_empty(upstream),
                    current: is_head == "*",
                });
            } else if let Some(name) = refname.strip_prefix("refs/remotes/") {
                // origin/HEAD 只是指向默认分支的符号引用,不是独立分支
                if !symref.is_empty() || name.ends_with("/HEAD") {
                    continue;
                }
                let (remote, short) = name.split_once('/').unwrap_or((name, ""));
                result.remote.push(RemoteBranch {
                    name: name.to_string(),
                    remote: remote.to_string(),
                    short: short.to_string(),
                    hash: hash.to_string(),
                });
            } else if let Some(name) = refname.strip_prefix("refs/tags/") {
                // 附注标签要剥到提交本身,UI 才能在提交行上定位
                let target = if peeled.is_empty() { hash } else { peeled };
                result.tags.push(TagInfo {
                    name: name.to_string(),
                    hash: target.to_string(),
                });
            }
        }
        Ok(result)
    }

    /// 提交历史(按 `--date-order`,子提交一定排在父提交之前,供图谱布局使用)。
    pub fn history_log(&self, q: &LogQuery) -> Result<LogResult, GitError> {
        let head = self.head_hash();
        let limit = match q.limit {
            Some(n) if n > 0 => n as usize,
            _ => DEFAULT_LOG_LIMIT,
        };
        let skip = q.skip.filter(|s| *s > 0).unwrap_or(0) as usize;
        let branch = q.branch.as_deref().map(str::trim).unwrap_or("");
        let text = q.text.as_deref().unwrap_or("");
        let author = q.author.as_deref().unwrap_or("");

        if branch.starts_with('-') {
            return Err(msg(format!("无效的分支: {}", branch)));
        }
        // 空仓库:HEAD 指向尚未诞生的分支,`git log HEAD` 会报错,这里直接返回空列表
        if !branch.is_empty() && head.is_empty() && self.try_resolve_commit(branch).is_none() {
            return Ok(LogResult { commits: Vec::new(), head, has_more: false, warning: None });
        }

        let n_arg = format!("-n{}", limit + 1);
        let skip_arg = format!("--skip={}", skip);
        let mut args: Vec<String> = vec![
            "log".into(),
            "--date-order".into(),
            "--decorate=full".into(),
            "--no-color".into(),
            "--no-show-signature".into(),
            LOG_FORMAT.into(),
            n_arg,
            skip_arg,
        ];
        // 路径过滤时开启父提交改写,图谱才能连成线而不是一堆孤点
        if !q.paths.is_empty() {
            args.push("--parents".into());
        }
        if !text.is_empty() || !author.is_empty() {
            // 用 ERE 统一处理:--fixed-strings 会连带作用到 --author,导致作者锚定失效
            args.push("--extended-regexp".into());
        }
        if !text.is_empty() {
            let pattern = if q.regex { text.to_string() } else { ere_escape(text) };
            args.push(format!("--grep={}", pattern));
            if !q.match_case {
                args.push("--regexp-ignore-case".into());
            }
        }
        if !author.is_empty() {
            // --author 匹配的是 "Name <email>",锚定首尾实现按姓名精确匹配
            args.push(format!("--author=^{} <", ere_escape(author)));
        }
        if let Some(since) = q.since.filter(|s| *s > 0) {
            args.push(format!("--since=@{}", since));
        }
        if branch.is_empty() {
            // stash 也挂在 refs/ 下,混进历史图谱里只会是噪音
            args.push("--exclude=refs/stash".into());
            args.push("--all".into());
        } else {
            args.push(branch.to_string());
        }
        args.push("--".into());
        for p in q.paths.iter().filter(|p| !p.is_empty()) {
            args.push(top_pathspec(p));
        }

        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        let first = self.run_git_raw(&arg_refs, &[])?;
        let mut out = first;
        let mut only_head = false;
        let nothing = |o: &std::process::Output| {
            !o.status.success() && parse_log_records(&String::from_utf8_lossy(&o.stdout)).is_empty()
        };
        if nothing(&out) {
            // 仓库有损坏对象时尽量把读得到的提交拿出来,逐级放宽:
            // 1. --date-order 要先走完整张图才输出,去掉它改成边走边输出;
            // 2. --all 会先预读所有分支的父提交,仍然一条都拿不到时退到只看 HEAD。
            let streaming: Vec<&str> = arg_refs.iter().copied().filter(|a| *a != "--date-order").collect();
            out = self.run_git_raw(&streaming, &[])?;
            if nothing(&out) && branch.is_empty() {
                let head_only: Vec<&str> = streaming
                    .iter()
                    .map(|a| if *a == "--all" { "HEAD" } else { a })
                    .filter(|a| *a != "--exclude=refs/stash")
                    .collect();
                let retry = self.run_git_raw(&head_only, &[])?;
                if !nothing(&retry) {
                    out = retry;
                    only_head = true;
                }
            }
        }
        let raw = String::from_utf8_lossy(&out.stdout);
        let mut commits = parse_log_records(&raw);
        let warning = if out.status.success() {
            None
        } else if commits.is_empty() {
            return Err(command_failed(&out));
        } else {
            // 损坏的对象之后的历史读不到,也就没有"下一页"
            let scope = if only_head { "(其他分支无法读取,仅显示 HEAD)" } else { "" };
            Some(format!("{}{}", scope, failure_detail(&out)))
        };
        let has_more = warning.is_none() && commits.len() > limit;
        commits.truncate(limit);

        // 搜索框里输入的是提交哈希:无论消息是否匹配都要把它带出来,且只放在第一页避免分页重复
        if is_hex_prefix(text) {
            if let Some(full) = self.try_resolve_commit(text) {
                if skip == 0 {
                    if !commits.iter().any(|c| c.hash == full) {
                        if let Some(c) = self.log_single(&full)? {
                            commits.insert(0, c);
                        }
                    }
                } else {
                    commits.retain(|c| c.hash != full);
                }
            }
        }

        Ok(LogResult { commits, head, has_more, warning })
    }

    /// 所有引用上出现过的作者,去重并按不区分大小写排序。
    pub fn history_authors(&self) -> Result<Vec<String>, GitError> {
        let raw = self.run_git(&["log", "--exclude=refs/stash", "--all", "--no-show-signature", "--format=%an"])?;
        let set: HashSet<&str> = raw.lines().filter(|l| !l.is_empty()).collect();
        let mut authors: Vec<String> = set.into_iter().map(str::to_string).collect();
        authors.sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()).then_with(|| a.cmp(b)));
        Ok(authors)
    }

    pub fn commit_details(&self, rev: &str) -> Result<CommitDetails, GitError> {
        let full = self.resolve_commit(rev)?;
        let raw = self.run_git(&[
            "log",
            "-1",
            "--no-walk",
            "--decorate=full",
            "--no-color",
            "--no-show-signature",
            "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%D%x1f%B",
            &full,
        ])?;
        let f: Vec<&str> = raw.splitn(9, '\x1f').collect();
        if f.len() < 9 {
            return Err(msg(format!("无法解析提交信息: {}", full)));
        }
        let parents = split_hashes(f[1]);
        let files = self.commit_files(&full, parents.first().map(String::as_str))?;
        let pushed = self.is_pushed(&full)?;
        let is_head = self.head_hash() == full;
        Ok(CommitDetails {
            hash: f[0].to_string(),
            parents,
            author: f[2].to_string(),
            email: f[3].to_string(),
            author_time: f[4].trim().parse().unwrap_or(0),
            committer: f[5].to_string(),
            commit_time: f[6].trim().parse().unwrap_or(0),
            refs: parse_refs(f[7]),
            message: f[8].trim_end_matches('\n').to_string(),
            files,
            pushed,
            is_head,
        })
    }

    /// 单个文件在该提交中的改动(相对第一父提交;根提交相对空树)。
    pub fn commit_file_diff(&self, rev: &str, path: &str, old_path: Option<&str>) -> Result<String, GitError> {
        let full = self.resolve_commit(rev)?;
        require_path(path)?;
        let parents = self.parents_of(&full)?;
        let base = parents.first().map(String::as_str).unwrap_or(EMPTY_TREE);
        let mut args: Vec<String> = diff_text_args();
        args.push("-M".into());
        args.push(base.to_string());
        args.push(full.clone());
        args.push("--".into());
        args.push(top_pathspec(path));
        if let Some(old) = old_path.filter(|o| !o.is_empty() && *o != path) {
            args.push(top_pathspec(old));
        }
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.run_git(&arg_refs)
    }

    /// 该提交与当前工作区之间的文件差异列表。
    pub fn compare_with_local(&self, rev: &str) -> Result<Vec<HistoryFileChange>, GitError> {
        let full = self.resolve_commit(rev)?;
        let raw = self.run_git(&["diff", "--no-color", "--name-status", "-M", "-z", &full])?;
        Ok(parse_name_status_z(&raw))
    }

    pub fn compare_with_local_diff(&self, rev: &str, path: &str) -> Result<String, GitError> {
        let full = self.resolve_commit(rev)?;
        require_path(path)?;
        let mut args = diff_text_args();
        args.push(full);
        args.push("--".into());
        args.push(top_pathspec(path));
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.run_git(&arg_refs)
    }

    pub fn tree_at(&self, rev: &str) -> Result<Vec<String>, GitError> {
        let full = self.resolve_commit(rev)?;
        let raw = self.run_git(&["ls-tree", "-r", "--name-only", "-z", "--full-tree", &full])?;
        Ok(raw.split('\0').filter(|s| !s.is_empty()).map(str::to_string).collect())
    }

    pub fn file_at(&self, rev: &str, path: &str) -> Result<FileAtRevision, GitError> {
        let full = self.resolve_commit(rev)?;
        require_path(path)?;
        let spec = format!("{}:{}", full, path.trim_start_matches('/'));
        let out = self.run_git_raw(&["cat-file", "blob", &spec], &[])?;
        if !out.status.success() {
            return Err(msg(format!("文件在该提交中不存在: {}", path)));
        }
        let head_len = out.stdout.len().min(8000);
        if out.stdout[..head_len].contains(&0) {
            return Ok(FileAtRevision { content: String::new(), binary: true });
        }
        Ok(FileAtRevision {
            content: String::from_utf8_lossy(&out.stdout).into_owned(),
            binary: false,
        })
    }

    pub fn create_patch(&self, rev: &str) -> Result<String, GitError> {
        let full = self.resolve_commit(rev)?;
        self.run_git(&["format-patch", "-1", &full, "--stdout"])
    }

    /// 是否已被任一远程跟踪分支包含。
    pub fn is_pushed(&self, rev: &str) -> Result<bool, GitError> {
        let full = self.resolve_commit(rev)?;
        let raw = self.run_git(&["branch", "-r", "--contains", &full])?;
        Ok(raw.lines().any(|l| !l.trim().is_empty()))
    }

    /// 交互式 rebase 计划:从目标提交(含)到 HEAD,最老的在前。
    pub fn rebase_plan(&self, rev: &str) -> Result<RebasePlan, GitError> {
        let full = self.resolve_commit(rev)?;
        let (base, _) = self.linear_range(&full)?;
        let range = range_spec(base.as_deref());
        let raw = self.run_git(&[
            "log",
            "--reverse",
            "--no-color",
            "--no-show-signature",
            "--format=%x1e%H%x1f%s%x1f%B",
            &range,
        ])?;
        let entries = raw
            .split('\x1e')
            .filter(|r| !r.trim().is_empty())
            .filter_map(|r| {
                let f: Vec<&str> = r.splitn(3, '\x1f').collect();
                (f.len() == 3).then(|| RebasePlanEntry {
                    hash: f[0].trim().to_string(),
                    subject: f[1].to_string(),
                    message: f[2].trim_end_matches('\n').to_string(),
                })
            })
            .collect();
        Ok(RebasePlan { base, entries })
    }
}

// ---------------------------------------------------------------------------
// 写操作
// ---------------------------------------------------------------------------

impl GitEngine {
    pub fn cherry_pick(&self, rev: &str) -> Result<(), GitError> {
        self.ensure_idle()?;
        let full = self.resolve_commit(rev)?;
        let mut args = vec!["cherry-pick"];
        if self.parents_of(&full)?.len() > 1 {
            args.extend(["-m", "1"]);
        }
        args.push(&full);
        let out = self.run_git_raw(&args, &[])?;
        if !out.status.success() {
            let _ = self.run_git_raw(&["cherry-pick", "--abort"], &[]);
            return Err(msg(format!("Cherry-pick 冲突,已中止: {}", failure_detail(&out))));
        }
        Ok(())
    }

    pub fn checkout_revision(&self, rev: &str) -> Result<(), GitError> {
        let full = self.resolve_commit(rev)?;
        self.run_git(&["checkout", "--detach", &full])?;
        Ok(())
    }

    pub fn revert_commit(&self, rev: &str) -> Result<(), GitError> {
        self.ensure_idle()?;
        let full = self.resolve_commit(rev)?;
        let mut args = vec!["revert", "--no-edit"];
        if self.parents_of(&full)?.len() > 1 {
            args.extend(["-m", "1"]);
        }
        args.push(&full);
        let out = self.run_git_raw(&args, &[])?;
        if !out.status.success() {
            let _ = self.run_git_raw(&["revert", "--abort"], &[]);
            return Err(msg(format!("Revert 冲突,已中止: {}", failure_detail(&out))));
        }
        Ok(())
    }

    pub fn reset_to(&self, rev: &str, mode: ResetMode) -> Result<(), GitError> {
        let full = self.resolve_commit(rev)?;
        self.run_git(&["reset", mode.flag(), &full])?;
        Ok(())
    }

    /// 撤销最近一次提交,改动保留在暂存区。
    pub fn undo_commit(&self) -> Result<(), GitError> {
        if self.head_hash().is_empty() {
            return Err(msg("仓库还没有任何提交"));
        }
        if self.try_resolve_commit("HEAD^").is_none() {
            return Err(msg("HEAD 没有父提交,无法撤销"));
        }
        self.run_git(&["reset", "--soft", "HEAD~1"])?;
        Ok(())
    }

    pub fn new_branch(&self, name: &str, rev: &str, checkout: bool) -> Result<(), GitError> {
        let name = name.trim();
        let ok = !name.is_empty()
            && !name.starts_with('-')
            && self.run_git_raw(&["check-ref-format", "--branch", name], &[])?.status.success();
        if !ok {
            return Err(msg(format!("无效的分支名: {}", name)));
        }
        let full = self.resolve_commit(rev)?;
        if checkout {
            self.run_git(&["switch", "-c", name, &full])?;
        } else {
            self.run_git(&["branch", name, &full])?;
        }
        Ok(())
    }

    pub fn new_tag(&self, name: &str, rev: &str, message: Option<&str>) -> Result<(), GitError> {
        let name = name.trim();
        let ok = !name.is_empty()
            && !name.starts_with('-')
            && self
                .run_git_raw(&["check-ref-format", &format!("refs/tags/{}", name)], &[])?
                .status
                .success();
        if !ok {
            return Err(msg(format!("无效的标签名: {}", name)));
        }
        let full = self.resolve_commit(rev)?;
        match message.filter(|m| !m.trim().is_empty()) {
            Some(m) => self.run_git(&["tag", "-a", name, "-m", m, &full])?,
            None => self.run_git(&["tag", name, &full])?,
        };
        Ok(())
    }

    /// 修改提交信息。HEAD 直接 amend(只改消息,不带入暂存区);其余走脚本化 rebase。
    pub fn reword(&self, rev: &str, message: &str) -> Result<(), GitError> {
        self.ensure_idle()?;
        require_message(message)?;
        let full = self.resolve_commit(rev)?;
        let msg_file = TempFile::create("msg", message)?;
        if full == self.head_hash() {
            let path = msg_file.path_str();
            self.run_git(&["commit", "--amend", "--only", "--allow-empty", "-F", &path])?;
            return Ok(());
        }
        let (base, commits) = self.linear_range(&full)?;
        let mut todo = String::new();
        for c in &commits {
            todo.push_str(&format!("pick {}\n", c));
            if *c == full {
                todo.push_str(&amend_exec_line(&msg_file));
            }
        }
        self.scripted_rebase(base.as_deref(), &todo, false)
    }

    /// 把已暂存的修改并入目标提交(保留目标原消息)。
    pub fn fixup_into(&self, rev: &str) -> Result<(), GitError> {
        self.fold_staged_into(rev, None)
    }

    /// 把已暂存的修改并入目标提交,并把目标提交消息替换为 `message`。
    pub fn squash_into(&self, rev: &str, message: &str) -> Result<(), GitError> {
        require_message(message)?;
        self.fold_staged_into(rev, Some(message))
    }

    pub fn drop_commit(&self, rev: &str) -> Result<(), GitError> {
        self.ensure_idle()?;
        let full = self.resolve_commit(rev)?;
        let (base, commits) = self.linear_range(&full)?;
        let todo: String = commits
            .iter()
            .map(|c| format!("{} {}\n", if *c == full { "drop" } else { "pick" }, c))
            .collect();
        self.scripted_rebase(base.as_deref(), &todo, false)
    }

    /// 按 UI 编辑好的计划执行交互式 rebase。条目必须恰好覆盖 base..HEAD,防止旧计划误删提交。
    pub fn rebase_interactive(&self, base: Option<&str>, entries: &[RebaseEntry]) -> Result<(), GitError> {
        self.ensure_idle()?;
        if entries.is_empty() {
            return Err(msg("rebase 计划为空"));
        }
        if let Some(first) = entries.iter().find(|e| e.action != RebaseAction::Drop) {
            if matches!(first.action, RebaseAction::Squash | RebaseAction::Fixup) {
                return Err(msg("第一个提交不能是 squash / fixup"));
            }
        }
        let head = self.head_hash();
        if head.is_empty() {
            return Err(msg("仓库还没有任何提交"));
        }
        let base_full = match base.filter(|b| !b.trim().is_empty()) {
            Some(b) => {
                let full = self.resolve_commit(b)?;
                if !self.is_ancestor(&full, &head)? {
                    return Err(msg("rebase 基点不在当前分支的历史中"));
                }
                Some(full)
            }
            None => None,
        };
        let range = range_spec(base_full.as_deref());
        self.ensure_no_merges(&range)?;
        let expected: HashSet<String> = self
            .run_git(&["rev-list", &range])?
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect();

        let mut seen = HashSet::new();
        let mut resolved = Vec::with_capacity(entries.len());
        for e in entries {
            let full = self.resolve_commit(&e.hash)?;
            if !seen.insert(full.clone()) {
                return Err(msg(format!("rebase 计划中提交重复: {}", e.hash)));
            }
            resolved.push(full);
        }
        if seen != expected {
            return Err(msg("rebase 计划与当前分支历史不一致,请刷新后重试"));
        }

        // 消息临时文件需要活到 rebase 结束
        let mut msg_files = Vec::new();
        let mut todo = String::new();
        for (e, full) in entries.iter().zip(&resolved) {
            let new_msg = e.message.as_deref().filter(|m| !m.trim().is_empty());
            match e.action {
                RebaseAction::Pick => todo.push_str(&format!("pick {}\n", full)),
                RebaseAction::Drop => todo.push_str(&format!("drop {}\n", full)),
                RebaseAction::Fixup => todo.push_str(&format!("fixup {}\n", full)),
                RebaseAction::Reword | RebaseAction::Squash => {
                    let verb = if e.action == RebaseAction::Reword { "pick" } else { "squash" };
                    todo.push_str(&format!("{} {}\n", verb, full));
                    // 没给新消息时:reword 退化为 pick,squash 保留 git 默认的合并消息
                    if let Some(m) = new_msg {
                        let f = TempFile::create("msg", m)?;
                        todo.push_str(&amend_exec_line(&f));
                        msg_files.push(f);
                    }
                }
            }
        }
        let result = self.scripted_rebase(base_full.as_deref(), &todo, false);
        drop(msg_files);
        result
    }

    /// 把 `hash` 到 HEAD 的提交推送到上游分支(只推到该提交为止)。
    pub fn push_up_to(&self, rev: &str) -> Result<PushTarget, GitError> {
        let current = self
            .current_branch_name()
            .ok_or_else(|| msg("当前处于游离 HEAD,无法推送"))?;
        let full = self.resolve_commit(rev)?;
        if !self.is_ancestor(&full, &self.head_hash())? {
            return Err(msg("该提交不在当前分支的历史中"));
        }
        let remote = self.config_get(&format!("branch.{}.remote", current));
        let merge = self.config_get(&format!("branch.{}.merge", current));
        let target = match (remote, merge) {
            (Some(r), Some(m)) if r != "." => PushTarget {
                remote: r,
                branch: m.strip_prefix("refs/heads/").unwrap_or(&m).to_string(),
            },
            _ => PushTarget { remote: "origin".into(), branch: current.clone() },
        };
        let refspec = format!("{}:refs/heads/{}", full, target.branch);
        self.run_git_env(&["push", &target.remote, &refspec], &[("GIT_TERMINAL_PROMPT", "0")])?;
        Ok(target)
    }

    fn fold_staged_into(&self, rev: &str, message: Option<&str>) -> Result<(), GitError> {
        self.ensure_idle()?;
        let full = self.resolve_commit(rev)?;
        if !self.has_staged_changes()? {
            return Err(msg("没有已暂存的修改"));
        }
        // 先校验范围再提交,避免校验失败时留下一个孤立的 fixup 提交
        let (base, commits) = self.linear_range(&full)?;
        let msg_file = message.map(|m| TempFile::create("msg", m)).transpose()?;

        self.run_git(&["commit", "--fixup", &full])?;
        let fixup_hash = self.head_hash();

        // 自己生成 todo:不依赖 "fixup! <subject>" 的标题匹配,重名提交也不会并错
        let mut todo = String::new();
        for c in &commits {
            todo.push_str(&format!("pick {}\n", c));
            if *c == full {
                todo.push_str(&format!("fixup {}\n", fixup_hash));
                if let Some(f) = &msg_file {
                    todo.push_str(&amend_exec_line(f));
                }
            }
        }
        if let Err(e) = self.scripted_rebase(base.as_deref(), &todo, true) {
            // 还原到操作前:撤掉 fixup 提交,修改回到暂存区
            if self.head_hash() == fixup_hash {
                let _ = self.run_git(&["reset", "--soft", "HEAD~1"]);
            }
            return Err(e);
        }
        Ok(())
    }

    /// 用预生成的 todo 跑 `git rebase -i`;任何失败都 `--abort`,保证不留半途状态。
    fn scripted_rebase(&self, base: Option<&str>, todo: &str, autosquash: bool) -> Result<(), GitError> {
        let todo_file = TempFile::create("todo", todo)?;
        // git 会把 todo 文件路径追加为参数:cp <预生成 todo> <git 的 todo>
        let seq_editor = format!("cp {}", sh_quote(&todo_file.path_str()));
        let mut args = vec!["rebase", "-i", "--autostash"];
        if autosquash {
            args.push("--autosquash");
        }
        match base {
            Some(b) => args.push(b),
            None => args.push("--root"),
        }
        let out = self.run_git_raw(&args, &[("GIT_SEQUENCE_EDITOR", seq_editor.as_str()), ("GIT_EDITOR", "true")])?;
        if !out.status.success() || self.rebase_in_progress() {
            let _ = self.run_git_raw(&["rebase", "--abort"], &[]);
            return Err(msg(format!("Rebase 失败,已中止: {}", failure_detail(&out))));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

impl GitEngine {
    /// HEAD 的完整哈希;空仓库返回 ""。
    fn head_hash(&self) -> String {
        self.try_resolve_commit("HEAD").unwrap_or_default()
    }

    fn current_branch_name(&self) -> Option<String> {
        let out = self.run_git_raw(&["symbolic-ref", "--quiet", "--short", "HEAD"], &[]).ok()?;
        if !out.status.success() {
            return None;
        }
        non_empty(String::from_utf8_lossy(&out.stdout).trim())
    }

    fn try_resolve_commit(&self, rev: &str) -> Option<String> {
        let rev = rev.trim();
        if rev.is_empty() || rev.starts_with('-') {
            return None;
        }
        let spec = format!("{}^{{commit}}", rev);
        let out = self.run_git_raw(&["rev-parse", "--verify", "--quiet", &spec], &[]).ok()?;
        if !out.status.success() {
            return None;
        }
        non_empty(String::from_utf8_lossy(&out.stdout).trim())
    }

    fn resolve_commit(&self, rev: &str) -> Result<String, GitError> {
        if rev.trim().is_empty() {
            return Err(msg("缺少提交哈希"));
        }
        self.try_resolve_commit(rev).ok_or_else(|| msg(format!("找不到提交: {}", rev.trim())))
    }

    fn parents_of(&self, full: &str) -> Result<Vec<String>, GitError> {
        let raw = self.run_git(&["rev-list", "--parents", "-n", "1", full])?;
        Ok(raw.split_whitespace().skip(1).map(str::to_string).collect())
    }

    fn is_ancestor(&self, ancestor: &str, descendant: &str) -> Result<bool, GitError> {
        if descendant.is_empty() {
            return Ok(false);
        }
        let out = self.run_git_raw(&["merge-base", "--is-ancestor", ancestor, descendant], &[])?;
        match out.status.code() {
            Some(0) => Ok(true),
            Some(1) => Ok(false),
            _ => Err(command_failed(&out)),
        }
    }

    fn ensure_no_merges(&self, range: &str) -> Result<(), GitError> {
        let merges = self.run_git(&["rev-list", "--merges", range])?;
        if merges.trim().is_empty() {
            Ok(())
        } else {
            Err(msg("范围内包含合并提交,不支持交互式 rebase"))
        }
    }

    /// 目标提交到 HEAD 的线性区间:返回 (rebase 基点, 区间内提交 最老在前)。基点 None 表示从根开始。
    fn linear_range(&self, full: &str) -> Result<(Option<String>, Vec<String>), GitError> {
        let head = self.head_hash();
        if !self.is_ancestor(full, &head)? {
            return Err(msg("该提交不在当前分支的历史中"));
        }
        let base = self.parents_of(full)?.into_iter().next();
        let range = range_spec(base.as_deref());
        self.ensure_no_merges(&range)?;
        let commits = self
            .run_git(&["rev-list", "--reverse", &range])?
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect();
        Ok((base, commits))
    }

    fn has_staged_changes(&self) -> Result<bool, GitError> {
        let out = self.run_git_raw(&["diff", "--cached", "--quiet"], &[])?;
        match out.status.code() {
            Some(0) => Ok(false),
            Some(1) => Ok(true),
            _ => Err(command_failed(&out)),
        }
    }

    fn git_path_exists(&self, name: &str) -> bool {
        let out = match self.run_git_raw(&["rev-parse", "--git-path", name], &[]) {
            Ok(o) if o.status.success() => o,
            _ => return false,
        };
        let p = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
        let full = if p.is_absolute() { p } else { self.repo_path().join(p) };
        full.exists()
    }

    fn rebase_in_progress(&self) -> bool {
        self.git_path_exists("rebase-merge") || self.git_path_exists("rebase-apply")
    }

    /// 写操作失败时会执行 `--abort`;若用户自己有进行中的操作,先拒绝,免得误中止别人的现场。
    fn ensure_idle(&self) -> Result<(), GitError> {
        let busy = self.rebase_in_progress()
            || ["CHERRY_PICK_HEAD", "REVERT_HEAD", "MERGE_HEAD"]
                .iter()
                .any(|n| self.git_path_exists(n));
        if busy {
            Err(msg("仓库中有进行中的 rebase / merge / cherry-pick / revert,请先完成或中止"))
        } else {
            Ok(())
        }
    }

    fn config_get(&self, key: &str) -> Option<String> {
        let out = self.run_git_raw(&["config", "--get", key], &[]).ok()?;
        if !out.status.success() {
            return None;
        }
        non_empty(String::from_utf8_lossy(&out.stdout).trim())
    }

    fn log_single(&self, full: &str) -> Result<Option<LogCommit>, GitError> {
        let raw = self.run_git(&[
            "log",
            "-1",
            "--no-walk",
            "--decorate=full",
            "--no-color",
            "--no-show-signature",
            LOG_FORMAT,
            full,
        ])?;
        Ok(parse_log_records(&raw).into_iter().next())
    }

    fn commit_files(&self, full: &str, first_parent: Option<&str>) -> Result<Vec<HistoryFileChange>, GitError> {
        let raw = match first_parent {
            Some(p) => self.run_git(&["diff", "--no-color", "--name-status", "-M", "-z", p, full])?,
            None => self.run_git(&[
                "diff-tree",
                "--root",
                "--no-commit-id",
                "-r",
                "--name-status",
                "-M",
                "-z",
                full,
            ])?,
        };
        Ok(parse_name_status_z(&raw))
    }
}

/// 生命周期绑定的临时文件,drop 时删除。
struct TempFile {
    path: PathBuf,
}

impl TempFile {
    fn create(tag: &str, content: &str) -> Result<Self, GitError> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir().join(format!(
            "codelite_git_{}_{}_{}_{}",
            tag,
            std::process::id(),
            nanos,
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&path, content)?;
        Ok(Self { path })
    }

    fn path_str(&self) -> String {
        // git 在 Windows 上也走 sh,统一用正斜杠
        self.path.to_string_lossy().replace('\\', "/")
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn amend_exec_line(msg_file: &TempFile) -> String {
    format!("exec git commit --amend --only --allow-empty -F {}\n", sh_quote(&msg_file.path_str()))
}

fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn range_spec(base: Option<&str>) -> String {
    match base {
        Some(b) => format!("{}..HEAD", b),
        None => "HEAD".to_string(),
    }
}

/// 统一使用以仓库根为基准、关闭通配的 pathspec:路径里的 `*` / `[` 不会被当成 glob。
fn top_pathspec(p: &str) -> String {
    format!(":(top,literal){}", p.trim_start_matches('/'))
}

/// 输出给 UI 解析的 unified diff:屏蔽 color / external diff / 前缀配置对格式的影响。
fn diff_text_args() -> Vec<String> {
    ["diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

fn require_path(path: &str) -> Result<(), GitError> {
    if path.trim().is_empty() {
        Err(msg("缺少文件路径"))
    } else {
        Ok(())
    }
}

fn require_message(message: &str) -> Result<(), GitError> {
    if message.trim().is_empty() {
        Err(msg("提交信息不能为空"))
    } else {
        Ok(())
    }
}

fn failure_detail(out: &std::process::Output) -> String {
    match command_failed(out) {
        GitError::CommandFailed(_, m) => m,
        other => other.to_string(),
    }
}

fn non_empty(s: &str) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

fn split_hashes(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_string).collect()
}

fn is_hex_prefix(s: &str) -> bool {
    (4..=40).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// 转义为 POSIX ERE 字面量。
fn ere_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for ch in s.chars() {
        if "\\.^$|?*+()[]{}".contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

fn parse_log_records(raw: &str) -> Vec<LogCommit> {
    raw.split('\x1e')
        .filter(|r| !r.trim().is_empty())
        .filter_map(|record| {
            let record = record.trim_end_matches('\n');
            let f: Vec<&str> = record.splitn(7, '\x1f').collect();
            if f.len() < 7 {
                return None;
            }
            Some(LogCommit {
                hash: f[0].trim().to_string(),
                parents: split_hashes(f[1]),
                author: f[2].to_string(),
                email: f[3].to_string(),
                time: f[4].trim().parse().unwrap_or(0),
                refs: parse_refs(f[5]),
                subject: f[6].to_string(),
            })
        })
        .collect()
}

/// 解析 `--decorate=full` 下的 `%D`,例如 `HEAD -> refs/heads/main, tag: refs/tags/v1, refs/remotes/origin/main`。
fn parse_refs(decor: &str) -> Vec<GitRef> {
    let mut refs = Vec::new();
    for item in decor.split(", ").map(str::trim).filter(|s| !s.is_empty()) {
        let item = match item.strip_prefix("HEAD -> ") {
            Some(rest) => {
                refs.push(GitRef { name: "HEAD".into(), kind: RefKind::Head });
                rest
            }
            None => item,
        };
        let item = item.strip_prefix("tag: ").unwrap_or(item);
        if item == "HEAD" {
            refs.push(GitRef { name: "HEAD".into(), kind: RefKind::Head });
        } else if let Some(n) = item.strip_prefix("refs/heads/") {
            refs.push(GitRef { name: n.into(), kind: RefKind::Local });
        } else if let Some(n) = item.strip_prefix("refs/remotes/") {
            if !n.ends_with("/HEAD") {
                refs.push(GitRef { name: n.into(), kind: RefKind::Remote });
            }
        } else if let Some(n) = item.strip_prefix("refs/tags/") {
            refs.push(GitRef { name: n.into(), kind: RefKind::Tag });
        }
        // 其他命名空间(refs/stash、refs/notes 等)不在图谱上展示
    }
    refs
}

/// 解析 `--name-status -z`:`M\0path\0`,重命名/复制为 `R100\0old\0new\0`。
fn parse_name_status_z(raw: &str) -> Vec<HistoryFileChange> {
    let mut tokens = raw.split('\0').filter(|t| !t.is_empty());
    let mut changes = Vec::new();
    while let Some(status) = tokens.next() {
        let letter = status.trim().chars().next().unwrap_or('M');
        if letter == 'R' || letter == 'C' {
            let (Some(old), Some(new)) = (tokens.next(), tokens.next()) else { break };
            changes.push(HistoryFileChange {
                path: new.to_string(),
                old_path: Some(old.to_string()),
                status: letter.to_string(),
            });
        } else {
            let Some(path) = tokens.next() else { break };
            changes.push(HistoryFileChange {
                path: path.to_string(),
                old_path: None,
                status: letter.to_string(),
            });
        }
    }
    changes
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    /// 测试用临时目录,drop 时清理(断言失败也不会遗留)。
    struct TestDir(PathBuf);

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn unique_dir(tag: &str) -> TestDir {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "codelite_hist_{}_{}_{}_{}",
            tag,
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        TestDir(dir)
    }

    fn git_env(dir: &Path, args: &[&str], envs: &[(&str, &str)]) -> String {
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(dir).args(args);
        for (k, v) in envs {
            cmd.env(k, v);
        }
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        git_env(dir, args, &[])
    }

    fn configure(dir: &Path) {
        for (k, v) in [
            ("user.name", "CodeLite Tester"),
            ("user.email", "tester@codelite.dev"),
            ("commit.gpgsign", "false"),
            ("tag.gpgsign", "false"),
            ("core.autocrlf", "false"),
        ] {
            git(dir, &["config", k, v]);
        }
    }

    fn init_repo() -> (TestDir, GitEngine) {
        let d = unique_dir("repo");
        git(&d.0, &["init", "-q", "-b", "main"]);
        configure(&d.0);
        let engine = GitEngine::new(&d.0);
        (d, engine)
    }

    /// 裸仓库作为远程,并把本地 main 推上去建立上游。
    fn add_bare_remote(dir: &Path) -> TestDir {
        let bare = unique_dir("remote");
        git(&bare.0, &["init", "-q", "--bare", "-b", "main"]);
        git(dir, &["remote", "add", "origin", bare.0.to_str().unwrap()]);
        git(dir, &["push", "-q", "-u", "origin", "main"]);
        bare
    }

    fn write(dir: &Path, path: &str, content: &str) {
        let p = dir.join(path);
        if let Some(parent) = p.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(p, content).unwrap();
    }

    fn read(dir: &Path, path: &str) -> String {
        fs::read_to_string(dir.join(path)).unwrap()
    }

    fn commit_file(dir: &Path, path: &str, content: &str, message: &str) -> String {
        write(dir, path, content);
        git(dir, &["add", "--", path]);
        git(dir, &["commit", "-q", "-m", message]);
        git(dir, &["rev-parse", "HEAD"])
    }

    fn commit_file_at(dir: &Path, path: &str, content: &str, message: &str, ts: i64) -> String {
        write(dir, path, content);
        git(dir, &["add", "--", path]);
        let date = format!("@{} +0000", ts);
        git_env(
            dir,
            &["commit", "-q", "-m", message],
            &[("GIT_AUTHOR_DATE", &date), ("GIT_COMMITTER_DATE", &date)],
        );
        git(dir, &["rev-parse", "HEAD"])
    }

    fn head(dir: &Path) -> String {
        git(dir, &["rev-parse", "HEAD"])
    }

    /// HEAD 历史的提交标题,最新在前。
    fn subjects(dir: &Path) -> Vec<String> {
        git(dir, &["log", "--format=%s", "HEAD"]).lines().map(str::to_string).collect()
    }

    fn is_clean(dir: &Path) -> bool {
        git(dir, &["status", "--porcelain"]).is_empty()
    }

    fn all_log(engine: &GitEngine) -> LogResult {
        engine.history_log(&LogQuery::default()).unwrap()
    }

    fn query(f: impl FnOnce(&mut LogQuery)) -> LogQuery {
        let mut q = LogQuery::default();
        f(&mut q);
        q
    }

    fn r(name: &str, kind: RefKind) -> GitRef {
        GitRef { name: name.into(), kind }
    }

    fn assert_no_operation(engine: &GitEngine) {
        assert!(engine.ensure_idle().is_ok(), "repo was left mid-operation");
    }

    // ---- 纯解析 ----------------------------------------------------------

    #[test]
    fn test_parse_refs_classification() {
        let refs = parse_refs(
            "HEAD -> refs/heads/main, tag: refs/tags/v1.0, refs/remotes/origin/dev, refs/remotes/origin/HEAD, refs/stash",
        );
        assert_eq!(
            refs,
            vec![
                r("HEAD", RefKind::Head),
                r("main", RefKind::Local),
                r("v1.0", RefKind::Tag),
                r("origin/dev", RefKind::Remote),
            ]
        );
        assert_eq!(parse_refs("HEAD, refs/heads/feat/x"), vec![r("HEAD", RefKind::Head), r("feat/x", RefKind::Local)]);
        assert!(parse_refs("").is_empty());
    }

    #[test]
    fn test_parse_name_status_and_escape() {
        let changes = parse_name_status_z("M\0a b.txt\0R087\0old.rs\0new.rs\0C100\0x\0y\0D\0gone\0");
        assert_eq!(changes.len(), 4);
        assert_eq!(changes[0], HistoryFileChange { path: "a b.txt".into(), old_path: None, status: "M".into() });
        assert_eq!(changes[1], HistoryFileChange { path: "new.rs".into(), old_path: Some("old.rs".into()), status: "R".into() });
        assert_eq!(changes[2].status, "C");
        assert_eq!(changes[3].status, "D");
        assert_eq!(ere_escape("a.b(c)*"), "a\\.b\\(c\\)\\*");
        assert!(is_hex_prefix("abcd") && is_hex_prefix("0123456789abcdef"));
        assert!(!is_hex_prefix("abc") && !is_hex_prefix("xyz12") && !is_hex_prefix(&"a".repeat(41)));
        assert!(ResetMode::parse("keep").is_err());
    }

    // ---- 读操作 ----------------------------------------------------------

    #[test]
    fn test_log_parses_commits_refs_and_special_subjects() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "a.txt", "1\n", "first");
        let weird = "修复\t问题 ✓ — émoji 🎉 | pipes; \"quotes\"";
        let c2 = commit_file(dir, "b.txt", "2\n", weird);
        git(dir, &["tag", "-a", "v1.0", "-m", "release", &c2]);
        git(dir, &["tag", "lw", &c1]);
        git(dir, &["branch", "dev", &c1]);

        let res = all_log(&engine);
        assert_eq!(res.head, c2);
        assert!(!res.has_more);
        assert_eq!(res.commits.len(), 2);
        let top = &res.commits[0];
        assert_eq!(top.hash, c2);
        assert_eq!(top.subject, weird);
        assert_eq!(top.parents, vec![c1.clone()]);
        assert_eq!(top.author, "CodeLite Tester");
        assert_eq!(top.email, "tester@codelite.dev");
        assert!(top.time > 0);
        assert_eq!(
            top.refs,
            vec![r("HEAD", RefKind::Head), r("main", RefKind::Local), r("v1.0", RefKind::Tag)]
        );
        let bottom = &res.commits[1];
        assert!(bottom.parents.is_empty());
        assert!(bottom.refs.contains(&r("lw", RefKind::Tag)));
        assert!(bottom.refs.contains(&r("dev", RefKind::Local)));

        // stash 不应出现在全量历史里
        write(dir, "a.txt", "dirty\n");
        git(dir, &["stash", "-q"]);
        assert_eq!(all_log(&engine).commits.len(), 2);

        // 游离 HEAD:HEAD 与 main 分开列出
        git(dir, &["checkout", "-q", "--detach", &c2]);
        let res = all_log(&engine);
        assert_eq!(
            res.commits[0].refs,
            vec![r("HEAD", RefKind::Head), r("v1.0", RefKind::Tag), r("main", RefKind::Local)]
        );
        let b = engine.branches().unwrap();
        assert!(b.detached);
        assert_eq!(b.current, None);
        assert_eq!(b.head, c2);
    }

    #[test]
    fn test_log_text_search_by_message_and_hash() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let alpha = commit_file(dir, "a", "1", "Add feature alpha");
        commit_file(dir, "b", "2", "Fix bug in parser");
        commit_file(dir, "c", "3", "fix typo (docs)");

        let hits = |q: LogQuery| -> Vec<String> {
            engine.history_log(&q).unwrap().commits.into_iter().map(|c| c.subject).collect()
        };
        assert_eq!(hits(query(|q| q.text = Some("fix".into()))).len(), 2);
        assert_eq!(
            hits(query(|q| {
                q.text = Some("fix".into());
                q.match_case = true;
            })),
            vec!["fix typo (docs)"]
        );
        // 非正则模式下特殊字符按字面匹配
        assert_eq!(hits(query(|q| q.text = Some("typo (docs".into()))), vec!["fix typo (docs)"]);
        assert!(hits(query(|q| q.text = Some("a.d".into()))).is_empty());
        assert_eq!(
            hits(query(|q| {
                q.text = Some("^Add .*alpha$".into());
                q.regex = true;
            })),
            vec!["Add feature alpha"]
        );
        // 非法正则返回错误而非 panic
        assert!(engine
            .history_log(&query(|q| {
                q.text = Some("(".into());
                q.regex = true;
            }))
            .is_err());

        // 按短哈希搜索:即使消息不匹配也要带出该提交,并排在最前
        let short = &alpha[..8];
        let res = engine.history_log(&query(|q| q.text = Some(short.into()))).unwrap();
        assert_eq!(res.commits.len(), 1);
        assert_eq!(res.commits[0].hash, alpha);
        // 翻页时不重复出现
        let res = engine
            .history_log(&query(|q| {
                q.text = Some(short.into());
                q.skip = Some(1);
            }))
            .unwrap();
        assert!(res.commits.iter().all(|c| c.hash != alpha));
    }

    #[test]
    fn test_log_filters_author_since_paths_branch_and_paging() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        commit_file_at(dir, "a.txt", "1", "old root", 1_600_000_000);
        write(dir, "dir/b.txt", "b");
        git(dir, &["add", "."]);
        git(dir, &["commit", "-q", "-m", "by alice", "--author", "Alice <alice@x.dev>"]);
        write(dir, "a.txt", "2");
        git(dir, &["add", "."]);
        git(dir, &["commit", "-q", "-m", "by alice smith", "--author", "Alice Smith <as@x.dev>"]);
        git(dir, &["switch", "-q", "-c", "side"]);
        let side = commit_file(dir, "side.txt", "s", "side work");
        git(dir, &["switch", "-q", "main"]);

        let subjects_of = |q: LogQuery| -> Vec<String> {
            engine.history_log(&q).unwrap().commits.into_iter().map(|c| c.subject).collect()
        };

        assert_eq!(subjects_of(query(|q| q.author = Some("Alice".into()))), vec!["by alice"]);
        assert_eq!(engine.history_authors().unwrap(), vec!["Alice", "Alice Smith", "CodeLite Tester"]);

        let recent = subjects_of(query(|q| q.since = Some(1_650_000_000)));
        assert_eq!(recent.len(), 3);
        assert!(!recent.contains(&"old root".to_string()));

        assert_eq!(subjects_of(query(|q| q.paths = vec!["dir".into()])), vec!["by alice"]);
        let only_a = engine.history_log(&query(|q| q.paths = vec!["a.txt".into()])).unwrap();
        assert_eq!(only_a.commits.len(), 2);
        // 路径过滤时父提交被改写,图谱保持连通
        assert_eq!(only_a.commits[0].parents, vec![only_a.commits[1].hash.clone()]);

        assert_eq!(all_log(&engine).commits.len(), 4);
        let main_only = subjects_of(query(|q| q.branch = Some("main".into())));
        assert_eq!(main_only.len(), 3);
        let side_only = engine.history_log(&query(|q| q.branch = Some("side".into()))).unwrap();
        assert_eq!(side_only.commits[0].hash, side);
        assert!(engine.history_log(&query(|q| q.branch = Some("--all".into()))).is_err());

        let page1 = engine.history_log(&query(|q| q.limit = Some(3))).unwrap();
        assert_eq!(page1.commits.len(), 3);
        assert!(page1.has_more);
        let page2 = engine
            .history_log(&query(|q| {
                q.limit = Some(3);
                q.skip = Some(3);
            }))
            .unwrap();
        assert_eq!(page2.commits.len(), 1);
        assert!(!page2.has_more);
        assert_eq!(page2.commits[0].subject, "old root");
    }

    #[test]
    fn test_empty_repo_is_not_an_error() {
        let (_d, engine) = init_repo();
        let res = all_log(&engine);
        assert!(res.commits.is_empty());
        assert_eq!(res.head, "");
        let res = engine.history_log(&query(|q| q.branch = Some("HEAD".into()))).unwrap();
        assert!(res.commits.is_empty());
        let b = engine.branches().unwrap();
        assert_eq!(b.current.as_deref(), Some("main"));
        assert_eq!(b.head, "");
        assert!(!b.detached);
        assert!(b.local.is_empty());
        assert!(engine.history_authors().unwrap().is_empty());
        assert!(engine.undo_commit().is_err());
    }

    #[test]
    fn test_branches_with_upstream_and_pushed_state() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "a", "1", "one");
        let _bare = add_bare_remote(dir);
        git(dir, &["switch", "-q", "-c", "dev"]);
        commit_file(dir, "b", "2", "two");
        git(dir, &["push", "-q", "-u", "origin", "dev"]);
        git(dir, &["switch", "-q", "main"]);
        git(dir, &["fetch", "-q", "origin"]);
        git(dir, &["remote", "set-head", "origin", "main"]);
        git(dir, &["tag", "-a", "v1", "-m", "annotated", &c1]);
        let local_only = commit_file(dir, "c", "3", "three");

        let b = engine.branches().unwrap();
        assert_eq!(b.current.as_deref(), Some("main"));
        assert_eq!(b.head, local_only);
        assert!(!b.detached);
        let main = b.local.iter().find(|l| l.name == "main").unwrap();
        assert!(main.current);
        assert_eq!(main.upstream.as_deref(), Some("origin/main"));
        let dev = b.local.iter().find(|l| l.name == "dev").unwrap();
        assert!(!dev.current);
        assert_eq!(dev.upstream.as_deref(), Some("origin/dev"));
        let names: Vec<&str> = b.remote.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["origin/dev", "origin/main"]);
        let odev = &b.remote[0];
        assert_eq!((odev.remote.as_str(), odev.short.as_str()), ("origin", "dev"));
        assert_eq!(b.tags, vec![TagInfo { name: "v1".into(), hash: c1.clone() }]);

        let log = all_log(&engine);
        let root = log.commits.iter().find(|c| c.hash == c1).unwrap();
        assert!(root.refs.contains(&r("origin/main", RefKind::Remote)));
        assert!(root.refs.iter().all(|x| x.name != "origin/HEAD"));

        assert!(engine.is_pushed(&c1).unwrap());
        assert!(!engine.is_pushed(&local_only).unwrap());
        let details = engine.commit_details(&c1).unwrap();
        assert!(details.pushed);
        assert!(!details.is_head);
    }

    #[test]
    fn test_commit_details_root_and_rename() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let body = "line one\nline two\nline three\nline four\n";
        let root = commit_file(dir, "a.txt", body, "root commit");
        commit_file(dir, "b.txt", "bee\n", "add b");
        git(dir, &["mv", "a.txt", "c.txt"]);
        write(dir, "b.txt", "bee\nmore\n");
        git(dir, &["add", "."]);
        git(dir, &["commit", "-q", "-m", "Rename a to c\n\nBody paragraph.\n"]);
        let top = head(dir);

        let rd = engine.commit_details(&root[..10]).unwrap();
        assert_eq!(rd.hash, root);
        assert!(rd.parents.is_empty());
        assert_eq!(rd.message, "root commit");
        assert_eq!(rd.files, vec![HistoryFileChange { path: "a.txt".into(), old_path: None, status: "A".into() }]);
        assert!(!rd.is_head && !rd.pushed);
        let root_diff = engine.commit_file_diff(&root, "a.txt", None).unwrap();
        assert!(root_diff.contains("+line one"));

        let td = engine.commit_details(&top).unwrap();
        assert!(td.is_head);
        assert_eq!(td.message, "Rename a to c\n\nBody paragraph.");
        assert_eq!(td.committer, "CodeLite Tester");
        assert!(td.author_time > 0 && td.commit_time > 0);
        assert_eq!(td.refs, vec![r("HEAD", RefKind::Head), r("main", RefKind::Local)]);
        assert!(td.files.contains(&HistoryFileChange {
            path: "c.txt".into(),
            old_path: Some("a.txt".into()),
            status: "R".into()
        }));
        assert!(td.files.contains(&HistoryFileChange { path: "b.txt".into(), old_path: None, status: "M".into() }));
        let rename_diff = engine.commit_file_diff(&top, "c.txt", Some("a.txt")).unwrap();
        assert!(rename_diff.contains("rename from a.txt"));
        let mod_diff = engine.commit_file_diff(&top, "b.txt", None).unwrap();
        assert!(mod_diff.contains("+more") && mod_diff.contains("--- a/b.txt"));

        assert!(engine.commit_details("deadbeefdeadbeef").is_err());
        assert!(engine.commit_details("").is_err());
    }

    #[test]
    fn test_tree_file_patch_and_compare_local() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        write(dir, "a.txt", "alpha\n");
        write(dir, "dir/b.txt", "beta\n");
        fs::write(dir.join("bin.dat"), [0u8, 1, 2, 3, 0, 255]).unwrap();
        git(dir, &["add", "."]);
        git(dir, &["commit", "-q", "-m", "snapshot"]);
        let c = head(dir);

        let mut paths = engine.tree_at(&c).unwrap();
        paths.sort();
        assert_eq!(paths, vec!["a.txt", "bin.dat", "dir/b.txt"]);

        assert_eq!(
            engine.file_at(&c, "dir/b.txt").unwrap(),
            FileAtRevision { content: "beta\n".into(), binary: false }
        );
        assert_eq!(engine.file_at(&c, "bin.dat").unwrap(), FileAtRevision { content: String::new(), binary: true });
        assert!(engine.file_at(&c, "missing.txt").is_err());

        let patch = engine.create_patch(&c).unwrap();
        assert!(patch.contains("Subject: [PATCH] snapshot"));
        assert!(patch.contains("+alpha"));

        write(dir, "a.txt", "alpha\nnew line\n");
        fs::remove_file(dir.join("dir/b.txt")).unwrap();
        let mut files = engine.compare_with_local(&c).unwrap();
        files.sort_by(|a, b| a.path.cmp(&b.path));
        assert_eq!(
            files,
            vec![
                HistoryFileChange { path: "a.txt".into(), old_path: None, status: "M".into() },
                HistoryFileChange { path: "dir/b.txt".into(), old_path: None, status: "D".into() },
            ]
        );
        let diff = engine.compare_with_local_diff(&c, "a.txt").unwrap();
        assert!(diff.contains("+new line"));
    }

    // ---- 写操作 ----------------------------------------------------------

    #[test]
    fn test_cherry_pick_success_and_conflict_aborts() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        commit_file(dir, "f.txt", "base\n", "base");
        git(dir, &["switch", "-q", "-c", "feature"]);
        let add_g = commit_file(dir, "g.txt", "gee\n", "add g");
        let change_f = commit_file(dir, "f.txt", "feature\n", "feature edits f");
        git(dir, &["switch", "-q", "main"]);
        commit_file(dir, "f.txt", "main\n", "main edits f");

        engine.cherry_pick(&add_g).unwrap();
        assert_eq!(read(dir, "g.txt"), "gee\n");
        assert_eq!(subjects(dir)[0], "add g");

        let before = head(dir);
        let err = engine.cherry_pick(&change_f).unwrap_err().to_string();
        assert!(err.starts_with("Cherry-pick 冲突,已中止"), "{}", err);
        assert_eq!(head(dir), before);
        assert!(is_clean(dir));
        assert!(!engine.git_path_exists("CHERRY_PICK_HEAD"));
        assert_no_operation(&engine);
        assert_eq!(read(dir, "f.txt"), "main\n");
    }

    #[test]
    fn test_revert_and_conflict_aborts() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        commit_file(dir, "f.txt", "one\n", "one");
        let add = commit_file(dir, "g.txt", "gee\n", "add g");
        engine.revert_commit(&add).unwrap();
        assert!(!dir.join("g.txt").exists());
        assert!(subjects(dir)[0].starts_with("Revert \"add g\""));

        let edit = commit_file(dir, "f.txt", "two\n", "two");
        commit_file(dir, "f.txt", "three\n", "three");
        let before = head(dir);
        let err = engine.revert_commit(&edit).unwrap_err().to_string();
        assert!(err.starts_with("Revert 冲突,已中止"), "{}", err);
        assert_eq!(head(dir), before);
        assert!(is_clean(dir));
        assert!(!engine.git_path_exists("REVERT_HEAD"));
    }

    #[test]
    fn test_reset_modes_and_undo_commit() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "f.txt", "1\n", "one");
        commit_file(dir, "f.txt", "2\n", "two");
        let c3 = commit_file(dir, "f.txt", "3\n", "three");

        engine.reset_to(&c1, ResetMode::Soft).unwrap();
        assert_eq!(head(dir), c1);
        assert!(!git(dir, &["diff", "--cached"]).is_empty());

        engine.reset_to(&c3, ResetMode::Hard).unwrap();
        assert_eq!(head(dir), c3);
        assert!(is_clean(dir));

        engine.reset_to(&c1, ResetMode::Mixed).unwrap();
        assert!(git(dir, &["diff", "--cached"]).is_empty());
        assert!(!git(dir, &["diff"]).is_empty());
        engine.reset_to(&c3, ResetMode::Hard).unwrap();

        engine.undo_commit().unwrap();
        assert_eq!(subjects(dir), vec!["two", "one"]);
        assert!(git(dir, &["diff", "--cached"]).contains("+3"));
        assert_eq!(read(dir, "f.txt"), "3\n");

        engine.reset_to(&c1, ResetMode::Hard).unwrap();
        let err = engine.undo_commit().unwrap_err().to_string();
        assert!(err.contains("没有父提交"));
    }

    #[test]
    fn test_checkout_new_branch_and_tag() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "a", "1", "one");
        let c2 = commit_file(dir, "b", "2", "two");

        engine.new_branch("feat/x", &c1, false).unwrap();
        assert_eq!(git(dir, &["rev-parse", "feat/x"]), c1);
        assert_eq!(engine.branches().unwrap().current.as_deref(), Some("main"));
        engine.new_branch("co", &c1, true).unwrap();
        assert_eq!(engine.branches().unwrap().current.as_deref(), Some("co"));
        assert_eq!(head(dir), c1);
        assert!(engine.new_branch("bad..name", &c1, false).is_err());
        assert!(engine.new_branch("-x", &c1, false).is_err());
        assert!(engine.new_branch("", &c1, false).is_err());

        engine.new_tag("v1", &c2, Some("release one")).unwrap();
        engine.new_tag("v2", &c2, None).unwrap();
        engine.new_tag("v3", &c2, Some("  ")).unwrap();
        assert_eq!(git(dir, &["cat-file", "-t", "v1"]), "tag");
        assert_eq!(git(dir, &["cat-file", "-t", "v2"]), "commit");
        assert_eq!(git(dir, &["cat-file", "-t", "v3"]), "commit");
        assert!(engine.branches().unwrap().tags.iter().all(|t| t.hash == c2));
        assert!(engine.new_tag("bad tag", &c2, None).is_err());

        engine.checkout_revision(&c2).unwrap();
        let b = engine.branches().unwrap();
        assert!(b.detached);
        assert_eq!(b.head, c2);
    }

    #[test]
    fn test_reword_head_and_non_head() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        commit_file(dir, "a", "1", "one");
        let c2 = commit_file(dir, "b", "2", "two");
        commit_file(dir, "c", "3", "three");

        // HEAD:只改消息,暂存区的修改不能被带进提交
        write(dir, "staged.txt", "staged\n");
        git(dir, &["add", "staged.txt"]);
        engine.reword("HEAD", "three, reworded\n\nwith body").unwrap();
        assert_eq!(subjects(dir), vec!["three, reworded", "two", "one"]);
        assert_eq!(git(dir, &["log", "-1", "--format=%B"]), "three, reworded\n\nwith body");
        assert!(!git(dir, &["show", "--name-only", "--format=", "HEAD"]).contains("staged.txt"));
        assert!(git(dir, &["diff", "--cached", "--name-only"]).contains("staged.txt"));

        // 非 HEAD:脚本化 rebase,本地修改经 autostash 保留
        engine.reword(&c2, "two, reworded").unwrap();
        assert_eq!(subjects(dir), vec!["three, reworded", "two, reworded", "one"]);
        assert_eq!(git(dir, &["log", "-1", "--format=%B"]), "three, reworded\n\nwith body");
        assert_eq!(read(dir, "staged.txt"), "staged\n");
        assert_no_operation(&engine);

        assert!(engine.reword("HEAD", "   ").is_err());
    }

    #[test]
    fn test_drop_commit() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        commit_file(dir, "f1", "1", "one");
        let c2 = commit_file(dir, "f2", "2", "two");
        commit_file(dir, "f3", "3", "three");
        engine.drop_commit(&c2).unwrap();
        assert_eq!(subjects(dir), vec!["three", "one"]);
        assert!(!dir.join("f2").exists() && dir.join("f3").exists());
        engine.drop_commit("HEAD").unwrap();
        assert_eq!(subjects(dir), vec!["one"]);
        assert_no_operation(&engine);
    }

    #[test]
    fn test_fixup_and_squash_into() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "a.txt", "one\n", "A");
        commit_file(dir, "b.txt", "bee\n", "B");
        commit_file(dir, "c.txt", "see\n", "C");

        assert_eq!(engine.fixup_into(&c1).unwrap_err().to_string(), "没有已暂存的修改");

        // 根提交 fixup(--root),同时有一个未暂存的修改要经 autostash 保留
        write(dir, "a.txt", "one\ntwo\n");
        git(dir, &["add", "a.txt"]);
        write(dir, "c.txt", "see\nunstaged\n");
        engine.fixup_into(&c1).unwrap();
        assert_eq!(subjects(dir), vec!["C", "B", "A"]);
        assert_eq!(git(dir, &["show", "HEAD~2:a.txt"]), "one\ntwo");
        assert_eq!(read(dir, "c.txt"), "see\nunstaged\n");
        assert!(git(dir, &["diff", "--cached"]).is_empty());
        git(dir, &["checkout", "--", "c.txt"]);

        // squash_into:并入并替换目标提交消息
        let b = git(dir, &["rev-parse", "HEAD~1"]);
        write(dir, "b.txt", "bee\nbuzz\n");
        git(dir, &["add", "b.txt"]);
        engine.squash_into(&b, "B, now with buzz\n\ndetails").unwrap();
        assert_eq!(subjects(dir), vec!["C", "B, now with buzz", "A"]);
        assert_eq!(git(dir, &["log", "-1", "--format=%B", "HEAD~1"]), "B, now with buzz\n\ndetails");
        assert_eq!(git(dir, &["show", "HEAD~1:b.txt"]), "bee\nbuzz");
        assert!(is_clean(dir));
        assert_no_operation(&engine);

        write(dir, "b.txt", "x\n");
        git(dir, &["add", "b.txt"]);
        assert!(engine.squash_into("HEAD", "").is_err());
    }

    #[test]
    fn test_fixup_conflict_restores_staged_changes() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "f.txt", "a\n", "one");
        commit_file(dir, "f.txt", "b\n", "two");
        write(dir, "f.txt", "c\n");
        git(dir, &["add", "f.txt"]);
        let before = head(dir);
        let err = engine.fixup_into(&c1).unwrap_err().to_string();
        assert!(err.starts_with("Rebase 失败,已中止"), "{}", err);
        assert_eq!(head(dir), before);
        assert!(git(dir, &["diff", "--cached"]).contains("+c"));
        assert_no_operation(&engine);
    }

    #[test]
    fn test_rebase_plan_and_interactive() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c: Vec<String> = (1..=5)
            .map(|i| commit_file(dir, &format!("f{}", i), &format!("{}\n", i), &format!("commit {}", i)))
            .collect();

        let plan = engine.rebase_plan(&c[1]).unwrap();
        assert_eq!(plan.base.as_deref(), Some(c[0].as_str()));
        let hashes: Vec<&str> = plan.entries.iter().map(|e| e.hash.as_str()).collect();
        assert_eq!(hashes, vec![c[1].as_str(), c[2].as_str(), c[3].as_str(), c[4].as_str()]);
        assert_eq!(plan.entries[0].subject, "commit 2");
        assert_eq!(plan.entries[0].message, "commit 2");
        assert_eq!(engine.rebase_plan(&c[0]).unwrap().base, None);

        let e = |h: &str, action: RebaseAction, m: Option<&str>| RebaseEntry {
            hash: h.to_string(),
            action,
            message: m.map(str::to_string),
        };

        // 首条为 squash / 计划与历史不一致 → 拒绝
        assert!(engine
            .rebase_interactive(Some(&c[0]), &[e(&c[1], RebaseAction::Squash, None)])
            .is_err());
        let err = engine
            .rebase_interactive(Some(&c[0]), &[e(&c[1], RebaseAction::Pick, None)])
            .unwrap_err()
            .to_string();
        assert!(err.contains("不一致"));
        assert_eq!(head(dir), c[4]);

        // 重排 + reword + squash(带消息)+ drop 一次完成
        engine
            .rebase_interactive(
                Some(&c[0]),
                &[
                    e(&c[2], RebaseAction::Pick, None),
                    e(&c[1], RebaseAction::Reword, Some("two reworded")),
                    e(&c[4], RebaseAction::Squash, Some("two and five")),
                    e(&c[3], RebaseAction::Drop, None),
                ],
            )
            .unwrap();
        assert_eq!(subjects(dir), vec!["two and five", "commit 3", "commit 1"]);
        assert!(dir.join("f2").exists() && dir.join("f5").exists() && !dir.join("f4").exists());
        assert_eq!(git(dir, &["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]), "f2\nf5");
        assert_no_operation(&engine);

        // 从根开始;squash 不带消息时保留 git 默认的合并消息,fixup 丢弃消息
        let plan = engine.rebase_plan("HEAD~2").unwrap();
        assert_eq!(plan.base, None);
        let p: Vec<String> = plan.entries.iter().map(|x| x.hash.clone()).collect();
        engine
            .rebase_interactive(
                None,
                &[
                    e(&p[0], RebaseAction::Pick, None),
                    e(&p[1], RebaseAction::Squash, None),
                    e(&p[2], RebaseAction::Fixup, None),
                ],
            )
            .unwrap();
        assert_eq!(subjects(dir).len(), 1);
        let body = git(dir, &["log", "-1", "--format=%B"]);
        assert!(body.contains("commit 1") && body.contains("commit 3") && !body.contains("two and five"));
        assert!(dir.join("f5").exists());
    }

    #[test]
    fn test_rebase_rejects_merges_and_foreign_commits() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "a", "1", "one");
        git(dir, &["switch", "-q", "-c", "side"]);
        let side = commit_file(dir, "s", "s", "side");
        git(dir, &["switch", "-q", "main"]);
        commit_file(dir, "b", "2", "two");
        git(dir, &["merge", "-q", "--no-ff", "-m", "merge side", "side"]);

        let err = engine.rebase_plan(&c1).unwrap_err().to_string();
        assert_eq!(err, "范围内包含合并提交,不支持交互式 rebase");
        assert!(engine.reword(&c1, "x").is_err());
        assert!(engine.drop_commit(&c1).is_err());

        git(dir, &["switch", "-q", "side"]);
        commit_file(dir, "t", "t", "side 2");
        git(dir, &["switch", "-q", "main"]);
        let foreign = git(dir, &["rev-parse", "side"]);
        assert!(engine.rebase_plan(&foreign).unwrap_err().to_string().contains("不在当前分支"));
        assert!(engine.rebase_plan(&side).is_err());
    }

    #[test]
    fn test_interactive_rebase_conflict_aborts() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        let c1 = commit_file(dir, "f.txt", "a\n", "one");
        let c2 = commit_file(dir, "f.txt", "b\n", "two");
        let c3 = commit_file(dir, "f.txt", "c\n", "three");
        write(dir, "other.txt", "local\n");

        let entries = [
            RebaseEntry { hash: c3.clone(), action: RebaseAction::Pick, message: None },
            RebaseEntry { hash: c2.clone(), action: RebaseAction::Pick, message: None },
        ];
        let err = engine.rebase_interactive(Some(&c1), &entries).unwrap_err().to_string();
        assert!(err.starts_with("Rebase 失败,已中止"), "{}", err);
        assert_eq!(head(dir), c3);
        assert_eq!(subjects(dir), vec!["three", "two", "one"]);
        assert_eq!(read(dir, "f.txt"), "c\n");
        assert_eq!(read(dir, "other.txt"), "local\n");
        assert_no_operation(&engine);
    }

    #[test]
    fn test_push_up_to() {
        let (d, engine) = init_repo();
        let dir = &d.0;
        commit_file(dir, "a", "1", "one");
        let bare = add_bare_remote(dir);
        let c2 = commit_file(dir, "b", "2", "two");
        let c3 = commit_file(dir, "c", "3", "three");

        let target = engine.push_up_to(&c2).unwrap();
        assert_eq!(target, PushTarget { remote: "origin".into(), branch: "main".into() });
        assert_eq!(git(&bare.0, &["rev-parse", "main"]), c2);
        git(dir, &["fetch", "-q", "origin"]);
        assert!(engine.is_pushed(&c2).unwrap());
        assert!(!engine.is_pushed(&c3).unwrap());

        // 无上游:默认 origin + 当前分支名
        git(dir, &["switch", "-q", "-c", "topic"]);
        let t1 = commit_file(dir, "t", "t", "topic work");
        let target = engine.push_up_to(&t1).unwrap();
        assert_eq!(target, PushTarget { remote: "origin".into(), branch: "topic".into() });
        assert_eq!(git(&bare.0, &["rev-parse", "topic"]), t1);

        // 不在当前分支历史上 / 游离 HEAD → 拒绝
        git(dir, &["switch", "-q", "main"]);
        assert!(engine.push_up_to(&t1).unwrap_err().to_string().contains("不在当前分支"));
        git(dir, &["checkout", "-q", "--detach", "HEAD"]);
        assert!(engine.push_up_to(&c2).unwrap_err().to_string().contains("游离"));
    }

    #[test]
    fn log_returns_readable_commits_when_history_is_corrupt() {
        let (d, engine) = init_repo();
        let oldest = commit_file_at(&d.0, "a.txt", "a", "first", 1_700_000_000);
        commit_file_at(&d.0, "b.txt", "b", "second", 1_700_000_100);
        commit_file_at(&d.0, "c.txt", "c", "third", 1_700_000_200);

        // 模拟磁盘损坏:最老那个提交的 loose 对象变成无法解压的垃圾
        let obj = d.0.join(".git/objects").join(&oldest[..2]).join(&oldest[2..]);
        let mut perms = fs::metadata(&obj).unwrap().permissions();
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        fs::set_permissions(&obj, perms).unwrap();
        fs::write(&obj, b"not zlib at all").unwrap();

        let res = engine.history_log(&LogQuery::default()).unwrap();
        let got: Vec<&str> = res.commits.iter().map(|c| c.subject.as_str()).collect();
        // git 输出一个提交前要先解析它的父提交,所以紧挨着损坏点的 "second" 也出不来
        assert_eq!(got, ["third"]);
        assert!(!res.has_more);
        let warning = res.warning.expect("partial log must carry git's error");
        assert!(warning.contains(&oldest[..7]) || warning.contains("corrupt"), "{warning}");

        // 一条都读不到时仍然是错误
        let broken = query(|q| q.branch = Some(oldest.clone()));
        assert!(engine.history_log(&broken).is_err());
    }
}
