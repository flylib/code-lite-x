import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import 'stripe_button.dart';

/// 右侧活动条。目前只有通知;以后插件贡献的右侧工具窗也放在这里。
class RightActivityStripe extends StatelessWidget {
  const RightActivityStripe({super.key, this.hasNotification = false});

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
        ],
      ),
    );
  }
}
