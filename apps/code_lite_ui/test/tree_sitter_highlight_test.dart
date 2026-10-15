import 'dart:math';

import 'package:code_lite_ui/core/ffi/rust_syntax.dart';
import 'package:code_lite_ui/features/editor/syntax/color_schemes.dart';
import 'package:code_lite_ui/features/editor/syntax/document_highlighter.dart';
import 'package:code_lite_ui/features/editor/syntax/languages.dart';
import 'package:code_lite_ui/features/editor/syntax/tokenizer.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// 某一行里 [word] 那段文字的颜色。
Color? colorOf(DocumentHighlighter h, int line, String text, String word) {
  final at = text.indexOf(word);
  var pos = 0;
  for (final s in h.spansAt(line)) {
    final t = s.text ?? '';
    if (at >= pos && at < pos + t.length) return s.style?.color;
    pos += t.length;
  }
  return null;
}

Future<void> settle(DocumentHighlighter h) async {
  for (var i = 0; i < 500; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (h.repaint.value > 0 && h.styleKeyAt(0).startsWith('t')) return;
  }
  fail('tree never became ready');
}

void main() {
  final java = languages.detect('A.java');
  final scheme = islandsDarkScheme;
  final field = scheme.styleOf(TokenKind.field)!.color;
  final function = scheme.styleOf(TokenKind.function)!.color;
  final keyword = scheme.styleOf(TokenKind.keyword)!.color;

  test('the Rust syntax library is loaded in tests (otherwise only the Dart fallback is tested)', () {
    final d = SyntaxTreeDoc.open('java', ['class A {}']);
    expect(d, isNotNull);
    d!.close();
    expect(SyntaxTreeDoc.open('cobol', ['x']), isNull);
  });

  test('grammar choice: tsx by extension, none for languages without a grammar', () {
    final ts = languages.detect('a.ts');
    expect(DocumentHighlighter.treeSitterGrammar(ts, 'a.ts'), 'typescript');
    expect(DocumentHighlighter.treeSitterGrammar(ts, 'a.tsx'), 'tsx');
    expect(DocumentHighlighter.treeSitterGrammar(languages.detect('a.yaml'), 'a.yaml'), isNull);
    expect(DocumentHighlighter.treeSitterGrammar(java, 'A.java'), 'java');
  });

  test('tokenizer first, then the syntax tree: fields purple, calls blue', () async {
    final lines = [
      'class A {',
      '  private int count = 1;',
      '  void run(int n) { this.count = n; System.out.println(n); }',
      '}',
    ];
    final h = DocumentHighlighter(treeSitter: true)..update(java, lines, scheme: scheme, path: 'A.java');
    expect(h.debugHasTree, isTrue);
    // 逐行分词认不出字段
    expect(colorOf(h, 2, lines[2], 'count'), isNot(field));
    await settle(h);
    expect(colorOf(h, 1, lines[1], 'count'), field);
    expect(colorOf(h, 2, lines[2], 'count'), field, reason: 'this.count');
    expect(colorOf(h, 2, lines[2], 'out'), field, reason: 'System.out');
    expect(colorOf(h, 2, lines[2], 'println'), function);
    expect(colorOf(h, 2, lines[2], 'this'), keyword);
    expect(h.styleKeyAt(2), startsWith('t'));
    h.dispose();
  });

  test('a keystroke re-parses inline: the edited line has tree colors right away', () async {
    var lines = ['class A {', '  int v;', '  void f() { }', '}'];
    final h = DocumentHighlighter(treeSitter: true)..update(java, lines, scheme: scheme, path: 'A.java');
    await settle(h);
    lines = [...lines]..[2] = '  void f() { this.v = 1; }';
    h.update(java, lines, scheme: scheme, path: 'A.java');
    expect(colorOf(h, 2, lines[2], 'v ='), field);
    h.dispose();
  });

  test('after random edits the tree still matches the text line by line', () async {
    final rnd = Random(3);
    var lines = List.generate(200, (i) => 'final int a$i = $i;');
    final h = DocumentHighlighter(treeSitter: true)..update(java, lines, scheme: scheme, path: 'A.java');
    await settle(h);
    for (var step = 0; step < 200; step++) {
      final next = [...lines];
      final s = rnd.nextInt(next.length + 1);
      final del = min(rnd.nextInt(3), next.length - s);
      next.replaceRange(s, s + del, List.generate(rnd.nextInt(3), (k) => 'final int b${step}_$k = $k;'));
      if (rnd.nextBool() && next.isNotEmpty) {
        final i = rnd.nextInt(next.length);
        next[i] = 'final String c$step = "中文😀";';
      }
      lines = next;
      h.update(java, lines, scheme: scheme, path: 'A.java');
    }
    for (var i = 0; i < 400; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    for (var i = 0; i < lines.length; i++) {
      expect(h.styleKeyAt(i), startsWith('t'), reason: 'line $i uses the tree');
      expect(colorOf(h, i, lines[i], 'final'), keyword, reason: lines[i]);
      // 拼回来的文字和这一行一致(token 列号没错位)
      expect(h.spansAt(i).map((s) => s.text).join(), lines[i]);
    }
    final strLine = lines.indexWhere((l) => l.contains('😀'));
    if (strLine >= 0) {
      expect(colorOf(h, strLine, lines[strLine], '"中文'), scheme.styleOf(TokenKind.string)!.color);
    }
    h.dispose();
  });

  test('languages without a grammar keep the tokenizer only', () {
    final yaml = languages.detect('a.yaml');
    final h = DocumentHighlighter(treeSitter: true)..update(yaml, ['a: 1'], scheme: scheme, path: 'a.yaml');
    expect(h.debugHasTree, isFalse);
    expect(h.styleKeyAt(0), startsWith('s'));
    h.dispose();
  });

  test('switching language reopens the tree; markdown code blocks never open one', () async {
    final h = DocumentHighlighter(treeSitter: true)..update(java, ['class A {}'], scheme: scheme, path: 'A.java');
    expect(h.debugHasTree, isTrue);
    h.update(languages.detect('a.txt'), ['class A {}'], scheme: scheme, path: 'a.txt');
    expect(h.debugHasTree, isFalse);
    h.dispose();
    final md = DocumentHighlighter()..update(java, ['class A {}']);
    expect(md.debugHasTree, isFalse);
  });
}
