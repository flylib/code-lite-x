import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/intellij_theme.dart';
import '../project_explorer/project_explorer_widget.dart' show fileTypeIconWidget;

/// 按文件名查找:给查询词和条数,返回 Rust 文件索引的结果(`ApiClient.fileIndexQuery`)。
typedef FileQuery = Map<String, dynamic> Function(String query, int limit);

/// Go to File 选中的文件和(可选的)行号、列号(从 `Foo.java:120:5` 里来,1 起)。
class GotoFileTarget {
  const GotoFileTarget(this.path, {this.line, this.column});

  final String path;
  final int? line;
  final int? column;
}

/// 把 `Foo.java:120:5` 拆成查询词和行列号(IntelliJ 的写法)。
(String, int?, int?) parseGotoQuery(String raw) {
  final m = RegExp(r'^(.*?):(\d+)(?::(\d+))?\s*$').firstMatch(raw);
  if (m == null) return (raw.trim(), null, null);
  return (m.group(1)!.trim(), int.parse(m.group(2)!), m.group(3) == null ? null : int.parse(m.group(3)!));
}

/// 弹出 Go to File(IntelliJ 的 ⇧⌘O):输入文件名模糊查找,回车打开。
/// [recent]:没输入时列出的最近打开的文件(相对路径)。
Future<GotoFileTarget?> showGotoFileDialog(
  BuildContext context, {
  required FileQuery query,
  VoidCallback? refresh,
  List<String> recent = const [],
}) {
  return showDialog<GotoFileTarget>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => GotoFileDialog(query: query, refresh: refresh, recent: recent),
  );
}

class GotoFileDialog extends StatefulWidget {
  const GotoFileDialog({super.key, required this.query, this.refresh, this.recent = const []});

  final FileQuery query;

  /// 打开时让 Rust 后台重扫一遍清单(新建 / 删掉的文件跟上)。
  final VoidCallback? refresh;
  final List<String> recent;

  @override
  State<GotoFileDialog> createState() => _GotoFileDialogState();
}

class _Hit {
  const _Hit(this.path, this.indices);

  final String path;
  final Set<int> indices;
}

