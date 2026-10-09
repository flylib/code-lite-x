import 'dart:math';

import 'package:code_lite_ui/features/commit/line_diff.dart';
import 'package:code_lite_ui/features/git/merge_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三方合并的拆块与结果。
String text(List<String> lines) => lines.isEmpty ? '' : '${lines.join('\n')}\n';

MergeModel model(List<String> base, List<String> left, List<String> right) =>
    MergeModel(base: text(base), left: text(left), right: text(right));

void main() {
  test('lineHunks: positions of each change', () {
    expect(lineHunks(['a', 'b', 'c'], ['a', 'B', 'c']).map((h) => '${h.aStart}-${h.aEnd}/${h.bStart}-${h.bEnd}'), ['1-2/1-2']);
    expect(lineHunks(['a', 'c'], ['a', 'b', 'c']).single.delta, 1);
    expect(lineHunks(['a', 'b', 'c', 'd', 'e'], ['x', 'b', 'c', 'd']).map((h) => '${h.aStart}-${h.aEnd}/${h.bStart}-${h.bEnd}'), ['0-1/0-1', '4-5/4-4']);
    expect(lineHunks(const [], const []), isEmpty);
  });

  test('changes on different lines are separate non-conflicting chunks; same lines differently is a conflict', () {
    final m = model(
      ['p', 'a', 'b', 'c', 'd', 'e', 'f'],
      ['p', 'A', 'b', 'c', 'D1', 'e', 'f'],
      ['p', 'a', 'b', 'C', 'D2', 'e', 'f', 'g'],
    );
    expect(m.chunks.map((c) => c.kind), [ChunkKind.left, ChunkKind.conflict, ChunkKind.right]);
    final conflict = m.chunks[1];
    expect(conflict.base, ['c', 'd'], reason: '右侧改了 c、d,左侧改了 d:合成一块');
    expect(conflict.left, ['c', 'D1']);
    expect(conflict.right, ['C', 'D2']);
    expect(m.chunks[2].base, isEmpty, reason: '末尾追加:纯插入');
    expect(m.chunks[2].right, ['g']);
    expect(m.unresolvedChanges, 3);
    expect(m.unresolvedConflicts, 1);
    expect(m.resultLines, ['p', 'a', 'b', 'c', 'd', 'e', 'f'], reason: '还没处理时结果是基准版本');
  });

  test('adjacent changes conflict (like git); identical changes on both sides are one chunk', () {
    final adj = model(['a', 'b', 'c'], ['A', 'b', 'c'], ['a', 'B', 'c']);
    expect(adj.chunks.single.kind, ChunkKind.conflict);
    expect(adj.chunks.single.base, ['a', 'b']);

    final same = model(['a', 'b', 'c'], ['a', 'X', 'c'], ['a', 'X', 'c']);
    expect(same.chunks.single.kind, ChunkKind.same);
    expect(same.unresolvedConflicts, 0);
    same.apply(same.chunks.single, MergeSide.right);
    expect(same.chunks.single.resolved, isTrue, reason: '一样的改动处理任一侧就够了');
    expect(same.resultLines, ['a', 'X', 'c']);

    final bothInsert = model(['a', 'b'], ['a', 'x', 'b'], ['a', 'y', 'b']);
    expect(bothInsert.chunks.single.kind, ChunkKind.conflict, reason: '同一位置各插入不同内容');
  });

  test('apply / ignore / append both sides of a conflict / hand edit / undo', () {
    final m = model(['1', 'c', '2'], ['1', 'L', '2'], ['1', 'R', '2']);
    final c = m.chunks.single;
    m.apply(c, MergeSide.left);
    expect(m.resultLines, ['1', 'L', '2']);
    expect(c.resolved, isFalse, reason: '冲突:右侧还等着处理');
    expect(c.pending(MergeSide.right), isTrue);
    m.apply(c, MergeSide.right);
    expect(m.resultLines, ['1', 'L', 'R', '2'], reason: '两侧都要:按采用顺序拼起来');
    expect(c.resolved, isTrue);

    m.undo();
    expect(m.resultLines, ['1', 'L', '2']);
    m.ignore(c, MergeSide.right);
    expect(c.resolved, isTrue);
    expect(m.resultLines, ['1', 'L', '2']);

    m.undo();
    m.undo();
    expect(m.resultLines, ['1', 'c', '2']);
    expect(m.canUndo, isFalse);

    m.ignore(c, MergeSide.left);
    m.ignore(c, MergeSide.right);
    expect(m.resultLines, ['1', 'c', '2'], reason: '两侧都不要:保留基准');
    expect(c.resolved, isTrue);

    m.editResult(1, 2, ['hand', 'made']);
    expect(m.resultLines, ['1', 'hand', 'made', '2']);
    expect(c.pending(MergeSide.left), isFalse, reason: '手改过的块算解决了');
  });

  test('apply non-conflicting changes leaves conflicts alone; per side', () {
    final m = model(
      ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
      ['A', 'b', 'c', 'D1', 'e', 'f', 'g'],
      ['a', 'b', 'c', 'D2', 'e', 'f', 'G'],
    );
    expect(m.chunks.map((c) => c.kind), [ChunkKind.left, ChunkKind.conflict, ChunkKind.right]);
    expect(m.applyNonConflicting(MergeSide.right), 1);
    expect(m.resultLines, ['a', 'b', 'c', 'd', 'e', 'f', 'G']);
    expect(m.applyNonConflicting(), 1);
    expect(m.resultLines, ['A', 'b', 'c', 'd', 'e', 'f', 'G']);
    expect(m.unresolvedChanges, 1);
    expect(m.unresolvedConflicts, 1);
    expect(m.applyNonConflicting(), 0);
    m.undo();
    expect(m.resultLines.first, 'a', reason: '批量操作一步撤销');
  });

  test('rows align the three columns; fillers where a side has fewer lines; numbering skips fillers', () {
    final m = model(['a', 'b', 'z'], ['a', 'x', 'y', 'z'], ['a', 'b', 'z']);
    final rows = m.rows();
    expect(rows.length, 4, reason: 'a,块(2 行),z');
    final chunkRows = rows.where((r) => r.chunk != null).toList();
    expect(chunkRows.length, 2);
    expect(chunkRows.first.firstOfChunk, isTrue);
    expect([for (final r in chunkRows) r.leftText], ['x', 'y']);
    expect([for (final r in chunkRows) r.rightText], ['b', null]);
    expect([for (final r in chunkRows) r.resultText], ['b', null]);
    expect(rows.last.left, 3);
    expect(rows.last.right, 2);
    expect(rows.last.result, 2);

    // 都删掉了、而且已处理:不占行
    final del = model(['a', 'b', 'c'], ['a', 'c'], ['a', 'c']);
    expect(del.rows().length, 3, reason: '没处理时显示基准的 b');
    del.apply(del.chunks.single, MergeSide.left);
    expect(del.rows().length, 2);
  });

  test('result text keeps the line ending style and the trailing newline of Yours', () {
    final crlf = MergeModel(base: 'a\r\nb\r\n', left: 'a\r\nB\r\n', right: 'a\r\nb\r\n');
    crlf.applyNonConflicting();
    expect(crlf.resultText, 'a\r\nB\r\n');
    final noEol = MergeModel(base: 'a\nm\nb', left: 'a\nm\nB', right: 'A\nm\nb');
    noEol.applyNonConflicting();
    expect(noEol.resultText, 'A\nm\nB', reason: 'Yours 末尾没有换行,结果也没有');
    expect(MergeModel(base: '', left: '', right: '').resultText, '');
    final added = MergeModel(base: '', left: 'x\n', right: 'y\n');
    expect(added.chunks.single.kind, ChunkKind.conflict, reason: '两边新建了同名文件');
  });

  test('property: taking one side everywhere reproduces that side exactly (random edits)', () {
    final rnd = Random(7);
    List<String> mutate(List<String> base) {
      final out = <String>[];
      for (final line in base) {
        final r = rnd.nextInt(10);
        if (r == 0) continue; // 删
        if (r == 1) out.add('${line}_${rnd.nextInt(3)}'); // 改
        if (r == 2) out.add('ins${rnd.nextInt(4)}'); // 插
        if (r != 1) out.add(line);
      }
      if (rnd.nextBool()) out.add('tail${rnd.nextInt(2)}');
      return out;
    }

    for (var round = 0; round < 400; round++) {
      final base = [for (var i = 0; i < rnd.nextInt(25); i++) 'l${rnd.nextInt(6)}'];
      final left = mutate(base), right = mutate(base);
      for (final side in MergeSide.values) {
        final m = model(base, left, right);
        for (final c in m.chunks) {
          if (c.pending(side)) m.apply(c, side);
          final other = side == MergeSide.left ? MergeSide.right : MergeSide.left;
          if (c.pending(other)) m.ignore(c, other);
        }
        expect(m.resultLines, side == MergeSide.left ? left : right, reason: 'round $round $side\nbase=$base\nleft=$left\nright=$right');
        expect(m.unresolvedChanges, 0);
        // 对齐行里每栏的文字按顺序拼起来就是该栏的版本
        final rows = m.rows();
        expect([for (final r in rows) if (r.leftText != null) r.leftText], left);
        expect([for (final r in rows) if (r.rightText != null) r.rightText], right);
      }
      // 没处理时结果就是基准
      expect(model(base, left, right).resultLines, base);
    }
  });

  group('editing the result directly', () {
    test('typing on one line: the chunk it falls in is resolved by hand; consecutive typing is one undo step', () {
      final m = model(['a', 'b', 'c'], ['a', 'B', 'c'], ['a', 'b', 'c', 'd']);
      expect(m.chunks.map((c) => c.kind), [ChunkKind.left, ChunkKind.right]);
      m.setResultLine(1, 'bx');
      m.setResultLine(1, 'bxy');
      expect(m.resultLines, ['a', 'bxy', 'c']);
      expect(m.chunks.first.resolved, isTrue);
      expect(m.chunks.last.resolved, isFalse);
      m.undo();
      expect(m.resultLines, ['a', 'b', 'c'], reason: '同一行连续打的字一步撤销');
      expect(m.canUndo, isFalse);

      m.setResultLine(1, 'q');
      m.setResultLine(0, 'z');
      m.undo();
      expect(m.resultLines, ['a', 'q', 'c'], reason: '换了一行打字就是新的一步');
      m.setResultLine(1, 'q'); // 没变
      expect(m.resultLines, ['a', 'q', 'c']);
    });

    test('editing unchanged lines keeps the three columns aligned; left / right still show the originals', () {
      final m = model(['a', 'b', 'c'], ['a', 'b', 'C'], ['a', 'b', 'c']);
      m.editResult(0, 1, ['a1', 'a2', 'a3']);
      expect(m.resultLines, ['a1', 'a2', 'a3', 'b', 'c']);
      final rows = m.rows();
      expect([for (final r in rows) r.leftText], ['a', null, null, 'b', 'C'], reason: '没动的 b 仍然对着 b');
      expect([for (final r in rows) r.resultText], ['a1', 'a2', 'a3', 'b', 'c']);
      expect([for (final r in rows) r.edited], [true, true, true, false, false]);
      expect(rows.last.result, 4);
      expect(m.chunks.single.resolved, isFalse, reason: '没改到改动块');
      m.apply(m.chunks.single, MergeSide.left);
      expect(m.resultLines, ['a1', 'a2', 'a3', 'b', 'C'], reason: '手改别处之后按钮照样能用');
    });

    test('an edit across a segment boundary (join, split) goes to the first segment', () {
      final m = model(['a', 'b', 'c'], ['a', 'B', 'c'], ['a', 'b', 'c']);
      // 在块的第一行行首退格:和上一行(没变的段)合成一行
      m.editResult(0, 2, ['ab']);
      expect(m.resultLines, ['ab', 'c']);
      expect(m.chunks.single.resolved, isTrue, reason: '块的内容被并到前一段:块变空、算手工解决');
      expect(m.chunks.single.result, isEmpty);
      m.undo();
      expect(m.resultLines, ['a', 'b', 'c']);
      // 拆行
      m.editResult(2, 3, ['', 'c']);
      expect(m.resultLines, ['a', 'b', '', 'c']);
      expect(m.chunks.single.resolved, isFalse);
      expect(m.resultText, 'a\nb\n\nc\n');
    });

    test('property: random direct edits keep result = concatenation of segments and rows consistent', () {
      final rnd = Random(3);
      for (var round = 0; round < 200; round++) {
        final base = [for (var i = 0; i < 1 + rnd.nextInt(12); i++) 'l$i'];
        final left = [...base]..[rnd.nextInt(base.length)] = 'L';
        final right = [...base, 'R'];
        final m = model(base, left, right);
        var expected = List.of(m.resultLines);
        for (var step = 0; step < 6; step++) {
          if (expected.isEmpty) break;
          final start = rnd.nextInt(expected.length);
          final end = start + 1 + rnd.nextInt((expected.length - start).clamp(1, 3));
          final e = end > expected.length ? expected.length : end;
          final lines = [for (var i = 0; i < rnd.nextInt(3); i++) 'e$round.$step.$i'];
          m.editResult(start, e, lines);
          expected = [...expected.sublist(0, start), ...lines, ...expected.sublist(e)];
          expect(m.resultLines, expected, reason: 'round $round step $step');
          expect([for (final r in m.rows()) if (r.resultText != null) r.resultText], expected);
          expect([for (final r in m.rows()) if (r.leftText != null) r.leftText], left);
        }
      }
    });
  });
}
