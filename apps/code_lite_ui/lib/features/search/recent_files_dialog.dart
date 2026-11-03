import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import '../project_explorer/project_explorer_widget.dart' show fileTypeIconWidget, speedSearchMatch;

/// Recent Files 里的一个文件。
class RecentFileItem {
  const RecentFileItem({required this.path, required this.name, required this.directory, this.detail});

  /// 选中后打开用的路径。
  final String path;
  final String name;

  /// 名字后面的灰字:同名文件的相对目录,或项目外文件的位置;不需要时为 null。
  final String? detail;

  /// 选中时底部显示的所在目录(`~/` 开头)。
  final String directory;
}

/// Recent Files 左边的一个工具窗。
class RecentToolItem {
  const RecentToolItem({required this.id, required this.label, required this.icon, this.shortcut});

  final String id;
  final String label;
  final Widget Function(Color color, double size) icon;

  /// 打开它的快捷键(显示用);没有就不显示。
  final String? shortcut;
}

/// 在 Recent Files 里选了什么:一个文件([split] 为 true 时在右侧拆分中打开),或一个工具窗。
class RecentFilesChoice {
  const RecentFilesChoice.file(String this.file, {this.split = false}) : tool = null;
  const RecentFilesChoice.tool(String this.tool)
      : file = null,
        split = false;

  final String? file;
  final bool split;
  final String? tool;
}

/// 弹出 Recent Files(IntelliJ 的 ⌘E):左边是工具窗,右边是最近打开的文件(新的在前)。
/// 打开时选中第二个文件(第一个就是当前文件,⌘E 回车 = 回到上一个文件)。
/// [toggleKeys] 是打开它的快捷键:弹出来以后再按一次切换「仅显示已编辑」。
Future<RecentFilesChoice?> showRecentFilesDialog(
  BuildContext context, {
  required List<RecentFileItem> files,
  required List<RecentFileItem> editedFiles,
  required List<RecentToolItem> tools,
  String? currentFile,
  List<ShortcutActivator> toggleKeys = const [],
  String? toggleLabel,
}) {
  return showDialog<RecentFilesChoice>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => RecentFilesDialog(
      files: files,
      editedFiles: editedFiles,
      tools: tools,
      currentFile: currentFile,
      toggleKeys: toggleKeys,
      toggleLabel: toggleLabel,
    ),
  );
}

class RecentFilesDialog extends StatefulWidget {
  const RecentFilesDialog({
    super.key,
    required this.files,
    required this.editedFiles,
    required this.tools,
    this.currentFile,
    this.toggleKeys = const [],
    this.toggleLabel,
  });

  final List<RecentFileItem> files;
  final List<RecentFileItem> editedFiles;
  final List<RecentToolItem> tools;
  final String? currentFile;
  final List<ShortcutActivator> toggleKeys;
  final String? toggleLabel;

  @override
  State<RecentFilesDialog> createState() => _RecentFilesDialogState();
}

class _RecentFilesDialogState extends State<RecentFilesDialog> {
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  bool _editedOnly = false;

  /// 打字就是快速搜索(同 IntelliJ):只留下名字匹配的工具窗和文件。
  String _query = '';

  /// 键盘在哪一栏:左边工具窗 / 右边文件。
  bool _inFiles = true;
  int _file = 0;
  int _tool = 0;
  int? _hoverFile;
  int? _hoverTool;

  static const double _rowHeight = 26;
  static const int _visibleRows = 20;

