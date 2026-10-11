import 'package:flutter/material.dart';

import '../../core/state/layout_store.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/intellij_theme.dart';
import '../bottom_tools/bottom_tools_widget.dart';
import 'stripe_button.dart';

export '../../core/state/layout_store.dart' show SideTool, ToolSide, ToolSlot;

/// 左侧活动条。上半段切左侧工具窗,下半段切底部工具窗(IntelliJ 布局),最下面是调试和通知。设置在菜单里(⌘,)。
///
/// 之前左侧工具窗和底部工具窗的按钮混在一个 enum 里,选中态语义也混着;
/// 现在两组各自独立 —— 与 IntelliJ 一致,也和 design/Main.dc.html 对得上。
class ActivityStripeWidget extends StatelessWidget {
  const ActivityStripeWidget({
    super.key,
    required this.leftTool,
    required this.isLeftOpen,
    required this.bottomTab,
    required this.isBottomOpen,
    required this.onSelectTool,
    required this.onSelectBottomTab,
    this.hasNotification = false,
    this.buildToolTitle,
    this.visibleTools,
    this.slotOf,
    this.sideOf,
  });

  final SideTool leftTool;
  final bool isLeftOpen;
  final BottomToolTab bottomTab;
  final bool isBottomOpen;
  final ValueChanged<SideTool> onSelectTool;
  final ValueChanged<BottomToolTab> onSelectBottomTab;

  /// 通知按钮上的小黄点。
  final bool hasNotification;

  /// 项目里检测到了构建工具(Maven……)时为它的名字,活动条多出构建工具窗的按钮;null 时不显示。
  final String? buildToolTitle;

  /// 正在显示的左侧工具窗(上下拆分时可能有两个);null 时按 [leftTool] / [isLeftOpen] 判断。
  final Set<SideTool>? visibleTools;

  /// 工具窗放在左上方还是左下方;放在左下方的按钮排在分隔线下面(IntelliJ 的做法)。null 时都在上方。
  final ToolSlot Function(SideTool tool)? slotOf;

  /// 工具窗停靠在哪一侧;放到右侧的不在这条活动条上(在 [RightStripeWidget])。null 时都在左侧。
  final ToolSide Function(SideTool tool)? sideOf;

  bool _isVisible(SideTool tool) => visibleTools?.contains(tool) ?? (isLeftOpen && leftTool == tool);

  /// 某一块([slot])的左侧工具窗按钮,按钮之间留 6px。
  List<Widget> _leftButtons(ToolSlot slot) => spacedButtons([
        for (final tool in SideTool.values)
          if ((sideOf?.call(tool) ?? ToolSide.left) == ToolSide.left && (slotOf?.call(tool) ?? ToolSlot.top) == slot)
            sideToolButton(tool, active: _isVisible(tool), onTap: () => onSelectTool(tool), buildToolTitle: buildToolTitle),
      ]);

  @override
  Widget build(BuildContext context) {
    final lower = _leftButtons(ToolSlot.bottom);
    return Container(
      width: IntelliJMetrics.activityStripe,
      decoration: const BoxDecoration(
        color: IntelliJTheme.stripeBg,
        border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          ..._leftButtons(ToolSlot.top),
          // 放到左下方的工具窗:分隔线下面
          if (lower.isNotEmpty) ...[
            Container(
              width: 20,
              height: 1,
              margin: const EdgeInsets.symmetric(vertical: 8),
              color: IntelliJTheme.border,
            ),
            ...lower,
          ],

          const Spacer(),

          // 下半段:底部工具窗(与 IntelliJ 一致,贴着它们打开的位置)。
          StripeButton(
            icon: Icons.terminal_outlined,
            tooltip: '终端 (⌥F12)',
            isActive: isBottomOpen && bottomTab == BottomToolTab.terminal,
            onTap: () => onSelectBottomTab(BottomToolTab.terminal),
          ),
          const SizedBox(height: 6),
          StripeButton(
            iconBuilder: (color, size) => GitBranchIcon(color: color, size: size),
            tooltip: 'Git 提交与日志',
            isActive: isBottomOpen && bottomTab == BottomToolTab.git,
            onTap: () => onSelectBottomTab(BottomToolTab.git),
          ),
          const SizedBox(height: 6),
          // 调试和通知放在最下面(原先在标题栏右上角和右侧活动条)。
          StripeButton(
            icon: Icons.bug_report_outlined,
            tooltip: 'Debug (Shift+F9)',
            isActive: false,
            onTap: () {},
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.notifications_none_outlined,
            tooltip: '通知',
            isActive: false,
            badgeColor: hasNotification ? IntelliJTheme.accentYellow : null,
            onTap: () {},
          ),
          // 设置在菜单里:CodeLiteX ▸ Settings…(⌘,)。
        ],
      ),
    );
  }
}

