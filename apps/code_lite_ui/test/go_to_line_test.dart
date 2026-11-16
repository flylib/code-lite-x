import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/go_to_line_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// ⌘L(IntelliJ 的 Go to Line:Column)弹框跳到某行某列。
void main() {
  test('defaults: Cmd+L on macOS, Ctrl+G elsewhere', () {
    expect(keymapActionById(KeymapIds.gotoLine)!.mac, ['meta L']);
    expect(keymapActionById(KeymapIds.gotoLine)!.other, ['ctrl G']);
  });

  group('parseLineColumn', () {
    const lens = [10, 3, 0, 20]; // 4 行
    ({int line, int col})? p(String s) => parseLineColumn(s, currentLine: 1, lineLengths: lens);

    test('line, line:column, :column and line,column (1-based in, 0-based out)', () {
      expect(p('3'), (line: 2, col: 0));
      expect(p('4:5'), (line: 3, col: 4));
      expect(p(' 4 : 5 '), (line: 3, col: 4));
      expect(p('4,5'), (line: 3, col: 4));
      expect(p(':2'), (line: 1, col: 1), reason: '只给列 = 当前行');
      expect(p('4:'), (line: 3, col: 0));
    });

    test('past the end clamps to the last line / the line end', () {
      expect(p('999'), (line: 3, col: 0));
      expect(p('2:99'), (line: 1, col: 3));
    });

    test('garbage is refused', () {
      for (final s in ['', ' ', ':', 'abc', '0', '1:0', '-3', '1:2:3', '12a']) {
        expect(p(s), isNull, reason: s);
      }
    });
  });

  testWidgets('Cmd+L opens the dialog with the caret position selected; Enter jumps there and the editor keeps focus',
      (tester) async {
    final ctrl = CodeEditorController(initialText: [for (var i = 1; i <= 300; i++) 'line $i'].join('\n'));
    var jumps = 0;
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['a.txt'],
          activeFile: 'a.txt',
          codeContent: ctrl.text,
          controller: ctrl,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
          onCodeChanged: (_) {},
          keymap: KeymapStore(mac: true),
          onBeforeJump: () => jumps++,
        ),
      ),
    ));
    Future<void> cmdL() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'line 2'));
    await tester.pump(const Duration(seconds: 1));
    ctrl.setCursor(const EditorPosition(1, 3));
    await cmdL();

    expect(find.text('转到行:列'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('goto-line-field')));
    expect(field.controller!.text, '2:4');
    expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 3), reason: '全选,直接打新的行号');

    await tester.enterText(find.byKey(const ValueKey('goto-line-field')), 'x');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('转到行:列'), findsOneWidget, reason: '输错了不关');

    await tester.enterText(find.byKey(const ValueKey('goto-line-field')), '256:3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('转到行:列'), findsNothing);
    expect(ctrl.cursorPosition, const EditorPosition(255, 2));
    expect(jumps, 1, reason: '跳走前记下位置,⌘[ 能回来');
    expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'line 256'), findsOneWidget, reason: '滚到了那一行');

    // Esc 取消:光标不动;焦点还在编辑器上(⌘L 能再弹)
    await cmdL();
    expect(find.text('转到行:列'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('转到行:列'), findsNothing);
    expect(ctrl.cursorPosition, const EditorPosition(255, 2));
    await cmdL();
    expect(find.text('转到行:列'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
