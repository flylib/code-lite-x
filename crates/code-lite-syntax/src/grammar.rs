//! 各语言的语法包 + 着色规则(tree-sitter 的 highlights 查询),以及查询里的分类名 → 编辑器 token 种类。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use tree_sitter::{Language, Query};

/// token 种类,和 Dart 的 `TokenKind` 对应(编码见 `rust_syntax_native.dart`)。
/// `PLAIN` 也会涂:字符串插值 `${name}` 里的变量要盖掉外面字符串的颜色。
pub mod kind {
    pub const PLAIN: u8 = 0;
    pub const KEYWORD: u8 = 1;
    pub const TYPE: u8 = 2;
    pub const CONSTANT: u8 = 3;
    pub const BUILTIN: u8 = 4;
    pub const FUNCTION: u8 = 5;
    pub const STRING: u8 = 6;
    pub const NUMBER: u8 = 7;
    pub const COMMENT: u8 = 8;
    pub const DOC_COMMENT: u8 = 9;
    pub const ANNOTATION: u8 = 10;
    pub const FIELD: u8 = 11;
    pub const TAG: u8 = 12;
    pub const ATTRIBUTE: u8 = 13;
}

pub struct Grammar {
    pub language: Language,
    pub query: Query,
    /// 每个捕获名(按下标)对应的 token 种类;`None` = 不认这个分类,同一个节点让后面的规则决定。
    pub kinds: Vec<Option<u8>>,
    /// 同一个节点被几条规则匹配时谁说了算。各语言自带的规则写法不统一:Java / Python / Go 按「先写的生效」才对,
    /// Dart / JavaScript / TypeScript / Rust 按「后写的生效」才对(逐个语言拿样例对照过,见测试)。
    /// 我们自己补的规则(queries/*.scm)按各自的顺序放在前面或后面。
    pub last_wins: bool,
    /// 折叠范围的查询:`@fold` 跨多行的节点本身;`@fold.group` 连续的同类节点合成一段(import、单行注释);
    /// `@fold.header` 从前一个兄弟节点所在行起算(Python 的语句块从冒号那行开始)。
    pub folds: Query,
}

/// 支持的语法名(Dart 侧按语言 id / 扩展名选)。
pub const NAMES: &[&str] = &["java", "dart", "javascript", "typescript", "tsx", "python", "go", "rust"];

pub fn is_known(name: &str) -> bool {
    NAMES.contains(&name)
}

/// 编译好的语法(查询编译要几毫秒,每种语言只编一次,在后台线程里)。
pub fn get(name: &str) -> Option<Arc<Grammar>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Arc<Grammar>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    if let Some(g) = cache.lock().unwrap().get(name) {
        return Some(g.clone());
    }
    let g = Arc::new(build(name)?);
    cache.lock().unwrap().insert(name.to_string(), g.clone());
    Some(g)
}

fn build(name: &str) -> Option<Grammar> {
    let js = tree_sitter_javascript::HIGHLIGHT_QUERY;
    let jsx = tree_sitter_javascript::JSX_HIGHLIGHT_QUERY;
    let ts = tree_sitter_typescript::HIGHLIGHTS_QUERY;
    let ts_extra = include_str!("../queries/typescript.scm");
    let js_extra = include_str!("../queries/javascript.scm");
    let (language, sources, last_wins): (Language, Vec<&str>, bool) = match name {
        "java" => (tree_sitter_java::LANGUAGE.into(), vec![include_str!("../queries/java.scm"), tree_sitter_java::HIGHLIGHTS_QUERY], false),
        "dart" => (tree_sitter_dart::LANGUAGE.into(), vec![tree_sitter_dart::HIGHLIGHTS_QUERY, include_str!("../queries/dart.scm")], true),
        "javascript" => (tree_sitter_javascript::LANGUAGE.into(), vec![js, js_extra, jsx], true),
        "typescript" => (tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(), vec![ts, js, js_extra, ts_extra], true),
        "tsx" => (tree_sitter_typescript::LANGUAGE_TSX.into(), vec![ts, js, js_extra, ts_extra, jsx], true),
        "python" => (tree_sitter_python::LANGUAGE.into(), vec![include_str!("../queries/python.scm"), tree_sitter_python::HIGHLIGHTS_QUERY], false),
        "go" => (tree_sitter_go::LANGUAGE.into(), vec![include_str!("../queries/go.scm"), tree_sitter_go::HIGHLIGHTS_QUERY], false),
        "rust" => (tree_sitter_rust::LANGUAGE.into(), vec![tree_sitter_rust::HIGHLIGHTS_QUERY, include_str!("../queries/rust.scm")], true),
        _ => return None,
    };
    let query = Query::new(&language, &sources.join("\n")).ok()?;
    let kinds = query.capture_names().iter().map(|c| kind_of(name, c)).collect();
    let folds = Query::new(&language, fold_query(name)).ok()?;
    Some(Grammar { language, query, kinds, last_wins, folds })
}

