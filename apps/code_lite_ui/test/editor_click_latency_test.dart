import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 点击代码区:光标要在鼠标按下的那一刻就到位(IntelliJ 就是这样),不能等手势判定。
void main() {
  late CodeEditorController ctrl;

  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ctrl = CodeEditorController(initialText: [for (var i = 0; i < 30; i++) '-- 第 $i 行:以下几处是为过审核规则做的妥协 select * from t$i;'].join('\n'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['a.sql'],
          activeFile: 'a.sql',
          codeContent: '',
          controller: ctrl,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  }

  /// 第 [line] 行文字中间某处的屏幕坐标。
  Offset pointOn(WidgetTester tester, int line) {
    final text = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('-- 第 $line 行'));
    final box = tester.getRect(text);
    return Offset(box.left + box.width * 0.4, box.center.dy);
  }

  testWidgets('the caret moves on mouse down, before any gesture timeout', (tester) async {
    await pumpEditor(tester);
    expect(ctrl.cursorPosition.line, 0);
    final gesture = await tester.startGesture(pointOn(tester, 7), kind: PointerDeviceKind.mouse);
    await tester.pump(); // 只给一帧,不推进手势判定的计时
    expect(ctrl.cursorPosition.line, 7, reason: '按下就该到位');
    expect(ctrl.cursorPosition.col, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ctrl.cursorPosition.line, 7);
    await done(tester);
  });

  testWidgets('double-click still selects a word; dragging still selects', (tester) async {
    await pumpEditor(tester);
    final p = pointOn(tester, 3);
    await tester.tapAt(p, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(p, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(ctrl.hasSelection, isTrue, reason: '双击选词');

    final from = pointOn(tester, 5);
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ctrl.hasSelection, isTrue, reason: '拖动选区');
    expect(ctrl.cursorPosition.line, greaterThan(5));
    await done(tester);
  });

  testWidgets('a right click does not move the caret', (tester) async {
    await pumpEditor(tester);
    final gesture = await tester.startGesture(pointOn(tester, 9), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ctrl.cursorPosition.line, 0);
    await done(tester);
  });
}
