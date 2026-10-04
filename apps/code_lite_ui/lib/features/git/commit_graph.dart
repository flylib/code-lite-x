import 'package:flutter/material.dart';

/// 一行里的一段线。纵坐标用行内比例:0 行顶、0.5 节点中心、1 行底;横坐标是轨道号。
class GraphLine {
  const GraphLine(this.fromLane, this.fromY, this.toLane, this.toY, this.color);

  final int fromLane;
  final double fromY;
  final int toLane;
  final double toY;
  final int color;

  @override
  String toString() => 'L($fromLane@$fromY -> $toLane@$toY c$color)';
}

class GraphRow {
  const GraphRow({required this.lane, required this.color, required this.lines, required this.width});

  /// 提交节点所在的轨道。
  final int lane;
  final int color;
  final List<GraphLine> lines;

  /// 这一行用到的轨道数(决定提交信息从哪里开始画)。
  final int width;
}

/// 把按 `--date-order` 排好(子提交总在父提交之前)的提交排成多轨道图。
///
/// 做法与 IntelliJ / gitk 相同:维护"每条轨道接下来等哪个提交"的数组。
/// 轨道一旦分配就不挪位置(只在空出来后复用),所以直通的线永远是竖直的。
/// 父提交不在列表里(被筛选掉 / 超出分页)时,线画到行底就断开。
List<GraphRow> layoutCommitGraph(List<String> hashes, List<List<String>> parents) {
  final lanes = <String?>[];
  final laneColor = <int>[];
  var nextColor = 0;
  final rows = <GraphRow>[];

  int allocate({int avoid = -1}) {
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] == null && i != avoid) return i;
    }
    lanes.add(null);
    laneColor.add(0);
    return lanes.length - 1;
  }

  for (var r = 0; r < hashes.length; r++) {
    final hash = hashes[r];
    final lines = <GraphLine>[];

    final incoming = <int>[
      for (var i = 0; i < lanes.length; i++)
        if (lanes[i] == hash) i,
    ];
    final int node;
    if (incoming.isEmpty) {
      node = allocate();
      laneColor[node] = nextColor++;
    } else {
      node = incoming.first;
    }
    final color = laneColor[node];

    // 上半段:等待本提交的轨道汇入节点;其余在用的轨道直通。
    for (final i in incoming) {
      lines.add(GraphLine(i, 0, node, 0.5, laneColor[i]));
    }
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] != null && lanes[i] != hash) {
        lines.add(GraphLine(i, 0, i, 1, laneColor[i]));
      }
    }
    for (final i in incoming) {
      lanes[i] = null;
    }

    // 下半段:节点连到各个父提交所在(或新开)的轨道。
    final ps = parents[r];
    for (var k = 0; k < ps.length; k++) {
      final p = ps[k];
      final existing = lanes.indexOf(p);
      if (existing >= 0 && k == 0 && existing > node && lanes[node] == null) {
        // 第一父提交已在右边某条轨道上等着:把那条轨道并进本轨道,
        // 保证第一父链(主线)不被挤到右边 —— IntelliJ 也是这样画的。
        lanes[node] = p;
        lanes[existing] = null;
        final i = lines.indexWhere((l) => l.fromLane == existing && l.toLane == existing && l.fromY == 0);
        if (i >= 0) lines[i] = GraphLine(existing, 0, node, 1, laneColor[existing]);
        lines.add(GraphLine(node, 0.5, node, 1, laneColor[node]));
        continue;
      }
      if (existing >= 0) {
        lines.add(GraphLine(node, 0.5, existing, 1, laneColor[existing]));
        continue;
      }
      final int target;
      if (k == 0 && lanes[node] == null) {
        target = node; // 第一父提交沿用本轨道和颜色
      } else {
        target = allocate(avoid: node);
        laneColor[target] = nextColor++;
      }
      lanes[target] = p;
      lines.add(GraphLine(node, 0.5, target, 1, laneColor[target]));
    }

    while (lanes.isNotEmpty && lanes.last == null) {
      lanes.removeLast();
      laneColor.removeLast();
    }

    var width = node + 1;
    for (final l in lines) {
      width = [width, l.fromLane + 1, l.toLane + 1].reduce((a, b) => a > b ? a : b);
    }
    rows.add(GraphRow(lane: node, color: color, lines: lines, width: width));
  }
  return rows;
}

/// IntelliJ 提交图的配色。
const List<Color> graphPalette = [
  Color(0xFFD4A84B), // 主干的金黄,与截图一致
  Color(0xFF5C9DE8),
  Color(0xFF59A869),
  Color(0xFFC77DBB),
  Color(0xFFE07B53),
  Color(0xFF3FB4B4),
  Color(0xFFB4A0E5),
  Color(0xFFDB5860),
];

Color graphColor(int index) => graphPalette[index % graphPalette.length];

const double kLaneWidth = 14;

class CommitGraphPainter extends CustomPainter {
  CommitGraphPainter(this.row, {required this.isHead});

  final GraphRow row;
  final bool isHead;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    double x(int lane) => kLaneWidth / 2 + lane * kLaneWidth + 4;
    final paint = Paint()
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final l in row.lines) {
      paint.color = graphColor(l.color);
      canvas.drawLine(Offset(x(l.fromLane), l.fromY * h), Offset(x(l.toLane), l.toY * h), paint);
    }
    final center = Offset(x(row.lane), h / 2);
    final fill = Paint()..color = graphColor(row.color);
    canvas.drawCircle(center, 4, fill);
    if (isHead) {
      // HEAD 画成空心环,和 IntelliJ 一样一眼能看出当前位置。
      canvas.drawCircle(center, 2, Paint()..color = const Color(0xFF1E1F22));
    }
  }

  @override
  bool shouldRepaint(CommitGraphPainter old) => old.row != row || old.isHead != isHead;
}