/// 哪些节点能折叠(和 IntelliJ 一样:类体、方法体 / 代码块、多行注释、连续的 import、数组 / 对象字面量)。
fn fold_query(name: &str) -> &'static str {
    match name {
        "java" => "[(class_body) (interface_body) (enum_body) (annotation_type_body) (block) (constructor_body) (switch_block) (array_initializer) (block_comment)] @fold
                   [(import_declaration) (line_comment)] @fold.group",
        "dart" => "[(class_body) (block) (switch_block) (enum_body) (extension_body) (list_literal) (set_or_map_literal) (block_comment) (documentation_block_comment)] @fold
                   [(import_or_export) (comment)] @fold.group",
        "javascript" => "[(statement_block) (class_body) (object) (array) (switch_body) (template_string) (jsx_element)] @fold
                         [(import_statement) (comment)] @fold.group",
        "typescript" => "[(statement_block) (class_body) (object) (array) (switch_body) (template_string) (interface_body) (enum_body) (object_type)] @fold
                         [(import_statement) (comment)] @fold.group",
        "tsx" => "[(statement_block) (class_body) (object) (array) (switch_body) (template_string) (interface_body) (enum_body) (object_type) (jsx_element)] @fold
                  [(import_statement) (comment)] @fold.group",
        "python" => "(block) @fold.header
                     [(dictionary) (list) (set) (tuple) (string)] @fold
                     [(import_statement) (import_from_statement) (comment)] @fold.group",
        "go" => "[(block) (literal_value) (field_declaration_list) (interface_type) (import_spec_list) (raw_string_literal)] @fold
                 (comment) @fold.group",
        "rust" => "[(block) (declaration_list) (field_declaration_list) (enum_variant_list) (match_block) (use_list) (block_comment)] @fold
                   [(use_declaration) (line_comment)] @fold.group",
        _ => "",
    }
}

/// 查询里的分类名 → token 种类,按 IntelliJ 的着色习惯:
/// 字段 / 全大写常量是紫色,true / false / null 和 `this` 跟关键字一类,局部变量、参数、运算符、括号不着色。
fn kind_of(lang: &str, capture: &str) -> Option<u8> {
    use kind::*;
    let c = capture;
    let base = c.split('.').next().unwrap_or(c);
    // 各语言的例外
    match (lang, c) {
        // JSX 的属性名
        ("javascript" | "tsx", "attribute") => return Some(ATTRIBUTE),
        _ => {}
    }
    Some(match c {
        _ if base == "comment" && c.contains("documentation") => DOC_COMMENT,
        _ if base == "comment" => COMMENT,
        "string.special.key" => FIELD,
        _ if base == "string" || base == "escape" || base == "character" => STRING,
        _ if base == "number" || base == "float" => NUMBER,
        "boolean" | "constant.builtin" => CONSTANT,
        "constant" | "property" | "field" | "variable.member" => FIELD,
        // int / void / i32 这类和 Dart 的逐行分词一样算类型(两边不一致的话,打开文件解析完的那一刻颜色会跳)
        "type.builtin" => TYPE,
        "variable.builtin" | "punctuation.special" => KEYWORD,
        _ if base == "keyword" => KEYWORD,
        _ if c.starts_with("function.builtin") => BUILTIN,
        _ if base == "function" || base == "method" => FUNCTION,
        _ if base == "type" || base == "constructor" => TYPE,
        "attribute" | "annotation" => ANNOTATION,
        _ if base == "tag" => TAG,
        "embedded" => PLAIN,
        // variable / variable.parameter / operator / punctuation / label …
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_grammar_and_query_compiles() {
        for n in NAMES {
            let g = get(n).unwrap_or_else(|| panic!("{n} failed to build"));
            assert!(g.kinds.iter().any(|k| k.is_some()), "{n}");
        }
        assert!(get("cobol").is_none());
    }
}
