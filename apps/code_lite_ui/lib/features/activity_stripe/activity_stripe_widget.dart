import 'package:flutter/material.dart';

import '../../core/state/layout_store.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/intellij_theme.dart';
import '../bottom_tools/bottom_tools_widget.dart';
import 'stripe_button.dart';

export '../../core/state/layout_store.dart' show LeftTool;

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
    required this.onSelectLeftTool,
    required this.onSelectBottomTab,
    this.hasNotification = false,
    this.buildToolTitle,
  });

  final LeftTool leftTool;
  final bool isLeftOpen;
  final BottomToolTab bottomTab;
  final bool isBottomOpen;
  final ValueChanged<LeftTool> onSelectLeftTool;
  final ValueChanged<BottomToolTab> onSelectBottomTab;

  /// 通知按钮上的小黄点。
  final bool hasNotification;

  /// 项目里检测到了构建工具(Maven……)时为它的名字,活动条多出构建工具窗的按钮;null 时不显示。
  final String? buildToolTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: IntelliJMetrics.activityStripe,
      decoration: const BoxDecoration(
        color: IntelliJTheme.stripeBg,
        border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          StripeButton(
            icon: Icons.folder_outlined,
            tooltip: '项目 (⌘1)',
            isActive: isLeftOpen && leftTool == LeftTool.project,
            onTap: () => onSelectLeftTool(LeftTool.project),
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.task_alt,
            tooltip: 'Commit (⌘0)',
            isActive: isLeftOpen && leftTool == LeftTool.commit,
            onTap: () => onSelectLeftTool(LeftTool.commit),
          ),
          const SizedBox(height: 6),
          StripeButton(
            iconBuilder: (color, size) => PullRequestIcon(color: color, size: size),
            tooltip: 'Pull Requests',
            isActive: isLeftOpen && leftTool == LeftTool.pullRequests,
            onTap: () => onSelectLeftTool(LeftTool.pullRequests),
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.account_tree_outlined,
            tooltip: '结构 (⌘7)',
            isActive: isLeftOpen && leftTool == LeftTool.structure,
            onTap: () => onSelectLeftTool(LeftTool.structure),
          ),
          if (buildToolTitle != null) ...[
            const SizedBox(height: 6),
            StripeButton(
              iconBuilder: (color, size) => BuildToolIcon(color: color, size: size),
              tooltip: buildToolTitle!,
              isActive: isLeftOpen && leftTool == LeftTool.build,
              onTap: () => onSelectLeftTool(LeftTool.build),
            ),
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

/// 构建工具窗的图标:圆角框里一个斜体 m(IntelliJ 的 Maven 工具窗图标是这个样子)。
class BuildToolIcon extends StatelessWidget {
  const BuildToolIcon({super.key, required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.2),
        border: Border.all(color: color, width: 1.4),
      ),
      child: Text(
        'm',
        style: TextStyle(color: color, fontSize: size * 0.7, fontWeight: FontWeight.w700, fontStyle: FontStyle.italic, height: 1),
      ),
    );
  }
}
