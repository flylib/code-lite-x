import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/build_tools/build_model.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/context_menu_region.dart';
import 'build_tools_store.dart';
import '../tool_window/tool_window_actions.dart';

const TextStyle _label = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 13);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle _error = TextStyle(color: Color(0xFFE5534B), fontSize: 12);
const Color _mavenBlue = Color(0xFF548AF7);
const double _rowHeight = 24;
const double _indent = 20;

/// 左侧的构建工具窗,照 IntelliJ 的 Maven 窗口:标题行、工具栏,
/// 所有模块平铺在顶层(聚合根标 (root)),每个模块下是 Lifecycle、Plugins、Repositories、Dependencies。
/// 双击阶段 / 插件目标在终端里运行;⌘ / Ctrl 点击可在同一模块里多选,工具栏 ▶ 一起运行。
class BuildToolsPanel extends StatelessWidget {
  const BuildToolsPanel({super.key, required this.store, this.onOpenFile});

  final BuildToolsStore store;

  /// 右键模块「打开 pom.xml」(相对项目根的路径)。
  final ValueChanged<String>? onOpenFile;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final rows = <Widget>[];
        for (final p in store.projects) {
          for (final m in p.root.all) {
            _addModule(rows, p, m, isRoot: identical(m, p.root) && m.modules.isNotEmpty);
          }
        }
        return Container(
          color: IntelliJTheme.sidebarBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ToolWindowTitleRow(title: store.title),
              _Toolbar(store: store),
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

  void _addModule(List<Widget> rows, BuildProject p, BuildModule m, {required bool isRoot}) {
    final key = BuildToolsStore.moduleKey(p, m);
    final open = store.isExpanded(key);
    rows.add(ToolTreeRow(
      key: ValueKey('build-module-$key'),
      depth: 0,
      expandable: true,
      expanded: open,
      selected: store.isModuleSelected(key),
      icon: _ModuleIcon(error: m.error != null),
      label: m.name,
      trailing: m.error ?? (isRoot ? '(root)' : null),
      trailingStyle: m.error != null ? _error : _muted,
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

    // 清单声明的任务组(Lifecycle)
    for (final g in p.tool.taskGroups) {
      final gk = BuildToolsStore.groupKey(p, m, g.name);
      final gOpen = _addGroup(rows, key, gk, g.name, 'lifecycle');
      if (!gOpen) continue;
      for (final task in g.tasks) {
        _addTask(rows, p, m, key, task, task, depth: 2);
      }
    }

    // 读取器读出的节点组(Plugins / Repositories / Dependencies)
    for (final g in m.groups) {
      final gk = BuildToolsStore.groupKey(p, m, g.name);
      final gOpen = _addGroup(rows, key, gk, g.name, g.kind);
      if (!gOpen) continue;
      for (final item in g.items) {
        final ik = BuildToolsStore.itemKey(gk, item);
        if (item.task != null) {
          _addTask(rows, p, m, key, item.task!, item.label, depth: 2);
          continue;
        }
        final iOpen = store.isExpanded(ik);
        rows.add(ToolTreeRow(
          key: ValueKey('build-item-$ik'),
          depth: 2,
          expandable: item.children.isNotEmpty,
          expanded: iOpen,
          selected: store.selectedNode == ik,
          icon: _itemIcon(g.kind),
          label: item.label,
          trailing: item.detail,
          tooltip: item.detail,
          onTap: (_) => store.selectNode(key, ik),
          onDoubleTap: item.children.isEmpty ? null : () => store.toggleExpanded(ik),
          onToggle: () => store.toggleExpanded(ik),
          menu: item.detail == null
              ? null
              : () => [
                    MenuItemButton(
                      onPressed: () => Clipboard.setData(ClipboardData(text: g.kind == 'dependencies' ? item.label : item.detail!)),
                      child: Text(g.kind == 'repositories' ? '复制 URL' : '复制坐标'),
                    ),
                  ],
        ));
        if (!iOpen) continue;
        for (final c in item.children) {
          if (c.task != null) _addTask(rows, p, m, key, c.task!, c.label, depth: 3);
        }
      }
    }
  }

  bool _addGroup(List<Widget> rows, String moduleKey, String gk, String name, String kind) {
    final open = store.isExpanded(gk);
    rows.add(ToolTreeRow(
      key: ValueKey('build-group-$gk'),
      depth: 1,
      expandable: true,
      expanded: open,
      selected: store.selectedNode == gk,
      icon: _FolderIcon(kind: kind),
      label: name,
      onTap: (_) => store.selectNode(moduleKey, gk),
      onDoubleTap: () => store.toggleExpanded(gk),
      onToggle: () => store.toggleExpanded(gk),
    ));
    return open;
  }

  void _addTask(List<Widget> rows, BuildProject p, BuildModule m, String key, String task, String label, {required int depth}) {
    final command = store.commandFor(p, m, [task]);
    rows.add(ToolTreeRow(
      key: ValueKey('build-task-$key/$task'),
      depth: depth,
      expandable: false,
      expanded: false,
      selected: store.isTaskSelected(key, task),
      icon: const Icon(Icons.settings_outlined, size: 15, color: IntelliJTheme.textSecondary),
      label: label,
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

  static Widget _itemIcon(String kind) => switch (kind) {
        'plugins' => const Icon(Icons.extension_outlined, size: 14, color: IntelliJTheme.textSecondary),
        'repositories' => const Icon(Icons.storage_outlined, size: 14, color: IntelliJTheme.textSecondary),
        _ => const Icon(Icons.inventory_2_outlined, size: 14, color: IntelliJTheme.textSecondary),
      };
}

/// 「Maven」标题 + 拆分 / 选项 / 收起按钮(IntelliJ 工具窗的标题行)。
class ToolWindowTitleRow extends StatelessWidget {
  const ToolWindowTitleRow({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 12, right: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const ToolWindowActions(),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.store});

  final BuildToolsStore store;

  @override
  Widget build(BuildContext context) {
    final project = store.toolbarProject;
    final hasProjects = store.projects.isNotEmpty;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle), bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      // 侧栏可拖窄到 160px:按钮放不下时横向滚动,不溢出。
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ToolbarIconButton(icon: Icons.sync, tooltip: '重新加载所有 ${store.title} 项目', onTap: store.loading ? null : store.reload),
            const ToolbarSeparator(),
            ToolbarIconButton(
              icon: Icons.play_arrow,
              color: const Color(0xFF5FB865),
              tooltip: '运行选中的任务',
              onTap: store.canRunSelected ? store.runSelected : null,
            ),
            ToolbarIconButton(
              icon: Icons.smart_display_outlined,
              tooltip: '执行 ${store.title} 目标',
              onTap: hasProjects ? () => _executeGoal(context) : null,
            ),
            if (project != null && project.tool.options.isNotEmpty) ...[
              const ToolbarSeparator(),
              for (final o in project.tool.options)
                ToolbarIconButton(
                  icon: _optionIcon(o),
                  tooltip: o.label,
                  active: store.isOptionOn(project.tool, o.id),
                  onTap: () => store.toggleOption(project.tool, o.id),
                ),
            ],
            const ToolbarSeparator(),
            ToolbarIconButton(icon: Icons.unfold_more, tooltip: '全部展开', onTap: hasProjects ? store.expandAll : null),
            ToolbarIconButton(icon: Icons.unfold_less, tooltip: '全部折叠', onTap: hasProjects ? store.collapseAll : null),
          ],
        ),
      ),
    );
  }

  Future<void> _executeGoal(BuildContext context) async {
    final target = store.targetModule;
    if (target == null) return;
    final (project, module) = target;
    final args = await showDialog<String>(
      context: context,
      builder: (_) => _GoalDialog(
        title: '执行 ${project.tool.name} 目标',
        module: module.name,
        prefix: store.commandFor(project, module, const []),
      ),
    );
    if (args != null) store.runRaw(project, module, args);
  }

  static IconData _optionIcon(BuildToolOption o) => switch (o.icon) {
        'cloud_off' => Icons.cloud_off_outlined,
        'skip' => Icons.block,
        _ => Icons.tune,
      };
}

/// 「执行 Maven 目标」:输入参数(`dependency:tree -Dverbose`),在选中的模块上运行。
class _GoalDialog extends StatefulWidget {
  const _GoalDialog({required this.title, required this.module, required this.prefix});

