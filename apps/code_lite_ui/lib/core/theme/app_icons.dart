import 'package:flutter/widgets.dart';

/// IntelliJ New UI 的 Git 图标:上方左右两个空心圆,左侧主干一直到底,
/// 右侧分支向下弯回汇入主干。Material 图标里没有这个形状,所以自己画。
class GitBranchIcon extends StatelessWidget {
  const GitBranchIcon({super.key, required this.color, this.size = 18});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _GitBranchPainter(color)),
    );
  }
}

class _GitBranchPainter extends CustomPainter {
  _GitBranchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 在 18×18 的网格上作图,再按实际尺寸缩放。
    final s = size.width / 18;
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    const r = 2.2;
    const left = Offset(4.8, 4.2);
    const right = Offset(13.2, 4.2);
    canvas.drawCircle(left, r, paint);
    canvas.drawCircle(right, r, paint);

    // 主干:左圆下沿一直到底。
    canvas.drawLine(Offset(left.dx, left.dy + r), Offset(left.dx, 16.2), paint);

    // 分支:右圆下沿先竖直向下,再以平滑曲线弯回主干。
    final branch = Path()
      ..moveTo(right.dx, right.dy + r)
      ..lineTo(right.dx, 7.6)
      ..cubicTo(right.dx, 11.2, left.dx, 9.6, left.dx, 12.8);
    canvas.drawPath(branch, paint);
  }

  @override
  bool shouldRepaint(_GitBranchPainter old) => old.color != color;
}
