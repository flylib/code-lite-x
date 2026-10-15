import 'package:flutter/material.dart';

import '../../core/state/project_manager.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/context_menu_region.dart';
import '../title_bar/project_menu.dart' show ProjectBadge, abbreviatePath;
import '../tool_window/tool_window_actions.dart';

const TextStyle _name = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 11);

/// 左侧的「Opening」工具窗:当前打开的所有项目(一个进程、都留在内存里),以及项目组。
/// 点一个切过去(它的标签、终端、语言服务器原样都在);× 才真正关掉它。
///
/// 项目组(IntelliJ 的 Project Group):＋ 新建,把项目拖到组上归进去、拖到组外移出(右键菜单也能移)。
/// 组记住成员:关掉的项目在组里显示成灰色,点一下重新打开。
class OpenProjectsPanel extends StatelessWidget {
  const OpenProjectsPanel({
    super.key,
    required this.manager,
    required this.onSwitch,
    required this.onClose,
    required this.onCloseOthers,
    required this.onOpenPath,
    required this.onCloseGroup,
    this.home,
  });

  final ProjectManager manager;
  final ValueChanged<OpenProject> onSwitch;

  /// 关闭一个项目(有未保存的改动时由调用方先问)。
  final ValueChanged<OpenProject> onClose;
  final ValueChanged<OpenProject> onCloseOthers;

  /// 重新打开组里关掉的项目。
  final ValueChanged<String> onOpenPath;

  /// 关掉组里打开着的项目(逐个问未保存的改动)。
  final ValueChanged<ProjectGroup> onCloseGroup;
  final String? home;

  Widget _row(OpenProject p, List<OpenProject> projects, {required bool inGroup}) => _DraggableProject(
        path: p.path,
        name: p.name,
        child: _ProjectRow(
          key: ValueKey('open-project-${p.path}'),
          entry: p,
          active: identical(manager.activeProject, p),
          home: home,
          indent: inGroup,
          others: projects.length > 1,
          groupMenu: _groupMenu(context: null, path: p.path),
          onSwitch: () => onSwitch(p),
          onClose: () => onClose(p),
          onCloseOthers: () => onCloseOthers(p),
        ),
      );

  /// 右键菜单里的「移到项目组 ▸」/「移出项目组」。
  List<Widget> _groupMenu({required BuildContext? context, required String path}) {
    final current = manager.groupOf(path);
    final targets = [for (final g in manager.groups) if (!identical(g, current)) g];
    return [
      if (targets.isNotEmpty)
        SubmenuButton(
          menuChildren: [
            for (final g in targets) MenuItemButton(onPressed: () => manager.moveToGroup(path, g), child: Text(g.name)),
          ],
          child: const Text('移到项目组'),
        ),
      if (current != null) MenuItemButton(onPressed: () => manager.moveToGroup(path, null), child: Text('移出项目组「${current.name}」')),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final projects = manager.projects;
        final groups = manager.groups;
        final grouped = {for (final g in groups) ...g.members};
        final loose = [for (final p in projects) if (!grouped.contains(p.path)) p];
        return Container(
          color: IntelliJTheme.panelBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // IntelliJ 新 UI:标题栏和内容同一块底色,没有分隔线
              Container(
                height: 40,
                padding: const EdgeInsets.only(left: 12, right: 6),
                // 侧栏可拖窄到 160px:标题可省略
                child: Row(
                  children: [
                    const Flexible(
                      child: Text(
                        'Opening',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (projects.isNotEmpty) Text('${projects.length}', key: const ValueKey('open-projects-count'), style: _muted),
                    const Spacer(),
                    Tooltip(
                      message: '新建项目组…',
                      child: InkWell(
                        key: const ValueKey('open-projects-add'),
                        onTap: () => _newGroup(context),
                        borderRadius: BorderRadius.circular(4),
                        child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.add, size: 16, color: IntelliJTheme.textMuted)),
                      ),
                    ),
                    const ToolWindowActions(),
                  ],
                ),
              ),
              Expanded(
                child: projects.isEmpty && groups.isEmpty
                    ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('没有打开的项目', style: _muted)))
                    // 组外的空白处也是放置区:组里的项目拖到这里就移出项目组
                    : _DropZone(
                        key: const ValueKey('ungrouped-drop'),
                        accept: (path) => manager.groupOf(path) != null,
                        onDrop: (path) => manager.moveToGroup(path, null),
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          children: [
                            for (final g in groups) ...[
                              _DropZone(
                                key: ValueKey('group-drop-${g.name}'),
                                accept: (path) => !g.members.contains(ProjectManager.normalize(path)),
                                onDrop: (path) => manager.moveToGroup(path, g),
                                child: _GroupHeader(
                                  group: g,
                                  openCount: g.members.where((m) => manager.find(m) != null).length,
                                  onToggle: () => manager.setGroupCollapsed(g, !g.collapsed),
                                  onOpenAll: () => manager.openGroup(g),
                                  onCloseAll: () => onCloseGroup(g),
                                  onRename: () => _renameGroup(context, g),
                                  onDelete: () => manager.deleteGroup(g),
                                ),
                              ),
                              if (!g.collapsed)
                                for (final m in g.members)
                                  if (manager.find(m) case final open?)
                                    _row(open, projects, inGroup: true)
                                  else
                                    _DraggableProject(
                                      path: m,
                                      name: OpenProject(m).name,
                                      child: _ClosedMemberRow(
                                        key: ValueKey('closed-member-$m'),
                                        path: m,
                                        home: home,
                                        onOpen: () => onOpenPath(m),
                                        onRemove: () => manager.moveToGroup(m, null),
                                        groupMenu: _groupMenu(context: context, path: m),
                                      ),
                                    ),
                            ],
                            for (final p in loose) _row(p, projects, inGroup: false),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _newGroup(BuildContext context) async {
    final name = await showGroupNameDialog(context, title: '新建项目组', action: '创建', available: manager.groupNameAvailable);
    if (name != null) await manager.createGroup(name);
  }

  Future<void> _renameGroup(BuildContext context, ProjectGroup g) async {
    final name = await showGroupNameDialog(
      context,
      title: '重命名项目组',
      action: '重命名',
      initial: g.name,
      available: (n) => manager.groupNameAvailable(n, except: g),
    );
    if (name != null) await manager.renameGroup(g, name);
  }
}

/// 输入项目组名字的对话框;名字为空或重名时不让确定。返回名字,取消返回 null。
Future<String?> showGroupNameDialog(
  BuildContext context, {
  required String title,
  required String action,
  required bool Function(String name) available,
  String initial = '',
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _GroupNameDialog(title: title, action: action, available: available, initial: initial),
    );

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog({required this.title, required this.action, required this.available, required this.initial});

  final String title;
  final String action;
  final bool Function(String name) available;
  final String initial;

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  // 对话框自己持有:关闭动画放完、对话框销毁时才释放
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (widget.available(name)) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final name = _controller.text.trim();
    final ok = widget.available(name);
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(widget.title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const ValueKey('group-name-field'),
          controller: _controller,
          autofocus: true,
          style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            hintText: '比如 bcpoker',
            hintStyle: _muted,
            errorText: name.isEmpty || ok ? null : '已经有叫「$name」的项目组了',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: ok ? _submit : null, child: Text(widget.action)),
      ],
    );
  }
}

/// 可以拖动的项目(拖到项目组上归组,拖到组外移出)。
class _DraggableProject extends StatelessWidget {
  const _DraggableProject({required this.path, required this.name, required this.child});