  final String title;
  final String module;

  /// 不带任务的命令(`mvn -f core/pom.xml`),显示在输入框前面。
  final String prefix;

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (_text.text.trim().isEmpty) return;
    Navigator.pop(context, _text.text);
  }

  @override
  Widget build(BuildContext context) {
    final exe = widget.prefix.split(' ').first;
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(widget.title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('在 ${widget.module} 上运行', style: _muted),
            const SizedBox(height: 10),
            TextField(
              controller: _text,
              autofocus: true,
              style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontFamily: 'monospace'),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                prefixText: '$exe ',
                prefixStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 13, fontFamily: 'monospace'),
                hintText: 'dependency:tree -Dverbose',
                hintStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 13),
                border: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
                enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('执行')),
      ],
    );
  }
}

class ToolbarSeparator extends StatelessWidget {
  const ToolbarSeparator({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 5), color: IntelliJTheme.border);
}

class ToolbarIconButton extends StatelessWidget {
  const ToolbarIconButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.color, this.active = false});

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
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: active ? BoxDecoration(color: IntelliJTheme.accentBlue.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4)) : null,
          child: Icon(icon, size: 16, color: enabled ? (color ?? IntelliJTheme.textSecondary) : IntelliJTheme.textMuted.withValues(alpha: 0.5)),
        ),
      ),
    );
  }
}

