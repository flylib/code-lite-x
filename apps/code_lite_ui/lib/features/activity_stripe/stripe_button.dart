import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';

/// 活动条上的单个按钮。选中态是实心灰色圆角块 + 亮图标(IntelliJ 新 UI / Islands 的做法),
/// 没选中是浅灰图标、悬停时淡灰底。
class StripeButton extends StatefulWidget {
  const StripeButton({
    super.key,
    this.icon,
    this.iconBuilder,
    required this.tooltip,
    required this.isActive,
    required this.onTap,
    this.badgeColor,
  }) : assert(icon != null || iconBuilder != null, 'StripeButton 需要 icon 或 iconBuilder');

  final IconData? icon;

  /// 自绘图标(Material 里没有的形状,比如 Git 分支)。传了它就忽略 [icon]。
  final Widget Function(Color color, double size)? iconBuilder;
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
    final iconColor = active ? IntelliJTheme.textHigh : IntelliJTheme.icon;

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
                Container(
                  width: IntelliJMetrics.stripeItem,
                  height: IntelliJMetrics.stripeItem,
                  decoration: BoxDecoration(
                    color: active
                        ? IntelliJTheme.stripeActiveBg
                        : (_hovered ? IntelliJTheme.hoverBg : Colors.transparent),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Center(
                    child: widget.iconBuilder?.call(iconColor, IntelliJMetrics.stripeIcon) ??
                        Icon(widget.icon, size: IntelliJMetrics.stripeIcon, color: iconColor),
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
