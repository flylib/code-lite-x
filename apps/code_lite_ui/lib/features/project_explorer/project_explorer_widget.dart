import '../../core/build_tools/makefile.dart' show isMakefileName;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/keymap/keymap.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/context_menu_region.dart' show darculaMenuTheme;
import '../editor/syntax/languages.dart';
import '../tool_window/tool_window_actions.dart';
import 'rename_dialog.dart';
import '../../core/l10n/l10n.dart';

/// 左侧 Project 文件树。
///
/// - 展开状态按完整路径记(以前按目录名记,所有叫 `src` 的目录会一起展开);
/// - 初次扫描只到几层深,更深的目录(`loaded: false`)展开时再经 [onLoadChildren] 读取;
/// - Java / Kotlin 源码根(`src/main/java`)下只有一个子目录的包链压成一行,如 `com.acme.app`,与 IntelliJ 一致;
/// - 文件图标按语法引擎识别出的语言区分;
/// - 快速搜索(IntelliJ 的 speed search):点一下文件树让它获得焦点,直接打字就在展开着的节点里找,
///   选中跳到第一个匹配,↑↓ 在匹配之间跳,回车打开,Esc 退出。只在文件树有焦点时生效。
/// - 右键菜单(IntelliJ 的项目视图菜单),目前有 Rename(⇧F6)。
class ProjectExplorerWidget extends StatefulWidget {
  final Map<String, dynamic> treeData;
  final String activeFilePath;
  final ValueChanged<String> onSelectFile;

  /// 读取一个还没扫描的目录,返回该目录节点(含 children)。
  final Future<Map<String, dynamic>> Function(String path)? onLoadChildren;

  /// 把 [path] 改名为同一目录下的 `newName`,返回失败原因(null 成功)。不传(单独打开的文件)就不能改名。
  final Future<String?> Function(String path, String newName)? onRename;

  /// 快捷键表(⇧F6 改名);不传按默认键位。
  final KeymapStore? keymap;

  const ProjectExplorerWidget({
    super.key,
    required this.treeData,
    required this.activeFilePath,
    required this.onSelectFile,
    this.onLoadChildren,
    this.onRename,
    this.keymap,
  });

  @override
  State<ProjectExplorerWidget> createState() => _ProjectExplorerWidgetState();
}

class _ProjectExplorerWidgetState extends State<ProjectExplorerWidget> {
  final Set<String> _expanded = {};
  bool _rootCollapsed = false;

