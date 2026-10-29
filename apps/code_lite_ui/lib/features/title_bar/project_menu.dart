import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import 'anchored_popup.dart';

/// 项目名的徽章字母:多个词取首词和末词的首字母(`bcpoker_data_archiving` → BA),
/// 只有一个词取前两个字母(`bcpoker` → BC);与 IntelliJ 一致。
String projectInitials(String name) {
  final words = name.split(RegExp(r'[_\-\s.]+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    final w = words.first;
    return (w.length >= 2 ? w.substring(0, 2) : w).toUpperCase();
  }
  return (words.first[0] + words.last[0]).toUpperCase();
}

const List<Color> _badgePalette = [
  Color(0xFF2E9E8F), // teal
  Color(0xFF6B6BD6), // indigo
  Color(0xFFB05DC9), // purple
  Color(0xFFD9803F), // orange
  Color(0xFF4C8FD6), // blue
  Color(0xFF5FA05A), // green
  Color(0xFFC8506B), // rose
  Color(0xFFA88A2E), // olive
];

/// 同一个项目名永远是同一种颜色。
Color projectColor(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _badgePalette[h % _badgePalette.length];
}

/// `/Users/me/code/app` → `~/code/app`。
String abbreviatePath(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  return path.startsWith('$home/') ? '~${path.substring(home.length)}' : path;
}

/// `~/code/app` → `/Users/me/code/app`;别的路径原样返回。
String expandHome(String path, String? home) {
  final p = path.trim();
  if (home == null || home.isEmpty) return p;
  if (p == '~') return home;
  return p.startsWith('~/') ? '$home${p.substring(1)}' : p;
}

String projectNameOf(String path) => path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

/// [query] 的字符按顺序出现在 [text] 里(不必相邻)。
bool _isSubsequence(String query, String text) {
  var i = 0;
  for (var j = 0; j < text.length && i < query.length; j++) {
    if (text.codeUnitAt(j) == query.codeUnitAt(i)) i++;
  }
  return i == query.length;
}

/// 项目搜索的匹配程度,越小越好;不匹配返回 null。不分大小写,依次看:
/// 项目名以查询开头(0)→ 名字里包含(1)→ 名字里按顺序出现(2)→ 路径里包含(3)→ 路径里按顺序出现(4)。
/// 查询为空时所有项目都匹配(0)。和 IntelliJ 一样,`ad` 能搜到 `~/Worker/java/bcpoker_data_archiving`
/// (路径里先有 java 的 a,后有 data 的 d)。
int? projectMatchScore(String query, String path, {String? home}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final name = projectNameOf(path).toLowerCase();
  final at = name.indexOf(q);
  if (at == 0) return 0;
  if (at > 0) return 1;
  if (_isSubsequence(q, name)) return 2;
  final shown = abbreviatePath(path, home).toLowerCase();
  if (shown.contains(q)) return 3;
  if (_isSubsequence(q, shown)) return 4;
  return null;
}

/// 按 [query] 过滤并排序 [paths]:匹配得越好越靠前,一样好的保持原来的顺序(最近的在前)。
List<String> filterProjects(String query, List<String> paths, {String? home}) {
  final scored = <(int, int, String)>[];
  for (var i = 0; i < paths.length; i++) {
    final score = projectMatchScore(query, paths[i], home: home);
    if (score != null) scored.add((score, i, paths[i]));
  }
  scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final e in scored) e.$3];
}

class ProjectBadge extends StatelessWidget {
  const ProjectBadge({super.key, required this.name, this.size = 24});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: projectColor(name), borderRadius: BorderRadius.circular(size / 4)),
      child: Text(
        projectInitials(name),
        style: TextStyle(color: Colors.white, fontSize: size * 0.46, fontWeight: FontWeight.w700, height: 1),
      ),
    );
  }
}

/// 标题栏上的项目名;点开是 New Project / Open / Clone,以及已打开和最近的项目。
class ProjectChip extends StatelessWidget {
  const ProjectChip({
    super.key,
    required this.projectPath,
    required this.recent,
    required this.onSwitch,
    required this.onNewProject,
    required this.onOpen,
    required this.onClone,
    this.home,
    this.openProjects = const [],
  });

