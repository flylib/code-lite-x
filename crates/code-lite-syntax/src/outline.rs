//! 结构视图的大纲(没有语言服务器时用):按语法树找出类、方法、字段……,还原层级。
//! 输出和 Dart 那边 `lspParseDocumentSymbols` 同样的 JSON:
//! `[{name, kind, line_start, col_start, line_end, col_end, children}]`,行列从 0 起,列是 UTF-16。
//!
//! 和原来的正则大纲一样:函数 / 方法体里面的东西(局部变量、闭包、局部类)不进大纲;
//! 类、接口、结构体、impl 里的函数算方法。

use std::collections::HashMap;

use serde_json::{json, Value};
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor};

use crate::grammar;

/// 每种语言的「定义」查询:捕获名就是大纲里的种类(`@class`、`@method`……),`@name` 是名字(几个就用 `.` 连起来,
/// 比如 Dart 的命名构造函数 `A.named`),Go 方法的 `@receiver` 拼进名字里(同 gopls:`(*S).M`)。
/// 同一个节点被几条规则匹配时写在前面的那条生效。
fn query_source(name: &str) -> &'static str {
    match name {
        "java" => r#"
            (class_declaration name: (identifier) @name) @class
            (record_declaration name: (identifier) @name) @class
            (interface_declaration name: (identifier) @name) @interface
            (annotation_type_declaration name: (identifier) @name) @interface
            (enum_declaration name: (identifier) @name) @enum
            (enum_constant name: (identifier) @name) @variant
            (method_declaration name: (identifier) @name) @method
            (constructor_declaration name: (identifier) @name) @constructor
            (field_declaration declarator: (variable_declarator name: (identifier) @name) @field)
        "#,
        "dart" => r#"
            (class_declaration name: (identifier) @name) @class
            (mixin_declaration name: (identifier) @name) @class
            (extension_declaration name: (identifier) @name) @class
            (enum_declaration name: (identifier) @name) @enum
            (enum_constant name: (identifier) @name) @variant
            (function_declaration signature: (function_signature name: (identifier) @name)) @function
            (method_declaration signature: (method_signature [
              (function_signature name: (identifier) @name)
              (getter_signature name: (identifier) @name)
              (setter_signature name: (identifier) @name)
            ])) @method
            (constructor_signature name: (identifier) @name) @constructor
            (constant_constructor_signature (identifier) @name) @constructor
            (factory_constructor_signature (identifier) @name) @constructor
            (redirecting_factory_constructor_signature (identifier) @name) @constructor
            (initialized_identifier name: (identifier) @name) @field
            (static_final_declaration (identifier) @name) @field
        "#,
        "javascript" => r#"
            (class_declaration name: (_) @name) @class
            (function_declaration name: (_) @name) @function
            (generator_function_declaration name: (_) @name) @function
            (method_definition name: (_) @name) @method
            (field_definition property: (_) @name) @field
            (variable_declarator name: (identifier) @name value: [(arrow_function) (function_expression)]) @function
        "#,
        "typescript" | "tsx" => r#"
            (class_declaration name: (_) @name) @class
            (abstract_class_declaration name: (_) @name) @class
            (interface_declaration name: (_) @name) @interface
            (enum_declaration name: (_) @name) @enum
            (enum_body name: (_) @name @variant)
            (enum_assignment name: (_) @name) @variant
            (type_alias_declaration name: (_) @name) @type
            (function_declaration name: (_) @name) @function
            (generator_function_declaration name: (_) @name) @function
            (method_definition name: (_) @name) @method
            (method_signature name: (_) @name) @method
            (abstract_method_signature name: (_) @name) @method
            (public_field_definition name: (_) @name) @field
            (property_signature name: (_) @name) @field
            (variable_declarator name: (identifier) @name value: [(arrow_function) (function_expression)]) @function
        "#,
        "python" => r#"
            (class_definition name: (identifier) @name) @class
            (function_definition name: (identifier) @name) @function
            (class_definition body: (block (expression_statement (assignment left: (identifier) @name) @field)))
            (module (expression_statement (assignment left: (identifier) @name) @variable))
        "#,
        "go" => r#"
            (type_spec name: (type_identifier) @name type: (struct_type)) @struct
            (type_spec name: (type_identifier) @name type: (interface_type)) @interface
            (type_spec name: (type_identifier) @name) @type
            (field_declaration name: (field_identifier) @name) @field
            (method_elem name: (field_identifier) @name) @method
            (method_declaration receiver: (parameter_list (parameter_declaration type: (_) @receiver)) name: (field_identifier) @name) @method
            (function_declaration name: (identifier) @name) @function
            (const_spec name: (identifier) @name) @constant
            (var_spec name: (identifier) @name) @variable
        "#,
        "rust" => r#"
            (struct_item name: (_) @name) @struct
            (union_item name: (_) @name) @struct
            (enum_item name: (_) @name) @enum
            (enum_variant name: (_) @name) @variant
            (trait_item name: (_) @name) @trait
            (impl_item) @impl
            (function_item name: (_) @name) @function
            (function_signature_item name: (_) @name) @function
            (mod_item name: (_) @name) @module
            (const_item name: (_) @name) @constant
            (static_item name: (_) @name) @constant
            (type_item name: (_) @name) @type
            (field_declaration name: (_) @name) @field
            (macro_definition name: (_) @name) @function
        "#,
        _ => "",
    }
}

