/// 终端里的选区(拖动选中、双击选词、三击选行,⌘C 复制)。
///
/// 位置用「绝对行号」记:0 是回滚缓冲里最早的一行。翻页、来新输出时视图在动,
/// 选区仍然贴在原来那几行文字上(IntelliJ 终端的做法)。列是单元格下标,宽字符占两格。
class TermPos implements Comparable<TermPos> {
  const TermPos(this.line, this.col);

  final int line;
  final int col;

  @override
  int compareTo(TermPos other) => line != other.line ? line.compareTo(other.line) : col.compareTo(other.col);

  @override
  bool operator ==(Object other) => other is TermPos && other.line == line && other.col == col;

  @override
  int get hashCode => Object.hash(line, col);

  @override
  String toString() => '($line,$col)';
}

/// [anchor] 是按下的位置,[extent] 跟着鼠标走;两端都含(选中的是单元格)。
class TermSelection {
  const TermSelection(this.anchor, this.extent);

  final TermPos anchor;
  final TermPos extent;

  TermPos get start => anchor.compareTo(extent) <= 0 ? anchor : extent;
  TermPos get end => anchor.compareTo(extent) <= 0 ? extent : anchor;

  /// 第 [line] 行被选中的列范围(含两端),这行不在选区里返回 null。[cols] 是屏幕宽度。
  (int, int)? colsOn(int line, int cols) {
    final s = start, e = end;
    if (line < s.line || line > e.line) return null;
    final c0 = line == s.line ? s.col : 0;
    final c1 = line == e.line ? e.col : cols - 1;
    return c1 < c0 ? null : (c0, c1);
  }
}

/// 一行的单元格(宽字符后面那格是空串),用来按列取文字。
class TermLine {
  const TermLine(this.cells, {this.wrapped = false});

  final List<String> cells;

  /// 这一行是自动折行折出来的(没有真正的换行):复制时和下一行接起来。
  final bool wrapped;
}

/// 选区里的文字。[lineAt] 给出某个绝对行(拿不到时 null,就停在那里)。
/// 行尾的空格去掉;折行的行和下一行直接接上,其余行之间用 \n。
String selectionText(TermSelection sel, TermLine? Function(int line) lineAt, int cols) {
  final out = StringBuffer();
  var newline = false; // 上一行之后要不要换行(等确定还有下一行再写,免得末尾多一个 \n)
  for (var line = sel.start.line; line <= sel.end.line; line++) {
    final l = lineAt(line);
    if (l == null) break;
    final range = sel.colsOn(line, cols);
    if (range == null) continue;
    final (c0, c1) = range;
    final buf = StringBuffer();
    for (var c = c0; c <= c1 && c < l.cells.length; c++) {
      buf.write(l.cells[c]);
    }
    final last = line == sel.end.line;
    final joinNext = l.wrapped && !last && c1 >= cols - 1;
    if (newline) out.write('\n');
    out.write(joinNext ? buf.toString() : buf.toString().trimRight());
    newline = !joinNext;
  }
  return out.toString();
}

const String _wordBreaks = ' \t"\'`()[]{}<>,;|';

/// 双击选词:[col] 所在的连续非分隔字符(路径、类名、URL 里的 / . : - 都算词的一部分)。
(int, int) wordRange(List<String> cells, int col) {
  if (cells.isEmpty) return (0, 0);
  var c = col.clamp(0, cells.length - 1);
  // 点在宽字符的后半格上:算前半格
  if (c > 0 && cells[c].isEmpty) c--;
  bool isWord(int i) => i >= 0 && i < cells.length && (cells[i].isEmpty || !_wordBreaks.contains(cells[i]));
  if (!isWord(c)) return (c, c);
  var a = c, b = c;
  while (isWord(a - 1)) {
    a--;
  }
  while (isWord(b + 1)) {
    b++;
  }
  return (a, b);
}
