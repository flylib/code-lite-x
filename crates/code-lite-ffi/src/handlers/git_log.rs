//! `codelite_git_call` 的方法分派:Git Log 工具窗口的全部读写操作。
//! 返回值约定:成功 `{"status":"ok", ...结果字段平铺}`,失败 `{"status":"error","error":"..."}`。

use code_lite_fs::git::{GitEngine, GitError};
use code_lite_fs::git_history::{LogQuery, RebaseEntry, ResetMode};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::Path;

#[derive(Deserialize)]
struct HashParams {
    hash: String,
}

#[derive(Deserialize)]
struct HashPathParams {
    hash: String,
    path: String,
    #[serde(default)]
    old_path: Option<String>,
}

#[derive(Deserialize)]
struct ResetParams {
    hash: String,
    mode: String,
}

#[derive(Deserialize)]
struct NewBranchParams {
    name: String,
    hash: String,
    #[serde(default)]
    checkout: Option<bool>,
}

#[derive(Deserialize)]
struct NewTagParams {
    name: String,
    hash: String,
    #[serde(default)]
    message: Option<String>,
}

#[derive(Deserialize)]
struct MessageParams {
    hash: String,
    message: String,
}

#[derive(Deserialize)]
struct RebaseParams {
    #[serde(default)]
    base: Option<String>,
    entries: Vec<RebaseEntry>,
}

/// 完整调用:解析参数 JSON → 分派 → 包装 status。永不返回 Err,错误编码进 JSON。
pub fn call(root: &Path, method: &str, params_json: &str) -> Value {
    let params = if params_json.trim().is_empty() {
        Value::Object(Map::new())
    } else {
        match serde_json::from_str::<Value>(params_json) {
            Ok(Value::Null) => Value::Object(Map::new()),
            Ok(v) => v,
            Err(e) => return error(format!("参数不是合法的 JSON: {}", e)),
        }
    };
    match dispatch(root, method, params) {
        Ok(Value::Object(mut obj)) => {
            obj.insert("status".into(), Value::from("ok"));
            Value::Object(obj)
        }
        Ok(_) => error("内部错误:结果不是 JSON 对象".into()),
        Err(e) => error(e),
    }
}

fn error(msg: String) -> Value {
    json!({ "status": "error", "error": msg })
}

fn parse<T: DeserializeOwned>(params: Value) -> Result<T, String> {
    serde_json::from_value(params).map_err(|e| format!("参数无效: {}", e))
}

fn ser<T: Serialize>(r: Result<T, GitError>) -> Result<Value, String> {
    let v = r.map_err(|e| e.to_string())?;
    serde_json::to_value(v).map_err(|e| e.to_string())
}

fn done(r: Result<(), GitError>) -> Result<Value, String> {
    r.map(|_| json!({})).map_err(|e| e.to_string())
}

fn field<T: Serialize>(key: &str, r: Result<T, GitError>) -> Result<Value, String> {
    let v = ser(r)?;
    let mut obj = Map::new();
    obj.insert(key.into(), v);
    Ok(Value::Object(obj))
}

pub fn dispatch(root: &Path, method: &str, params: Value) -> Result<Value, String> {
    let git = GitEngine::new(root);
    match method {
        "git.branches" => ser(git.branches()),
        "git.log" => {
            let q: LogQuery = parse(params)?;
            ser(git.history_log(&q))
        }
        "git.authors" => field("authors", git.history_authors()),
        "git.commit_details" => {
            let p: HashParams = parse(params)?;
            ser(git.commit_details(&p.hash))
        }
        "git.commit_file_diff" => {
            let p: HashPathParams = parse(params)?;
            field("diff", git.commit_file_diff(&p.hash, &p.path, p.old_path.as_deref()))
        }
        "git.compare_local" => {
            let p: HashParams = parse(params)?;
            field("files", git.compare_with_local(&p.hash))
        }
        "git.compare_local_diff" => {
            let p: HashPathParams = parse(params)?;
            field("diff", git.compare_with_local_diff(&p.hash, &p.path))
        }
        "git.tree_at" => {
            let p: HashParams = parse(params)?;
            field("paths", git.tree_at(&p.hash))
        }
        "git.file_at" => {
            let p: HashPathParams = parse(params)?;
            ser(git.file_at(&p.hash, &p.path))
        }
        "git.create_patch" => {
            let p: HashParams = parse(params)?;
            field("patch", git.create_patch(&p.hash))
        }
        "git.cherry_pick" => {
            let p: HashParams = parse(params)?;
            done(git.cherry_pick(&p.hash))
        }
        "git.checkout_revision" => {
            let p: HashParams = parse(params)?;
            done(git.checkout_revision(&p.hash))
        }
        "git.revert" => {
            let p: HashParams = parse(params)?;
            done(git.revert_commit(&p.hash))
        }
        "git.reset" => {
            let p: ResetParams = parse(params)?;
            let mode = ResetMode::parse(&p.mode).map_err(|e| e.to_string())?;
            done(git.reset_to(&p.hash, mode))
        }
        "git.undo_commit" => done(git.undo_commit()),
        "git.new_branch" => {
            let p: NewBranchParams = parse(params)?;
            done(git.new_branch(&p.name, &p.hash, p.checkout.unwrap_or(false)))
        }
        "git.new_tag" => {
            let p: NewTagParams = parse(params)?;
            done(git.new_tag(&p.name, &p.hash, p.message.as_deref()))
        }
        "git.reword" => {
            let p: MessageParams = parse(params)?;
            done(git.reword(&p.hash, &p.message))
        }
        "git.fixup" => {
            let p: HashParams = parse(params)?;
            done(git.fixup_into(&p.hash))
        }
        "git.squash_into" => {
            let p: MessageParams = parse(params)?;
            done(git.squash_into(&p.hash, &p.message))
        }
        "git.drop" => {
            let p: HashParams = parse(params)?;
            done(git.drop_commit(&p.hash))
        }
        "git.rebase_plan" => {
            let p: HashParams = parse(params)?;
            ser(git.rebase_plan(&p.hash))
        }
        "git.rebase_interactive" => {
            let p: RebaseParams = parse(params)?;
            done(git.rebase_interactive(p.base.as_deref(), &p.entries))
        }
        "git.push_up_to" => {
            let p: HashParams = parse(params)?;
            ser(git.push_up_to(&p.hash))
        }
        "git.is_pushed" => {
            let p: HashParams = parse(params)?;
            field("pushed", git.is_pushed(&p.hash))
        }
        other => Err(format!("未知的 git 方法: {}", other)),
    }
}