/// 每种语言的大纲查询(编译一次)。
fn query_for(name: &str, g: &grammar::Grammar) -> Option<&'static Query> {
    use std::sync::{Mutex, OnceLock};
    static CACHE: OnceLock<Mutex<HashMap<String, &'static Query>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    if let Some(q) = cache.lock().unwrap().get(name) {
        return Some(q);
    }
    let q: &'static Query = Box::leak(Box::new(Query::new(&g.language, query_source(name)).ok()?));
    cache.lock().unwrap().insert(name.to_string(), q);
    Some(q)
}

struct Item {
    kind: String,
    name: String,
    /// 名字的位置(跳转落在名字上,不落在注解 / 文档注释上)。
    name_pos: Option<(usize, usize)>,
    start_byte: usize,
    end_byte: usize,
    end: (usize, usize),
    pattern: usize,
}

/// 第 [row] 行第 [byte_col] 个字节处的 UTF-16 列。
fn utf16_col(text: &str, line_starts: &[usize], row: usize, byte_col: usize) -> usize {
    let ls = line_starts.get(row).copied().unwrap_or(text.len());
    let end = (ls + byte_col).min(text.len());
    let mut e = end;
    while e > ls && !text.is_char_boundary(e) {
        e -= 1;
    }
    text[ls..e].encode_utf16().count()
}

