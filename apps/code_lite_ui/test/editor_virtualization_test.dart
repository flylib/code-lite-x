import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/visible_lines.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 大文件:只构建视口附近的行;光标闪烁不重建编辑区;行号栏按位数加宽。
void main() {
  test('visible range covers the viewport plus overscan, aligned to chunks', () {
    final (a, b) = VisibleLines.rangeFor(lineCount: 20000, lineHeight: 20, scrollOffset: 0, viewportHeight: 600);
    expect(a, 0);
    expect(b, greaterThanOrEqualTo(30 + 40 - 1));
    expect(b, lessThan(200));
    final (c, d) = VisibleLines.rangeFor(lineCount: 20000, lineHeight: 20, scrollOffset: 200000, viewportHeight: 600);
    expect(c, lessThanOrEqualTo(10000 - 40));
    expect(d, greaterThanOrEqualTo(10030 + 40 - 1));
    expect(d - c, lessThan(250));
    expect(VisibleLines.rangeFor(lineCount: 0, lineHeight: 20, scrollOffset: 0, viewportHeight: 600), (0, -1));
    expect(VisibleLines.rangeFor(lineCount: 10, lineHeight: 20, scrollOffset: 0, viewportHeight: 600), (0, 9));
    // 小幅滚动(不跨分块)范围不变 → 不重建
    final r1 = VisibleLines.rangeFor(lineCount: 20000, lineHeight: 20, scrollOffset: 20000, viewportHeight: 600);
    final r2 = VisibleLines.rangeFor(lineCount: 20000, lineHeight: 20, scrollOffset: 20000 + 100, viewportHeight: 600);
    expect(r2, r1);
  });

  group('large file', () {
    late CodeEditorController ctrl;

    Future<void> pumpEditor(WidgetTester tester, int lines) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ctrl = CodeEditorController(initialText: [for (var i = 0; i < lines; i++) 'int v$i = $i; // 第 $i 行'].join('\n'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorViewWidget(
            openTabs: const ['Big.java'],
            activeFile: 'Big.java',
            codeContent: '',
            controller: ctrl,
            onSelectTab: (_) {},
            onCloseTab: (_) {},
            onCodeChanged: (_) {},
          ),
        ),
      ));
      await tester.pump();
    }

    Future<void> dispose(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    }

    Finder codeLine(int i) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'int v$i = $i; // 第 $i 行');
    int builtCodeLines() =>
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('int v')).evaluate().length;

    testWidgets('20k lines: only rows near the viewport are built; scrolling brings others in', (tester) async {
      await pumpEditor(tester, 20000);
      expect(codeLine(0), findsOneWidget);
      expect(codeLine(19999), findsNothing);
      expect(builtCodeLines(), lessThan(200), reason: '2 万行里只构建视口附近的');

      // 滚到第 10000 行附近
      final scrollable = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      tester.state<ScrollableState>(scrollable).position.jumpTo(10000 * 20.0);
      await tester.pump();
      expect(codeLine(10005), findsOneWidget);
      expect(codeLine(0), findsNothing);
      expect(builtCodeLines(), lessThan(250));
      expect(find.text('10006'), findsOneWidget, reason: '行号栏同样跟着滚动');

      // 光标设在可见行,输入照常
      ctrl.setCursor(const EditorPosition(10005, 0));
      ctrl.insertText('final ');
      await tester.pump();
      expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'final int v10005 = 10005; // 第 10005 行'), findsOneWidget);
      await dispose(tester);
    });

    testWidgets('gutter widens for 5-digit line numbers instead of clipping them', (tester) async {
      await pumpEditor(tester, 20000);
      final scrollable = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      tester.state<ScrollableState>(scrollable).position.jumpTo(19980 * 20.0);
      await tester.pump();
      final number = find.text('20000');
      expect(number, findsOneWidget);
      // 文字完整排下(没有被截断):单行、宽度等于自身内容宽度
      final para = tester.renderObject<RenderParagraph>(number);
      expect(para.didExceedMaxLines, isFalse);
      expect(para.size.width, moreOrLessEquals(para.getMaxIntrinsicWidth(double.infinity), epsilon: 0.5));
      expect(tester.takeException(), isNull, reason: '没有 RenderFlex 溢出');
      await dispose(tester);
    });

    testWidgets('caret blink does not notify the controller (no full editor rebuild)', (tester) async {
      await pumpEditor(tester, 300);
      ctrl.setCursor(const EditorPosition(3, 2));
      await tester.pump();
      var notifications = 0;
      void count() => notifications++;
      ctrl.addListener(count);
      final blinks = <bool>[];
      void onBlink() => blinks.add(ctrl.caretBlink.value);
      ctrl.caretBlink.addListener(onBlink);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(blinks, [false, true, false, true], reason: '光标照常闪烁');
      expect(notifications, 0, reason: '闪烁只通知 caretBlink,编辑区不重建');
      ctrl.removeListener(count);
      ctrl.caretBlink.removeListener(onBlink);
      await dispose(tester);
    });
  });
}
