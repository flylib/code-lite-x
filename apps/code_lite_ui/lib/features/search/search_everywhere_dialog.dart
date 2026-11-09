import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/l10n.dart';
import '../../core/lsp/java_reference.dart';
import '../../core/theme/intellij_theme.dart';
import '../project_explorer/project_explorer_widget.dart' show fileTypeIconWidget;

/// Search Everywhere 的标签(IntelliJ 的 All / Classes / Files / Symbols / Actions)。
enum SearchTab {
  all('全部', 'All'),
  classes('类', 'Classes'),
  files('文件', 'Files'),
  symbols('符号', 'Symbols'),
  actions('操作', 'Actions');

  const SearchTab(this.zh, this.en);

  final String zh;
  final String en;

  String get label => tr(zh, en);
}

/// 一条结果的种类(决定图标)。
enum SearchHitKind { classType, method, field, symbol, file, action }

/// Search Everywhere 的一条结果:跳到 [path] 的 [line] / [col],或执行 [actionId]。
class SearchHit {
  const SearchHit({
    required this.kind,
    required this.title,
    this.detail,
    this.location,
    this.path,
    this.line,
    this.col,
    this.actionId,
    this.shortcut,
  });

  final SearchHitKind kind;
  final String title;

  /// 名字后面的灰字(`of com.foo.service`)。
  final String? detail;

  /// 最右边的灰字(所在目录、模块)。
  final String? location;

  final String? path;
  final int? line;
  final int? col;
  final String? actionId;

  /// 操作的快捷键(显示用)。
  final String? shortcut;

  /// 同一个位置算同一条(引用解析出来的和语言服务器给的可能重复)。
  String get key => actionId ?? '$path:${line ?? -1}:$title';
}

/// 各标签的数据来源(由应用提供,测试里换成假的)。文件和操作是同步的(Rust 文件索引、快捷键表),
/// 类和符号要问语言服务器,引用要读文件,是异步的。
class SearchSources {
  const SearchSources({
    required this.files,
    required this.classes,
    required this.symbols,
    required this.actions,
    required this.reference,
  });

  final List<SearchHit> Function(String query, int limit) files;
  final Future<List<SearchHit>> Function(String query) classes;
  final Future<List<SearchHit>> Function(String query) symbols;
  final List<SearchHit> Function(String query) actions;

  /// 输入的是 `com.foo.Bar#baz(...)` 这种引用(IntelliJ「复制引用」复制出来的)时:它指的类 / 方法。
  final Future<List<SearchHit>> Function(CodeReference reference) reference;
}

/// 弹出 Search Everywhere(IntelliJ 连按两下 Shift):顶上是标签,下面是输入框和结果。
/// 粘贴「复制引用」得到的 `com.foo.Bar#baz(com.foo.Dto)` 能直接定位到那个方法。
Future<SearchHit?> showSearchEverywhere(BuildContext context, {required SearchSources sources, SearchTab initialTab = SearchTab.all}) {
  return showDialog<SearchHit>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => SearchEverywhereDialog(sources: sources, initialTab: initialTab),
  );
}

class SearchEverywhereDialog extends StatefulWidget {
  const SearchEverywhereDialog({super.key, required this.sources, this.initialTab = SearchTab.all});

  final SearchSources sources;
  final SearchTab initialTab;

  @override
  State<SearchEverywhereDialog> createState() => _SearchEverywhereDialogState();
}

/// 列表里的一行:分组标题或结果。
class _Row {
  const _Row.header(this.header) : hit = null;
  const _Row.hit(SearchHit this.hit) : header = null;

  final String? header;
  final SearchHit? hit;
}

