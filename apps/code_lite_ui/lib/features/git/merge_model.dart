// 三方合并(IntelliJ 的 Merge Revisions 窗口)的数据:基准版本、两侧版本,
// 拆成「没变的段」和「改动块」,记录每块怎么处理,算出合并结果。
//
// 和 git 的判定一致:两侧改了同一段(或紧挨着的段),而且改得不一样 → 冲突;
// 只有一侧改了 → 普通改动,可以直接采用;两侧改得一模一样 → 只算一处。

import 'package:flutter/foundation.dart';

import '../commit/line_diff.dart';

enum MergeSide { left, right }

enum ChunkKind {
  /// 只有左侧(Yours)改了。
  left,

  /// 只有右侧(Theirs)改了。
  right,

  /// 两侧改得一样。
  same,

  /// 两侧都改了,而且不一样。
  conflict,
}

/// 一处改动。行号都是 0 起、左闭右开。
class MergeChunk {
  MergeChunk({
    required this.kind,
    required this.baseStart,
    required this.base,
    required this.left,
    required this.right,
  });

  final ChunkKind kind;
  final int baseStart;
  final List<String> base;
  final List<String> left;
  final List<String> right;

  /// 已经采用的侧,按采用的顺序(冲突时两侧都采用 = 先后拼起来)。
  final List<MergeSide> applied = [];
  final Set<MergeSide> ignored = {};

  /// 用户在结果里手改过的内容;非 null 时就是这块的结果。
  List<String>? custom;

  bool get isConflict => kind == ChunkKind.conflict;

  /// 这一侧在这块里有改动(有按钮可按)。
  bool changedOn(MergeSide side) => switch (kind) {
        ChunkKind.left => side == MergeSide.left,
        ChunkKind.right => side == MergeSide.right,
        ChunkKind.same || ChunkKind.conflict => true,
      };

  List<String> linesOf(MergeSide side) => side == MergeSide.left ? left : right;

  bool handled(MergeSide side) => applied.contains(side) || ignored.contains(side);

  /// 这一侧还等着处理(显示 » / « 和 ×)。
  bool pending(MergeSide side) {
    if (custom != null || !changedOn(side)) return false;
    // 两侧改得一样:处理了任一侧就算处理完了
    if (kind == ChunkKind.same) return applied.isEmpty && ignored.isEmpty;
    return !handled(side);
  }

  bool get resolved => !pending(MergeSide.left) && !pending(MergeSide.right);

  /// 这块在结果里的内容:手改的 > 采用的侧(按顺序拼) > 基准版本(还没处理 / 都忽略了)。
  List<String> get result {
    final c = custom;
    if (c != null) return c;
    if (applied.isEmpty) return base;
    if (kind == ChunkKind.same) return left;
    return [for (final s in applied) ...linesOf(s)];
  }

  _ChunkState _save() => _ChunkState(List.of(applied), Set.of(ignored), custom == null ? null : List.of(custom!));

  void _restore(_ChunkState s) {
    applied
      ..clear()
      ..addAll(s.applied);
    ignored
      ..clear()
      ..addAll(s.ignored);
    custom = s.custom;
  }
}

class _ChunkState {
  const _ChunkState(this.applied, this.ignored, this.custom);
  final List<MergeSide> applied;
  final Set<MergeSide> ignored;
  final List<String>? custom;
}

/// 文件的一段:要么是三方都一样的几行([chunk] 为 null),要么是一处改动。
class MergeSegment {
  const MergeSegment.equal(this.baseStart, this.lines) : chunk = null;
  MergeSegment.change(MergeChunk this.chunk)
      : baseStart = chunk.baseStart,
        lines = const [];

  final int baseStart;

  /// 没变的几行(改动块为空)。
  final List<String> lines;
  final MergeChunk? chunk;
}

/// 对齐后的一行:三栏各自的行号(这一栏是补位的空行时为 null)和文字。
class MergeRow {
  const MergeRow({this.left, this.result, this.right, this.leftText, this.resultText, this.rightText, this.chunk, this.firstOfChunk = false});

  final int? left;
  final int? result;
  final int? right;
  final String? leftText;
  final String? resultText;
  final String? rightText;
  final MergeChunk? chunk;

  /// 改动块的第一行:按钮放在这里。
  final bool firstOfChunk;
}

