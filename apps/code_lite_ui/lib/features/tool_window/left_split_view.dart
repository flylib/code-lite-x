import 'package:flutter/material.dart';

import '../../core/state/layout_store.dart';
import '../../core/theme/intellij_theme.dart';

/// 左栏上下拆分:上面是左上方的工具窗,下面是左下方的,中间的分隔条可以拖动。
class LeftSplitView extends StatelessWidget {
  const LeftSplitView({super.key, required this.layout, required this.top, required this.bottom});

  final LayoutStore layout;
  final Widget top;
  final Widget bottom;

  static const double _handle = 5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxHeight - _handle;
        return Column(
          children: [
            SizedBox(height: total * layout.leftSplit, child: top),
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => layout.resizeLeftSplit(layout.leftSplit + d.delta.dy / total),
                child: Container(
                  height: _handle,
                  alignment: Alignment.center,
                  color: IntelliJTheme.panelBg,
                  child: Container(height: 1, color: IntelliJTheme.border),
                ),
              ),
            ),
            Expanded(child: bottom),
          ],
        );
      },
    );
  }
}
