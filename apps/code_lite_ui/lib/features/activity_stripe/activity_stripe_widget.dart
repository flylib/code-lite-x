import '../project_explorer/project_explorer_widget.dart' show MakefileIcon;
import 'package:flutter/material.dart';

import '../../core/keymap/keymap.dart';
import '../../core/state/layout_store.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/intellij_theme.dart';
import '../bottom_tools/bottom_tools_widget.dart';
import 'stripe_button.dart';

export '../../core/state/layout_store.dart' show SideTool, ToolSide, ToolSlot;

/// 左侧活动条。上半段切左侧工具窗,下半段切底部工具窗(IntelliJ 布局),最下面是调试。通知在右活动条顶上。设置在菜单里(⌘,)。
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
    this.buildToolTitle,
    this.showMake = false,
    this.visibleTools,
    this.slotOf,
    this.sideOf,
    this.keymap,
  });

  final SideTool leftTool;
  final bool isLeftOpen;
  final BottomToolTab bottomTab;
  final bool isBottomOpen;
  final ValueChanged<SideTool> onSelectTool;
  final ValueChanged<BottomToolTab> onSelectBottomTab;

  /// 项目里检测到了构建工具(Maven……)时为它的名字,活动条多出构建工具窗的按钮;null 时不显示。
  final String? buildToolTitle;

  /// 项目里有 Makefile:显示 make 工具窗的按钮。
  final bool showMake;

  /// 正在显示的左侧工具窗(上下拆分时可能有两个);null 时按 [leftTool] / [isLeftOpen] 判断。
  final Set<SideTool>? visibleTools;

  /// 工具窗放在左上方还是左下方;放在左下方的按钮排在分隔线下面(IntelliJ 的做法)。null 时都在上方。
  final ToolSlot Function(SideTool tool)? slotOf;

  /// 工具窗停靠在哪一侧;放到右侧的不在这条活动条上(在 [RightStripeWidget])。null 时都在左侧。
  final ToolSide Function(SideTool tool)? sideOf;

  /// 按钮提示里显示的快捷键;null 时按默认键位。
  final KeymapStore? keymap;

  bool _isVisible(SideTool tool) => visibleTools?.contains(tool) ?? (isLeftOpen && leftTool == tool);

  /// 某一块([slot])的左侧工具窗按钮,按钮之间留 6px。
  List<Widget> _leftButtons(ToolSlot slot) => spacedButtons([
        for (final tool in SideTool.values)
          if ((sideOf?.call(tool) ?? ToolSide.left) == ToolSide.left && (slotOf?.call(tool) ?? ToolSlot.top) == slot)
            sideToolButton(tool, active: _isVisible(tool), onTap: () => onSelectTool(tool), buildToolTitle: buildToolTitle, showMake: showMake, keymap: keymap),
      ]);

  @override
  Widget build(BuildContext context) {
    final lower = _leftButtons(ToolSlot.bottom);
    return Container(
      width: IntelliJMetrics.activityStripe,
      color: IntelliJTheme.stripeBg,
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        children: [
          ..._leftButtons(ToolSlot.top),
          // 放到左下方的工具窗:分隔线下面
          if (lower.isNotEmpty) ...[
            Container(width: 18, height: 1, margin: const EdgeInsets.symmetric(vertical: 6), color: IntelliJTheme.border),
            ...lower,
          ],

          const Spacer(),

          // 下半段:底部工具窗(与 IntelliJ 一致,贴着它们打开的位置)。
          StripeButton(
            icon: Icons.terminal_outlined,
            tooltip: withShortcut('终端', KeymapIds.terminal, keymap),
            isActive: isBottomOpen && bottomTab == BottomToolTab.terminal,
            onTap: () => onSelectBottomTab(BottomToolTab.terminal),
          ),
          const SizedBox(height: _gap),
          StripeButton(
            iconBuilder: (color, size) => GitBranchIcon(color: color, size: size),
            tooltip: withShortcut('Git 提交与日志', KeymapIds.git, keymap),
            isActive: isBottomOpen && bottomTab == BottomToolTab.git,
            onTap: () => onSelectBottomTab(BottomToolTab.git),
          ),
          const SizedBox(height: _gap),
          // 调试放在最下面(原先在标题栏右上角)。
          StripeButton(
            icon: Icons.bug_report_outlined,
            tooltip: 'Debug (Shift+F9)',
            isActive: false,
            onTap: () {},
          ),
          // 设置在菜单里:CodeLiteX ▸ Settings…(⌘,)。
        ],
      ),
    );
  }
}

/// 工具窗对应的快捷键操作。
String keymapIdOf(SideTool tool) => switch (tool) {
      SideTool.project => KeymapIds.project,
      SideTool.commit => KeymapIds.commit,
      SideTool.pullRequests => KeymapIds.pullRequests,
      SideTool.structure => KeymapIds.structure,
      SideTool.openProjects => KeymapIds.openProjects,
      SideTool.build => KeymapIds.build,
      SideTool.make => KeymapIds.make,
    };

