import 'package:flutter/painting.dart';

import 'language.dart';
import 'tokenizer.dart';

/// IntelliJ Darcula 的语法配色。
TextStyle? syntaxStyle(TokenKind kind) => switch (kind) {
      TokenKind.plain || TokenKind.punctuation => null,
      TokenKind.keyword || TokenKind.constant => const TextStyle(color: Color(0xFFCC7832)),
      TokenKind.type => const TextStyle(color: Color(0xFF9876AA)),
      TokenKind.field => const TextStyle(color: Color(0xFF9876AA), fontStyle: FontStyle.italic),
      TokenKind.builtin => const TextStyle(color: Color(0xFF8888C6)),
      TokenKind.function => const TextStyle(color: Color(0xFFFFC66D)),
      TokenKind.string || TokenKind.attrValue => const TextStyle(color: Color(0xFF6A8759)),
      TokenKind.number => const TextStyle(color: Color(0xFF6897BB)),
      TokenKind.comment || TokenKind.quote => const TextStyle(color: Color(0xFF808080), fontStyle: FontStyle.italic),
      TokenKind.docComment => const TextStyle(color: Color(0xFF629755), fontStyle: FontStyle.italic),
      TokenKind.annotation => const TextStyle(color: Color(0xFFBBB529)),
      TokenKind.variable => const TextStyle(color: Color(0xFF9876AA)),
      TokenKind.tag => const TextStyle(color: Color(0xFFE8BF6A)),
      TokenKind.attribute => const TextStyle(color: Color(0xFFBABABA)),
      TokenKind.entity => const TextStyle(color: Color(0xFF6D9CBE)),
      TokenKind.heading => const TextStyle(color: Color(0xFFCC7832), fontWeight: FontWeight.bold),
      TokenKind.bold => const TextStyle(fontWeight: FontWeight.bold),
      TokenKind.italic => const TextStyle(fontStyle: FontStyle.italic),
      TokenKind.link => const TextStyle(color: Color(0xFF287BDE)),
      TokenKind.codeSpan => const TextStyle(color: Color(0xFFA5C261)),
      TokenKind.listMarker || TokenKind.key || TokenKind.section => const TextStyle(color: Color(0xFFCC7832)),
    };

const Color syntaxDefaultColor = Color(0xFFA9B7C6);

/// 一个文档的高亮结果缓存。每次刷新只重新分词「改动的行」,
/// 以及其后因行首状态变了(比如新开了一个块注释)而受影响的行;状态一旦与旧结果一致就停止。
class DocumentHighlighter {
  LanguageSpec? _lang;
  List<String> _lines = const [];
  List<int> _start = const [];
  List<int> _end = const [];
  List<List<TextSpan>> _spans = const [];

  /// 最近一次 [update] 实际重新分词的行数(测试 / 性能观测用)。
  int lastRetokenized = 0;

  LanguageSpec? get language => _lang;

  /// 第 [line] 行的着色片段。
  List<TextSpan> spansAt(int line) => line < _spans.length ? _spans[line] : const [TextSpan(text: '')];

  /// 第 [line] 行开始时的分词状态(同一行文字在块注释里外着色不同,排版缓存要把它算进 key)。
  int startStateAt(int line) => line < _start.length ? _start[line] : 0;

  void update(LanguageSpec lang, List<String> lines) {
    if (identical(lang, _lang) && identical(lines, _lines)) {
      lastRetokenized = 0;
      return;
    }
    final full = !identical(lang, _lang);
    final old = full ? const <String>[] : _lines;
    final on = old.length, nn = lines.length;

    // 公共前缀 / 后缀:中间才是改动的部分。
    var p = 0;
    while (p < on && p < nn && old[p] == lines[p]) {
      p++;
    }
    var sfx = 0;
    while (sfx < on - p && sfx < nn - p && old[on - 1 - sfx] == lines[nn - 1 - sfx]) {
      sfx++;
    }

    final start = List<int>.filled(nn, 0);
    final end = List<int>.filled(nn, 0);
    final spans = List<List<TextSpan>>.filled(nn, const []);
    for (var i = 0; i < p; i++) {
      start[i] = _start[i];
      end[i] = _end[i];
      spans[i] = _spans[i];
    }
    var state = p == 0 ? 0 : _end[p - 1];
    var count = 0;
    for (var i = p; i < nn; i++) {
      final oi = i >= nn - sfx ? i - nn + on : -1;
      if (oi >= 0 && _start[oi] == state) {
        // 后缀与旧结果对齐且行首状态相同:后面都不会变,直接沿用。
        for (var j = i; j < nn; j++) {
          final oj = j - nn + on;
          start[j] = _start[oj];
          end[j] = _end[oj];
          spans[j] = _spans[oj];
        }
        break;
      }
      final r = tokenizeLine(lang, lines[i], state);
      start[i] = state;
      end[i] = r.endState;
      spans[i] = _toSpans(lines[i], r.tokens);
      state = r.endState;
      count++;
    }
    _lang = lang;
    _lines = lines;
    _start = start;
    _end = end;
    _spans = spans;
    lastRetokenized = count;
  }

  static List<TextSpan> _toSpans(String line, List<Token> tokens) {
    if (line.isEmpty) return const [TextSpan(text: '')];
    final out = <TextSpan>[];
    var pos = 0;
    for (final t in tokens) {
      if (t.start > pos) out.add(TextSpan(text: line.substring(pos, t.start)));
      out.add(TextSpan(text: line.substring(t.start, t.end), style: syntaxStyle(t.kind)));
      pos = t.end;
    }
    if (pos < line.length) out.add(TextSpan(text: line.substring(pos)));
    return out;
  }
}