/// 侧边工具窗在活动条上的按钮;[SideTool.build] 在项目里没有构建工具时没有按钮(null)。
Widget? sideToolButton(SideTool tool, {required bool active, required VoidCallback onTap, String? buildToolTitle}) {
  return switch (tool) {
    SideTool.project => StripeButton(icon: Icons.folder_outlined, tooltip: '项目 (⌘1)', isActive: active, onTap: onTap),
    SideTool.commit => StripeButton(icon: Icons.task_alt, tooltip: 'Commit (⌘0)', isActive: active, onTap: onTap),
    SideTool.pullRequests => StripeButton(
        iconBuilder: (color, size) => PullRequestIcon(color: color, size: size),
        tooltip: 'Pull Requests',
        isActive: active,
        onTap: onTap,
      ),
    SideTool.structure => StripeButton(icon: Icons.account_tree_outlined, tooltip: '结构 (⌘7)', isActive: active, onTap: onTap),
    SideTool.openProjects => StripeButton(icon: Icons.layers_outlined, tooltip: 'Opening Projects', isActive: active, onTap: onTap),
    SideTool.build => buildToolTitle == null
        ? null
        : StripeButton(
            iconBuilder: (color, size) => BuildToolIcon(color: color, size: size),
            tooltip: buildToolTitle,
            isActive: active,
            onTap: onTap,
          ),
  };
}

/// 按钮之间留 6px;null(没有按钮的工具窗)跳过。
List<Widget> spacedButtons(Iterable<Widget?> buttons) {
  final list = [for (final b in buttons) if (b != null) b];
  return [
    for (var i = 0; i < list.length; i++) ...[if (i > 0) const SizedBox(height: 6), list[i]],
  ];
}

/// 右活动条:只放停靠在右侧的工具窗按钮,上方一组、分隔线、下方一组;右侧没有工具窗时整条不显示。
class RightStripeWidget extends StatelessWidget {
  const RightStripeWidget({
    super.key,
    required this.visibleTools,
    required this.sideOf,
    required this.slotOf,
    required this.onSelectTool,
    this.buildToolTitle,
  });

  final Set<SideTool> visibleTools;
  final ToolSide Function(SideTool tool) sideOf;
  final ToolSlot Function(SideTool tool) slotOf;
  final ValueChanged<SideTool> onSelectTool;
  final String? buildToolTitle;

  List<Widget> _buttons(ToolSlot slot) => spacedButtons([
        for (final tool in SideTool.values)
          if (sideOf(tool) == ToolSide.right && slotOf(tool) == slot)
            sideToolButton(tool, active: visibleTools.contains(tool), onTap: () => onSelectTool(tool), buildToolTitle: buildToolTitle),
      ]);

  @override
  Widget build(BuildContext context) {
    final upper = _buttons(ToolSlot.top);
    final lower = _buttons(ToolSlot.bottom);
    if (upper.isEmpty && lower.isEmpty) return const SizedBox.shrink();
    return Container(
      width: IntelliJMetrics.activityStripe,
      decoration: const BoxDecoration(
        color: IntelliJTheme.stripeBg,
        border: Border(left: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          ...upper,
          if (upper.isNotEmpty && lower.isNotEmpty)
            Container(width: 20, height: 1, margin: const EdgeInsets.symmetric(vertical: 8), color: IntelliJTheme.border),
          ...lower,
        ],
      ),
    );
  }
}

/// 构建工具窗的图标:斜体 m(IntelliJ 的 Maven 工具窗图标)。
class BuildToolIcon extends StatelessWidget {
  const BuildToolIcon({super.key, required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Text(
          'm',
          style: TextStyle(color: color, fontSize: size * 1.15, fontWeight: FontWeight.w500, fontStyle: FontStyle.italic, height: 1),
        ),
      ),
    );
  }
}