class _GotoFileDialogState extends State<GotoFileDialog> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<_Hit> _hits = const [];
  int _selected = 0;
  bool _ready = true;
  int _files = 0;
  String? _error;

  /// 清单还没建好 / 正在后台重扫时,隔一会儿再查一次,建好后结果自动出来。
  Timer? _poll;
  int _generation = -1;
  int _polls = 0;

  static const int _limit = 50;
  static const double _rowHeight = 30;

  @override
  void initState() {
    super.initState();
    widget.refresh?.call();
    _run();
    _input.addListener(_run);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _run() {
    final (q, _, _) = parseGotoQuery(_input.text);
    if (q.isEmpty) {
      setState(() {
        _hits = [for (final p in widget.recent) _Hit(p, const {})];
        _selected = 0;
        _error = null;
      });
      _schedulePoll();
      return;
    }
    final r = widget.query(q, _limit);
    if (r['status'] != 'ok') {
      setState(() {
        _error = r['error'] as String? ?? '查找失败';
        _hits = const [];
      });
      return;
    }
    setState(() {
      _error = null;
      _ready = r['ready'] == true;
      _files = (r['files'] as num?)?.toInt() ?? 0;
      _generation = (r['generation'] as num?)?.toInt() ?? _generation;
      _hits = [
        for (final h in (r['results'] as List? ?? const []))
          _Hit(h['path'] as String, {for (final i in (h['indices'] as List? ?? const [])) (i as num).toInt()}),
      ];
      _selected = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _schedulePoll();
  }

  /// 清单没建好,或打开时触发的后台重扫还没完成:过一会儿再查(最多约 5 秒)。
  void _schedulePoll() {
    _poll?.cancel();
    if (_polls > 50) return;
    _poll = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      _polls++;
      final (q, _, _) = parseGotoQuery(_input.text);
      final probe = widget.query(q.isEmpty ? '\u0000' : q, 1);
      final gen = (probe['generation'] as num?)?.toInt() ?? _generation;
      final ready = probe['ready'] == true;
      final building = probe['building'] == true;
      if (ready != _ready || gen != _generation) {
        _run(); // 清单换了:重新查
      } else if (!ready || building) {
        _schedulePoll();
      }
    });
  }

  void _open([int? index]) {
    final i = index ?? _selected;
    if (i < 0 || i >= _hits.length) return;
    final (_, line, col) = parseGotoQuery(_input.text);
    Navigator.of(context).pop(GotoFileTarget(_hits[i].path, line: line, column: col));
  }

  void _move(int delta) {
    if (_hits.isEmpty) return;
    setState(() => _selected = (_selected + delta).clamp(0, _hits.length - 1));
    if (!_scroll.hasClients) return;
    final top = _selected * _rowHeight;
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
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _open();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final (q, _, _) = parseGotoQuery(_input.text);
    final String? hint = _error ??
        (!_ready
            ? '正在建立文件索引…'
            : q.isEmpty
                ? (widget.recent.isEmpty ? '输入文件名;可加 / 按路径找,加 :行号 跳到那一行' : null)
                : _hits.isEmpty
                    ? '没有匹配的文件($_files 个文件中)'
                    : null);
    return Align(
      alignment: const Alignment(0, -0.55),
      child: Material(
        color: IntelliJTheme.popupBg,
        elevation: 12,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 640,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Row(
                  children: [
                    const Text('Files', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (_ready && _files > 0) Text('$_files 个文件', style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11.5)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    key: const ValueKey('goto-file-input'),
                    controller: _input,
                    autofocus: true,
                    style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 14),
                    cursorColor: IntelliJTheme.caret,
                    onSubmitted: (_) => _open(),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18, color: IntelliJTheme.textMuted),
                      prefixIconConstraints: const BoxConstraints(minWidth: 32),
                      hintText: '文件名',
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
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                  child: Text(hint, key: const ValueKey('goto-file-hint'), style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5)),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 12 * _rowHeight),
                  child: ListView.builder(
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 6),
                    itemExtent: _rowHeight,
                    itemCount: _hits.length,
                    itemBuilder: (context, i) => _row(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(int i) {
    final hit = _hits[i];
    final slash = hit.path.lastIndexOf('/');
    final name = hit.path.substring(slash + 1);
    final dir = slash < 0 ? '' : hit.path.substring(0, slash);
    final selected = i == _selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _selected = i),
      child: GestureDetector(
        onTap: () => _open(i),
        child: Container(
          key: ValueKey('goto-file-row-${hit.path}'),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2E436E) : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              fileTypeIconWidget(name, size: 15),
              const SizedBox(width: 8),
              Flexible(
                flex: 3,
                child: _highlighted(name, slash + 1, hit.indices, const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13)),
              ),
              if (dir.isNotEmpty) ...[
                const SizedBox(width: 10),
                Flexible(
                  flex: 4,
                  child: _highlighted(dir, 0, hit.indices, const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// [text] 是整个路径里从 [offset] 开始的一段;[indices] 是整个路径里匹配上的字符(UTF-16 下标)。
  Widget _highlighted(String text, int offset, Set<int> indices, TextStyle style) {
    if (indices.isEmpty) return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    final hit = style.copyWith(color: const Color(0xFFE8BA36), fontWeight: FontWeight.w600);
    final spans = <TextSpan>[];
    final buf = StringBuffer();
    bool? on;
    for (var i = 0; i < text.length; i++) {
      final h = indices.contains(offset + i);
      if (on != null && h != on) {
        spans.add(TextSpan(text: buf.toString(), style: on ? hit : style));
        buf.clear();
      }
      on = h;
      buf.write(text[i]);
    }
    if (buf.isNotEmpty) spans.add(TextSpan(text: buf.toString(), style: on == true ? hit : style));
    return Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
