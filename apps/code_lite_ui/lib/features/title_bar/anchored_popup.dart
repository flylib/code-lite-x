import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';

/// 在 [anchor] 这个控件正下方弹出一块面板(IntelliJ 标题栏上项目 / 分支那种弹窗)。
/// 点面板外面或按 Esc 关闭;[builder] 里用 `Navigator.pop(context, value)` 带值关闭。
///
/// 用 showGeneralDialog 而不是 showMenu:里面要放搜索框和可滚动的树,不是一列菜单项。
Future<T?> showAnchoredPopup<T>(
  BuildContext anchor, {
  required WidgetBuilder builder,
  double width = 380,
  double maxHeight = 600,
  double gap = 4,
}) {
  final box = anchor.findRenderObject() as RenderBox;
  final topLeft = box.localToGlobal(Offset.zero);
  final screen = MediaQuery.sizeOf(anchor);
  final left = topLeft.dx.clamp(8.0, math.max(8.0, screen.width - width - 8)).toDouble();
  final top = topLeft.dy + box.size.height + gap;
  final height = math.max(120.0, math.min(maxHeight, screen.height - top - 12));

  return showGeneralDialog<T>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, _, __) => Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: Material(
              color: IntelliJTheme.panelBg,
              elevation: 12,
              shadowColor: Colors.black,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: IntelliJTheme.border),
              ),
              child: builder(ctx),
            ),
          ),
        ),
      ],
    ),
  );
}

/// 弹窗里的一行:悬停变色,可点。
class PopupRow extends StatelessWidget {
  const PopupRow({
    super.key,
    required this.child,
    required this.onTap,
    this.height = 28,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.selected = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double height;
  final EdgeInsetsGeometry padding;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: IntelliJTheme.hoverBg,
      child: Container(
        height: height,
        color: selected ? IntelliJTheme.selectionBg : null,
        padding: padding,
        alignment: Alignment.centerLeft,
        child: child,
      ),
    );
  }
}

const TextStyle popupText = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13);
const TextStyle popupMuted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle popupHeader = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12, fontWeight: FontWeight.w600);
