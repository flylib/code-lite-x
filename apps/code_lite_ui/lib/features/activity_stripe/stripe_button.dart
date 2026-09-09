import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';

/// 活动条上的单个按钮。选中态是淡蓝底 + 蓝图标 + 左侧 2px 指示条,
/// 取自 design/ 的稿子(IntelliJ New UI 的做法);此前是实心蓝底 + 白图标,
/// 在暗色主题里过重。
class StripeButton extends StatefulWidget {
  const StripeButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.onTap,
    this.badgeColor,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;
  final Color? badgeColor;

  @override
  State<StripeButton> createState() => _StripeButtonState();
}

class _StripeButtonState extends State<StripeButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isActive;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: IntelliJMetrics.activityStripe,
            height: IntelliJMetrics.stripeItem,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (active)
                  Positioned(
                    left: 0,
                    top: 8,
                    bottom: 8,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: IntelliJTheme.accentBlue,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                Container(
                  width: IntelliJMetrics.stripeItem,
                  height: IntelliJMetrics.stripeItem,
                  decoration: BoxDecoration(
                    color: active
                        ? IntelliJTheme.selectionBg
                        : (_hovered ? IntelliJTheme.hoverBg : Colors.transparent),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Center(
                    child: Icon(
                      widget.icon,
                      size: IntelliJMetrics.stripeIcon,
                      color: active ? IntelliJTheme.accentBlue : IntelliJTheme.textMuted,
                    ),
                  ),
                ),
                if (widget.badgeColor != null && !active)
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: widget.badgeColor, shape: BoxShape.circle),
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
