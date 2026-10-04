import 'dart:math';

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
}
