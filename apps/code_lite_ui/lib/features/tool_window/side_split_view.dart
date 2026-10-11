import 'package:flutter/material.dart';

import '../../core/state/layout_store.dart';
import '../../core/theme/intellij_theme.dart';

/// 一侧上下拆分:上面是上方的工具窗,下面是下方的,各是一块岛;中间的缝可以拖动。
class SideSplitView extends StatelessWidget {
  const SideSplitView({super.key, required this.layout, required this.side, required this.top, required this.bottom});

  final LayoutStore layout;
  final ToolSide side;
  final Widget top;
  final Widget bottom;

  static const double _handle = IntelliJMetrics.islandGap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxHeight - _handle;
        return Column(
          children: [
            SizedBox(height: total * layout.splitOf(side), child: top),
            MouseRegion(
              cursor: SystemMouseCursors.resizeRow,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => layout.resizeSplit(side, layout.splitOf(side) + d.delta.dy / total),
                child: const SizedBox(height: _handle, width: double.infinity),
              ),
            ),
            Expanded(child: bottom),
          ],
        );
      },
    );
  }
}