  /// 当前项目目录;没打开项目时为 null。
  final String? projectPath;

  /// 现在打开着的所有项目(一个进程、都在内存里);点一个是切换。空时只有当前项目。
  final List<String> openProjects;

  /// 最近打开的项目(最新的在前,可能含当前这个)。
  final List<String> recent;
  final String? home;
  final ValueChanged<String> onSwitch;
  final VoidCallback onNewProject;
  final VoidCallback onOpen;
  final VoidCallback onClone;

  @override
  Widget build(BuildContext context) {
    final path = projectPath;
    final name = path == null ? tr('无项目', 'No Project') : projectNameOf(path);
    return Builder(
      builder: (context) => Tooltip(
        message: path == null ? tr('打开或新建一个项目', 'Open or create a project') : abbreviatePath(path, home),
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: IntelliJTheme.hoverBg,
          onTap: () => _open(context),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (path != null) ProjectBadge(name: name) else const Icon(Icons.folder_open, size: 18, color: IntelliJTheme.textSecondary),
                const SizedBox(width: 8),
                Text(name, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 2),
                const Icon(Icons.keyboard_arrow_down, size: 16, color: IntelliJTheme.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    await showAnchoredPopup<void>(
      context,
      width: 380,
      builder: (popup) => _ProjectPopup(
        current: projectPath,
        open: openProjects.isNotEmpty ? openProjects : [if (projectPath != null) projectPath!],
        recent: recent.where((p) => p != projectPath && !openProjects.contains(p)).toList(),
        home: home,
        onPick: (action) {
          Navigator.pop(popup);
          action();
        },
        onSwitch: onSwitch,
        onNewProject: onNewProject,
        onOpen: onOpen,
        onClone: onClone,
      ),
    );
  }
}

/// 弹窗里一行可以选中的东西:顶部的 New / Open / Clone,或者一个项目。
class _Entry {
  const _Entry.action(this.icon, this.zh, this.en, this.run)
      : path = null,
        isCurrent = false;
  const _Entry.project(String this.path, {required this.isCurrent, required this.run})
      : icon = null,
        zh = '',
        en = '';

  final IconData? icon;
  final String zh;
  final String en;
  String get label => tr(zh, en);
  final String? path;
  final bool isCurrent;
  final VoidCallback run;
}

/// 项目弹窗:顶部是搜索框(一打开就聚焦,直接敲字就过滤),下面是操作和项目列表。
/// ↑ ↓ 移动高亮,回车打开高亮的那一项;敲了字之后高亮默认落在第一个匹配上。
class _ProjectPopup extends StatefulWidget {
  const _ProjectPopup({
    required this.current,
    required this.open,
    required this.recent,
    required this.home,
    required this.onPick,
    required this.onSwitch,
    required this.onNewProject,
    required this.onOpen,
    required this.onClone,
  });

  final String? current;
  final List<String> open;
  final List<String> recent;
  final String? home;
  final void Function(VoidCallback action) onPick;
  final ValueChanged<String> onSwitch;
  final VoidCallback onNewProject;
  final VoidCallback onOpen;
  final VoidCallback onClone;

  @override
  State<_ProjectPopup> createState() => _ProjectPopupState();
}

class _ProjectPopupState extends State<_ProjectPopup> {
  final TextEditingController _search = TextEditingController();
  final GlobalKey _selectedKey = GlobalKey();

  /// 键盘选中的行;null = 没动过:搜索时是第一项,没搜索时是当前打开的项目。
  int? _selected;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (_search.text == _lastQuery) return;
      _lastQuery = _search.text;
      setState(() => _selected = null); // 查询变了:高亮回到第一个匹配
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim();

  List<_Entry> get _actions {
    final q = _query.toLowerCase();
    return [
      for (final a in [
        _Entry.action(Icons.add, '新建项目…', 'New Project…', widget.onNewProject),
        _Entry.action(Icons.folder_open_outlined, '打开…', 'Open…', widget.onOpen),
        _Entry.action(Icons.fork_right, '克隆存储库…', 'Clone Repository…', widget.onClone),
      ])
        if (matchesEitherLanguage(q, a.zh, a.en)) a,
    ];
  }

  List<_Entry> get _open => [
        for (final p in filterProjects(_query, widget.open, home: widget.home)) _Entry.project(p, isCurrent: p == widget.current, run: () => widget.onSwitch(p)),
      ];

  List<_Entry> get _recent => [
        for (final p in filterProjects(_query, widget.recent, home: widget.home)) _Entry.project(p, isCurrent: false, run: () => widget.onSwitch(p)),
      ];

  int _highlight(List<_Entry> all) {
    if (all.isEmpty) return -1;
    final s = _selected;
    if (s != null) return s.clamp(0, all.length - 1);
    return _query.isNotEmpty ? 0 : all.indexWhere((e) => e.isCurrent);
  }

  void _move(List<_Entry> all, int delta) {
    if (all.isEmpty) return;
    final cur = _highlight(all);
    setState(() => _selected = cur < 0 ? (delta > 0 ? 0 : all.length - 1) : (cur + delta) % all.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: Duration.zero);
    });
  }

  void _activate(List<_Entry> all) {
    final i = _highlight(all);
    if (i >= 0) widget.onPick(all[i].run);
  }

  Widget _row(_Entry e, bool highlighted) {
    final key = highlighted ? _selectedKey : null;
    final path = e.path;
    if (path == null) {
      return PopupRow(
        key: key,
        selected: highlighted,
        onTap: () => widget.onPick(e.run),
        child: Row(children: [
          Icon(e.icon, size: 16, color: IntelliJTheme.textSecondary),
          const SizedBox(width: 8),
          Text(e.label, style: popupText),
        ]),
      );
    }
    final name = projectNameOf(path);
    return PopupRow(
      key: key,
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      onTap: () => widget.onPick(e.run),
      selected: highlighted,
      child: Row(children: [
        ProjectBadge(name: name, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: popupText, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(abbreviatePath(path, widget.home), style: popupMuted, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text(text, style: popupHeader),
      );

  @override
  Widget build(BuildContext context) {
    const divider = Divider(height: 9, thickness: 1, color: IntelliJTheme.borderSubtle, indent: 8, endIndent: 8);
    final actions = _actions;
    final open = _open;
    final recent = _recent;
    final all = [...actions, ...open, ...recent];
    final highlight = _highlight(all);
    var index = 0;
    Widget row(_Entry e) => _row(e, index++ == highlight);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(all, 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(all, -1),
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 8),
            child: Row(children: [
              const Icon(Icons.search, size: 16, color: IntelliJTheme.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  style: popupText,
                  cursorColor: IntelliJTheme.caret,
                  onSubmitted: (_) => _activate(all),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: tr('搜索项目', 'Search projects'),
                    hintStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 13),
                  ),
                ),
              ),
              if (_search.text.isNotEmpty)
                InkWell(
                  onTap: _search.clear,
                  borderRadius: BorderRadius.circular(4),
                  child: Tooltip(
                    message: tr('清除', 'Clear'),
                    child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 15, color: IntelliJTheme.textMuted)),
                  ),
                ),
            ]),
          ),
          const Divider(height: 1, thickness: 1, color: IntelliJTheme.borderSubtle),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final e in actions) row(e),
                if (open.isNotEmpty) ...[
                  if (actions.isNotEmpty) divider,
                  _header(tr('打开的项目', 'Open Projects')),
                  for (final e in open) row(e),
                ],
                if (recent.isNotEmpty) ...[
                  if (actions.isNotEmpty || open.isNotEmpty) divider,
                  _header(tr('最近项目', 'Recent Projects')),
                  for (final e in recent) row(e),
                ],
                if (all.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('没有匹配的项目', 'No matching projects'), style: popupMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
