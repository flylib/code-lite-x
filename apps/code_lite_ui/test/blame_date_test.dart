import 'package:code_lite_ui/features/editor/blame.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:flutter_test/flutter_test.dart';

/// 行号旁的 Git 注释栏:今天的提交显示 Today,其它显示 年/月/日。
void main() {
  final now = DateTime(2026, 10, 12, 19, 30);

  test('today (any time of day) is "Today"; yesterday and other years keep the date', () {
    expect(blameDate(DateTime(2026, 10, 12, 0, 0, 1), now: now), 'Today');
    expect(blameDate(DateTime(2026, 10, 12, 23, 59), now: now), 'Today');
    expect(blameDate(DateTime(2026, 10, 11, 23, 59), now: now), '2026/10/11');
    expect(blameDate(DateTime(2025, 10, 12, 12), now: now), '2025/10/12', reason: '去年的同一天不是今天');
  });

  test('the annotation label uses it together with the author', () {
    final c = BlameCommit.fromJson({
      'hash': 'a' * 40,
      'author': 'zanson2023',
      'email': 'z@example.com',
      'time': DateTime(2026, 10, 12, 9).millisecondsSinceEpoch ~/ 1000,
      'summary': 'x',
    }, 'a.sql');
    final a = EditorAppearance();
    expect(blameLabel(c, a, now: now), 'Today  zanson2023');
    expect(blameLabel(c, a, now: DateTime(2026, 10, 13, 8)), '2026/10/12  zanson2023');
    a.dispose();
  });
}
