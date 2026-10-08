import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/build_tools/build_model.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/context_menu_region.dart';
import 'build_tools_store.dart';

const TextStyle _label = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 11);
const double _rowHeight = 24;
const double _indent = 16;

/// 左侧的构建工具窗(IntelliJ 的 Maven 窗口):模块树 → 任务组(Lifecycle)→ 任务。
/// 双击任务在终端里运行;⌘ / Ctrl 点击可在同一模块里多选,工具栏 ▶ 一起运行。
class BuildToolsPanel extends StatelessWidget {
  const BuildToolsPanel({super.key, required this.store, this.onOpenFile});

  final BuildToolsStore store;

  /// 右键模块「打开构建文件」(相对项目根的路径)。
  final ValueChanged<String>? onOpenFile;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final rows = <Widget>[];
        for (final p in store.projects) {
          _addModule(rows, p, p.root, 0);
        }
        return Container(
          color: IntelliJTheme.sidebarBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(store: store),
              if (store.loading) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: store.projects.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(store.loading ? '正在读取项目…' : '没有检测到构建文件', style: _muted, textAlign: TextAlign.center),
                        ),
                      )
                    : ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: rows),
              ),
            ],
          ),
        );
      },
    );
  }

  void _addModule(List<Widget> rows, BuildProject p, BuildModule m, int depth) {
    final key = BuildToolsStore.moduleKey(p, m);
    final open = store.isExpanded(key);
    rows.add(_TreeRow(
      key: ValueKey('build-module-$key'),
      depth: depth,
      expandable: true,
      expanded: open,
      selected: store.selectedModule == key && store.selectedTasks.isEmpty,
      icon: _ModuleIcon(error: m.error != null),
      label: m.name,
      trailing: m.error ?? (depth == 0 ? '(root)' : null),
      trailingIsError: m.error != null,
      tooltip: m.error ?? m.buildFile,
      onTap: (_) => store.selectModule(key),
      onDoubleTap: () => store.toggleExpanded(key),
      onToggle: () => store.toggleExpanded(key),
      menu: () => [
        MenuItemButton(
          onPressed: onOpenFile == null ? null : () => onOpenFile!(m.buildFile),
          child: Text('打开 ${m.buildFile.split('/').last}'),
        ),
        MenuItemButton(onPressed: store.reload, child: Text('重新加载 ${p.tool.name} 项目')),
      ],
    ));
    if (!open) return;
    for (final g in p.tool.taskGroups) {
      final gk = BuildToolsStore.groupKey(p, m, g.name);
      final gOpen = store.isExpanded(gk);
      rows.add(_TreeRow(
        key: ValueKey('build-group-$gk'),
        depth: depth + 1,
        expandable: true,
        expanded: gOpen,
        selected: false,
        icon: const Icon(Icons.folder_outlined, size: 14, color: IntelliJTheme.textSecondary),
        label: g.name,
        onTap: (_) => store.toggleExpanded(gk),
        onToggle: () => store.toggleExpanded(gk),
      ));
      if (!gOpen) continue;
      for (final task in g.tasks) {
        final command = store.commandFor(p, m, [task]);
        rows.add(_TreeRow(
          key: ValueKey('build-task-$key/$task'),
          depth: depth + 2,
          expandable: false,
          expanded: false,
          selected: store.isTaskSelected(key, task),
          icon: const Icon(Icons.settings_outlined, size: 14, color: Color(0xFF6E9FD8)),
          label: task,
          tooltip: command,
          onTap: (multi) => store.selectTask(key, task, toggle: multi),
          onDoubleTap: () => store.run(p, m, [task]),
          menu: () => [
            MenuItemButton(
              leadingIcon: const Icon(Icons.play_arrow, size: 16, color: Color(0xFF5FB865)),
              onPressed: () => store.run(p, m, [task]),
              child: Text("运行 '$task'"),
            ),
            if (store.selectedModule == key && store.selectedTasks.length > 1)
              MenuItemButton(onPressed: store.runSelected, child: Text('运行选中的 ${store.selectedTasks.length} 个任务')),
            MenuItemButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: command)),
              child: const Text('复制命令行'),
            ),
          ],
        ));
      }
    }
    for (final c in m.modules) {
      _addModule(rows, p, c, depth + 1);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.store});

  final BuildToolsStore store;

  @override
  Widget build(BuildContext context) {
    final project = store.toolbarProject;
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: const BoxDecoration(
        color: IntelliJTheme.subHeaderBg,
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      // 侧栏可拖窄到 160px:标题要能省略,按钮不换行。
      child: Row(
        children: [
          Expanded(
            child: Text(
              store.title.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
          _ToolButton(icon: Icons.refresh, tooltip: '重新加载项目', onTap: store.loading ? null : store.reload),
          _ToolButton(
            icon: Icons.play_arrow,
            color: const Color(0xFF5FB865),
            tooltip: '运行选中的任务',
            onTap: store.canRunSelected ? store.runSelected : null,
          ),
          if (project != null)
            for (final o in project.tool.options)
              _ToolButton(
                icon: _optionIcon(o),
                tooltip: o.label,
                active: store.isOptionOn(project.tool, o.id),
                onTap: () => store.toggleOption(project.tool, o.id),
              ),
          _ToolButton(icon: Icons.unfold_less, tooltip: '全部折叠', onTap: store.collapseAll),
        ],
      ),
    );
  }

  static IconData _optionIcon(BuildToolOption o) => switch (o.icon) {
        'cloud_off' => Icons.cloud_off_outlined,
        'skip' => Icons.block,
        _ => Icons.tune,
      };
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.tooltip, required this.onTap, this.color, this.active = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;

  /// 开关处于打开状态(淡蓝底)。
  final bool active;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: active ? '$tooltip(已开启)' : tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: active ? BoxDecoration(color: IntelliJTheme.accentBlue.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4)) : null,
          child: Icon(icon, size: 15, color: enabled ? (color ?? IntelliJTheme.textSecondary) : IntelliJTheme.textMuted.withValues(alpha: 0.5)),
        ),
      ),
    );
  }
}

