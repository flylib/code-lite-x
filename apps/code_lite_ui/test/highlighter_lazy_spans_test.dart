import 'dart:math';

import 'package:code_lite_ui/features/editor/syntax/color_schemes.dart';
import 'package:code_lite_ui/features/editor/syntax/document_highlighter.dart';
import 'package:code_lite_ui/features/editor/syntax/language.dart';
import 'package:code_lite_ui/features/editor/syntax/languages.dart';
import 'package:code_lite_ui/features/editor/syntax/tokenizer.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// 参照答案:从头到尾、整篇着色(就是改造前的做法)。
List<List<TextSpan>> eagerSpans(LanguageSpec lang, List<String> lines, EditorColorScheme scheme) {
  final out = <List<TextSpan>>[];
  var state = 0;
  for (final line in lines) {
    final r = tokenizeLine(lang, line, state);
    out.add(DocumentHighlighter.spansFor(line, r.tokens, scheme));
    state = r.endState;
  }
  return out;
}

String describe(List<TextSpan> spans) => spans.map((s) => '${s.text}|${s.style?.color?.toARGB32()}').join(' ');

void main() {
  final kotlin = languages.byId('kotlin')!;

  test('spans made on demand are exactly the eager ones, through random edits that open and close comments and strings', () {
    final rnd = Random(11);
    const pieces = ['val x = 1', '/* open', 'close */', '"""raw', 'end"""', '// note', 'fun f() {', '}', '"str \$name"', ''];
    var lines = [for (var i = 0; i < 120; i++) pieces[rnd.nextInt(pieces.length)]];
    final h = DocumentHighlighter();
    for (var step = 0; step < 300; step++) {
      h.update(kotlin, lines);
      final expected = eagerSpans(kotlin, lines, darculaScheme);
      // 只看一部分行(像视口那样),顺序也打乱
      for (var k = 0; k < 25; k++) {
        final i = rnd.nextInt(lines.length);
        expect(describe(h.spansAt(i)), describe(expected[i]), reason: 'step $step line $i');
      }
      lines = [...lines];
      switch (rnd.nextInt(3)) {
        case 0:
          lines[rnd.nextInt(lines.length)] = pieces[rnd.nextInt(pieces.length)];
        case 1:
          lines.insert(rnd.nextInt(lines.length + 1), pieces[rnd.nextInt(pieces.length)]);
        case 2:
          if (lines.length > 1) lines.removeAt(rnd.nextInt(lines.length));
      }
    }
  });

  test('a large document keeps no spans for lines nobody asked to draw', () {
    final lines = [for (var i = 0; i < 20000; i++) 'val v$i = "line $i" // comment'];
    final h = DocumentHighlighter()..update(kotlin, lines);
    expect(h.debugCachedSpanLines, 0, reason: '打开文件时只算分词状态,不做着色片段');
    for (var i = 1000; i < 1060; i++) {
      h.spansAt(i);
    }
    expect(h.debugCachedSpanLines, 60);
    // 一路滚完整个文件:缓存有上限,不会涨到两万行
    for (var i = 0; i < lines.length; i++) {
      h.spansAt(i);
    }
    expect(h.debugCachedSpanLines, lessThanOrEqualTo(DocumentHighlighter.spanCacheSize));
  });

  test('the same line drawn twice is served from the cache', () {
    final h = DocumentHighlighter()..update(kotlin, ['val a = 1', 'val b = 2']);
    final first = h.spansAt(0);
    expect(identical(h.spansAt(0), first), isTrue);
  });

  test('changing the colour scheme recolours without re-lexing', () {
    final java = languages.byId('java')!;
    final h = DocumentHighlighter()..update(java, const ['public int x = 1;']);
    expect(h.spansAt(0).first.style!.color, const Color(0xFFCC7832));
    h.update(java, const ['public int x = 1;'], scheme: colorSchemeById('monokai'));
    expect(h.lastRetokenized, 0, reason: '分词状态和配色无关');
    expect(h.spansAt(0).first.style!.color, const Color(0xFFF92672));
  });

  test('line states are still right after edits far from the line', () {
    final h = DocumentHighlighter();
    final lines = ['/* a', 'b', 'c */', 'val x = 1'];
    h.update(kotlin, lines);
    expect(h.startStateAt(1), isNot(0), reason: '第 1 行在注释里');
    expect(h.startStateAt(3), 0);
    final edited = [...lines]..[0] = 'val y = 2';
    h.update(kotlin, edited);
    expect(h.startStateAt(1), 0, reason: '注释没了,后面的行跟着变');
    expect(describe(h.spansAt(1)), describe(eagerSpans(kotlin, edited, darculaScheme)[1]));
  });

  test('out of range lines are empty, as before', () {
    final h = DocumentHighlighter()..update(kotlin, const ['val a = 1']);
    expect(h.spansAt(5).single.text, '');
    expect(h.startStateAt(5), 0);
  });
}
