import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'color_schemes.dart';
import 'language.dart';
import 'tokenizer.dart';

/// token 的样式(默认 Darcula;编辑区按设置里选的配色方案传入 [scheme])。
TextStyle? syntaxStyle(TokenKind kind, [EditorColorScheme? scheme]) => (scheme ?? darculaScheme).styleOf(kind);

/// 一个文档的高亮。
///
/// 每一行只记两个整数:行首、行尾的分词状态(块注释 / 多行字符串会影响后面的行,所以状态要全文算)。
/// 着色片段([TextSpan])只为真正要画的行按需生成,放在一个有上限的缓存里。
/// 以前整篇文档的片段都常驻内存:2 万行的文件约 20 万个片段、近 30 MB,滚动时还拖慢垃圾回收。
///
/// 每次刷新只重新分词「改动的行」,以及其后因行首状态变了(比如新开了一个块注释)而受影响的行;
/// 状态一旦与旧结果一致就停止。
class DocumentHighlighter {
  /// 着色片段缓存最多存多少行:两个窗格的可见行加上下余量还绰绰有余。
  static const int spanCacheSize = 1024;

  LanguageSpec? _lang;
  EditorColorScheme? _scheme;
  List<String> _lines = const [];
  Int32List _start = Int32List(0);
  Int32List _end = Int32List(0);

  /// 「行首状态 + 行文本」→ 着色片段(LRU)。同样的文字在同样的状态下着色一定相同,
  /// 所以行号变了(上面插了一行)也能命中。
  final Map<String, List<TextSpan>> _spanCache = {};

  /// 最近一次 [update] 实际重新分词的行数(测试 / 性能观测用)。
  int lastRetokenized = 0;

  LanguageSpec? get language => _lang;

  /// 测试用:缓存里有几行的着色片段。
  int get debugCachedSpanLines => _spanCache.length;

  /// 第 [line] 行开始时的分词状态(同一行文字在块注释里外着色不同,排版缓存要把它算进 key)。
  int startStateAt(int line) => line < _start.length ? _start[line] : 0;

  /// 第 [line] 行的着色片段。
  List<TextSpan> spansAt(int line) {
    final lang = _lang;
    if (lang == null || line >= _lines.length) return const [TextSpan(text: '')];
    final text = _lines[line];
    final state = _start[line];
    final key = '$state\u0000$text';
    final cached = _spanCache.remove(key);
    if (cached != null) return _spanCache[key] = cached; // 重新插入 = 标为最近使用
    if (_spanCache.length >= spanCacheSize) _spanCache.remove(_spanCache.keys.first);
    return _spanCache[key] = spansFor(text, tokenizeLine(lang, text, state).tokens, _scheme ?? darculaScheme);
  }

  void update(LanguageSpec lang, List<String> lines, {EditorColorScheme? scheme}) {
    final colors = scheme ?? darculaScheme;
    if (!identical(colors, _scheme) || !identical(lang, _lang)) _spanCache.clear(); // 片段里带着颜色
    if (identical(lang, _lang) && identical(lines, _lines)) {
      _scheme = colors;
      lastRetokenized = 0;
      return;
    }
    // 换了语言:全部重新分词(配色不影响分词状态)
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

    final start = Int32List(nn);
    final end = Int32List(nn);
    if (p > 0) {
      start.setRange(0, p, _start);
      end.setRange(0, p, _end);
    }
    var state = p == 0 ? 0 : _end[p - 1];
    var count = 0;
    for (var i = p; i < nn; i++) {
      final oi = i >= nn - sfx ? i - nn + on : -1;
      if (oi >= 0 && _start[oi] == state) {
        // 后缀与旧结果对齐且行首状态相同:后面都不会变,直接沿用。
        start.setRange(i, nn, _start, oi);
        end.setRange(i, nn, _end, oi);
        break;
      }
      final endState = tokenizeLine(lang, lines[i], state).endState;
      start[i] = state;
      end[i] = endState;
      state = endState;
      count++;
    }
    _lang = lang;
    _scheme = colors;
    _lines = lines;
    _start = start;
    _end = end;
    lastRetokenized = count;
  }

  /// 一行文字和它的 token → 着色片段。
  static List<TextSpan> spansFor(String line, List<Token> tokens, EditorColorScheme scheme) {
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
