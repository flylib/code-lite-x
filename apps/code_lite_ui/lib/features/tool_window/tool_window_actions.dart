import 'package:flutter/material.dart';

import '../../core/state/layout_store.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/context_menu_region.dart' show darculaMenuTheme, MenuDivider;

/// 告诉左侧工具窗它是谁、布局在哪:标题栏右侧的 [ToolWindowActions] 据此工作。
/// 面板单独使用(测试、预览)时没有这个 scope,按钮不显示。
class ToolWindowScope extends InheritedWidget {
  const ToolWindowScope({super.key, required this.tool, required this.layout, required super.child});

  final LeftTool tool;
  final LayoutStore layout;

  static ToolWindowScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ToolWindowScope>();

  @override
  bool updateShouldNotify(ToolWindowScope old) => old.tool != tool || old.layout != layout;
}

/// 左侧工具窗标题栏右侧的按钮(IntelliJ 工具窗标题栏的样子):
/// 「拆分到下方 / 移回上方」、⋮ 选项菜单(移动到 ▸ 左侧上方 / 左侧下方、隐藏)、「—」收起。
class ToolWindowActions extends StatelessWidget {
  const ToolWindowActions({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = ToolWindowScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final layout = scope.layout;
    final tool = scope.tool;
    return ListenableBuilder(
      listenable: layout,
      builder: (context, _) {
        final atBottom = layout.slotOf(tool) == ToolSlot.bottom;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HeaderButton(
              icon: atBottom ? Icons.vertical_align_top : Icons.splitscreen_outlined,
              tooltip: atBottom ? '移到左侧上方' : '拆分到左侧下方(与上方的工具窗同时显示)',
              onTap: () => layout.moveLeftTool(tool, atBottom ? ToolSlot.top : ToolSlot.bottom),
            ),
            _OptionsMenu(layout: layout, tool: tool),
            _HeaderButton(icon: Icons.remove, tooltip: '隐藏', onTap: () => layout.hideLeftTool(tool)),
          ],
        );
      },
    );
  }
}

class _OptionsMenu extends StatelessWidget {
  const _OptionsMenu({required this.layout, required this.tool});

  final LayoutStore layout;
  final LeftTool tool;

  @override
  Widget build(BuildContext context) {
    final slot = layout.slotOf(tool);
    Widget check(bool on) => SizedBox(width: 18, child: on ? const Icon(Icons.check, size: 14) : null);
    return Theme(
      data: darculaMenuTheme(Theme.of(context)),
      child: MenuAnchor(
        menuChildren: [
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                leadingIcon: check(slot == ToolSlot.top),
                onPressed: () => layout.moveLeftTool(tool, ToolSlot.top),
                child: const Text('左侧上方'),
              ),
              MenuItemButton(
                leadingIcon: check(slot == ToolSlot.bottom),
                onPressed: () => layout.moveLeftTool(tool, ToolSlot.bottom),
                child: const Text('左侧下方'),
              ),
            ],
            child: const Text('移动到'),
          ),
          const MenuDivider(),
          MenuItemButton(onPressed: () => layout.hideLeftTool(tool), child: const Text('隐藏')),
        ],
        builder: (context, controller, _) => _HeaderButton(
          icon: Icons.more_vert,
          tooltip: '选项',
          onTap: () => controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(width: 24, height: 24, child: Icon(icon, size: 16, color: IntelliJTheme.textSecondary)),
      ),
    );
  }
}