/// Maven 模块图标:蓝色斜体 m(IntelliJ 的模块图标);读取出错时红色。
class _ModuleIcon extends StatelessWidget {
  const _ModuleIcon({required this.error});

  final bool error;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      child: Text(
        'm',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: error ? const Color(0xFFE5534B) : _mavenBlue,
          fontSize: 17,
          fontStyle: FontStyle.italic,
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    );
  }
}

/// 文件夹 + 右下角小徽标:Lifecycle / Plugins 是齿轮,Repositories 是勾,Dependencies 是链接。
class _FolderIcon extends StatelessWidget {
  const _FolderIcon({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    final badge = switch (kind) {
      'repositories' => Icons.check,
      'dependencies' => Icons.link,
      _ => Icons.settings,
    };
    return SizedBox(
      width: 17,
      height: 16,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.folder_outlined, size: 15, color: IntelliJTheme.textSecondary),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              decoration: const BoxDecoration(color: IntelliJTheme.sidebarBg, shape: BoxShape.circle),
              child: Icon(badge, size: 9, color: _mavenBlue),
            ),
          ),
        ],
      ),
    );
  }
}

/// 树的一行。单击 / 双击自己判断(GestureDetector 的 onDoubleTap 会把单击延迟到双击超时之后)。
class ToolTreeRow extends StatefulWidget {
  const ToolTreeRow({
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
    this.trailingStyle = _muted,
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
  final TextStyle trailingStyle;
  final String? tooltip;
  final List<Widget> Function()? menu;

  @override
  State<ToolTreeRow> createState() => ToolTreeRowState();
}

class ToolTreeRowState extends State<ToolTreeRow> {
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
              width: 18,
              child: w.expandable
                  ? GestureDetector(
                      onTap: w.onToggle,
                      child: Icon(w.expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 16, color: IntelliJTheme.textSecondary),
                    )
                  : null,
            ),
            w.icon,
            const SizedBox(width: 6),
            Flexible(child: Text(w.label, style: _label, overflow: TextOverflow.ellipsis, maxLines: 1)),
            if (w.trailing != null) ...[
              const SizedBox(width: 6),
              Expanded(child: Text(w.trailing!, overflow: TextOverflow.ellipsis, maxLines: 1, style: w.trailingStyle)),
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