/// 把文本拆成行,记下换行风格和末尾是否有换行,存回去时原样还原。
class MergeText {
  MergeText(String text)
      : crlf = text.contains('\r\n'),
        trailingNewline = text.endsWith('\n'),
        lines = _split(text);

  final bool crlf;
  final bool trailingNewline;
  final List<String> lines;

  static List<String> _split(String text) {
    if (text.isEmpty) return const [];
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    return lines;
  }
}

class MergeModel extends ChangeNotifier {
  MergeModel({required String base, required String left, required String right})
      : _leftText = MergeText(left),
        _rightText = MergeText(right),
        _base = MergeText(base).lines {
    segments = _build(_base, _leftText.lines, _rightText.lines);
    chunks = [for (final s in segments) if (s.chunk != null) s.chunk!];
  }

  final MergeText _leftText;
  final MergeText _rightText;
  final List<String> _base;

  late final List<MergeSegment> segments;
  late final List<MergeChunk> chunks;

  final List<List<_ChunkState>> _undo = [];

  List<String> get leftLines => _leftText.lines;
  List<String> get rightLines => _rightText.lines;

  int get unresolvedChanges => chunks.where((c) => !c.resolved).length;
  int get unresolvedConflicts => chunks.where((c) => c.isConflict && !c.resolved).length;
  int get conflictCount => chunks.where((c) => c.isConflict).length;
  bool get canUndo => _undo.isNotEmpty;

  // ---------------------------------------------------------------------------
  // 拆块
  // ---------------------------------------------------------------------------

  static List<MergeSegment> _build(List<String> base, List<String> left, List<String> right) {
    final lh = lineHunks(base, left);
    final rh = lineHunks(base, right);
    // 两侧的改动按基准位置排在一起,重叠或紧挨着的归成一组(git 也把紧挨着的改动当冲突)
    final all = [for (final h in lh) (h, MergeSide.left), for (final h in rh) (h, MergeSide.right)]
      ..sort((a, b) => a.$1.aStart != b.$1.aStart ? a.$1.aStart.compareTo(b.$1.aStart) : a.$1.aEnd.compareTo(b.$1.aEnd));
    final groups = <List<(LineHunk, MergeSide)>>[];
    var groupEnd = -1;
    for (final h in all) {
      if (groups.isNotEmpty && h.$1.aStart <= groupEnd) {
        groups.last.add(h);
        if (h.$1.aEnd > groupEnd) groupEnd = h.$1.aEnd;
      } else {
        groups.add([h]);
        groupEnd = h.$1.aEnd;
      }
    }

    final segments = <MergeSegment>[];
    var pos = 0;
    for (final g in groups) {
      final start = g.map((h) => h.$1.aStart).reduce((a, b) => a < b ? a : b);
      final end = g.map((h) => h.$1.aEnd).reduce((a, b) => a > b ? a : b);
      if (start > pos) segments.add(MergeSegment.equal(pos, base.sublist(pos, start)));
      final l = _sideLines(left, lh, g, MergeSide.left, start, end);
      final r = _sideLines(right, rh, g, MergeSide.right, start, end);
      final hasLeft = g.any((h) => h.$2 == MergeSide.left);
      final hasRight = g.any((h) => h.$2 == MergeSide.right);
      final kind = hasLeft && hasRight
          ? (listEquals(l, r) ? ChunkKind.same : ChunkKind.conflict)
          : (hasLeft ? ChunkKind.left : ChunkKind.right);
      segments.add(MergeSegment.change(MergeChunk(kind: kind, baseStart: start, base: base.sublist(start, end), left: l, right: r)));
      pos = end;
    }
    if (pos < base.length) segments.add(MergeSegment.equal(pos, base.sublist(pos)));
    return segments;
  }

  /// 基准里 [start, end) 这一段在某一侧对应的行。这一侧在组里有改动时,从第一段改动往前、
  /// 最后一段往后都是没变的行,线性对应;没有改动时整段按之前的累计偏移平移过去。
  static List<String> _sideLines(List<String> side, List<LineHunk> hunks, List<(LineHunk, MergeSide)> group, MergeSide which, int start, int end) {
    final mine = [for (final h in group) if (h.$2 == which) h.$1];
    if (mine.isNotEmpty) {
      final from = mine.first.bStart - (mine.first.aStart - start);
      final to = mine.last.bEnd + (end - mine.last.aEnd);
      return side.sublist(from, to);
    }
    // 不在组里、又从组前面开始的改动一定整段都在组前面(碰到组的都被归进组了)
    var delta = 0;
    for (final h in hunks) {
      if (h.aStart < start) delta += h.delta;
    }
    return side.sublist(start + delta, end + delta);
  }

