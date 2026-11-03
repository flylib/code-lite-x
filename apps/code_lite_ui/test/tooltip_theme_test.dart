import 'package:code_lite_ui/core/theme/intellij_theme.dart';
import 'package:code_lite_ui/features/editor/blame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 悬停提示(blame、按钮……)跟主题一致:深底、白字(不是 Flutter 默认的浅灰底)。
void main() {
  testWidgets('tooltips are dark with light text', (tester) async {
    final commit = BlameCommit(hash: '4013bce8aa', author: 'zanson2023', email: 'z@example.com', time: DateTime(2026, 10, 31), summary: 'feat: task center', path: 'a.md');
    await tester.pumpWidget(MaterialApp(
      theme: IntelliJTheme.darkTheme,
      home: Scaffold(
        body: Center(child: Tooltip(key: const ValueKey('tip'), message: blameTooltip(commit), child: const Text('2026/10/31 zanson...'))),
      ),
    ));
    (tester.state(find.byKey(const ValueKey('tip'))) as TooltipState).ensureTooltipVisible();
    await tester.pumpAndSettle();

    final text = find.textContaining('4013bce8');
    expect(text, findsOneWidget);
    final style = tester.widget<Text>(text).style ?? DefaultTextStyle.of(tester.element(text)).style;
    final color = style.color ?? DefaultTextStyle.of(tester.element(text)).style.color;
    expect(color, IntelliJTheme.textHigh);
    final box = tester.widgetList<Container>(find.ancestor(of: text, matching: find.byType(Container)))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((d) => d.color != null);
    expect(box.color, IntelliJTheme.popupBg);
  });
}
