import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../core/ffi/rust_syntax.dart';
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
///
/// [treeSitter] 为真时(编辑器用),Java / Dart / JS / TS / Python / Go / Rust 另有一棵语法树在 Rust 里
/// (`SyntaxTreeDoc`,见 docs/rust-core.md 第 6 项):语法树跟上了的行按它着色(分得清字段、方法调用、
/// 字符串插值……),打开文件后第一次解析完之前、以及正在后台重解析的那几行,仍用上面的逐行分词。
class DocumentHighlighter {
  DocumentHighlighter({this.treeSitter = false});

  final bool treeSitter;

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

  /// 语法树换了(后台解析完)时 +1:编辑区据此重画。
  final ValueNotifier<int> repaint = ValueNotifier(0);

  SyntaxTreeDoc? _tree;
  String? _treeGrammar;
  int _treeGeneration = -1;
  Timer? _treePoll;

  /// 语法树给的各行 token(只存取过的行;语法树一变就清空)。值为 null = 这行用逐行分词。
  final Map<int, _TreeLine?> _treeLines = {};

  /// 语法树用哪个语法(`code_lite_syntax::NAMES`);没有对应语法的语言返回 null。
  static String? treeSitterGrammar(LanguageSpec lang, String? path) => switch (lang.id) {
        'java' || 'dart' || 'python' || 'go' || 'rust' || 'javascript' => lang.id,
        'typescript' => (path ?? '').toLowerCase().endsWith('.tsx') ? 'tsx' : 'typescript',
        _ => null,
      };

  /// 测试用:是否有语法树、语法树给了几行。
  @visibleForTesting
  bool get debugHasTree => _tree != null;

  void dispose() {
    _treePoll?.cancel();
    _treePoll = null;
    _tree?.close();
    _tree = null;
    repaint.dispose();
  }

  /// 折叠范围按 256 行一块缓存(语法树一变就清空)。
  final Map<int, List<FoldRange>> _foldChunks = {};
  static const _foldChunk = 256;

  /// 语法树已建好、后台也没在重解析(折叠范围可信,可以拿来核对收起的段)。
  bool get treeSettled {
    final t = _tree;
    if (t == null) return false;
    final st = t.status;
    return st & 1 == 0 && st >> 1 > 0;
  }

  /// 从第 [from, to) 行开始的折叠范围(起始行升序);没有语法树时为空。
  List<FoldRange> foldsIn(int from, int to) {
    final tree = _tree;
    if (tree == null || to <= from) return const [];
    final out = <FoldRange>[];
    for (var c = from ~/ _foldChunk; c * _foldChunk < to; c++) {
      final chunk = _foldChunks[c] ??= tree.folds(c * _foldChunk, (c + 1) * _foldChunk) ?? const [];
      for (final r in chunk) {
        if (r.start >= from && r.start < to) out.add(r);
      }
    }
    return out;
  }

  /// 第 [line] 行的样式标识:同一行文字着色不同时(块注释里外、语法树给的 token 不同)排版缓存要区分。
  String styleKeyAt(int line) {
    final t = _treeLineAt(line);
    return t != null ? 't${t.signature}' : 's${startStateAt(line)}';
  }

  _TreeLine? _treeLineAt(int line) {
    final tree = _tree;
    if (tree == null || line < 0 || line >= _lines.length) return null;
    if (_treeLines.containsKey(line)) return _treeLines[line];
    // 一次取一屏多:可见行一般连着取
    final from = line - 32 < 0 ? 0 : line - 32;
    final to = line + 160 > _lines.length ? _lines.length : line + 160;
    final slice = tree.highlight(from, to);
    for (var i = from; i < to; i++) {
      final raw = slice == null ? null : slice.lines[i - from];
      _treeLines[i] = raw == null ? null : _TreeLine.from(raw, _lines[i].length);
    }
    return _treeLines[line];
  }

