import 'package:flutter/widgets.dart';

/// 只构建落在视口里的行(上下再各留 [overscan] 行余量)。
///
/// 编辑区、行号栏、Git 改动标记条、Blame 栏都放在同一个纵向滚动视图里,各自用它包一层:
/// 外面给一个「全部行高」的盒子保持滚动长度,里面只摆可见的那几十行。文件多大,每帧的工作量都一样。
///
/// 滚动位置取自最近的纵向 [Scrollable](不依赖 ScrollController —— 同一个标签在分屏两侧打开时
/// controller 会挂着两个 position)。滚动时只有可见范围跨过一个分块([chunk] 行)才重建,
/// 平滑滚动的大部分帧不触发 build。
class VisibleLines extends StatefulWidget {
  const VisibleLines({
    super.key,
    required this.lineCount,
    required this.lineHeight,
    required this.builder,
    this.topPadding = 0,
    this.overscan = 40,
    this.chunk = 32,
  });

  final int lineCount;
  final double lineHeight;

  /// 第 0 行上方的留白(它在滚动内容里的 y 坐标)。
  final double topPadding;
  final int overscan;
  final int chunk;

  /// [first]..[last](闭区间)是要构建的行;没有行时 last < first。
  final Widget Function(BuildContext context, int first, int last) builder;

  /// 视口尚未布局(首帧)时假定的高度。
  static const double fallbackViewport = 1200;

  /// 给定滚动位置时应构建的范围(纯函数,便于测试)。
  static (int, int) rangeFor({
    required int lineCount,
    required double lineHeight,
    required double scrollOffset,
    required double viewportHeight,
    double topPadding = 0,
    int overscan = 40,
    int chunk = 32,
  }) {
    if (lineCount <= 0) return (0, -1);
    var first = ((scrollOffset - topPadding) / lineHeight).floor() - overscan;
    var last = ((scrollOffset + viewportHeight - topPadding) / lineHeight).ceil() + overscan;
    // 对齐到分块边界:小幅滚动时范围不变,不必重建。
    first = (first ~/ chunk) * chunk;
    last = ((last + chunk) ~/ chunk) * chunk - 1;
    return (first.clamp(0, lineCount - 1), last.clamp(0, lineCount - 1));
  }

  @override
  State<VisibleLines> createState() => _VisibleLinesState();
}

class _VisibleLinesState extends State<VisibleLines> {
  ScrollPosition? _position;
  (int, int) _range = (0, -1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (!identical(p, _position)) {
      _position?.removeListener(_onScroll);
      _position = p?..addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  (int, int) _compute() {
    final p = _position;
    final ready = p != null && p.hasPixels && p.hasViewportDimension;
    return VisibleLines.rangeFor(
      lineCount: widget.lineCount,
      lineHeight: widget.lineHeight,
      scrollOffset: ready ? p.pixels : 0,
      viewportHeight: ready ? p.viewportDimension : VisibleLines.fallbackViewport,
      topPadding: widget.topPadding,
      overscan: widget.overscan,
      chunk: widget.chunk,
    );
  }

  void _onScroll() {
    final r = _compute();
    if (r != _range && mounted) setState(() => _range = r);
  }

  @override
  Widget build(BuildContext context) {
    // 窗口变高时滚动位置不变、也不会通知:依赖窗口尺寸,变了就重算范围。
    MediaQuery.maybeSizeOf(context);
    _range = _compute();
    // 首帧还没有视口尺寸:布局完成后按真实视口再算一次。
    final p = _position;
    if (p != null && !(p.hasPixels && p.hasViewportDimension)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
    return widget.builder(context, _range.$1, _range.$2);
  }
}
