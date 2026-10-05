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

/// IntelliJ / GitHub 的 Pull Request 图标:左侧一条带上下两个圆的主干,
/// 右下圆向上引出一条线,在顶部向左弯折,末端是指向左的箭头。
class PullRequestIcon extends StatelessWidget {
  const PullRequestIcon({super.key, required this.color, this.size = 18});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _PullRequestPainter(color)),
    );
  }
}

class _PullRequestPainter extends CustomPainter {
  _PullRequestPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 18;
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    const r = 2.2;
    const topLeft = Offset(4.6, 3.9);
    const bottomLeft = Offset(4.6, 14.1);
    const bottomRight = Offset(13.4, 14.1);
    canvas.drawCircle(topLeft, r, paint);
    canvas.drawCircle(bottomLeft, r, paint);
    canvas.drawCircle(bottomRight, r, paint);
    canvas.drawLine(Offset(topLeft.dx, topLeft.dy + r), Offset(bottomLeft.dx, bottomLeft.dy - r), paint);

    // 右侧:从右下圆向上,顶部圆角向左,末端箭头。
    final branch = Path()
      ..moveTo(bottomRight.dx, bottomRight.dy - r)
      ..lineTo(bottomRight.dx, 7.2)
      ..quadraticBezierTo(bottomRight.dx, 3.9, 10.2, 3.9)
      ..lineTo(8.4, 3.9);
    canvas.drawPath(branch, paint);
    final arrow = Path()
      ..moveTo(10.2, 2.0)
      ..lineTo(8.3, 3.9)
      ..lineTo(10.2, 5.8);
    canvas.drawPath(arrow, paint);
  }

  @override
  bool shouldRepaint(_PullRequestPainter old) => old.color != color;
}