  // ---------------------------------------------------------------------------
  // 操作
  // ---------------------------------------------------------------------------

  void _checkpoint() => _undo.add([for (final c in chunks) c._save()]);

  /// 撤销上一步(采用、忽略、手改、批量操作都算一步)。
  void undo() {
    if (_undo.isEmpty) return;
    final s = _undo.removeLast();
    for (var i = 0; i < chunks.length; i++) {
      chunks[i]._restore(s[i]);
    }
    notifyListeners();
  }

  /// 采用 [chunk] 里 [side] 的改动(» / «)。冲突里另一侧已经采用过时,接在它后面。
  void apply(MergeChunk chunk, MergeSide side) {
    if (!chunk.pending(side)) return;
    _checkpoint();
    if (chunk.kind == ChunkKind.same) {
      chunk.applied.addAll(MergeSide.values);
    } else {
      chunk.applied.add(side);
    }
    notifyListeners();
  }

  /// 不要 [chunk] 里 [side] 的改动(×)。
  void ignore(MergeChunk chunk, MergeSide side) {
    if (!chunk.pending(side)) return;
    _checkpoint();
    if (chunk.kind == ChunkKind.same) {
      chunk.ignored.addAll(MergeSide.values);
    } else {
      chunk.ignored.add(side);
    }
    notifyListeners();
  }

  /// 在结果里手改这一块。
  void edit(MergeChunk chunk, List<String> lines) {
    _checkpoint();
    chunk.custom = List.of(lines);
    notifyListeners();
  }

  /// 「Apply non-conflicting changes」:把还没处理的非冲突改动全部采用。[side] 为 null 时两侧都要。
  int applyNonConflicting([MergeSide? side]) {
    final targets = [
      for (final c in chunks)
        if (!c.isConflict && !c.resolved && (side == null || c.changedOn(side))) c,
    ];
    if (targets.isEmpty) return 0;
    _checkpoint();
    for (final c in targets) {
      if (c.kind == ChunkKind.same) {
        c.applied.addAll(MergeSide.values);
      } else {
        c.applied.add(c.kind == ChunkKind.left ? MergeSide.left : MergeSide.right);
      }
    }
    notifyListeners();
    return targets.length;
  }

  // ---------------------------------------------------------------------------
  // 结果与显示
  // ---------------------------------------------------------------------------

  List<String> get resultLines => [
        for (final s in segments)
          if (s.chunk == null) ...s.lines else ...s.chunk!.result,
      ];

  /// 写回文件的文本:换行风格和末尾换行跟 Yours 一致。
  String get resultText {
    final lines = resultLines;
    if (lines.isEmpty) return '';
    final nl = _leftText.crlf ? '\r\n' : '\n';
    return lines.join(nl) + (_leftText.trailingNewline || (_leftText.lines.isEmpty && _rightText.trailingNewline) ? nl : '');
  }

  /// 三栏对齐的行。改动块占三栏里最多的那几行,其余栏补空。
  List<MergeRow> rows() {
    final out = <MergeRow>[];
    var li = 0, ri = 0, oi = 0;
    for (final s in segments) {
      final chunk = s.chunk;
      if (chunk == null) {
        for (final line in s.lines) {
          out.add(MergeRow(left: li++, result: oi++, right: ri++, leftText: line, resultText: line, rightText: line));
        }
        continue;
      }
      final res = chunk.result;
      var n = [chunk.left.length, chunk.right.length, res.length].reduce((a, b) => a > b ? a : b);
      // 还没处理的块哪怕三栏都是空的也留一行,让按钮有地方放
      if (n == 0 && !chunk.resolved) n = 1;
      for (var k = 0; k < n; k++) {
        out.add(MergeRow(
          left: k < chunk.left.length ? li + k : null,
          right: k < chunk.right.length ? ri + k : null,
          result: k < res.length ? oi + k : null,
          leftText: k < chunk.left.length ? chunk.left[k] : null,
          rightText: k < chunk.right.length ? chunk.right[k] : null,
          resultText: k < res.length ? res[k] : null,
          chunk: chunk,
          firstOfChunk: k == 0,
        ));
      }
      li += chunk.left.length;
      ri += chunk.right.length;
      oi += res.length;
    }
    return out;
  }
}
