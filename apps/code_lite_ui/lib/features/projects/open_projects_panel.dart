import 'package:flutter/material.dart';

import '../../core/state/project_manager.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/context_menu_region.dart';
import '../title_bar/project_menu.dart' show ProjectBadge, abbreviatePath;
import '../tool_window/tool_window_actions.dart';

const TextStyle _name = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 11);

/// 左侧的「Opening Projects」工具窗:当前打开的所有项目(一个进程、都留在内存里)。
/// 点一个切过去(它的标签、终端、语言服务器原样都在);× 才真正关掉它。
class OpenProjectsPanel extends StatelessWidget {
  const OpenProjectsPanel({
    super.key,
    required this.manager,
    required this.onSwitch,
    required this.onClose,
    required this.onCloseOthers,
    required this.onOpenFolder,
    this.home,
  });

  final ProjectManager manager;
  final ValueChanged<OpenProject> onSwitch;

  /// 关闭一个项目(有未保存的改动时由调用方先问)。
  final ValueChanged<OpenProject> onClose;
  final ValueChanged<OpenProject> onCloseOthers;
  final VoidCallback onOpenFolder;
  final String? home;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final projects = manager.projects;
        return Container(
          color: IntelliJTheme.panelBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
                // 侧栏可拖窄到 160px:标题可省略
                child: Row(
                  children: [
                    const Flexible(
                      child: Text(
                        'Opening Projects',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (projects.isNotEmpty) Text('${projects.length}', key: const ValueKey('open-projects-count'), style: _muted),
                    const Spacer(),
                    Tooltip(
                      message: '打开项目…',
                      child: InkWell(
                        key: const ValueKey('open-projects-add'),
                        onTap: onOpenFolder,
                        borderRadius: BorderRadius.circular(4),
                        child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.add, size: 16, color: IntelliJTheme.textMuted)),
                      ),
                    ),
                    const ToolWindowActions(),
                  ],
                ),
              ),
              Expanded(
                child: projects.isEmpty
                    ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('没有打开的项目', style: _muted)))
                    : ListView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: [
                          for (final p in projects)
                            _ProjectRow(
                              key: ValueKey('open-project-${p.path}'),
                              entry: p,
                              active: identical(manager.activeProject, p),
                              home: home,
                              others: projects.length > 1,
                              onSwitch: () => onSwitch(p),
                              onClose: () => onClose(p),
                              onCloseOthers: () => onCloseOthers(p),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
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
  });

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
          padding: const EdgeInsets.only(left: 10, right: 6),
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
      ],
      child: row,
    );
  }
}
