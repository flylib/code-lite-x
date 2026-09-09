import 'package:flutter/material.dart';

import '../../core/state/layout_store.dart';
import '../../core/theme/intellij_theme.dart';
import 'stripe_button.dart';

/// 右侧活动条。切右侧工具窗 —— 与左侧同一套按钮语义。
///
/// 设计稿里右栏是 Cargo 与助手两个工具窗;再点一次当前项收起该栏。
class RightActivityStripe extends StatelessWidget {
  const RightActivityStripe({
    super.key,
    required this.rightTool,
    required this.onSelectRightTool,
    this.hasNotification = false,
  });

  final RightTool rightTool;
  final ValueChanged<RightTool> onSelectRightTool;
  final bool hasNotification;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: IntelliJMetrics.activityStripe,
      decoration: const BoxDecoration(
        color: IntelliJTheme.stripeBg,
        border: Border(left: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          StripeButton(
            icon: Icons.notifications_none_outlined,
            tooltip: '通知',
            isActive: false,
            badgeColor: hasNotification ? IntelliJTheme.accentYellow : null,
            onTap: () {},
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.inventory_2_outlined,
            tooltip: 'Cargo',
            isActive: rightTool == RightTool.cargo,
            onTap: () => onSelectRightTool(RightTool.cargo),
          ),
          const SizedBox(height: 6),
          StripeButton(
            icon: Icons.auto_awesome_outlined,
            tooltip: '助手',
            isActive: rightTool == RightTool.assistant,
            onTap: () => onSelectRightTool(RightTool.assistant),
          ),
        ],
      ),
    );
  }
}