  /// 语法树跟着文本走:换了语言 / 文件重新打开,改了几行就把那几行告诉 Rust。
  void _syncTree(LanguageSpec lang, String? path, List<String> lines, List<String> old, int p, int sfx, {required bool reopen}) {
    final grammar = treeSitter ? treeSitterGrammar(lang, path) : null;
    if (reopen || grammar != _treeGrammar) {
      _tree?.close();
      _tree = grammar == null ? null : SyntaxTreeDoc.open(grammar, lines);
      _treeGrammar = grammar;
    } else if (_tree != null) {
      _tree!.edit(p, old.length - p - sfx, lines.sublist(p, lines.length - sfx));
    } else {
      return;
    }
    _treeLines.clear();
    _foldChunks.clear();
    _watchTree();
  }

  /// 后台还在解析时每帧看一眼,解析完了丢掉缓存并通知重画。
  void _watchTree() {
    final tree = _tree;
    if (tree == null) return;
    final status = tree.status;
    _treeGeneration = status >> 1;
    if (status & 1 == 0 || _treePoll != null) return;
    _treePoll = Timer.periodic(const Duration(milliseconds: 16), (t) {
      final tr = _tree;
      if (tr == null) {
        t.cancel();
        _treePoll = null;
        return;
      }
      final st = tr.status;
      if (st >> 1 != _treeGeneration) {
        _treeGeneration = st >> 1;
        _treeLines.clear();
        _foldChunks.clear();
        repaint.value++;
      }
      if (st & 1 == 0) {
        t.cancel();
        _treePoll = null;
      }
    });
  }

  /// 测试用:缓存里有几行的着色片段。
  int get debugCachedSpanLines => _spanCache.length;

  /// 第 [line] 行开始时的分词状态(同一行文字在块注释里外着色不同,排版缓存要把它算进 key)。
  int startStateAt(int line) => line < _start.length ? _start[line] : 0;

  /// 第 [line] 行的着色片段。
  List<TextSpan> spansAt(int line) {
    final lang = _lang;
    if (lang == null || line >= _lines.length) return const [TextSpan(text: '')];
    final text = _lines[line];
    final tree = _treeLineAt(line);
    final state = _start[line];
    final key = tree != null ? 't${tree.signature}\u0000$text' : '$state\u0000$text';
    final cached = _spanCache.remove(key);
    if (cached != null) return _spanCache[key] = cached; // 重新插入 = 标为最近使用
    if (_spanCache.length >= spanCacheSize) _spanCache.remove(_spanCache.keys.first);
    final tokens = tree != null ? tree.tokens : tokenizeLine(lang, text, state).tokens;
    return _spanCache[key] = spansFor(text, tokens, _scheme ?? darculaScheme);
  }

  /// [path] 用来区分 .tsx(和 .ts 同一种语言,语法不同)。
  void update(LanguageSpec lang, List<String> lines, {EditorColorScheme? scheme, String? path}) {
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

    _syncTree(lang, path, lines, old, p, sfx, reopen: full);

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

/// 语法树给的一行 token。种类编码同 `code_lite_syntax::kind`。
class _TreeLine {
  _TreeLine(this.tokens, this.signature);

  final List<Token> tokens;

  /// 着色的指纹(缓存的 key)。
  final String signature;

  static const _kinds = [
    TokenKind.plain,
    TokenKind.keyword,
    TokenKind.type,
    TokenKind.constant,
    TokenKind.builtin,
    TokenKind.function,
    TokenKind.string,
    TokenKind.number,
    TokenKind.comment,
    TokenKind.docComment,
    TokenKind.annotation,
    TokenKind.field,
    TokenKind.tag,
    TokenKind.attribute,
  ];

  /// 越界(和 Rust 那边的文本对不上)时返回 null,这行退回逐行分词。
  static _TreeLine? from(Uint32List raw, int length) {
    final tokens = <Token>[];
    final sig = StringBuffer();
    var pos = 0;
    for (var i = 0; i + 2 < raw.length; i += 3) {
      final s = raw[i], e = raw[i + 1], k = raw[i + 2];
      if (s < pos || e > length || e <= s || k >= _kinds.length) return null;
      tokens.add(Token(s, e, _kinds[k]));
      sig
        ..write(s)
        ..write(',')
        ..write(e)
        ..write(',')
        ..write(k)
        ..write(';');
      pos = e;
    }
    return _TreeLine(tokens, sig.toString());
  }
}
