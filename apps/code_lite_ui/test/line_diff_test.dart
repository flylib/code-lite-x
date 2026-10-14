import 'dart:math';

import 'package:code_lite_ui/core/ffi/rust_diff.dart';
import 'package:code_lite_ui/features/commit/line_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('modified line pairs side by side; pure inserts/deletes get blanks on the other side', () {
    final rows = sideBySideDiff(
      ['a', 'b', 'c', 'd'],
      ['a', 'B', 'c', 'x', 'd'],
    );
    expect(rows.map((r) => r.kind).toList(), [
      DiffRowKind.equal,
      DiffRowKind.modify,
      DiffRowKind.equal,
      DiffRowKind.insert,
      DiffRowKind.equal,
    ]);
    expect(rows[1].left, 1);
    expect(rows[1].right, 1);
    expect(rows[3].left, isNull);
    expect(rows[3].right, 3);
    expect(changeBlockStarts(rows), [1, 3]);
  });

  test('new and deleted files', () {
    expect(sideBySideDiff([], ['x', 'y']).every((r) => r.kind == DiffRowKind.insert), isTrue);
    expect(sideBySideDiff(['x'], []).single.kind, DiffRowKind.delete);
    expect(sideBySideDiff(['same'], ['same']).single.kind, DiffRowKind.equal);
  });

  test('changedSpan isolates the edited part of a line', () {
    final s = changedSpan('private String serverAddress = "x";', 'private String serverA_ddress = "x";');
    expect(s.start, 'private String serverA'.length);
    expect('private String serverA_ddress = "x";'.substring(s.start, s.newEnd), '_');
    expect(s.oldEnd, s.start); // 旧行这里是纯插入
  });

  test('random inputs: both sides reconstruct exactly and equal rows really match', () {
    final rnd = Random(42);
    List<String> gen() => List.generate(rnd.nextInt(30), (_) => String.fromCharCode(97 + rnd.nextInt(4)));
    for (var t = 0; t < 500; t++) {
      final a = gen(), b = gen();
      final rows = sideBySideDiff(a, b);
      expect([for (final r in rows) if (r.left != null) a[r.left!]], a, reason: '$a → $b');
      expect([for (final r in rows) if (r.right != null) b[r.right!]], b, reason: '$a → $b');
      for (final r in rows.where((r) => r.kind == DiffRowKind.equal)) {
        expect(a[r.left!], b[r.right!]);
      }
      // 左右行号都严格递增
      final ls = [for (final r in rows) if (r.left != null) r.left!];
      final rs = [for (final r in rows) if (r.right != null) r.right!];
      expect(ls, List.generate(a.length, (i) => i));
      expect(rs, List.generate(b.length, (i) => i));
    }
  });

  /// 各段改动套到 a 上,得到的必须正好是 b;段落按位置递增、互不相邻,段外的行两边一致。
  void expectValidHunks(List<String> a, List<String> b, List<LineHunk> hunks) {
    final out = <String>[];
    var i = 0, j = 0, lastEnd = -1;
    for (final h in hunks) {
      expect(h.aStart, greaterThan(lastEnd), reason: 'hunks ordered and separated');
      expect(h.aEnd - h.aStart + h.bEnd - h.bStart, greaterThan(0));
      expect(h.bStart - j, h.aStart - i, reason: 'unchanged run has same length');
      for (; i < h.aStart; i++, j++) {
        expect(a[i], b[j]);
        out.add(a[i]);
      }
      out.addAll(b.sublist(h.bStart, h.bEnd));
      i = h.aEnd;
      j = h.bEnd;
      lastEnd = h.aEnd;
    }
    out.addAll(a.sublist(i));
    expect(out, b);
  }

  test('Rust diff is loaded in tests (otherwise the rest only checks the Dart fallback)', () {
    expect(rustLineHunks(['a'], ['b']), isNotNull);
  });

  test('Rust and Dart hunks are both valid on random inputs, incl. empty lines and non-ASCII', () {
    final rnd = Random(7);
    const alphabet = ['a', 'b', '', '中文', 'é', '  x', 'b'];
    List<String> gen() => List.generate(rnd.nextInt(40), (_) => alphabet[rnd.nextInt(alphabet.length)]);
    for (var t = 0; t < 500; t++) {
      final a = gen(), b = gen();
      expectValidHunks(a, b, lineHunks(a, b));
      expectValidHunks(a, b, dartLineHunks(a, b));
    }
  });

  test('empty vs single empty line are different inputs', () {
    expect(lineHunks([], ['']).single, isA<LineHunk>().having((h) => h.bEnd, 'bEnd', 1));
    expect(lineHunks([''], []).single.aEnd, 1);
    expect(lineHunks([''], ['']), isEmpty);
  });

  test('a 50k-line full rewrite finishes fast (the Dart Myers took >60s here)', () {
    final a = List.generate(50000, (i) => 'old line $i');
    final b = List.generate(50000, (i) => 'new line $i');
    final sw = Stopwatch()..start();
    final rows = sideBySideDiff(a, b);
    sw.stop();
    expect(rows.length, 50000);
    expect(rows.every((r) => r.kind == DiffRowKind.modify), isTrue);
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });
}
