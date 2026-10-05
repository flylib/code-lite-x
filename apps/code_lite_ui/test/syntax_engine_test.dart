import 'package:code_lite_ui/features/editor/syntax/document_highlighter.dart';
import 'package:code_lite_ui/features/editor/syntax/languages.dart';
import 'package:code_lite_ui/features/editor/syntax/tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把一行分成 (文本, 种类) 对,方便断言。空白不列出。
List<(String, TokenKind)> lex(String path, String line, [int state = 0]) {
  final r = tokenizeLine(languages.detect(path), line, state);
  return [
    for (final t in r.tokens)
      if (line.substring(t.start, t.end).trim().isNotEmpty) (line.substring(t.start, t.end).trim(), t.kind),
  ];
}

TokenKind? kindOf(String path, String line, String word, [int state = 0]) {
  for (final (text, kind) in lex(path, line, state)) {
    if (text == word) return kind;
  }
  return null;
}

void main() {
  group('language detection', () {
    test('by extension, file name and shebang', () {
      String id(String p, [String? first]) => languages.detect(p, firstLine: first).id;
      expect(id('game-api/src/main/java/com/acme/App.java'), 'java');
      expect(id('build.gradle.kts'), 'kotlin');
      expect(id('build.gradle'), 'groovy');
      expect(id('pom.xml'), 'xml');
      expect(id('mapper/UserMapper.xml'), 'xml');
      expect(id('application.yml'), 'yaml');
      expect(id('application.properties'), 'properties');
      expect(id('Dockerfile'), 'dockerfile');
      expect(id('Dockerfile.dev'), 'dockerfile');
      expect(id('Makefile'), 'makefile');
      expect(id('.gitignore'), 'ignore');
      expect(id('README.md'), 'markdown');
      expect(id('src/App.tsx'), 'typescript');
      expect(id('schema.sql'), 'sql');
      expect(id('Cargo.toml'), 'toml');
      expect(id('bin/run', '#!/usr/bin/env python3'), 'python');
      expect(id('deploy', '#!/bin/bash'), 'shellscript');
      expect(id('LICENSE'), 'plaintext');
      expect(id('data.unknownext'), 'plaintext');
    });
  });

  group('code lexer', () {
    test('Java: keywords, types, annotations, strings, numbers, constants', () {
      const f = 'A.java';
      expect(kindOf(f, '@Override public static final int MAX_SIZE = 0x1F;', '@Override'), TokenKind.annotation);
      expect(kindOf(f, 'public static final int MAX_SIZE = 0x1F;', 'public'), TokenKind.keyword);
      expect(kindOf(f, 'public static final int MAX_SIZE = 0x1F;', 'int'), TokenKind.type);
      expect(kindOf(f, 'public static final int MAX_SIZE = 0x1F;', 'MAX_SIZE'), TokenKind.field);
      expect(kindOf(f, 'public static final int MAX_SIZE = 0x1F;', '0x1F'), TokenKind.number);
      expect(kindOf(f, 'List<String> xs = repo.findAll("a\\"b");', 'List'), TokenKind.type);
      expect(kindOf(f, 'List<String> xs = repo.findAll("a\\"b");', 'findAll'), TokenKind.function);
      expect(kindOf(f, 'List<String> xs = repo.findAll("a\\"b");', '"a\\"b"'), TokenKind.string);
      expect(kindOf(f, 'return null; // done', '// done'), TokenKind.comment);
      expect(kindOf(f, 'char c = \'x\';', "'x'"), TokenKind.string);
      expect(kindOf(f, 'double d = 1.5e-3;', '1.5e-3'), TokenKind.number);
    });

    test('a doc comment spanning lines keeps its colour on every line', () {
      final java = languages.byId('java')!;
      final l1 = tokenizeLine(java, '/** Returns the', 0);
      expect(l1.tokens.single.kind, TokenKind.docComment);
      expect(l1.endState, isNot(0));
      final l2 = tokenizeLine(java, ' * public total */ int x;', l1.endState);
      expect(l2.tokens.first.kind, TokenKind.docComment, reason: '"public" 在注释里,不是关键字');
      expect(l2.endState, 0);
      expect(l2.tokens.any((t) => t.kind == TokenKind.type), isTrue, reason: '注释结束后的 int 正常着色');
    });

    test('multi-line strings: Python triple quotes, JS template, Kotlin raw', () {
      final py = languages.byId('python')!;
      final a = tokenizeLine(py, 'doc = """first', 0);
      expect(a.endState, isNot(0));
      final b = tokenizeLine(py, 'def not_code():', a.endState);
      expect(b.tokens.single.kind, TokenKind.string);
      final c = tokenizeLine(py, 'end""" + x', b.endState);
      expect(c.endState, 0);
      expect(kindOf('a.py', 'print(len(x))', 'print'), TokenKind.builtin);
      expect(kindOf('a.py', 'value = None', 'None'), TokenKind.constant);
      expect(kindOf('a.py', '@dataclass', '@dataclass'), TokenKind.annotation);
      expect(tokenizeLine(languages.byId('javascript')!, 'const s = `a \${b}', 0).endState, isNot(0));
    });

    test('Rust lifetimes are not strings; attributes are annotations', () {
      expect(kindOf('a.rs', "fn f<'a>(x: &'a str) -> Option<i32> {", 'fn'), TokenKind.keyword);
      final r = tokenizeLine(languages.byId('rust')!, "fn f<'a>(x: &'a str) {", 0);
      expect(r.tokens.where((t) => t.kind == TokenKind.string), isEmpty);
      expect(kindOf('a.rs', "let c = '\\n'; let d = 'x';", "'x'"), TokenKind.string);
      expect(kindOf('a.rs', '#[derive(Debug, Clone)]', '#[derive(Debug, Clone)]'), TokenKind.annotation);
    });

    test('SQL keywords ignore case; shell variables; C preprocessor', () {
      expect(kindOf('q.sql', 'SELECT id FROM users WHERE x = 1', 'SELECT'), TokenKind.keyword);
      expect(kindOf('q.sql', 'select id from users', 'from'), TokenKind.keyword);
      expect(kindOf('a.sh', r'echo "$HOME" && cd $DIR', r'$DIR'), TokenKind.variable);
      expect(kindOf('a.c', '#include <stdio.h>', '#include'), TokenKind.annotation);
      expect(kindOf('a.c', '#include <stdio.h>', '<stdio.h>'), TokenKind.string);
    });
  });

  group('structured formats', () {
    test('XML: tags, attributes, values, comments across lines, MyBatis placeholders', () {
      expect(kindOf('m.xml', '<select id="findById" resultType="User">', '<select'), TokenKind.tag);
      expect(kindOf('m.xml', '<select id="findById" resultType="User">', 'id'), TokenKind.attribute);
      expect(kindOf('m.xml', '<select id="findById" resultType="User">', '"findById"'), TokenKind.attrValue);
      expect(kindOf('m.xml', '  WHERE id = #{id} AND a &lt; 3', '#{id}'), TokenKind.variable);
      expect(kindOf('m.xml', '  WHERE id = #{id} AND a &lt; 3', '&lt;'), TokenKind.entity);
      final xml = languages.byId('xml')!;
      final c1 = tokenizeLine(xml, '<!-- start', 0);
      expect(c1.endState, 1);
      final c2 = tokenizeLine(xml, '<tag> still comment --> <b>', c1.endState);
      expect(c2.tokens.first.kind, TokenKind.comment);
      expect(c2.tokens.any((t) => t.kind == TokenKind.tag), isTrue);
      // 属性跨行
      final t1 = tokenizeLine(xml, '<dependency scope="test"', 0);
      expect(t1.endState, 2);
      expect(kindOf('pom.xml', '  optional="true">', 'optional', t1.endState), TokenKind.attribute);
      expect(kindOf('pom.xml', '  optional="true">', '"true"', t1.endState), TokenKind.attrValue);
    });

    test('JSON keys vs values, YAML keys/values/comments, properties', () {
      expect(kindOf('a.json', '  "name": "app", "n": 3, "ok": true', '"name"'), TokenKind.field);
      expect(kindOf('a.json', '  "name": "app", "n": 3, "ok": true', '"app"'), TokenKind.string);
      expect(kindOf('a.json', '  "name": "app", "n": 3, "ok": true', 'true'), TokenKind.constant);
      expect(kindOf('a.yml', '  port: 8080 # http', 'port'), TokenKind.key);
      expect(kindOf('a.yml', '  port: 8080 # http', '8080'), TokenKind.number);
      expect(kindOf('a.yml', '  port: 8080 # http', '# http'), TokenKind.comment);
      expect(kindOf('a.yml', '  enabled: true', 'true'), TokenKind.constant);
      expect(kindOf('a.yml', '- name: web', 'name'), TokenKind.key);
      expect(kindOf('a.properties', 'spring.datasource.url=jdbc:mysql://x', 'spring.datasource.url'), TokenKind.key);
      expect(kindOf('Cargo.toml', '[dependencies]', '[dependencies]'), TokenKind.section);
      expect(kindOf('Cargo.toml', 'serde = "1.0"', '"1.0"'), TokenKind.string);
    });

    test('Markdown headings, code fences, inline code and links', () {
      final md = languages.byId('markdown')!;
      expect(kindOf('R.md', '## 运行', '## 运行'), TokenKind.heading);
      final f = tokenizeLine(md, '```bash', 0);
      expect(f.endState, 1);
      expect(tokenizeLine(md, '# not a heading inside a fence', 1).tokens.single.kind, TokenKind.codeSpan);
      expect(tokenizeLine(md, '```', 1).endState, 0);
      expect(kindOf('R.md', 'run `make` see [docs](http://x)', '`make`'), TokenKind.codeSpan);
      expect(kindOf('R.md', 'run `make` see [docs](http://x)', '[docs](http://x)'), TokenKind.link);
      expect(kindOf('R.md', '- item', '-'), TokenKind.listMarker);
    });
  });

  group('DocumentHighlighter', () {
    final java = languages.byId('java')!;
    List<String> doc(int n) => [for (var i = 0; i < n; i++) 'int x$i = $i;'];

    test('editing one line re-lexes only that line', () {
      final h = DocumentHighlighter();
      final lines = doc(200);
      h.update(java, lines);
      expect(h.lastRetokenized, 200);
      final edited = [...lines]..[100] = 'int changed = 1;';
      h.update(java, edited);
      expect(h.lastRetokenized, 1);
      final inserted = [...edited]..insert(50, '// new');
      h.update(java, inserted);
      expect(h.lastRetokenized, 1, reason: '插入一行后,后面的行按后缀对齐沿用');
    });

    test('opening a block comment re-lexes until the state converges again', () {
      final h = DocumentHighlighter();
      final lines = doc(20);
      h.update(java, lines);
      final opened = [...lines]..[5] = '/* start';
      h.update(java, opened);
      expect(h.lastRetokenized, 15, reason: '第 5 行之后全进了注释');
      expect(h.spansAt(10).single.style, syntaxStyle(TokenKind.comment));
      final closed = [...opened]..[8] = 'end */ int y = 2;';
      h.update(java, closed);
      expect(h.spansAt(12).any((s) => s.style == syntaxStyle(TokenKind.type)), isTrue);
      expect(h.lastRetokenized, lessThan(15));
    });

    test('switching language re-lexes everything', () {
      final h = DocumentHighlighter();
      h.update(java, doc(10));
      h.update(languages.byId('kotlin')!, doc(10));
      expect(h.lastRetokenized, 10);
    });
  });
}
