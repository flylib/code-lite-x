/// 并排差异视图的行模型:左边是旧版本,右边是新版本,逐行对齐。
library;

enum DiffRowKind { equal, insert, delete, modify }

class DiffRow {
  const DiffRow(this.kind, this.left, this.right);

  final DiffRowKind kind;

  /// 左侧(旧)行号,0 起;这一行左边是空位时为 null。
  final int? left;

  /// 右侧(新)行号,0 起;这一行右边是空位时为 null。
  final int? right;

  @override
  String toString() => '$kind($left,$right)';
}

/// 逐行比较 [a](旧)与 [b](新),输出左右对齐的行。
///
/// 用 Myers 差分求最短编辑脚本,再把相邻的"删一段 + 插一段"两两配成 modify 行 ——
/// 这样改过的行左右并排显示(IntelliJ 的蓝色块),多出来的才是纯增 / 纯删。
/// 先剥掉公共前后缀:大文件里通常只改了几行,剥完后实际参与差分的很少。
List<DiffRow> sideBySideDiff(List<String> a, List<String> b) {
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }

  final rows = <DiffRow>[for (var i = 0; i < start; i++) DiffRow(DiffRowKind.equal, i, i)];
  final ops = _myers(a.sublist(start, endA), b.sublist(start, endB));

  // ops: 0 = equal, -1 = delete, +1 = insert(按编辑脚本顺序)
  var i = start, j = start, k = 0;
  while (k < ops.length) {
    if (ops[k] == 0) {
      rows.add(DiffRow(DiffRowKind.equal, i++, j++));
      k++;
      continue;
    }
    var dels = 0, ins = 0;
    while (k < ops.length && ops[k] != 0) {
      ops[k] < 0 ? dels++ : ins++;
      k++;
    }
    final pairs = dels < ins ? dels : ins;
    for (var p = 0; p < pairs; p++) {
      rows.add(DiffRow(DiffRowKind.modify, i++, j++));
    }
    for (var p = pairs; p < dels; p++) {
      rows.add(DiffRow(DiffRowKind.delete, i++, null));
    }
    for (var p = pairs; p < ins; p++) {
      rows.add(DiffRow(DiffRowKind.insert, null, j++));
    }
  }
  for (var t = 0; t < a.length - endA; t++) {
    rows.add(DiffRow(DiffRowKind.equal, endA + t, endB + t));
  }
  return rows;
}

/// 每段连续改动的第一行在 [rows] 里的下标(上一处 / 下一处跳转用)。
List<int> changeBlockStarts(List<DiffRow> rows) => [
      for (var r = 0; r < rows.length; r++)
        if (rows[r].kind != DiffRowKind.equal && (r == 0 || rows[r - 1].kind == DiffRowKind.equal)) r,
    ];

/// 一对被修改的行里真正变了的那一段(去掉公共前后缀),用于行内高亮。
({int start, int oldEnd, int newEnd}) changedSpan(String oldLine, String newLine) {
  var s = 0;
  while (s < oldLine.length && s < newLine.length && oldLine.codeUnitAt(s) == newLine.codeUnitAt(s)) {
    s++;
  }
  var eo = oldLine.length, en = newLine.length;
  while (eo > s && en > s && oldLine.codeUnitAt(eo - 1) == newLine.codeUnitAt(en - 1)) {
    eo--;
    en--;
  }
  return (start: s, oldEnd: eo, newEnd: en);
}

/// Myers O(ND) 差分。返回编辑脚本:0 保留、-1 删除 a 的一行、+1 插入 b 的一行。
List<int> _myers(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  if (n == 0) return List.filled(m, 1);
  if (m == 0) return List.filled(n, -1);
  final max = n + m;
  final offset = max;
  var v = List<int>.filled(2 * max + 2, 0);
  final trace = <List<int>>[];
  outer:
  for (var d = 0; d <= max; d++) {
    trace.add(List.of(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
        x = v[offset + k + 1]; // 下移:插入
      } else {
        x = v[offset + k - 1] + 1; // 右移:删除
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) break outer;
    }
  }

  // 从终点沿 trace 回溯出编辑脚本。
  final ops = <int>[];
  var x = n, y = m;
  for (var d = trace.length - 1; d > 0; d--) {
    final vd = trace[d];
    final k = x - y;
    final int prevK;
    if (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = vd[offset + prevK];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(0);
      x--;
      y--;
    }
    ops.add(x == prevX ? 1 : -1);
    x = prevX;
    y = prevY;
  }
  while (x > 0 && y > 0) {
    ops.add(0);
    x--;
    y--;
  }
  return ops.reversed.toList();
}
