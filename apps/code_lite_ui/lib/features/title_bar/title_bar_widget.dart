import 'package:flutter/material.dart';
import '../../core/platform/window_chrome.dart';
import '../../core/theme/intellij_theme.dart';

/// 标题栏(IntelliJ 新 UI / Islands):左边红绿灯、项目、分支;右边运行配置、运行 / 调试、搜索、设置。
/// 底色是窗口底色,左侧带一片当前项目颜色的光晕(IntelliJ 按项目给标题栏上色)。
class TitleBarWidget extends StatelessWidget {
  const TitleBarWidget({
    super.key,
    this.onSearch,
    this.onSettings,
    this.accent,
    this.projectChip,
    this.branchChip,
    this.operationButtons,
  });

  final VoidCallback? onSearch;
  final VoidCallback? onSettings;

  /// 当前项目的颜色(和项目徽标同一个);null 时没有光晕。
  final Color? accent;

  /// 项目名(点开是新建 / 打开 / 克隆和最近项目)与当前分支(点开是 Git 操作);由应用组装。
  final Widget? projectChip;
  final Widget? branchChip;

  /// 分支名右边的按钮:合并 / 变基有冲突时的「查看冲突」和「放弃」。
  final Widget? operationButtons;

  @override
  Widget build(BuildContext context) {
    return _TitleBarDragRegion(child: _bar());
  }

  /// 项目颜色从左边淡出到窗口底色。截图里蓝色项目在徽标后面是 #344163,到 1/3 宽处已经看不出来。
  Gradient? _glow() {
    final c = accent;
    if (c == null) return null;
    Color mix(double a) => Color.alphaBlend(c.withValues(alpha: a), IntelliJTheme.frameBg);
    return LinearGradient(
      colors: [mix(0.30), mix(0.24), mix(0.08), IntelliJTheme.frameBg],
      stops: const [0, 0.14, 0.26, 0.4],
    );
  }

  Widget _bar() {
    return Container(
      height: IntelliJMetrics.titleBar,
      decoration: BoxDecoration(color: IntelliJTheme.frameBg, gradient: _glow()),
      padding: const EdgeInsets.only(left: 12, right: 8),
      child: Row(
        children: [
          // 左:给系统红绿灯留位置,然后是项目和分支
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _trafficLightsSpace(),
                  if (projectChip != null) projectChip!,
                  if (branchChip != null) ...[const SizedBox(width: 10), branchChip!],
                  if (operationButtons != null) operationButtons!,
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 右:运行配置与运行 / 调试 / 更多,隔开一点是搜索和设置
          _buildRunTarget(),
          _iconBtn(Icons.play_arrow_outlined, '运行 (⇧F10)', null, dim: true),
          _iconBtn(Icons.bug_report_outlined, 'Debug (⇧F9)', null, dim: true),
          _iconBtn(Icons.more_vert, '更多', null),
          const SizedBox(width: 18),
          _iconBtn(Icons.search, '搜索 (⇧⌘F)', onSearch),
          _iconBtn(Icons.settings_outlined, '设置 (⌘,)', onSettings),
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

  Widget _buildRunTarget() {
    return Tooltip(
      message: '运行配置',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(6),
        hoverColor: IntelliJTheme.hoverBg,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Current File', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13)),
              SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down, size: 15, color: IntelliJTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback? onTap, {bool dim = false}) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap ?? () {},
        borderRadius: BorderRadius.circular(6),
        hoverColor: IntelliJTheme.hoverBg,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon, size: 18, color: dim ? IntelliJTheme.textMuted : IntelliJTheme.icon),
        ),
      ),
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
