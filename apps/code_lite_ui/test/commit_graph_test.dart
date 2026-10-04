import 'package:code_lite_ui/features/git/commit_graph.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('layoutCommitGraph', () {
    test('linear history stays on one lane with one color', () {
      final rows = layoutCommitGraph(['c', 'b', 'a'], [
        ['b'],
        ['a'],
        [],
      ]);
      expect(rows.map((r) => r.lane), [0, 0, 0]);
      expect(rows.map((r) => r.color).toSet(), hasLength(1));
      expect(rows.every((r) => r.width == 1), isTrue);
      // 中间一行:上半段汇入、下半段连到父提交。
      expect(rows[1].lines.where((l) => l.fromY == 0 && l.toY == 0.5), hasLength(1));
      expect(rows[1].lines.where((l) => l.fromY == 0.5 && l.toY == 1), hasLength(1));
      // 根提交没有往下的线。
      expect(rows[2].lines.where((l) => l.fromY == 0.5), isEmpty);
    });

    test('branch and merge use a second lane and converge', () {
      //   m      (merge of x and f)
      //   |\
      //   x f
      //   |/
      //   base
      final rows = layoutCommitGraph(['m', 'f', 'x', 'base'], [
        ['x', 'f'],
        ['base'],
        ['base'],
        [],
      ]);
      expect(rows[0].lane, 0);
      expect(rows[0].width, 2); // 合并提交向下分出第二条轨道
      expect(rows[1].lane, 1); // f 在第二条轨道
      expect(rows[2].lane, 0); // x 留在主轨道
      expect(rows[3].lane, 0); // base 仍在主轨道:第一父链不被挤到右边
      // f 的轨道在 x 那一行斜着并入主轨道,base 只从正上方一条线汇入。
      expect(rows[2].lines.where((l) => l.fromLane == 1 && l.fromY == 0 && l.toLane == 0 && l.toY == 1), hasLength(1));
      expect(rows[3].lines.where((l) => l.toY == 0.5), hasLength(1));
      expect(rows[3].width, 1);
      expect(rows[1].color, isNot(rows[0].color));
    });

    test('parents missing from the page do not crash and lanes are released', () {
      final rows = layoutCommitGraph(['b', 'a'], [
        ['zzz'], // 被筛选掉的父提交
        ['yyy'],
      ]);
      expect(rows, hasLength(2));
      expect(rows[0].lane, 0);
      expect(rows[1].lane, 1); // a 不在 b 的父链上,开新轨道
    });
  });
}
