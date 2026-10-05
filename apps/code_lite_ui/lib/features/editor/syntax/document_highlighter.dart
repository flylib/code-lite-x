import 'package:flutter/painting.dart';

import 'color_schemes.dart';
import 'language.dart';
import 'tokenizer.dart';

/// token 的样式(默认 Darcula;编辑区按设置里选的配色方案传入 [scheme])。
TextStyle? syntaxStyle(TokenKind kind, [EditorColorScheme? scheme]) => (scheme ?? darculaScheme).styleOf(kind);


/// 一个文档的高亮结果缓存。每次刷新只重新分词「改动的行」,
/// 以及其后因行首状态变了(比如新开了一个块注释)而受影响的行;状态一旦与旧结果一致就停止。
class DocumentHighlighter {
  LanguageSpec? _lang;
  EditorColorScheme? _scheme;
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

  void update(LanguageSpec lang, List<String> lines, {EditorColorScheme? scheme}) {
    final colors = scheme ?? darculaScheme;
    if (identical(lang, _lang) && identical(lines, _lines) && identical(colors, _scheme)) {
      lastRetokenized = 0;
      return;
    }
    // 换了语言或配色:全部重新着色
    final full = !identical(lang, _lang) || !identical(colors, _scheme);
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
      spans[i] = _toSpans(lines[i], r.tokens, colors);
      state = r.endState;
      count++;
    }
    _lang = lang;
    _scheme = colors;
    _lines = lines;
    _start = start;
    _end = end;
    _spans = spans;
    lastRetokenized = count;
  }

  static List<TextSpan> _toSpans(String line, List<Token> tokens, EditorColorScheme scheme) {
    if (line.isEmpty) return const [TextSpan(text: '')];
    final out = <TextSpan>[];
    var pos = 0;
    for (final t in tokens) {
      if (t.start > pos) out.add(TextSpan(text: line.substring(pos, t.start)));
      out.add(TextSpan(text: line.substring(t.start, t.end), style: scheme.styleOf(t.kind)));
      pos = t.end;
    }
    if (pos < line.length) out.add(TextSpan(text: line.substring(pos)));
    return out;
  }
}
