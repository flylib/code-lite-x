use super::*;

fn joined(lines: &[&str]) -> String {
    lines.iter().map(|l| format!("{l}\n")).collect()
}

fn wait_parsed(d: &Document) {
    let t0 = Instant::now();
    while d.status() & 1 == 1 {
        assert!(t0.elapsed() < Duration::from_secs(10), "parse never finished");
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// 解出一行行的 (是否脏, [(起列, 止列, 种类)])。
fn decode(b: &[u8]) -> (bool, Vec<(bool, Vec<(u32, u32, u8)>)>) {
    let u32_at = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
    let ready = b[1] == 1;
    let n = u32_at(12) as usize;
    let mut o = 16;
    let mut lines = Vec::new();
    for _ in 0..n {
        let dirty = b[o] == 1;
        let c = u32_at(o + 1) as usize;
        o += 5;
        let mut toks = Vec::new();
        for _ in 0..c {
            toks.push((u32_at(o), u32_at(o + 4), b[o + 8]));
            o += 9;
        }
        lines.push((dirty, toks));
    }
    (ready, lines)
}

/// 某一行里文字 [word] 的种类(没着色返回 None)。
fn kind_at(doc: &Document, line: usize, src: &str, word: &str) -> Option<u8> {
    let (_, lines) = decode(&doc.highlight(line, line + 1));
    let col = src.find(word).unwrap() as u32;
    lines[0].1.iter().find(|t| t.0 <= col && col < t.1).map(|t| t.2)
}

#[test]
fn edits_keep_the_text_in_sync() {
    let mut lines: Vec<String> = (0..50).map(|i| format!("int a{i} = {i};")).collect();
    let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
    let doc = Document::open("java", joined(&refs)).unwrap();
    let mut seed = 7u64;
    let mut rnd = |m: usize| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (seed >> 33) as usize % m.max(1)
    };
    for step in 0..300 {
        let n = lines.len();
        let s = rnd(n + 1);
        let old = rnd(4).min(n - s);
        let new: Vec<String> = (0..rnd(4)).map(|k| format!("x{step}_{k}();")).collect();
        lines.splice(s..s + old, new.clone());
        let nt: String = new.iter().map(|l| format!("{l}\n")).collect();
        doc.edit(s, old, &nt);
        let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
        assert_eq!(doc.text(), joined(&refs), "step {step}");
        assert_eq!(doc.line_count(), lines.len());
    }
    wait_parsed(&doc);
    let (ready, out) = decode(&doc.highlight(0, lines.len()));
    assert!(ready);
    assert!(out.iter().all(|l| !l.0), "nothing dirty after the parse settles");
}

#[test]
fn java_colors_like_intellij() {
    let src = [
        "/** Doc. */",
        "class Foo {",
        "  private int count = 1;",
        "  static final String NAME = \"x\";",
        "  Foo() { super(); }",
        "  void run(int n) { this.count = n; System.out.println(NAME); bar(n); }",
        "  @Override public String toString() { return null; }",
        "}",
    ];
    let doc = Document::open("java", joined(&src)).unwrap();
    wait_parsed(&doc);
    use kind::*;
    assert_eq!(kind_at(&doc, 0, src[0], "/**"), Some(DOC_COMMENT));
    assert_eq!(kind_at(&doc, 1, src[1], "class"), Some(KEYWORD));
    assert_eq!(kind_at(&doc, 2, src[2], "count"), Some(FIELD), "field declaration");
    assert_eq!(kind_at(&doc, 2, src[2], "int"), Some(TYPE), "primitives are types, like the Dart tokenizer");
    assert_eq!(kind_at(&doc, 2, src[2], "1"), Some(NUMBER));
    assert_eq!(kind_at(&doc, 3, src[3], "NAME"), Some(FIELD));
    assert_eq!(kind_at(&doc, 3, src[3], "\"x\""), Some(STRING));
    assert_eq!(kind_at(&doc, 4, src[4], "Foo"), Some(FUNCTION), "constructor name");
    assert_eq!(kind_at(&doc, 4, src[4], "super"), Some(KEYWORD));
    assert_eq!(kind_at(&doc, 5, src[5], "run"), Some(FUNCTION));
    assert_eq!(kind_at(&doc, 5, src[5], "this"), Some(KEYWORD));
    assert_eq!(kind_at(&doc, 5, src[5], "count"), Some(FIELD), "this.count");
    assert_eq!(kind_at(&doc, 5, src[5], "out"), Some(FIELD), "System.out");
    assert_eq!(kind_at(&doc, 5, src[5], "println"), Some(FUNCTION));
    assert_eq!(kind_at(&doc, 5, src[5], "bar"), Some(FUNCTION));
    assert_eq!(kind_at(&doc, 5, src[5], "n)"), None, "parameters stay plain");
    assert_eq!(kind_at(&doc, 6, src[6], "Override"), Some(ANNOTATION));
    assert_eq!(kind_at(&doc, 6, src[6], "null"), Some(CONSTANT));
}

#[test]
fn columns_are_utf16() {
    let src = ["class A {", "  String s = \"中文😀\"; int x = 1;", "}"];
    let doc = Document::open("java", joined(&src)).unwrap();
    wait_parsed(&doc);
    let (_, l) = decode(&doc.highlight(1, 2));
    let utf16: Vec<u16> = src[1].encode_utf16().collect();
    let x = String::from_utf16(&utf16[..]).unwrap();
    let num = l[0].1.iter().find(|t| t.2 == kind::NUMBER).unwrap();
    assert_eq!(&String::from_utf16(&utf16[num.0 as usize..num.1 as usize]).unwrap(), "1");
    let s = l[0].1.iter().find(|t| t.2 == kind::STRING).unwrap();
    assert_eq!(&String::from_utf16(&utf16[s.0 as usize..s.1 as usize]).unwrap(), "\"中文😀\"");
    assert!(x.contains("中文"));
}

#[test]
fn dart_js_ts_python_go_rust_basics() {
    use kind::*;
    let cases: &[(&str, &[&str], usize, &str, u8)] = &[
        ("dart", &["class A {", "  int n = 0;", "  void f() { print(n); foo.bar(); this.n = 1; }", "}"], 2, "bar", FUNCTION),
        ("dart", &["class A {", "  void f() { this.n = 1; }", "}"], 1, "n =", FIELD),
        ("dart", &["var s = 'a${b}c';"], 0, "'a", STRING),
        ("dart", &["var s = 'a${b}c';"], 0, "${", KEYWORD),
        ("javascript", &["const x = obj.prop; foo(); // c"], 0, "prop", FIELD),
        ("javascript", &["const x = obj.prop; foo(); // c"], 0, "foo", FUNCTION),
        ("typescript", &["let n: number = 1;", "interface I { a: string }"], 1, "interface", KEYWORD),
        ("tsx", &["const e = <div className=\"a\">hi</div>;"], 0, "div", TAG),
        ("python", &["def f(x):", "    return len(x)  # c"], 1, "len", BUILTIN),
        ("go", &["package main", "func main() { fmt.Println(\"x\") }"], 1, "Println", FUNCTION),
        ("rust", &["fn main() { let s = String::new(); println!(\"x\"); }"], 0, "fn", KEYWORD),
        ("rust", &["fn f() { obj.call(1); }"], 0, "call", FUNCTION),
        ("rust", &["const MAX: u8 = 1;"], 0, "MAX", FIELD),
        ("rust", &["const MAX: u8 = 1;"], 0, "1", NUMBER),
        ("python", &["class A:", "    def m(self):", "        obj.call(MAX)"], 2, "call", FUNCTION),
        ("python", &["class A:", "    def m(self):", "        obj.call(MAX)"], 2, "MAX", FIELD),
        ("go", &["package main", "func f() { x := len(p) }"], 1, "len", BUILTIN),
        ("go", &["package main", "func f() { obj.Call(1) }"], 1, "Call", FUNCTION),
        ("javascript", &["obj.call(1); require('x');"], 0, "call", FUNCTION),
        ("javascript", &["console.log(1);"], 0, "console", BUILTIN),
        ("rust", &["fn f() { let x = Some(1); }"], 0, "Some", CONSTANT),
        ("typescript", &["const MAX = 1; new Foo();"], 0, "MAX", FIELD),
        ("typescript", &["const MAX = 1; new Foo();"], 0, "Foo", TYPE),
        ("dart", &["void f() { obj.call(1); }"], 0, "call", FUNCTION),
        ("dart", &["void f() { obj.call(1); }"], 0, "void", KEYWORD),
    ];
    for (lang, src, line, word, want) in cases {
        let doc = Document::open(lang, joined(src)).unwrap();
        wait_parsed(&doc);
        assert_eq!(kind_at(&doc, *line, src[*line], word), Some(*want), "{lang}: {word} in {:?}", src[*line]);
    }
}

#[test]
fn dart_interpolation_is_not_painted_as_string() {
    let src = ["var s = 'a${name}c';"];
    let doc = Document::open("dart", joined(&src)).unwrap();
    wait_parsed(&doc);
    assert_eq!(kind_at(&doc, 0, src[0], "name"), None);
}

#[test]
fn string_interpolation_is_not_painted_as_string() {
    let src = ["const s = `a ${name} b`;"];
    let doc = Document::open("javascript", joined(&src)).unwrap();
    wait_parsed(&doc);
    assert_eq!(kind_at(&doc, 0, src[0], "`a"), Some(kind::STRING));
    assert_ne!(kind_at(&doc, 0, src[0], "name"), Some(kind::STRING));
}

#[test]
fn big_file_parses_in_background_and_small_edits_reparse_inline() {
    let mut src = String::from("class Big {\n");
    for i in 0..20000 {
        src.push_str(&format!("  int f{i}() {{ return this.v{i} + {i}; }}\n"));
    }
    src.push_str("}\n");
    let doc = Document::open("java", src).unwrap();
    // 第一次解析在后台:还没好时只回「没有语法树」,界面用自己的分词
    let (ready, _) = decode(&doc.highlight(0, 5));
    if !ready {
        assert_eq!(doc.status() & 1, 1);
    }
    wait_parsed(&doc);
    let g = doc.status() >> 1;
    let t0 = Instant::now();
    doc.edit(10000, 1, "  int g() { return 1; }\n");
    let took = t0.elapsed();
    // 同步预算 3 ms;超了也只是交给后台,不会卡住
    assert!(took < Duration::from_millis(50), "edit took {took:?}");
    wait_parsed(&doc);
    assert!(doc.status() >> 1 > g);
    let line = "  int g() { return 1; }";
    assert_eq!(kind_at(&doc, 10000, line, "g()"), Some(kind::FUNCTION));
}

#[test]
fn lines_edited_while_parsing_in_background_are_dirty() {
    let mut src = String::from("class Big {\n");
    for i in 0..30000 {
        src.push_str(&format!("  int f{i}() {{ return {i}; }}\n"));
    }
    src.push_str("}\n");
    let doc = Document::open("java", src).unwrap();
    wait_parsed(&doc);
    // 开一个块注释:后面整个文件都要重解析,超出同步预算 → 后台;解析期间再改几行
    doc.edit(1, 0, "/*\n");
    doc.edit(4, 0, "*/\n");
    let (ready, l) = decode(&doc.highlight(0, 8));
    assert!(ready);
    if doc.status() & 1 == 1 {
        assert!(l[4].0, "line edited during the background parse is dirty");
    }
    wait_parsed(&doc);
    let (_, l) = decode(&doc.highlight(0, 8));
    assert!(l.iter().all(|x| !x.0));
    assert!(l[2].1.iter().any(|t| t.2 == kind::COMMENT), "inside the new block comment");
    assert!(l[5].1.iter().any(|t| t.2 == kind::KEYWORD), "after it: code again");
}

#[test]
fn closed_documents_stop_their_background_parse() {
    let mut src = String::new();
    for i in 0..20000 {
        src.push_str(&format!("int f{i}() {{ return {i}; }}\n"));
    }
    let doc = Document::open("java", src).unwrap();
    doc.close();
    wait_parsed(&doc);
    assert!(Document::open("cobol", "x\n".into()).is_none());
}

#[test]
#[ignore]
fn dump_samples() {
    let samples: &[(&str, &str)] = &[
        ("java", "class A { int n; void f(int p) { this.n = p; obj.call(n); Foo.bar(); String s = \"x\"; int MAX = 1; List<String> l = new ArrayList<>(); } }"),
        ("dart", "class A { int n = 0; void f(int p) { this.n = p; obj.call(n); print('a${n}b'); final x = Foo(); x.y; } }"),
        ("javascript", "class A { m(p) { this.n = p; obj.call(n); console.log(`a${n}`); const MAX = 1; new Foo(); require('x'); x.y; } }"),
        ("typescript", "class A { n: number = 0; m(p: string): void { this.n = 1; obj.call(n); const MAX = 1; new Foo(); x.y; } }"),
        ("python", "class A:\n    def m(self, p):\n        self.n = len(p); obj.call(n); MAX = 1; Foo(); x.y; print(f'a{n}')\n"),
        ("go", "package main\nfunc (a *A) M(p int) { a.n = p; obj.Call(n); x := len(p); fmt.Println(x); var s Foo; s.y = 1 }\n"),
        ("rust", "impl A { fn m(&self, p: i32) { self.n = p; obj.call(n); let x = Foo::new(); println!(\"{}\", x.y); const MAX: u8 = 1; } }"),
    ];
    let names = ["P","KW","TYPE","CONST","BUILTIN","FN","STR","NUM","CMT","DOC","ANN","FIELD","TAG","ATTR"];
    for (lang, src) in samples {
        let text = if src.ends_with('\n') { src.to_string() } else { format!("{src}\n") };
        let doc = Document::open(lang, text.clone()).unwrap();
        wait_parsed(&doc);
        let n = doc.line_count();
        let (_, lines) = decode(&doc.highlight(0, n));
        let mut out = String::new();
        for (i, l) in text.lines().enumerate() {
            let u: Vec<u16> = l.encode_utf16().collect();
            for t in &lines[i].1 {
                out.push_str(&format!("{}:{} ", String::from_utf16_lossy(&u[t.0 as usize..t.1 as usize]), names[t.2 as usize]));
            }
        }
        println!("[{lang}] {out}");
    }
}

fn decode_folds(b: &[u8]) -> Vec<(u32, u32)> {
    let u = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
    assert_eq!(b[0], 1, "tree ready");
    (0..u(8) as usize).map(|i| (u(12 + i * 8), u(16 + i * 8))).collect()
}

fn folds_of(lang: &str, src: &[&str]) -> Vec<(u32, u32)> {
    let doc = Document::open(lang, joined(src)).unwrap();
    wait_parsed(&doc);
    decode_folds(&doc.folds(0, src.len()))
}

#[test]
fn java_folds() {
    let src = [
        "import a.B;",         // 0
        "import a.C;",         // 1
        "/**",                 // 2
        " * Doc.",             // 3
        " */",                 // 4
        "class A {",           // 5
        "  void f() {",        // 6
        "    if (x) {",        // 7
        "      g();",          // 8
        "    }",               // 9
        "  }",                 // 10
        "  // one",            // 11
        "  // two",            // 12
        "  int x; // trailing",// 13
        "  int[] a = {1,",     // 14
        "    2};",             // 15
        "}",                   // 16
    ];
    assert_eq!(
        folds_of("java", &src),
        vec![(0, 1), (2, 4), (5, 16), (6, 10), (7, 9), (11, 12), (14, 15)]
    );
}

#[test]
fn python_blocks_fold_from_the_header_line() {
    let src = ["import os", "import sys", "def f(x):", "    if x:", "        return 1", "    return 2", "", "y = 1"];
    assert_eq!(folds_of("python", &src), vec![(0, 1), (2, 5), (3, 4)]);
}

#[test]
fn folds_only_report_regions_starting_in_range_and_dedupe_same_start() {
    let src = ["class A {", "  void f() {", "    g(() -> {", "      h();", "    });", "  }", "}"];
    let doc = Document::open("java", joined(&src)).unwrap();
    wait_parsed(&doc);
    assert_eq!(decode_folds(&doc.folds(1, 3)), vec![(1, 5), (2, 4)]);
    let all = decode_folds(&doc.folds(0, src.len()));
    assert_eq!(all, vec![(0, 6), (1, 5), (2, 4)]);
}

#[test]
fn every_language_has_some_folds() {
    let cases: &[(&str, &[&str])] = &[
        ("dart", &["import 'a.dart';", "import 'b.dart';", "class A {", "  void f() {", "    g();", "  }", "}"]),
        ("javascript", &["function f() {", "  return {", "    a: 1,", "  };", "}"]),
        ("typescript", &["interface I {", "  a: string;", "}", "function f() {", "  g();", "}"]),
        ("tsx", &["function f() {", "  return (", "    <div>", "      hi", "    </div>", "  );", "}"]),
        ("go", &["package main", "import (", "  \"fmt\"", ")", "func main() {", "  fmt.Println()", "}"]),
        ("rust", &["use a::b;", "use a::c;", "impl A {", "    fn f() {", "        g();", "    }", "}"]),
    ];
    for (lang, src) in cases {
        let f = folds_of(lang, src);
        assert!(f.len() >= 2, "{lang}: {f:?}");
    }
}
