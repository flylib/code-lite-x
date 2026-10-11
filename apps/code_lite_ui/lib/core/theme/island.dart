import 'package:flutter/material.dart';

import 'intellij_theme.dart';

/// 一块「岛」(IntelliJ 新 UI 的 Islands 主题):编辑区、侧边工具窗、底部工具窗各是一块圆角面板,
/// 浮在窗口底色上,彼此之间留一条缝([IntelliJMetrics.islandGap])。
class Island extends StatelessWidget {
  const Island({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(IntelliJMetrics.islandRadius),
      child: ColoredBox(color: IntelliJTheme.islandBg, child: child),
    );
  }
}