  final String path;
  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) => Draggable<String>(
        data: path,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: IntelliJTheme.panelBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: IntelliJTheme.accentBlue),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3))],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ProjectBadge(name: name, size: 18),
              const SizedBox(width: 8),
              Text(name, style: _name),
            ]),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: child),
        child: child,
      );
}

/// 放置区:拖着项目经过时高亮,松手时 [onDrop]。
class _DropZone extends StatelessWidget {
  const _DropZone({super.key, required this.accept, required this.onDrop, required this.child});

  final bool Function(String path) accept;
  final ValueChanged<String> onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) => DragTarget<String>(
        onWillAcceptWithDetails: (d) => accept(d.data),
        onAcceptWithDetails: (d) => onDrop(d.data),
        builder: (context, candidates, _) => Container(
          decoration: BoxDecoration(
            color: candidates.isEmpty ? null : IntelliJTheme.accentBlue.withValues(alpha: 0.12),
            border: candidates.isEmpty ? null : Border.all(color: IntelliJTheme.accentBlue.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: child,
        ),
      );
}

/// 项目组的标题行:折叠箭头、文件夹图标、名字、打开数 / 成员数;右键菜单管理这个组。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.openCount,
    required this.onToggle,
    required this.onOpenAll,
    required this.onCloseAll,
    required this.onRename,
    required this.onDelete,
  });

  final ProjectGroup group;
  final int openCount;
  final VoidCallback onToggle;
  final VoidCallback onOpenAll;
  final VoidCallback onCloseAll;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final total = group.members.length;
    return ContextMenuRegion(
      menuBuilder: (_) => [
        MenuItemButton(onPressed: openCount < total ? onOpenAll : null, child: const Text('全部打开')),
        MenuItemButton(onPressed: openCount > 0 ? onCloseAll : null, child: const Text('全部关闭')),
        const MenuDivider(),
        MenuItemButton(onPressed: onRename, child: const Text('重命名…')),
        MenuItemButton(onPressed: onDelete, child: const Text('删除项目组(项目不关)')),
      ],
      child: InkWell(
        key: ValueKey('group-${group.name}'),
        onTap: onToggle,
        hoverColor: IntelliJTheme.hoverBg,
        child: SizedBox(
          height: 30,
          child: Row(
            children: [
              const SizedBox(width: 6),
              Icon(group.collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: IntelliJTheme.textMuted),
              const SizedBox(width: 2),
              const Icon(Icons.folder_outlined, size: 15, color: IntelliJTheme.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  group.name,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: _name.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 6),
              Text(total == 0 ? '把项目拖到这里' : '$openCount/$total', style: _muted),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 组里已经关掉的项目:灰色,点一下重新打开。
class _ClosedMemberRow extends StatelessWidget {
  const _ClosedMemberRow({
    super.key,
    required this.path,
    required this.home,
    required this.onOpen,
    required this.onRemove,
    required this.groupMenu,
  });

  final String path;
  final String? home;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  final List<Widget> groupMenu;

  @override
  Widget build(BuildContext context) {
    final name = OpenProject(path).name;
    return ContextMenuRegion(
      menuBuilder: (_) => [
        MenuItemButton(onPressed: onOpen, child: const Text('打开项目')),
        const MenuDivider(),
        ...groupMenu,
      ],
      child: Tooltip(
        message: '已关闭,点击重新打开',
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: onOpen,
          hoverColor: IntelliJTheme.hoverBg,
          child: Container(
            height: 48,
            padding: const EdgeInsets.only(left: 28, right: 6),
            child: Row(
              children: [
                Opacity(opacity: 0.35, child: ProjectBadge(name: name, size: 26)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, overflow: TextOverflow.ellipsis, maxLines: 1, style: _name.copyWith(color: IntelliJTheme.textMuted)),
                      const SizedBox(height: 2),
                      Text(abbreviatePath(path, home), overflow: TextOverflow.ellipsis, maxLines: 1, style: _muted.copyWith(color: IntelliJTheme.textMuted.withValues(alpha: 0.7))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectRow extends StatefulWidget {
  const _ProjectRow({
    super.key,
    required this.entry,
    required this.active,
    required this.home,
    required this.others,
    required this.onSwitch,
    required this.onClose,
    required this.onCloseOthers,
    this.indent = false,
    this.groupMenu = const [],
  });

  /// 在项目组里:往里缩一点。
  final bool indent;

  /// 右键菜单里移到 / 移出项目组的那几项。
  final List<Widget> groupMenu;

  final OpenProject entry;
  final bool active;
  final String? home;

  /// 还有别的项目(「关闭其它项目」才有意义)。
  final bool others;
  final VoidCallback onSwitch;
  final VoidCallback onClose;
  final VoidCallback onCloseOthers;

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final dimmed = !e.isLoaded && !e.loading;
    final showClose = _hover || widget.active;
    final row = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onSwitch,
        hoverColor: IntelliJTheme.hoverBg,
        child: Container(
          height: 48,
          padding: EdgeInsets.only(left: widget.indent ? 26 : 10, right: 6),
          decoration: BoxDecoration(
            color: widget.active ? IntelliJTheme.selectionBg : null,
            border: Border(left: BorderSide(color: widget.active ? IntelliJTheme.accentBlue : Colors.transparent, width: 2)),
          ),
          child: Row(
            children: [
              Opacity(opacity: dimmed ? 0.6 : 1, child: ProjectBadge(name: e.name, size: 26)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: _name.copyWith(fontWeight: widget.active ? FontWeight.w700 : FontWeight.w400, color: dimmed ? IntelliJTheme.textSecondary : IntelliJTheme.textHigh),
                    ),
                    const SizedBox(height: 2),
                    Text(abbreviatePath(e.path, widget.home), overflow: TextOverflow.ellipsis, maxLines: 1, style: _muted),
                  ],
                ),
              ),
              if (e.loading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: IntelliJTheme.accentBlue)),
                )
              else if (e.error != null)
                Tooltip(message: e.error!, child: const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.error_outline, size: 15, color: IntelliJTheme.gitRed)))
              else if (e.context != null)
                // 有没写盘的改动:小圆点(自动保存开着时一般一闪而过)
                ListenableBuilder(
                  listenable: e.context!.sessions,
                  builder: (context, _) => e.context!.hasDirtyTabs
                      ? Tooltip(
                          message: '有未保存的改动',
                          child: Container(key: const ValueKey('project-dirty'), width: 7, height: 7, margin: const EdgeInsets.symmetric(horizontal: 6), decoration: const BoxDecoration(color: IntelliJTheme.accentYellow, shape: BoxShape.circle)),
                        )
                      : const SizedBox.shrink(),
                ),
              SizedBox(
                width: 22,
                child: showClose
                    ? Tooltip(
                        message: '关闭项目(释放它的语言服务器和终端)',
                        waitDuration: const Duration(milliseconds: 400),
                        child: InkWell(
                          key: ValueKey('close-project-${e.path}'),
                          onTap: widget.onClose,
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.close, size: 15, color: IntelliJTheme.textMuted)),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
    return ContextMenuRegion(
      menuBuilder: (_) => [
        MenuItemButton(onPressed: widget.active ? null : widget.onSwitch, child: const Text('切换到此项目')),
        const MenuDivider(),
        MenuItemButton(onPressed: widget.onClose, child: const Text('关闭项目')),
        MenuItemButton(onPressed: widget.others ? widget.onCloseOthers : null, child: const Text('关闭其它项目')),
        if (widget.groupMenu.isNotEmpty) ...[const MenuDivider(), ...widget.groupMenu],
      ],
      child: row,
    );
  }
}