/// Maven 模块图标:蓝底小写 m(IntelliJ 的模块徽标);读取出错时红色。
class _ModuleIcon extends StatelessWidget {
  const _ModuleIcon({required this.error});

  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? const Color(0xFFE5534B) : const Color(0xFF6E9FD8);
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: color, width: 0.8),
      ),
      child: Text('m', style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold, height: 1)),
    );
  }
}

/// 树的一行。单击 / 双击自己判断(GestureDetector 的 onDoubleTap 会把单击延迟到双击超时之后)。
class _TreeRow extends StatefulWidget {
  const _TreeRow({
    super.key,
    required this.depth,
    required this.expandable,
    required this.expanded,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onToggle,
    this.onDoubleTap,
    this.trailing,
    this.trailingIsError = false,
    this.tooltip,
    this.menu,
  });

  final int depth;
  final bool expandable;
  final bool expanded;
  final bool selected;
  final Widget icon;
  final String label;

  /// 参数:是否按着 ⌘ / Ctrl(多选)。
  final void Function(bool multi) onTap;
  final VoidCallback? onToggle;
  final VoidCallback? onDoubleTap;
  final String? trailing;
  final bool trailingIsError;
  final String? tooltip;
  final List<Widget> Function()? menu;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  DateTime _lastTap = DateTime(0);

  void _tap() {
    final now = DateTime.now();
    final isDouble = now.difference(_lastTap) < const Duration(milliseconds: 400);
    _lastTap = isDouble ? DateTime(0) : now;
    final keys = HardwareKeyboard.instance;
    widget.onTap(keys.isMetaPressed || keys.isControlPressed);
    if (isDouble) widget.onDoubleTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    Widget row = InkWell(
      onTap: _tap,
      child: Container(
        height: _rowHeight,
        color: w.selected ? IntelliJTheme.accentBlue.withValues(alpha: 0.28) : null,
        padding: EdgeInsets.only(left: 6 + w.depth * _indent, right: 8),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: w.expandable
                  ? GestureDetector(
                      onTap: w.onToggle,
                      child: Icon(w.expanded ? Icons.expand_more : Icons.chevron_right, size: 14, color: IntelliJTheme.textMuted),
                    )
                  : null,
            ),
            w.icon,
            const SizedBox(width: 6),
            Flexible(child: Text(w.label, style: _label, overflow: TextOverflow.ellipsis, maxLines: 1)),
            if (w.trailing != null) ...[
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  w.trailing!,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: w.trailingIsError ? const TextStyle(color: Color(0xFFE5534B), fontSize: 11) : _muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (w.tooltip != null) {
      row = Tooltip(message: w.tooltip!, waitDuration: const Duration(milliseconds: 800), child: row);
    }
    final menu = w.menu;
    return menu == null ? row : ContextMenuRegion(menuBuilder: (_) => menu(), child: row);
  }
}