  /// 展开时按需读到的子节点(path → children)。
  final Map<String, List<Map<String, dynamic>>> _lazy = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};

  static const _sourceRoots = {'java', 'kotlin', 'scala', 'groovy'};

  @override
  void didUpdateWidget(ProjectExplorerWidget old) {
    super.didUpdateWidget(old);
    if (!identical(old.treeData, widget.treeData)) {
      // 重新扫描过(换项目或刷新):按需读的结果作废,展开状态在同一项目里保留。
      _lazy.clear();
      _failed.clear();
      if (old.treeData['path'] != widget.treeData['path']) {
        _expanded.clear();
        _rootCollapsed = false;
      }
    }
  }

  List<Map<String, dynamic>>? _childrenOf(Map<String, dynamic> node) {
    if (node['loaded'] == false) return _lazy[node['path'] as String? ?? ''];
    return (node['children'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? const [];
  }

  Future<void> _load(String path) async {
    final loader = widget.onLoadChildren;
    if (loader == null || _loading.contains(path) || _lazy.containsKey(path)) return;
    setState(() => _loading.add(path));
    try {
      final node = await loader(path);
      if (!mounted) return;
      setState(() {
        _lazy[path] = (node['children'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? const [];
        _loading.remove(path);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading.remove(path);
        _failed.add(path);
      });
    }
  }

  void _toggle(String path, Map<String, dynamic> node, {required bool isRoot}) {
    setState(() {
      if (isRoot) {
        _rootCollapsed = !_rootCollapsed;
      } else if (!_expanded.remove(path)) {
        _expanded.add(path);
      }
    });
    if (_isExpanded(path, isRoot: isRoot) && node['loaded'] == false) _load(path);
  }

  bool _isExpanded(String path, {required bool isRoot}) => isRoot ? !_rootCollapsed : _expanded.contains(path);

  // --- 焦点、选中行与快速搜索 ----------------------------------------------------------

  final FocusNode _focus = FocusNode(debugLabel: 'project-tree');
  final ScrollController _scroll = ScrollController();

  /// 键盘选中的行(路径);和编辑器里打开的文件([ProjectExplorerWidget.activeFilePath])是两回事。
  String? _selected;

  /// 快速搜索的输入;空串 = 没在搜。
  String _query = '';

  static const double _rowHeight = 24;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // 失去焦点就退出搜索(和 IntelliJ 一样)
      if (!_focus.hasFocus && _query.isNotEmpty) setState(() => _query = '');
      setState(() {});
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_Row> _rows() {
    final rows = <_Row>[];
    if (widget.treeData.isNotEmpty) _addRows(rows, widget.treeData, 0, isRoot: true, inSourceRoot: false);
    return rows;
  }

  void _activate(_Row r) {
    if (r.isDir) {
      _toggle(r.path, r.node!, isRoot: r.isRoot);
    } else if (r.isFile) {
      widget.onSelectFile(r.path);
    }
  }

  void _select(String path, List<_Row> rows) {
    setState(() => _selected = path);
    final i = rows.indexWhere((r) => r.path == path);
    if (i < 0 || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = 4 + i * _rowHeight;
    if (top < pos.pixels) {
      _scroll.jumpTo(top - 4);
    } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo((top + _rowHeight - pos.viewportDimension + 4).clamp(0.0, pos.maxScrollExtent));
    }
  }

  /// 搜索词变了:选中的还匹配就不动,否则从它开始往下找第一个匹配(找不到从头找)。
  void _searchFrom(List<_Row> rows, {int step = 0}) {
    final hits = [
      for (var i = 0; i < rows.length; i++)
        if (rows[i].selectable && speedSearchMatch(rows[i].name, _query) != null) i
    ];
    if (hits.isEmpty) {
      setState(() {});
      return;
    }
    final cur = rows.indexWhere((r) => r.path == _selected);
    int pick;
    if (step == 0) {
      pick = hits.contains(cur) ? cur : hits.firstWhere((i) => i >= cur, orElse: () => hits.first);
    } else if (step > 0) {
      pick = hits.firstWhere((i) => i > cur, orElse: () => hits.first);
    } else {
      pick = hits.lastWhere((i) => i < cur, orElse: () => hits.last);
    }
    _select(rows[pick].path, rows);
  }

  // --- 右键菜单与改名 -------------------------------------------------------------------

  final MenuController _menu = MenuController();
  _Row? _menuRow;

  static final KeymapStore _defaultKeymap = KeymapStore();
  KeymapStore get _keymap => widget.keymap ?? _defaultKeymap;

  bool _isShortcut(String id, KeyEvent e) => _keymap.shortcutsOf(id).any((k) => k.activator.accepts(e, HardwareKeyboard.instance));

  /// 项目根(改的是整个项目目录)和单独打开的文件不能在这里改名。
  bool _canRename(_Row r) => widget.onRename != null && r.selectable && !r.isRoot;

  bool _isControlClick(PointerDownEvent e) =>
      defaultTargetPlatform == TargetPlatform.macOS && e.buttons == kPrimaryButton && HardwareKeyboard.instance.isControlPressed;

  /// 右键点在哪一行:选中它,在点的地方弹菜单(同 IntelliJ,右键也会改变选中)。
  void _openMenu(Offset local) {
    if (!_scroll.hasClients) return;
    final rows = _rows();
    final i = ((local.dy + _scroll.position.pixels - 4) / _rowHeight).floor();
    if (i < 0 || i >= rows.length || !rows[i].selectable) return;
    _focus.requestFocus();
    setState(() {
      _selected = rows[i].path;
      _menuRow = rows[i];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menu.open(position: local);
    });
  }

  List<Widget> _menuItems() {
    final r = _menuRow;
    if (r == null) return const [];
    final keys = _keymap.shortcutsOf(KeymapIds.rename);
    return [
      MenuItemButton(
        key: const ValueKey('tree-menu-rename'),
        onPressed: _canRename(r) ? () => _rename(r) : null,
        shortcut: keys.isEmpty ? null : keys.first.activator as SingleActivator,
        child: Text(tr('重命名...', 'Rename...')),
      ),
    ];
  }

  /// 弹 Rename 对话框;改成功后选中新名字,展开着的目录(和它下面展开的)保持展开。
  /// 压成一行的包(`com.acme.app`)改的是最后一级目录。
  Future<void> _rename(_Row r) async {
    final onRename = widget.onRename;
    if (onRename == null || !_canRename(r)) return;
    final slash = r.path.lastIndexOf('/');
    final name = r.path.substring(slash + 1);
    final newName = await showRenameDialog(context, name: name, isDir: r.isDir, onRename: (n) => onRename(r.path, n));
    if (!mounted) return;
    if (newName != null) {
      final to = '${r.path.substring(0, slash + 1)}$newName';
      setState(() {
        final moved = {
          for (final p in _expanded)
            if (p == r.path || p.startsWith('${r.path}/')) p
        };
        _expanded
          ..removeAll(moved)
          ..addAll([for (final p in moved) '$to${p.substring(r.path.length)}']);
        _selected = to;
      });
    }
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e is KeyDownEvent && _isShortcut(KeymapIds.rename, e)) {
      final row = _rows().where((r) => r.selectable && r.path == _selected).firstOrNull;
      if (row == null || !_canRename(row)) return KeyEventResult.ignored;
      if (_query.isNotEmpty) setState(() => _query = '');
      _rename(row);
      return KeyEventResult.handled;
    }
    final kb = HardwareKeyboard.instance;
    if (kb.isMetaPressed || kb.isControlPressed) return KeyEventResult.ignored; // ⌘1 之类交给应用快捷键
    final rows = _rows();
    final selectable = [
      for (final r in rows)
        if (r.selectable) r
    ];
    if (selectable.isEmpty) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final cur = selectable.indexWhere((r) => r.path == _selected);
    final row = cur < 0 ? null : selectable[cur];
    final searching = _query.isNotEmpty;

    if (key == LogicalKeyboardKey.escape) {
      if (!searching) return KeyEventResult.ignored;
      setState(() => _query = '');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      final down = key == LogicalKeyboardKey.arrowDown;
      if (searching) {
        _searchFrom(rows, step: down ? 1 : -1);
      } else {
        final next = cur < 0 ? 0 : (cur + (down ? 1 : -1)).clamp(0, selectable.length - 1);
        _select(selectable[next].path, rows);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (row != null) _activate(row);
      if (searching) setState(() => _query = '');
      return KeyEventResult.handled;
    }
    if (!searching && row != null && (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowLeft)) {
      final right = key == LogicalKeyboardKey.arrowRight;
      if (row.isDir && row.expanded != right) {
        _toggle(row.path, row.node!, isRoot: row.isRoot); // → 展开 / ← 收起
      } else if (!right) {
        // ← 在文件或收起的目录上:跳到上一级目录
        final i = rows.indexOf(row);
        for (var j = i - 1; j >= 0; j--) {
          if (rows[j].isDir && rows[j].depth < row.depth) {
            _select(rows[j].path, rows);
            break;
          }
        }
      } else if (row.isDir && cur + 1 < selectable.length) {
        _select(selectable[cur + 1].path, rows); // → 在展开的目录上:进到第一个子节点
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      if (!searching) return KeyEventResult.ignored;
      setState(() => _query = _query.substring(0, _query.length - 1));
      if (_query.isNotEmpty) _searchFrom(_rows());
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (ch != null && ch.length == 1 && ch.codeUnitAt(0) > 0x20 && ch.codeUnitAt(0) != 0x7f) {
      setState(() => _query += ch);
      _searchFrom(rows);
      return KeyEventResult.handled;
    }
    if (ch == ' ' && searching) {
      setState(() => _query += ' ');
      _searchFrom(rows);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    final noMatch = _query.isNotEmpty && !rows.any((r) => r.selectable && speedSearchMatch(r.name, _query) != null);
    // 宽度与右侧分隔线由外层统一给出(可拖动调整)。
    return Container(
      color: IntelliJTheme.panelBg,
      child: Column(
        children: [
          // Tool window header
          // IntelliJ 新 UI:标题栏和内容同一块底色,没有分隔线
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 6),
            // 侧栏可拖窄到 160px:标题可省略,按钮用 InkWell 不占 Material 默认的大点击区。
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    tr('项目', 'Project'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, size: 16, color: IntelliJTheme.textMuted),
                const Spacer(),
                Tooltip(
                  message: tr('全部折叠', 'Collapse All'),
                  child: InkWell(
                    onTap: () => setState(_expanded.clear),
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.unfold_less, size: 14, color: IntelliJTheme.textMuted),
                    ),
                  ),
                ),
                const ToolWindowActions(),
              ],
            ),
          ),

          // Tree contents:扁平的行列表,只构建看得见的行。点一下获得焦点,之后打字就是快速搜索。
          Expanded(
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              // 按下就拿焦点(Listener 不参与手势竞争,不影响行上的点击)
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  _focus.requestFocus();
                  // macOS 上按住 Control 单击也是右键(触控板双指轻点系统本来就当右键发过来)
                  if (_isControlClick(e)) _openMenu(e.localPosition);
                },
                child: Theme(
                  data: darculaMenuTheme(Theme.of(context)),
                  child: MenuAnchor(
                    controller: _menu,
                    consumeOutsideTap: true,
                    menuChildren: _menuItems(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onSecondaryTapDown: (d) => _openMenu(d.localPosition),
                      child: Stack(
                        children: [
                          ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemExtent: _rowHeight,
                            itemCount: rows.length,
                            itemBuilder: (context, i) => _buildRow(rows[i]),
                          ),
                          if (_query.isNotEmpty)
                            Positioned(
                              top: 4,
                              left: 8,
                              right: 8,
                              child: _SearchField(query: _query, noMatch: noMatch),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addRows(List<_Row> rows, Map<String, dynamic> node, int depth, {required bool isRoot, required bool inSourceRoot}) {
    final isDir = node['is_dir'] as bool? ?? false;
    if (!isDir) {
      final name = node['name'] as String? ?? '';
      rows.add(_Row.file(node['path'] as String? ?? name, name, depth));
      return;
    }
    var name = node['name'] as String? ?? '';
    var dir = node;
    // 源码根下的包:只有一个子目录、没有文件的链压成 com.acme.app
    if (inSourceRoot) {
      while (true) {
        final kids = _childrenOf(dir);
        if (kids == null || kids.length != 1 || kids.first['is_dir'] != true) break;
        dir = kids.first;
        name = '$name.${dir['name']}';
      }
    }
    final path = dir['path'] as String? ?? name;
    final expanded = _isExpanded(path, isRoot: isRoot);
    rows.add(_Row.dir(path, name, depth, dir, expanded: expanded, isRoot: isRoot, isPackage: inSourceRoot));
    if (!expanded) return;

    final kids = _childrenOf(dir);
    if (kids == null) {
      // 还没读(比如重新扫描后仍处于展开状态):补读一次
      if (!_loading.contains(path) && !_failed.contains(path)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load(path));
      }
      rows.add(_Row.hint(_failed.contains(path) ? tr('无法读取', 'Cannot read') : tr('加载中…', 'Loading…'), depth + 1));
      return;
    }
    final childInSource = inSourceRoot || _sourceRoots.contains(dir['name']);
    for (final child in kids) {
      _addRows(rows, child, depth + 1, isRoot: false, inSourceRoot: childInSource && child['is_dir'] == true);
    }
  }

  Widget _buildRow(_Row r) {
    if (r.kind == _RowKind.hint) return _hintRow(r.name, r.depth);
    final selected = r.path == _selected;
    final hits = _query.isEmpty ? null : speedSearchMatch(r.name, _query);
    Widget tap(Widget child) => InkWell(
          key: ValueKey('${r.isDir ? 'dir' : 'file'}:${r.path}'),
          onTap: () {
            // Control+单击是弹菜单,不是打开
            if (defaultTargetPlatform == TargetPlatform.macOS && HardwareKeyboard.instance.isControlPressed) return;
            _focus.requestFocus();
            setState(() => _selected = r.path);
            _activate(r);
          },
          child: Container(
            decoration: BoxDecoration(
              color: selected ? (_focus.hasFocus ? _selectedFocused : _selectedIdle) : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: child,
          ),
        );
    return r.isDir ? tap(_dirRow(r, hits)) : tap(_fileRow(r, hits));
  }

  static const Color _selectedFocused = Color(0xFF2E436E);
  static const Color _selectedIdle = Color(0xFF26292E);

  Widget _dirRow(_Row r, List<int>? hits) {
    return Padding(
      padding: EdgeInsets.only(left: 8.0 + (r.depth * 12.0), right: 8),
      child: Row(
        children: [
          Icon(r.expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 14, color: IntelliJTheme.textMuted),
          const SizedBox(width: 4),
          Icon(
            r.isPackage ? Icons.folder_special_outlined : Icons.folder,
            size: 14,
            color: r.isPackage ? const Color(0xFF8A9199) : IntelliJTheme.gitYellow,
          ),
          const SizedBox(width: 6),
          Expanded(child: _label(r.name, hits, const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  Widget _hintRow(String text, int depth) => Padding(
        padding: EdgeInsets.only(left: 26.0 + (depth * 12.0), top: 3, bottom: 3),
        child: Text(text, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11.5)),
      );

  Widget _fileRow(_Row r, List<int>? hits) {
    final isActive = widget.activeFilePath == r.path;
    return Container(
      decoration: BoxDecoration(
        color: isActive && r.path != _selected ? IntelliJTheme.selectionBg : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      padding: EdgeInsets.only(left: 26.0 + (r.depth * 12.0), right: 8),
      child: Row(
        children: [
          fileTypeIconWidget(r.name, size: 13),
          const SizedBox(width: 6),
          Expanded(
            child: _label(r.name, hits, TextStyle(color: isActive ? const Color(0xFF6CB4F8) : IntelliJTheme.textPrimary, fontSize: 12)),
          ),
          if (isActive)
            Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(color: IntelliJTheme.gitGreen, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }

  /// 名字;快速搜索时匹配上的字符加底色(IntelliJ 的黄色高亮)。
  Widget _label(String name, List<int>? hits, TextStyle style) {
    if (hits == null || hits.isEmpty) return Text(name, style: style, overflow: TextOverflow.ellipsis, maxLines: 1);
    final hit = hits.toSet();
    final spans = <TextSpan>[];
    for (var i = 0; i < name.length; i++) {
      final on = hit.contains(i);
      final ch = name[i];
      if (spans.isNotEmpty && (spans.last.style?.backgroundColor != null) == on) {
        spans[spans.length - 1] = TextSpan(text: spans.last.text! + ch, style: spans.last.style);
      } else {
        spans.add(TextSpan(text: ch, style: on ? style.copyWith(backgroundColor: _matchBg, color: IntelliJTheme.textHigh) : style));
      }
    }
    return Text.rich(TextSpan(children: spans), overflow: TextOverflow.ellipsis, maxLines: 1, key: ValueKey('match:$name'));
  }

  static const Color _matchBg = Color(0xFF6B5A1E);
}

/// 文件图标的 widget:文件树、编辑器标签、Go to File 共用,同一种文件到处是同一个图标。
/// Makefile 是字母 M、Markdown 是 Markdown 标志(IntelliJ 的图标,Material 里没有),其余按 [fileTypeIcon]。
Widget fileTypeIconWidget(String name, {double size = 13}) {
  if (isMakefileName(name)) return MakefileIcon(size: size);
  if (languages.detect(name).id == 'markdown') return MarkdownIcon(size: size);
  final (icon, color) = fileTypeIcon(name);
  return Icon(icon, size: size, color: color);
}

/// Makefile 的图标:加粗的 M。文件树、Go to File、make 工具窗、活动条共用。
class MakefileIcon extends StatelessWidget {
  const MakefileIcon({super.key, this.size = 13, this.color = makefileIconColor});

  final double size;
  final Color color;

  /// IntelliJ Makefile 图标的蓝紫色。
  static const Color makefileIconColor = Color(0xFF8C9EFF);

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            'M',
            style: TextStyle(color: color, fontSize: size * 1.05, fontWeight: FontWeight.w800, height: 1, letterSpacing: -0.5),
          ),
        ),
      );
}

/// Markdown 文件的图标:Markdown 标志 —— 圆角框里一个 M 和一个向下的箭头(IntelliJ 的 Markdown 图标同款)。
/// 画出来而不是用文字,13px 下也清楚。
class MarkdownIcon extends StatelessWidget {
  const MarkdownIcon({super.key, this.size = 13, this.color = markdownIconColor});

  final double size;
  final Color color;

  static const Color markdownIconColor = Color(0xFF6CB4F8);

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _MarkdownMarkPainter(color)),
      );
}

class _MarkdownMarkPainter extends CustomPainter {
  _MarkdownMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final stroke = (w / 11).clamp(1.0, 2.0);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    // 外框:宽高比约 1.6(Markdown 标志的比例),竖直居中
    final boxH = w * 0.66;
    final top = (size.height - boxH) / 2;
    final box = Rect.fromLTWH(stroke / 2, top + stroke / 2, w - stroke, boxH - stroke);
    canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(w * 0.12)), p);
    // M
    final y0 = top + boxH * 0.28, y1 = top + boxH * 0.72;
    final mx0 = w * 0.2, mx1 = w * 0.52;
    canvas.drawPath(
      Path()
        ..moveTo(mx0, y1)
        ..lineTo(mx0, y0)
        ..lineTo((mx0 + mx1) / 2, y0 + (y1 - y0) * 0.45)
        ..lineTo(mx1, y0)
        ..lineTo(mx1, y1),
      p,
    );
    // ↓
    final ax = w * 0.72;
    canvas.drawLine(Offset(ax, y0), Offset(ax, y1), p);
    canvas.drawPath(
      Path()
        ..moveTo(ax - w * 0.1, y1 - (y1 - y0) * 0.38)
        ..lineTo(ax, y1)
        ..lineTo(ax + w * 0.1, y1 - (y1 - y0) * 0.38),
      p,
    );
  }

  @override
  bool shouldRepaint(_MarkdownMarkPainter old) => old.color != color;
}

/// 文件图标(按语法引擎识别的语言):文件树、Go to File 等处共用。
(IconData, Color) fileTypeIcon(String name) {
  final lang = languages.detect(name);
  return switch (lang.id) {
    'java' => (Icons.coffee_outlined, const Color(0xFFE76F00)),
    'kotlin' => (Icons.change_history, const Color(0xFFA97BFF)),
    'scala' => (Icons.stacked_line_chart, const Color(0xFFDE3423)),
    'groovy' => (Icons.code, const Color(0xFF4298B8)),
    'dart' => (Icons.flutter_dash, const Color(0xFF40C4FF)),
    'rust' => (Icons.settings_suggest_outlined, const Color(0xFFD87642)),
    'go' => (Icons.code, const Color(0xFF00ADD8)),
    'c' || 'cpp' || 'csharp' => (Icons.code, const Color(0xFF659AD2)),
    'swift' => (Icons.code, const Color(0xFFF05138)),
    'javascript' => (Icons.javascript, const Color(0xFFE8D44D)),
    'typescript' => (Icons.code, const Color(0xFF3178C6)),
    'python' => (Icons.code, const Color(0xFF4B8BBE)),
    'ruby' => (Icons.diamond_outlined, const Color(0xFFCC342D)),
    'php' => (Icons.php, const Color(0xFF8892BF)),
    'shellscript' || 'powershell' => (Icons.terminal, const Color(0xFF89D185)),
    'sql' => (Icons.storage, const Color(0xFFCC7832)),
    'xml' || 'html' => (Icons.code, const Color(0xFFE8BF6A)),
    'css' => (Icons.css, const Color(0xFF42A5F5)),
    'json' => (Icons.data_object, const Color(0xFFCBCB41)),
    'markdown' => (Icons.description_outlined, const Color(0xFF6CB4F8)),
    'yaml' || 'toml' || 'ini' || 'properties' => (Icons.tune, IntelliJTheme.textMuted),
    'dockerfile' => (Icons.directions_boat_outlined, const Color(0xFF2496ED)),
    'ignore' => (Icons.visibility_off_outlined, IntelliJTheme.textMuted),
    _ => (Icons.insert_drive_file_outlined, IntelliJTheme.textMuted),
  };
}

enum _RowKind { dir, file, hint }

/// 文件树里的一行(展开后摊平成列表,键盘选择和快速搜索都在这上面走)。
class _Row {
  _Row.dir(this.path, this.name, this.depth, this.node, {required this.expanded, required this.isRoot, required this.isPackage}) : kind = _RowKind.dir;
  _Row.file(this.path, this.name, this.depth)
      : kind = _RowKind.file,
        node = null,
        expanded = false,
        isRoot = false,
        isPackage = false;
  _Row.hint(this.name, this.depth)
      : kind = _RowKind.hint,
        path = '',
        node = null,
        expanded = false,
        isRoot = false,
        isPackage = false;

  final _RowKind kind;
  final String path;
  final String name;
  final int depth;
  final Map<String, dynamic>? node;
  final bool expanded;
  final bool isRoot;
  final bool isPackage;

  bool get isDir => kind == _RowKind.dir;
  bool get isFile => kind == _RowKind.file;
  bool get selectable => kind != _RowKind.hint;
}

/// 快速搜索的输入框(浮在文件树顶上);一个都没匹配上时字变红。
class _SearchField extends StatelessWidget {
  const _SearchField({required this.query, required this.noMatch});

  final String query;
  final bool noMatch;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('tree-speed-search'),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: IntelliJTheme.popupBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: noMatch ? IntelliJTheme.gitRed : IntelliJTheme.accentBlue),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 14, color: IntelliJTheme.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              query,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(color: noMatch ? IntelliJTheme.diagError : IntelliJTheme.textHigh, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 快速搜索的匹配(仿 IntelliJ):不分大小写;先找连续出现,没有再分段匹配 ——
/// 每一段要从「词的开头」开始(名字开头、`-` `_` `.` 等符号之后、小写后面的大写),
/// 所以 `admser` 能找到 admin-service,`adm` 却不会落到 .bcp-cl**a**u**d**e.y**m**l 上。
/// 返回匹配上的字符下标(高亮用),没匹配上返回 null。
List<int>? speedSearchMatch(String name, String query) {
  if (query.isEmpty) return null;
  final n = name.toLowerCase(), q = query.toLowerCase();
  final at = n.indexOf(q);
  if (at >= 0) return [for (var i = 0; i < q.length; i++) at + i];
  bool alnum(String c) => RegExp(r'[A-Za-z0-9]').hasMatch(c);
  bool wordStart(int i) {
    if (i == 0) return true;
    final prev = name[i - 1], cur = name[i];
    if (!alnum(prev)) return true;
    return cur.toUpperCase() == cur && cur.toLowerCase() != cur && prev.toLowerCase() == prev && prev.toUpperCase() != prev;
  }

  final out = <int>[];
  // qi:要匹配的查询字符;from:名字里从哪开始找;run:上一个字符紧挨着能接着匹配
  bool go(int qi, int from) {
    if (qi == q.length) return true;
    for (var i = from; i < n.length; i++) {
      final continues = out.isNotEmpty && i == out.last + 1;
      if (n[i] != q[qi] || !(continues || wordStart(i))) continue;
      out.add(i);
      if (go(qi + 1, i + 1)) return true;
      out.removeLast();
    }
    return false;
  }

  return go(0, 0) ? out : null;
}