/// 没传快捷键配置时(单独用活动条)按默认键位显示。
final KeymapStore _defaultKeymap = KeymapStore();

/// 按钮提示:名字加上当前的快捷键(没有快捷键就只有名字)。
String withShortcut(String name, String actionId, KeymapStore? keymap) {
  final label = (keymap ?? _defaultKeymap).labelOf(actionId);
  return label == null ? name : '$name ($label)';
}

/// 侧边工具窗在活动条上的按钮;[SideTool.build] 在项目里没有构建工具时、[SideTool.make] 没有 Makefile 时没有按钮(null)。
Widget? sideToolButton(SideTool tool,
    {required bool active, required VoidCallback onTap, String? buildToolTitle, bool showMake = false, KeymapStore? keymap}) {
  String tip(String name) => withShortcut(name, keymapIdOf(tool), keymap);
  return switch (tool) {
    SideTool.project => StripeButton(icon: Icons.folder_outlined, tooltip: tip('项目'), isActive: active, onTap: onTap),
    SideTool.commit => StripeButton(icon: Icons.task_alt, tooltip: tip('Commit'), isActive: active, onTap: onTap),
    SideTool.pullRequests => StripeButton(
        iconBuilder: (color, size) => PullRequestIcon(color: color, size: size),
        tooltip: tip('Pull Requests'),
        isActive: active,
        onTap: onTap,
      ),
    SideTool.structure => StripeButton(icon: Icons.account_tree_outlined, tooltip: tip('结构'), isActive: active, onTap: onTap),
    SideTool.openProjects => StripeButton(icon: Icons.layers_outlined, tooltip: tip('Opening Projects'), isActive: active, onTap: onTap),
    SideTool.build => buildToolTitle == null
        ? null
        : StripeButton(
            iconBuilder: (color, size) => BuildToolIcon(color: color, size: size),
            tooltip: tip(buildToolTitle),
            isActive: active,
            onTap: onTap,
          ),
    SideTool.make => !showMake
        ? null
        : StripeButton(
            iconBuilder: (color, size) => MakefileIcon(color: color, size: size),
            tooltip: tip('make'),
            isActive: active,
            onTap: onTap,
          ),
  };
}

/// 活动条按钮之间的间距(截图里按钮中心相距 40px)。
const double _gap = 10;

/// 按钮之间留 [_gap];null(没有按钮的工具窗)跳过。
List<Widget> spacedButtons(Iterable<Widget?> buttons) {
  final list = [for (final b in buttons) if (b != null) b];
  return [
    for (var i = 0; i < list.length; i++) ...[if (i > 0) const SizedBox(height: _gap), list[i]],
  ];
}

/// 右活动条(IntelliJ 的右侧栏):始终在窗口最右边。顶上是通知,下面是停靠在右侧的工具窗按钮,
/// 上方一组、分隔线、下方一组。
class RightStripeWidget extends StatelessWidget {
  const RightStripeWidget({
    super.key,
    required this.visibleTools,
    required this.sideOf,
    required this.slotOf,
    required this.onSelectTool,
    this.buildToolTitle,
    this.showMake = false,
    this.hasNotification = false,
    this.keymap,
  });

  final Set<SideTool> visibleTools;
  final ToolSide Function(SideTool tool) sideOf;
  final ToolSlot Function(SideTool tool) slotOf;
  final ValueChanged<SideTool> onSelectTool;
  final String? buildToolTitle;

  /// 项目里有 Makefile:显示 make 工具窗的按钮。
  final bool showMake;

  /// 通知按钮上的小黄点。
  final bool hasNotification;

  /// 按钮提示里显示的快捷键;null 时按默认键位。
  final KeymapStore? keymap;

  List<Widget> _buttons(ToolSlot slot) => spacedButtons([
        for (final tool in SideTool.values)
          if (sideOf(tool) == ToolSide.right && slotOf(tool) == slot)
            sideToolButton(tool, active: visibleTools.contains(tool), onTap: () => onSelectTool(tool), buildToolTitle: buildToolTitle, showMake: showMake, keymap: keymap),
      ]);

  @override
  Widget build(BuildContext context) {
    final upper = _buttons(ToolSlot.top);
    final lower = _buttons(ToolSlot.bottom);
    return Container(
      width: IntelliJMetrics.activityStripe,
      color: IntelliJTheme.stripeBg,
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Column(
        children: [
          StripeButton(
            icon: Icons.notifications_none_outlined,
            tooltip: '通知',
            isActive: false,
            badgeColor: hasNotification ? IntelliJTheme.accentYellow : null,
            onTap: () {},
          ),
          if (upper.isNotEmpty) ...[const SizedBox(height: _gap), ...upper],
          if (lower.isNotEmpty) ...[
            Container(width: 18, height: 1, margin: const EdgeInsets.symmetric(vertical: 6), color: IntelliJTheme.border),
            ...lower,
          ],
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
