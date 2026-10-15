import 'dart:collection';
import 'dart:typed_data';

import '../../core/ffi/rust_syntax.dart' show FoldRange;

export '../../core/ffi/rust_syntax.dart' show FoldRange;

/// 一个文档的代码折叠状态:哪些段收起了,以及「屏幕上第几行(可见行)」和「文档第几行」的换算。
///
/// 可折叠的范围来自语法树(`DocumentHighlighter.foldsIn`);这里只记收起的那些:起始行留着,
/// 起始行+1 ..= 结束行藏起来。收起的段可以嵌套,藏起来的行按最外层算。
/// 没有收起任何段时,可见行就是文档行(换算直接返回,零开销)。
class FoldState {
  /// 收起的段:起始行 → 结束行。
  final SplayTreeMap<int, int> _collapsed = SplayTreeMap();
  int _lineCount = 1;

  // 最外层的隐藏区间 [hiddenStart, hiddenEnd](= 起始行+1 .. 结束行)和它之前一共藏了多少行;
  // 收起的段一变就作废,下次用到时重算(收起的段通常只有几个到几十个)。
  Int32List? _hs;
  Int32List? _he;
  Int32List? _before;
  int _hidden = 0;

  bool get hasCollapsed => _collapsed.isNotEmpty;

  /// 收起的段(按起始行排序)。
  List<FoldRange> get collapsed => [for (final e in _collapsed.entries) FoldRange(e.key, e.value)];

  bool isCollapsed(int start) => _collapsed.containsKey(start);

  /// 在 [start] 行收起的段的结束行;没收起返回 null。
  int? collapsedEndAt(int start) => _collapsed[start];

  int get lineCount => _lineCount;

  set lineCount(int n) {
    final count = n < 1 ? 1 : n;
    if (count == _lineCount) return;
    _lineCount = count;
    _collapsed.removeWhere((s, e) => s >= count - 1);
    for (final s in _collapsed.keys.toList()) {
      if (_collapsed[s]! > count - 1) _collapsed[s] = count - 1;
    }
    _invalidate();
  }

  void _invalidate() {
    _hs = null;
    _he = null;
    _before = null;
  }

  void _build() {
    if (_hs != null) return;
    final hs = <int>[], he = <int>[];
    for (final e in _collapsed.entries) {
      final s = e.key + 1, end = e.value;
      if (end < s) continue;
      if (he.isNotEmpty && s <= he.last) {
        // 嵌在上一段里(或和它重叠):并进去
        if (end > he.last) he[he.length - 1] = end;
        continue;
      }
      hs.add(s);
      he.add(end);
    }
    final before = Int32List(hs.length + 1);
    for (var i = 0; i < hs.length; i++) {
      before[i + 1] = before[i] + he[i] - hs[i] + 1;
    }
    _hs = Int32List.fromList(hs);
    _he = Int32List.fromList(he);
    _before = before;
    _hidden = before[hs.length];
  }

  /// 起始行 ≤ [line] 的隐藏区间个数。
  int _intervalsUpTo(int line) {
    final hs = _hs!;
    var lo = 0, hi = hs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (hs[mid] <= line) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// 屏幕上一共几行。
  int get rowCount {
    if (_collapsed.isEmpty) return _lineCount;
    _build();
    return _lineCount - _hidden;
  }

  bool isHidden(int line) {
    if (_collapsed.isEmpty) return false;
    _build();
    final k = _intervalsUpTo(line);
    return k > 0 && line <= _he![k - 1];
  }

  /// 文档第 [line] 行在第几个可见行;藏起来的行算在它所在的(最外层)收起段的起始行上。
  int rowOfLine(int line) {
    if (_collapsed.isEmpty) return line;
    _build();
    final k = _intervalsUpTo(line);
    if (k > 0 && line <= _he![k - 1]) return _hs![k - 1] - 1 - _before![k - 1];
    return line - _before![k];
  }

  /// 第 [row] 个可见行是文档的第几行。
  int lineOfRow(int row) {
    if (_collapsed.isEmpty) return row;
    _build();
    final hs = _hs!, before = _before!;
    // 第 k 段之前的可见行数 = hs[k] - before[k];找有几段完全在 row 之前
    var lo = 0, hi = hs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (hs[mid] - before[mid] <= row) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return row + before[lo];
  }

  /// 收起一段(结束行必须在起始行之后)。返回是否有变化。
  bool collapse(FoldRange r) {
    if (r.end <= r.start || r.start < 0 || r.start >= _lineCount) return false;
    final end = r.end > _lineCount - 1 ? _lineCount - 1 : r.end;
    if (end <= r.start || _collapsed[r.start] == end) return false;
    _collapsed[r.start] = end;
    _invalidate();
    return true;
  }

  bool expand(int start) {
    if (_collapsed.remove(start) == null) return false;
    _invalidate();
    return true;
  }

  bool expandAll() {
    if (_collapsed.isEmpty) return false;
    _collapsed.clear();
    _invalidate();
    return true;
  }

  /// 展开藏着 [line] 的所有段(光标、跳转落进去时)。返回是否有变化。
  bool reveal(int line) {
    if (_collapsed.isEmpty) return false;
    final hit = [for (final e in _collapsed.entries) if (e.key < line && line <= e.value) e.key];
    if (hit.isEmpty) return false;
    hit.forEach(_collapsed.remove);
    _invalidate();
    return true;
  }

  /// 文本改了:第 [first]..[last] 行被换成了 [newCount] 行。
  /// 改动之后的段跟着挪;只在折叠起始行里改字(没增删行)的段保留;其余碰到改动的段展开(IntelliJ 也这样)。
  void applyEdit(int first, int last, int newCount) {
    final delta = newCount - (last - first + 1);
    if (_collapsed.isNotEmpty) {
      final moved = <int, int>{};
      _collapsed.forEach((s, e) {
        if (e < first) {
          moved[s] = e;
        } else if (s > last) {
          moved[s + delta] = e + delta;
        } else if (s == first && last == first && newCount == 1) {
          moved[s] = e;
        }
      });
      _collapsed
        ..clear()
        ..addAll(moved);
    }
    _lineCount += delta;
    _invalidate();
  }

  /// 语法树给了从 [from] 到 [to](不含)开始的折叠范围:这段里收起的段按它更新结束行,
  /// 已经不能折叠的(比如花括号删了)展开。返回是否有变化。
  bool reconcile(List<FoldRange> regions, int from, int to) {
    if (_collapsed.isEmpty) return false;
    final byStart = {for (final r in regions) r.start: r.end};
    var changed = false;
    for (final s in _collapsed.keys.where((s) => s >= from && s < to).toList()) {
      final end = byStart[s];
      if (end == null || end <= s) {
        _collapsed.remove(s);
        changed = true;
      } else if (end != _collapsed[s]) {
        _collapsed[s] = end;
        changed = true;
      }
    }
    if (changed) _invalidate();
    return changed;
  }
}