/// 大纲 JSON;不认识的语法返回 None。
pub fn outline(name: &str, text: &str) -> Option<String> {
    let g = grammar::get(name)?;
    let q = query_for(name, &g)?;
    let mut parser = Parser::new();
    parser.set_language(&g.language).ok()?;
    let tree = parser.parse(text, None)?;
    let mut line_starts = vec![0usize];
    line_starts.extend(text.bytes().enumerate().filter(|(_, b)| *b == b'\n').map(|(i, _)| i + 1));

    let names = q.capture_names();
    let mut items: Vec<Item> = Vec::new();
    let mut by_node: HashMap<usize, usize> = HashMap::new();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(q, tree.root_node(), text.as_bytes());
    while let Some(m) = matches.next() {
        let mut def: Option<(Node, &str)> = None;
        let mut name_nodes: Vec<Node> = Vec::new();
        let mut receiver: Option<Node> = None;
        for c in m.captures {
            match names[c.index as usize] {
                "name" => name_nodes.push(c.node),
                "receiver" => receiver = Some(c.node),
                kind => def = Some((c.node, kind)),
            }
        }
        let Some((node, kind)) = def else { continue };
        let node_text = |n: Node| n.utf8_text(text.as_bytes()).unwrap_or("").to_string();
        let mut name = name_nodes.iter().map(|n| node_text(*n)).collect::<Vec<_>>().join(".");
        if let Some(r) = receiver {
            name = format!("({}).{name}", node_text(r));
        }
        if kind == "impl" {
            // impl 的名字是它的头部:`impl Trait for Type`
            let head_end = node.child_by_field_name("body").map_or(node.end_byte(), |b| b.start_byte());
            name = text[node.start_byte()..head_end].split_whitespace().collect::<Vec<_>>().join(" ");
        }
        if name.is_empty() {
            continue;
        }
        // Dart 的构造函数签名后面跟着方法体(兄弟节点):范围算到方法体结尾
        let mut end_node = node;
        if let Some(next) = node.next_sibling() {
            if next.kind() == "function_body" {
                end_node = next;
            }
        }
        let name_pos = name_nodes.first().map(|n| (n.start_position().row, n.start_position().column));
        if let Some(&i) = by_node.get(&node.id()) {
            // 同一个节点:同一条规则的多个名字已经拼过了;别的规则让给先到的
            let it = &mut items[i];
            if it.pattern == m.pattern_index {
                if !it.name.split('.').any(|p| p == name) && name_nodes.len() == 1 {
                    it.name = format!("{}.{name}", it.name);
                }
            } else if m.pattern_index < it.pattern {
                // 匹配到达的顺序不一定是规则的顺序:写在前面的规则更具体(Go 的 struct / interface 先于泛泛的 type)
                it.kind = kind.to_string();
                it.name = name;
                it.name_pos = name_pos;
                it.pattern = m.pattern_index;
            }
            continue;
        }
        by_node.insert(node.id(), items.len());
        items.push(Item {
            kind: kind.to_string(),
            name,
            name_pos,
            start_byte: node.start_byte(),
            end_byte: end_node.end_byte(),
            end: (end_node.end_position().row, end_node.end_position().column),
            pattern: m.pattern_index,
        });
    }

    // 按范围还原层级:起点升序,同起点的大的在前
    items.sort_by(|a, b| a.start_byte.cmp(&b.start_byte).then(b.end_byte.cmp(&a.end_byte)));
    let opaque = |k: &str| matches!(k, "function" | "method" | "constructor");
    let container = |k: &str| matches!(k, "class" | "interface" | "struct" | "trait" | "impl" | "enum");
    // (节点 JSON, 结束字节, 种类)
    let mut stack: Vec<(Value, usize, String)> = Vec::new();
    let mut roots: Vec<Value> = Vec::new();
    fn pop_into(stack: &mut Vec<(Value, usize, String)>, roots: &mut Vec<Value>) {
        let (node, _, _) = stack.pop().unwrap();
        match stack.last_mut() {
            Some(parent) => parent.0["children"].as_array_mut().unwrap().push(node),
            None => roots.push(node),
        }
    }
    for it in items {
        while stack.last().is_some_and(|s| s.1 <= it.start_byte) {
            pop_into(&mut stack, &mut roots);
        }
        let parent_kind = stack.last().map(|s| s.2.clone());
        if parent_kind.as_deref().is_some_and(opaque) {
            continue; // 函数体里的不进大纲
        }
        let kind = if it.kind == "function" && parent_kind.as_deref().is_some_and(container) { "method".to_string() } else { it.kind };
        let (row, col) = it.name_pos.unwrap_or_else(|| {
            let p = tree.root_node().descendant_for_byte_range(it.start_byte, it.start_byte).map(|n| n.start_position()).unwrap_or_default();
            (p.row, p.column)
        });
        let node = json!({
            "name": it.name,
            "kind": kind,
            "line_start": row,
            "col_start": utf16_col(text, &line_starts, row, col),
            "line_end": it.end.0,
            "col_end": utf16_col(text, &line_starts, it.end.0, it.end.1),
            "children": [],
        });
        stack.push((node, it.end_byte, kind));
    }
    while !stack.is_empty() {
        pop_into(&mut stack, &mut roots);
    }
    Some(Value::Array(roots).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 大纲压成 `kind name@line` 的缩进文本,方便对照。
    fn flat(name: &str, src: &str) -> Vec<String> {
        let v: Value = serde_json::from_str(&outline(name, src).unwrap()).unwrap();
        let mut out = Vec::new();
        fn walk(v: &Value, depth: usize, out: &mut Vec<String>) {
            for n in v.as_array().unwrap() {
                out.push(format!("{}{} {}@{}", "  ".repeat(depth), n["kind"].as_str().unwrap(), n["name"].as_str().unwrap(), n["line_start"]));
                walk(&n["children"], depth + 1, out);
            }
        }
        walk(&v, 0, &mut out);
        out
    }

    #[test]
    fn java() {
        let src = "package p;\n@Ann\npublic class A {\n  private int x, y;\n  A() {}\n  void run() { int local = 1; Runnable r = new Runnable() { public void run() {} }; }\n  enum E { ONE, TWO }\n  interface I { void m(); }\n}\n";
        assert_eq!(
            flat("java", src),
            [
                "class A@2", "  field x@3", "  field y@3", "  constructor A@4", "  method run@5",
                "  enum E@6", "    variant ONE@6", "    variant TWO@6", "  interface I@7", "    method m@7",
            ]
        );
    }

    #[test]
    fn dart() {
        let src = "class A extends B {\n  int n = 0, m;\n  A(this.n);\n  A.named();\n  void f(int p) { var local = 1; }\n  int get g => 1;\n}\nvoid top() {}\nenum E { a, b }\nmixin M {}\n";
        assert_eq!(
            flat("dart", src),
            [
                "class A@0", "  field n@1", "  field m@1", "  constructor A@2", "  constructor A.named@3", "  method f@4", "  method g@5",
                "function top@7", "enum E@8", "  variant a@8", "  variant b@8", "class M@9",
            ]
        );
    }

    #[test]
    fn typescript_python_go_rust() {
        assert_eq!(
            flat("typescript", "class A { n: number = 0; m(): void { const inner = () => 1; } }\nconst g = () => 1;\ninterface I { a: string; b(): void }\ntype T = string;\nenum E { X, Y = 2 }\nexport class C {}\n"),
            ["class A@0", "  field n@0", "  method m@0", "function g@1", "interface I@2", "  field a@2", "  method b@2", "type T@3", "enum E@4", "  variant X@4", "  variant Y@4", "class C@5"]
        );
        assert_eq!(
            flat("python", "class A:\n    x = 1\n    def m(self):\n        y = 2\ndef f():\n    pass\nY = 2\n"),
            ["class A@0", "  field x@1", "  method m@2", "function f@4", "variable Y@6"]
        );
        assert_eq!(
            flat("go", "package p\ntype S struct { A int }\ntype I interface { M() }\nfunc (s *S) M() { x := 1 }\nfunc F() {}\nconst C = 1\n"),
            ["struct S@1", "  field A@1", "interface I@2", "  method M@2", "method (*S).M@3", "function F@4", "constant C@5"]
        );
        assert_eq!(
            flat("rust", "struct S { a: i32 }\nenum E { A }\ntrait T { fn m(&self); }\nimpl T for S { fn m(&self) { fn inner() {} } }\nfn f() {}\nmod m { fn g() {} }\n"),
            [
                "struct S@0", "  field a@0", "enum E@1", "  variant A@1", "trait T@2", "  method m@2", "impl impl T for S@3", "  method m@3",
                "function f@4", "module m@5", "  function g@5",
            ]
        );
    }

    #[test]
    fn columns_are_utf16_and_unknown_grammar_is_none() {
        let v: Value = serde_json::from_str(&outline("java", "/* 中文😀 */ class A {}\n").unwrap()).unwrap();
        assert_eq!(v[0]["col_start"], "/* 中文😀 */ class ".encode_utf16().count());
        assert!(outline("cobol", "x").is_none());
    }
}

#[cfg(test)]
mod bench {
    #[test]
    #[ignore]
    fn bench_outline() {
        for (lang, path) in [("java", std::env::var("JAVA_FILE").unwrap()), ("dart", std::env::var("DART_FILE").unwrap())] {
            let src = std::fs::read_to_string(&path).unwrap();
            let _ = super::outline(lang, &src);
            let t = std::time::Instant::now();
            let json = super::outline(lang, &src).unwrap();
            let v: serde_json::Value = serde_json::from_str(&json).unwrap();
            fn count(v: &serde_json::Value) -> usize { v.as_array().unwrap().iter().map(|n| 1 + count(&n["children"])).sum() }
            println!("BENCH {lang}: {:?}, {} symbols", t.elapsed(), count(&v));
        }
    }
}
