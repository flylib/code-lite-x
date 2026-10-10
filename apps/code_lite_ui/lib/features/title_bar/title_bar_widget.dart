import 'package:flutter/material.dart';
import '../../core/platform/window_chrome.dart';
import '../../core/theme/intellij_theme.dart';

class TitleBarWidget extends StatelessWidget {
  final String activeFile;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback? onSearch;

  /// 项目名(点开是新建 / 打开 / 克隆和最近项目)与当前分支(点开是 Git 操作);由应用组装。
  final Widget? projectChip;
  final Widget? branchChip;

  /// 分支名右边的按钮:合并 / 变基有冲突时的「查看冲突」和「放弃」。
  final Widget? operationButtons;

  const TitleBarWidget({
    super.key,
    required this.activeFile,
    required this.onUndo,
    required this.onRedo,
    this.onSearch,
    this.projectChip,
    this.branchChip,
    this.operationButtons,
  });

  @override
  Widget build(BuildContext context) {
    return _TitleBarDragRegion(child: _bar());
  }

  Widget _bar() {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: 给系统红绿灯留位置 & Project / Branch Badges
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _trafficLightsSpace(),
                  if (projectChip != null) projectChip!,
                  if (branchChip != null) ...[const SizedBox(width: 4), branchChip!],
                  if (operationButtons != null) operationButtons!,
                  const SizedBox(width: 12),
                  _buildBreadcrumb(),
                ],
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Center: Search Everywhere Input
          _buildSearchEverywhere(),

          const SizedBox(width: 8),

          // Right: Controls & Run
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIconBtn(Icons.undo, onUndo, 'Undo (Cmd+Z)'),
              _buildIconBtn(Icons.redo, onRedo, 'Redo (Cmd+Shift+Z)'),
              const SizedBox(width: 8),
              Container(width: 1, height: 16, color: IntelliJTheme.border),
              const SizedBox(width: 8),
              _buildRunTarget(),
              const SizedBox(width: 4),
              _buildActionBtn(Icons.play_arrow, IntelliJTheme.gitGreen, 'Run (Shift+F10)'),
            ],
          ),
        ],
      ),
    );
  }

  /// macOS:系统自带的红黄绿按钮浮在这里(标题栏透明、内容铺满窗口),这里只留出位置。
  /// 全屏时系统把它们收起来了,不留。其它系统用自己的原生标题栏,也不留。
  Widget _trafficLightsSpace() {
    if (!WindowChrome.usesNativeTrafficLights) return const SizedBox(width: 0);
    return ValueListenableBuilder<bool>(
      valueListenable: WindowChrome.fullScreen,
      builder: (context, full, _) => SizedBox(width: full ? 0 : WindowChrome.trafficLightsInset - 12),
    );
  }

  Widget _buildBreadcrumb() {
    return Text(
      activeFile,
      style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildSearchEverywhere() {
    return InkWell(
      onTap: onSearch,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 180,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: IntelliJTheme.panelBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: IntelliJTheme.border),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search, size: 14, color: IntelliJTheme.textMuted),
                SizedBox(width: 4),
                Text('Search...', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11)),
              ],
            ),
            Text('⇧ ⇧', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 9)),
          ],
        ),
      ),
    );
  }

  Widget _buildRunTarget() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: IntelliJTheme.panelBg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: IntelliJTheme.border),
      ),
      child: const Row(
        children: [
          Icon(Icons.circle, size: 6, color: IntelliJTheme.gitGreen),
          SizedBox(width: 4),
          Text('code-lite-desktop', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildActionBtn(IconData icon, Color color, String tooltip) {
    return IconButton(
      icon: Icon(icon, size: 16, color: color),
      tooltip: tooltip,
      onPressed: () {},
      splashRadius: 14,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }

  Widget _buildIconBtn(IconData icon, VoidCallback onPressed, String tooltip) {
    return IconButton(
      icon: Icon(icon, size: 16, color: IntelliJTheme.textPrimary),
      tooltip: tooltip,
      onPressed: onPressed,
      splashRadius: 14,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }

}

/// 标题栏就是窗口的标题栏:按着空白处拖动窗口,双击缩放。
///
/// 按钮、输入框自己先接事件,不受影响:父级只接「拖动」和「单击」,子控件接住的点击不会传上来,
/// 所以只有点在空白处才算。双击自己用时间戳判断 —— 用 GestureDetector.onDoubleTap 的话,
/// 它会把每个子控件的单击都推迟到双击超时(约 300ms)之后才生效。
class _TitleBarDragRegion extends StatefulWidget {
  const _TitleBarDragRegion({required this.child});

  final Widget child;

  @override
  State<_TitleBarDragRegion> createState() => _TitleBarDragRegionState();
}

class _TitleBarDragRegionState extends State<_TitleBarDragRegion> {
  DateTime _lastTap = DateTime(0);
  Offset _lastPosition = Offset.zero;

  void _onTapUp(TapUpDetails d) {
    final now = DateTime.now();
    final isDouble = now.difference(_lastTap) < const Duration(milliseconds: 400) && (d.globalPosition - _lastPosition).distance < 10;
    _lastTap = isDouble ? DateTime(0) : now;
    _lastPosition = d.globalPosition;
    if (isDouble) WindowChrome.toggleZoom();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => WindowChrome.startDrag(),
      onTapUp: _onTapUp,
      child: widget.child,
    );
  }
}