class _SearchEverywhereDialogState extends State<SearchEverywhereDialog> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late SearchTab _tab = widget.initialTab;

  List<SearchHit> _refs = const [];
  List<SearchHit> _classes = const [];
  List<SearchHit> _symbols = const [];
  List<SearchHit> _files = const [];
  List<SearchHit> _actions = const [];
  bool _searching = false;

  /// 选中的是第几条结果(不算分组标题)。
  int _selected = 0;
  int _generation = 0;
  Timer? _debounce;

  static const double _rowHeight = 28;
  static const int _allLimit = 6;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInput);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onInput() {
    final q = _input.text.trim();
    final gen = ++_generation;
    // 同步的先出来,异步的稍等一下再问(连续打字只问最后一次)
    setState(() {
      _files = q.isEmpty ? const [] : widget.sources.files(q, 50);
      _actions = q.isEmpty ? const [] : widget.sources.actions(q);
      if (q.isEmpty) {
        _refs = _classes = _symbols = const [];
      }
      _selected = 0;
      _searching = q.isNotEmpty;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _debounce?.cancel();
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 150), () => _runAsync(q, gen));
  }

  Future<void> _runAsync(String q, int gen) async {
    final ref = parseCodeReference(q);
    final results = await Future.wait([
      ref == null ? Future.value(const <SearchHit>[]) : widget.sources.reference(ref).catchError((_) => const <SearchHit>[]),
      // 引用的话按类名的简单名再问一遍语言服务器
      widget.sources.classes(ref?.simpleName ?? q).catchError((_) => const <SearchHit>[]),
      widget.sources.symbols(ref?.member ?? q).catchError((_) => const <SearchHit>[]),
    ]);
    if (!mounted || gen != _generation) return;
    setState(() {
      _refs = results[0];
      final seen = {for (final h in _refs) h.key};
      _classes = [for (final h in results[1]) if (seen.add(h.key)) h];
      _symbols = [for (final h in results[2]) if (seen.add(h.key)) h];
      _searching = false;
      _selected = 0;
    });
  }

  List<_Row> get _rows {
    switch (_tab) {
      case SearchTab.all:
        final rows = <_Row>[];
        void group(String title, List<SearchHit> hits) {
          if (hits.isEmpty) return;
          rows.add(_Row.header(title));
          rows.addAll(hits.take(_allLimit).map(_Row.hit));
        }
        rows.addAll(_refs.map(_Row.hit));
        group(SearchTab.classes.label, _classes);
        group(SearchTab.files.label, _files);
        group(SearchTab.symbols.label, _symbols);
        group(SearchTab.actions.label, _actions);
        return rows;
      case SearchTab.classes:
        return [for (final h in [..._refs.where((h) => h.kind == SearchHitKind.classType), ..._classes]) _Row.hit(h)];
      case SearchTab.files:
        return [for (final h in _files) _Row.hit(h)];
      case SearchTab.symbols:
        return [for (final h in [..._refs.where((h) => h.kind != SearchHitKind.classType), ..._symbols]) _Row.hit(h)];
      case SearchTab.actions:
        return [for (final h in _actions) _Row.hit(h)];
    }
  }

  List<SearchHit> get _hits => [for (final r in _rows) if (r.hit != null) r.hit!];

  void _setTab(SearchTab t) {
    setState(() {
      _tab = t;
      _selected = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _open([int? index]) {
    final hits = _hits;
    final i = index ?? _selected;
    if (i < 0 || i >= hits.length) return;
    Navigator.of(context).pop(hits[i]);
  }

  void _move(int delta) {
    final n = _hits.length;
    if (n == 0) return;
    setState(() => _selected = (_selected + delta).clamp(0, n - 1));
    if (!_scroll.hasClients) return;
    // 选中行在列表里的位置(分组标题也占一行)
    var row = 0, seen = -1;
    final rows = _rows;
    for (; row < rows.length; row++) {
      if (rows[row].hit != null && ++seen == _selected) break;
    }
    final top = row * _rowHeight;
    final pos = _scroll.position;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - pos.viewportDimension);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _move(10);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _move(-10);
    } else if (k == LogicalKeyboardKey.tab) {
      // Tab / ⇧Tab 换标签(同 IntelliJ)
      const tabs = SearchTab.values;
      final step = HardwareKeyboard.instance.isShiftPressed ? -1 : 1;
      _setTab(tabs[(tabs.indexOf(_tab) + step) % tabs.length]);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _open();
    } else if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final q = _input.text.trim();
    final empty = q.isNotEmpty && rows.isEmpty && !_searching;
    return Align(
      alignment: const Alignment(0, -0.55),
      child: Material(
        color: IntelliJTheme.popupBg,
        elevation: 12,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 720,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                child: Row(
                  children: [
                    for (final t in SearchTab.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: InkWell(
                          key: ValueKey('search-tab-${t.name}'),
                          onTap: () => _setTab(t),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: t == _tab ? IntelliJTheme.tabActiveBg : null,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: t == _tab ? IntelliJTheme.accentBlue : Colors.transparent),
                            ),
                            child: Text(t.label, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    key: const ValueKey('search-everywhere-input'),
                    controller: _input,
                    autofocus: true,
                    style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 14),
                    cursorColor: IntelliJTheme.caret,
                    onSubmitted: (_) => _open(),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18, color: IntelliJTheme.textMuted),
                      prefixIconConstraints: const BoxConstraints(minWidth: 32),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5, color: IntelliJTheme.textMuted)),
                            )
                          : null,
                      suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      hintText: tr('类名、文件名、符号、操作,或粘贴复制的引用', 'Class, file, symbol or action name, or a copied reference'),
                      hintStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 14),
                      filled: true,
                      fillColor: IntelliJTheme.islandBg,
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: IntelliJTheme.accentBlue)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: IntelliJTheme.accentBlue)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: IntelliJTheme.accentBlue)),
                    ),
                  ),
                ),
              ),
              if (empty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Text(tr('没有匹配的结果', 'Nothing found'),
                      key: const ValueKey('search-everywhere-empty'), style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5)),
                )
              else if (rows.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 14 * _rowHeight),
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 6),
                    itemExtent: _rowHeight,
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _row(rows, i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(List<_Row> rows, int i) {
    final r = rows[i];
    if (r.header != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(r.header!, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11.5)),
      );
    }
    final hit = r.hit!;
    final index = [for (var k = 0; k <= i; k++) if (rows[k].hit != null) k].length - 1;
    final selected = index == _selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _selected = index),
      child: GestureDetector(
        onTap: () => _open(index),
        child: Container(
          key: ValueKey('search-hit-${hit.key}'),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: selected ? const Color(0xFF2E436E) : null, borderRadius: BorderRadius.circular(5)),
          child: Row(
            children: [
              _icon(hit),
              const SizedBox(width: 8),
              Flexible(
                flex: 5,
                child: Text(hit.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13)),
              ),
              if (hit.detail != null) ...[
                const SizedBox(width: 6),
                Flexible(
                  flex: 5,
                  child: Text(hit.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5)),
                ),
              ],
              const Spacer(),
              if (hit.location != null || hit.shortcut != null)
                Flexible(
                  flex: 3,
                  child: Text(hit.shortcut ?? hit.location!,
                      maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 图标同 IntelliJ:类是蓝圈 C,方法红圈 m,字段黄圈 f,文件按类型,操作是闪电。
  Widget _icon(SearchHit hit) {
    Widget badge(String letter, Color color) => Container(
          width: 15,
          height: 15,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 1.3)),
          child: Text(letter, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700, height: 1)),
        );
    return switch (hit.kind) {
      SearchHitKind.classType => badge('C', const Color(0xFF6F9FF5)),
      SearchHitKind.method => badge('m', const Color(0xFFE5676E)),
      SearchHitKind.field => badge('f', IntelliJTheme.accentYellow),
      SearchHitKind.symbol => badge('s', IntelliJTheme.textSecondary),
      SearchHitKind.file => fileTypeIconWidget(hit.title, size: 15),
      SearchHitKind.action => const Icon(Icons.bolt, size: 15, color: IntelliJTheme.textSecondary),
    };
  }
}