  @override
  void initState() {
    super.initState();
    final files = _files;
    _file = files.length > 1 && files.first.path == widget.currentFile ? 1 : 0;
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<RecentFileItem> get _source => _editedOnly ? widget.editedFiles : widget.files;

  List<RecentFileItem> get _files =>
      _query.isEmpty ? _source : [for (final f in _source) if (speedSearchMatch(f.name, _query) != null) f];

  List<RecentToolItem> get _tools =>
      _query.isEmpty ? widget.tools : [for (final t in widget.tools) if (speedSearchMatch(t.label, _query) != null) t];

  void _setQuery(String q) {
    setState(() {
      _query = q;
      _file = 0;
      _tool = 0;
      if (_files.isEmpty && _tools.isNotEmpty) _inFiles = false;
      if (_tools.isEmpty && _files.isNotEmpty) _inFiles = true;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _toggleEditedOnly() {
    setState(() {
      _editedOnly = !_editedOnly;
      _file = 0;
      _inFiles = true;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _openFile(int i, {bool split = false}) {
    final files = _files;
    if (i < 0 || i >= files.length) return;
    Navigator.of(context).pop(RecentFilesChoice.file(files[i].path, split: split));
  }

  void _openTool(int i) {
    final tools = _tools;
    if (i < 0 || i >= tools.length) return;
    Navigator.of(context).pop(RecentFilesChoice.tool(tools[i].id));
  }

  void _move(int delta) {
    setState(() {
      if (_inFiles) {
        final n = _files.length;
        if (n == 0) return;
        _file = (_file + delta).clamp(0, n - 1);
      } else {
        final n = _tools.length;
        if (n == 0) return;
        _tool = (_tool + delta).clamp(0, n - 1);
      }
    });
    if (!_inFiles || !_scroll.hasClients) return;
    final top = _file * _rowHeight;
    final pos = _scroll.position;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - pos.viewportDimension);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (widget.toggleKeys.any((k) => k.accepts(e, HardwareKeyboard.instance))) {
      _toggleEditedOnly();
      return KeyEventResult.handled;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _move(10);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _move(-10);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      if (_tools.isNotEmpty) setState(() => _inFiles = false);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      if (_files.isNotEmpty) setState(() => _inFiles = true);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _inFiles ? _openFile(_file) : _openTool(_tool);
    } else if (k == LogicalKeyboardKey.escape) {
      _query.isEmpty ? Navigator.of(context).pop() : _setQuery('');
    } else if (k == LogicalKeyboardKey.backspace) {
      if (_query.isNotEmpty) _setQuery(_query.substring(0, _query.length - 1));
    } else {
      final keys = HardwareKeyboard.instance;
      final ch = e.character;
      if (keys.isMetaPressed || keys.isControlPressed || ch == null || ch.isEmpty || ch.codeUnitAt(0) < 0x20 || ch.codeUnitAt(0) == 0x7f) {
        return KeyEventResult.ignored;
      }
      _setQuery(_query + ch);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final tools = _tools;
    final selected = _inFiles && _file < files.length ? files[_file] : null;
    const listHeight = _rowHeight * _visibleRows;
    return Align(
      alignment: const Alignment(0, -0.4),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
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
                _header(files.isEmpty && tools.isEmpty),
                const Divider(height: 1, thickness: 1, color: IntelliJTheme.border),
                SizedBox(
                  height: listHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 220,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemExtent: _rowHeight,
                          itemCount: tools.length,
                          itemBuilder: (_, i) => _toolRow(tools[i], i),
                        ),
                      ),
                      const VerticalDivider(width: 1, thickness: 1, color: IntelliJTheme.border),
                      Expanded(
                        child: files.isEmpty
                            ? Center(
                                child: Text(
                                  _editedOnly ? tr('没有编辑过的文件', 'No edited files') : tr('没有最近的文件', 'No recent files'),
                                  key: const ValueKey('recent-files-empty'),
                                  style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5),
                                ),
                              )
                            : ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                itemExtent: _rowHeight,
                                itemCount: files.length,
                                itemBuilder: (_, i) => _fileRow(files[i], i),
                              ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, thickness: 1, color: IntelliJTheme.border),
                Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    selected?.directory ?? '',
                    key: const ValueKey('recent-files-location'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(bool noMatch) {
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Text(
              _editedOnly ? tr('最近编辑的文件', 'Recently Edited Files') : tr('最近的文件', 'Recent Files'),
              style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            if (_query.isNotEmpty) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Container(
                  key: const ValueKey('recent-files-query'),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: IntelliJTheme.islandBg, borderRadius: BorderRadius.circular(4), border: Border.all(color: IntelliJTheme.border)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search, size: 13, color: IntelliJTheme.textMuted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _query,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: noMatch ? IntelliJTheme.diagError : IntelliJTheme.textHigh, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const Spacer(),
            InkWell(
              key: const ValueKey('recent-files-edited-only'),
              onTap: _toggleEditedOnly,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: _editedOnly ? IntelliJTheme.accentBlue : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: _editedOnly ? IntelliJTheme.accentBlue : IntelliJTheme.textMuted),
                      ),
                      child: _editedOnly ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
                    ),
                    const SizedBox(width: 6),
                    Text(tr('仅显示已编辑', 'Show edited only'), style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5)),
                    if (widget.toggleLabel != null) ...[
                      const SizedBox(width: 6),
                      Text(widget.toggleLabel!, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration? _rowDecoration({required bool selected, required bool hovered}) {
    if (!selected && !hovered) return null;
    return BoxDecoration(
      color: selected ? const Color(0xFF2E436E) : IntelliJTheme.hoverBg,
      borderRadius: BorderRadius.circular(5),
    );
  }

  Widget _toolRow(RecentToolItem tool, int i) {
    final selected = !_inFiles && i == _tool;
    final indices = _query.isEmpty ? null : speedSearchMatch(tool.label, _query);
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverTool = i),
      onExit: (_) => setState(() => _hoverTool = null),
      child: GestureDetector(
        onTap: () => _openTool(i),
        child: Container(
          key: ValueKey('recent-tool-${tool.id}'),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: _rowDecoration(selected: selected, hovered: _hoverTool == i),
          child: Row(
            children: [
              tool.icon(IntelliJTheme.textPrimary, 16),
              const SizedBox(width: 8),
              Expanded(child: _highlighted(tool.label, indices, const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13))),
              if (tool.shortcut != null) ...[
                const SizedBox(width: 6),
                Text(tool.shortcut!, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileRow(RecentFileItem file, int i) {
    final selected = _inFiles && i == _file;
    final hovered = _hoverFile == i;
    final indices = _query.isEmpty ? null : speedSearchMatch(file.name, _query);
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverFile = i),
      onExit: (_) => setState(() => _hoverFile = null),
      child: GestureDetector(
        onTap: () => _openFile(i),
        child: Container(
          key: ValueKey('recent-file-${file.path}'),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.only(left: 8, right: 4),
          decoration: _rowDecoration(selected: selected, hovered: hovered),
          child: Row(
            children: [
              fileTypeIconWidget(file.name, size: 15),
              const SizedBox(width: 8),
              Flexible(child: _highlighted(file.name, indices, const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13))),
              if (file.detail != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(file.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
                ),
              ],
              const Spacer(),
              if (selected || hovered)
                Tooltip(
                  message: tr('在右侧拆分中打开', 'Open in Right Split'),
                  child: InkWell(
                    key: ValueKey('recent-file-split-${file.path}'),
                    onTap: () => _openFile(i, split: true),
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.vertical_split_outlined, size: 15, color: IntelliJTheme.textMuted),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 快速搜索匹配上的字符标黄(同文件树的快速搜索)。
  Widget _highlighted(String text, List<int>? indices, TextStyle style) {
    if (indices == null || indices.isEmpty) return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    final hit = style.copyWith(color: const Color(0xFFE8BA36), fontWeight: FontWeight.w600);
    final marks = indices.toSet();
    return Text.rich(
      TextSpan(children: [
        for (var i = 0; i < text.length; i++) TextSpan(text: text[i], style: marks.contains(i) ? hit : style),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
