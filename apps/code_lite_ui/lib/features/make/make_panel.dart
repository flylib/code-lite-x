import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/build_tools/makefile.dart';
import '../../core/theme/intellij_theme.dart';
import '../build_tools/build_tools_panel.dart' show ToolTreeRow, ToolWindowTitleRow, ToolbarIconButton, ToolbarSeparator;
import '../project_explorer/project_explorer_widget.dart' show MakefileIcon;
import 'make_store.dart';

const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const Color _run = Color(0xFF5FB865);

/// make 工具窗,照 IntelliJ 的 make 插件:标题、工具栏,项目里每个 Makefile 一个节点,下面是它的目标。
/// 双击目标(或选中后按工具栏 ▶ / 回车)在新的终端标签里运行 `make <目标>`。
class MakePanel extends StatelessWidget {
  const MakePanel({super.key, required this.store, this.onOpenFileAt, this.onOpenSettings});

  final MakeStore store;

  /// 跳到定义:打开 Makefile(相对项目根)并把光标放到目标那一行。
  final void Function(String path, int line)? onOpenFileAt;

  /// 工具栏的设置按钮:打开 设置 ▸ 构建工具(make 的路径)。
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final rows = <Widget>[];
        for (final f in store.files) {
          final open = store.isExpanded(f.path);
          rows.add(ToolTreeRow(
            key: ValueKey('make-file-${f.path}'),
            depth: 0,
            expandable: true,
            expanded: open,
            selected: store.selectedFile == f.path && store.selectedTarget == null,
            icon: const MakefileIcon(size: 15),
            label: f.path,
            trailing: f.targets.isEmpty ? '(没有目标)' : null,
            tooltip: f.path,
            onTap: (_) => store.select(f.path),
            onDoubleTap: () => store.toggleExpanded(f.path),
            onToggle: () => store.toggleExpanded(f.path),
            menu: () => [
              MenuItemButton(onPressed: onOpenFileAt == null ? null : () => onOpenFileAt!(f.path, 0), child: Text('打开 ${f.path.split('/').last}')),
              MenuItemButton(onPressed: store.reload, child: const Text('重新加载')),
            ],
          ));
          if (!open) continue;
          for (final t in store.visibleTargets(f)) {
            rows.add(_targetRow(f, t));
          }
        }
        return Container(
          color: IntelliJTheme.sidebarBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ToolWindowTitleRow(title: 'make'),
              _Toolbar(store: store, onOpenSettings: onOpenSettings),
              if (store.loading && store.files.isEmpty) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: store.files.isEmpty
                    ? Center(
                        child: Text(store.loading ? '正在查找 Makefile…' : '项目里没有 Makefile', style: _muted),
                      )
                    // 回车运行选中的目标(同 IntelliJ)
                    : CallbackShortcuts(
                        bindings: {const SingleActivator(LogicalKeyboardKey.enter): store.runSelected},
                        child: Focus(
                          child: ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: rows),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _targetRow(MakeFile f, MakeTarget t) {
    final command = store.commandFor(f.path, t.name);
    return ToolTreeRow(
      key: ValueKey('make-target-${f.path}/${t.name}'),
      depth: 1,
      expandable: false,
      expanded: false,
      selected: store.selectedFile == f.path && store.selectedTarget == t.name,
      icon: Icon(Icons.gps_fixed, size: 13, color: t.special ? IntelliJTheme.textMuted : IntelliJTheme.textSecondary),
      label: t.name,
      tooltip: command,
      onTap: (_) => store.select(f.path, t.name),
      onDoubleTap: () => store.run(f.path, t.name),
      menu: () => [
        MenuItemButton(
          leadingIcon: const Icon(Icons.play_arrow, size: 16, color: _run),
          onPressed: () => store.run(f.path, t.name),
          child: Text("运行 'make ${t.name}'"),
        ),
        MenuItemButton(
          onPressed: onOpenFileAt == null ? null : () => onOpenFileAt!(f.path, t.line),
          child: const Text('跳到定义'),
        ),
        MenuItemButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          child: const Text('复制命令行'),
        ),
      ],
    );
  }
}

/// 工具栏(同 IntelliJ 的 make 窗口):运行、重新加载、全部展开 / 折叠、按名字排序、显示特殊目标、设置。
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.store, this.onOpenSettings});

  final MakeStore store;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final has = store.files.isNotEmpty;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle), bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      // 侧栏可拖窄:放不下时横向滚动
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ToolbarIconButton(
              key: const ValueKey('make-run'),
              icon: Icons.play_arrow,
              color: _run,
              tooltip: store.selectedTarget == null ? '运行目标(先选中一个目标)' : "运行 'make ${store.selectedTarget}'",
              onTap: store.canRunSelected ? store.runSelected : null,
            ),
            ToolbarIconButton(key: const ValueKey('make-reload'), icon: Icons.sync, tooltip: '重新加载 Makefile', onTap: store.loading ? null : store.reload),
            const ToolbarSeparator(),
            ToolbarIconButton(icon: Icons.unfold_more, tooltip: '全部展开', onTap: has ? store.expandAll : null),
            ToolbarIconButton(icon: Icons.unfold_less, tooltip: '全部折叠', onTap: has ? store.collapseAll : null),
            const ToolbarSeparator(),
            ToolbarIconButton(
              key: const ValueKey('make-sort'),
              icon: Icons.sort_by_alpha,
              tooltip: '按名字排序',
              active: store.sortByName,
              onTap: store.toggleSortByName,
            ),
            ToolbarIconButton(
              key: const ValueKey('make-special'),
              icon: Icons.visibility_outlined,
              tooltip: '显示特殊目标(.PHONY 等)',
              active: store.showSpecial,
              onTap: store.toggleShowSpecial,
            ),
            const ToolbarSeparator(),
            ToolbarIconButton(key: const ValueKey('make-settings'), icon: Icons.settings_outlined, tooltip: 'make 设置(可执行文件路径)', onTap: onOpenSettings),
          ],
        ),
      ),
    );
  }
}
