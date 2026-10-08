import 'package:flutter/material.dart';

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
  });

  /// 当前项目目录;没打开项目时为 null。
  final String? projectPath;

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
    final name = path == null ? 'No Project' : projectNameOf(path);
    return Builder(
      builder: (context) => Tooltip(
        message: path == null ? '打开或新建一个项目' : abbreviatePath(path, home),
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
        recent: recent.where((p) => p != projectPath).toList(),
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

class _ProjectPopup extends StatelessWidget {
  const _ProjectPopup({
    required this.current,
    required this.recent,
    required this.home,
    required this.onPick,
    required this.onSwitch,
    required this.onNewProject,
    required this.onOpen,
    required this.onClone,
  });

  final String? current;
  final List<String> recent;
  final String? home;
  final void Function(VoidCallback action) onPick;
  final ValueChanged<String> onSwitch;
  final VoidCallback onNewProject;
  final VoidCallback onOpen;
  final VoidCallback onClone;

  Widget _action(IconData icon, String label, VoidCallback run) => PopupRow(
        onTap: () => onPick(run),
        child: Row(children: [
          Icon(icon, size: 16, color: IntelliJTheme.textSecondary),
          const SizedBox(width: 8),
          Text(label, style: popupText),
        ]),
      );

  Widget _project(String path, {required bool open}) {
    final name = projectNameOf(path);
    return PopupRow(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      onTap: () => onPick(() => onSwitch(path)),
      selected: open,
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
              Text(abbreviatePath(path, home), style: popupMuted, overflow: TextOverflow.ellipsis),
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
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        _action(Icons.add, 'New Project…', onNewProject),
        _action(Icons.folder_open_outlined, 'Open…', onOpen),
        _action(Icons.fork_right, 'Clone Repository…', onClone),
        if (current != null) ...[
          divider,
          _header('Open Projects'),
          _project(current!, open: true),
        ],
        if (recent.isNotEmpty) ...[
          divider,
          _header('Recent Projects'),
          for (final p in recent) _project(p, open: false),
        ],
      ],
    );
  }
}
