import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/lsp_overlay.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

EditorDiagnostic _diag(int line, {int col = 4, int severity = 1, String message = 'cannot find symbol'}) => EditorDiagnostic.fromJson({
      'range': {
        'start': {'line': line, 'character': col},
        'end': {'line': line, 'character': col + 3},
      },
      'severity': severity,
      'message': message,
    });

/// 编辑区右边的错误条:点标记跳到那个问题,悬停看提示,点空白处滚到对应位置(IntelliJ 的做法)。
void main() {
  test('hit: the nearest mark within 5px; an error beats a warning at the same spot; nothing far away', () {
    final err = _diag(100), warn = _diag(101, severity: 2), far = _diag(250);
    // 300 行、条高 600:第 100 行的标记顶边在 200,中心 201.5
    expect(errorStripeHit([warn, err, far], 300, 600, 201), same(err), reason: '一样近:错误优先');
    expect(errorStripeHit([warn, far], 300, 600, 204), same(warn));
    expect(errorStripeHit([err, far], 300, 600, 300), isNull, reason: '5px 以外不算点到');
    expect(errorStripeMarkTop(299, 300, 600), lessThanOrEqualTo(596), reason: '最后一行的标记不出界');
  });

  testWidgets('click a mark: the cursor goes to the problem and it scrolls into view; hover shows the message; empty space scrolls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ctrl = CodeEditorController(initialText: [for (var i = 0; i < 300; i++) 'int v$i = $i;'].join('\n'));
    final scroll = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['A.java'],
          activeFile: 'A.java',
          codeContent: '',
          controller: ctrl,
          verticalScroll: scroll,
          appearance: EditorAppearance(),
          diagnostics: [_diag(200, col: 6, message: 'cannot find symbol: v9999'), _diag(250, severity: 2, message: 'unused')],
          onSelectTab: (_) {},
          onCloseTab: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(scroll.offset, 0);

    final stripe = tester.getRect(find.byKey(const ValueKey('error-stripe')));
    Offset markAt(int line) => Offset(stripe.center.dx, stripe.top + errorStripeMarkTop(line, 300, stripe.height) + 1.5);

    // 悬停:手形光标 + 提示
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: stripe.center);
    await mouse.moveTo(markAt(200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('错误(第 201 行):cannot find symbol: v9999'), findsOneWidget);
    await mouse.removePointer();

    await tester.tapAt(markAt(200));
    await tester.pump();
    expect(ctrl.cursorPosition, const EditorPosition(200, 6), reason: '光标到报错的行和列');
    expect(scroll.offset, greaterThan(0), reason: '滚过去了');
    final afterError = scroll.offset;

    // 点空白处(条的顶部附近):滚回文件开头那一段
    await tester.tapAt(Offset(stripe.center.dx, stripe.top + 10));
    await tester.pump();
    expect(scroll.offset, lessThan(afterError));
    expect(ctrl.cursorPosition.line, lessThan(20));

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
    scroll.dispose();
  });
}
