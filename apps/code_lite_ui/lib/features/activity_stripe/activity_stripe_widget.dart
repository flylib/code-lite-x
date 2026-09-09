import 'package:flutter/material.dart';

import '../../core/state/layout_store.dart';
import '../../core/theme/intellij_theme.dart';
import '../bottom_tools/bottom_tools_widget.dart';
import 'stripe_button.dart';

export '../../core/state/layout_store.dart' show LeftTool;

/// 左侧活动条。上半段切左侧工具窗,中段切底部工具窗,下半段是终端与设置。
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
  });

  final LeftTool leftTool;
  final bool isLeftOpen;
  final BottomToolTab bottomTab;
  final bool isBottomOpen;
  final ValueChanged<LeftTool> onSelectLeftTool;
  final ValueChanged<BottomToolTab> onSelectBottomTab;

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
            icon: Icons.account_tree_outlined,
            tooltip: '结构 (⌘7)',
            isActive: isLeftOpen && leftTool == LeftTool.structure,
            onTap: () => onSelectLeftTool(LeftTool.structure),
          ),

          const _StripeDivider(),

          StripeButton(
            icon: Icons.commit_outlined,
            tooltip: 'Git 提交与日志',
            isActive: isBottomOpen && bottomTab == BottomToolTab.git,
            onTap: () => onSelectBottomTab(BottomToolTab.git),
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.hub_outlined,
            tooltip: 'CodeGraph 调用图',
            isActive: isBottomOpen && bottomTab == BottomToolTab.codegraph,
            onTap: () => onSelectBottomTab(BottomToolTab.codegraph),
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.storage_outlined,
            tooltip: '操作记录与回滚',
            isActive: isBottomOpen && bottomTab == BottomToolTab.sqlite,
            onTap: () => onSelectBottomTab(BottomToolTab.sqlite),
          ),

          const Spacer(),

          StripeButton(
            icon: Icons.terminal_outlined,
            tooltip: '终端 (⌥F12)',
            isActive: isBottomOpen && bottomTab == BottomToolTab.terminal,
            onTap: () => onSelectBottomTab(BottomToolTab.terminal),
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.tune,
            tooltip: '设置',
            isActive: false,
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _StripeDivider extends StatelessWidget {
  const _StripeDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 9),
      color: IntelliJTheme.border,
    );
  }
}
