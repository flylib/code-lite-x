import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// ⇧⌘↑ / ⇧⌘↓(IntelliJ 的 Move Statement Up / Down):光标所在行整行上移 / 下移一行,光标跟着走。
void main() {
  test('defaults: Shift+Cmd+Up / Down (Ctrl+Shift elsewhere), under Editing', () {
    final up = keymapActionById(KeymapIds.moveLineUp)!;
    expect(up.mac, ['shift meta UP']);
    expect(up.other, ['ctrl shift UP']);
    expect(keymapActionById(KeymapIds.moveLineDown)!.mac, ['shift meta DOWN']);
    expect(up.keymapGroup, KeymapGroup.editing);
  });

  test('one line moves up / down with the caret; nothing happens at the edges; one undo step', () {
    final c = CodeEditorController(initialText: 'a\nbb\nccc\ndddd');
    c.setCursor(const EditorPosition(2, 1));
    expect(c.moveLines(-1), isTrue);
    expect(c.text, 'a\nccc\nbb\ndddd');
    expect(c.cursorPosition, const EditorPosition(1, 1));
    expect(c.moveLines(-1), isTrue);
    expect(c.text, 'ccc\na\nbb\ndddd');
    expect(c.moveLines(-1), isFalse, reason: '已经在第一行');
    expect(c.text, 'ccc\na\nbb\ndddd');

    c.setCursor(const EditorPosition(2, 0));
    expect(c.moveLines(1), isTrue);
    expect(c.text, 'ccc\na\ndddd\nbb');
    expect(c.moveLines(1), isFalse, reason: '已经在最后一行');

    c.undo();
    expect(c.text, 'ccc\na\nbb\ndddd', reason: '一次移动一步撤销');
    c.dispose();
  });

  test('a selection moves the lines it spans; a selection ending at column 0 leaves that line', () {
    final c = CodeEditorController(initialText: 'a\nb\nc\nd\ne');
    c.setSelection(const EditorPosition(1, 0), const EditorPosition(2, 1));
    c.moveLines(1);
    expect(c.text, 'a\nd\nb\nc\ne');
    expect(c.selection.start, const EditorPosition(2, 0));
    expect(c.selection.end, const EditorPosition(3, 1));

    c.setSelection(const EditorPosition(2, 0), const EditorPosition(4, 0)); // 选中 b、c 两整行
    c.moveLines(-1);
    expect(c.text, 'a\nb\nc\nd\ne');
    expect(c.selection.start, const EditorPosition(1, 0));
    expect(c.selection.end, const EditorPosition(3, 0));
    c.dispose();
  });

  testWidgets('Shift+Cmd+Up / Down in the editor move the line instead of selecting to the file edge', (tester) async {
    final ctrl = CodeEditorController(initialText: 'one\ntwo\nthree');
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
        ),
      ),
    ));
    await tester.tap(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'two'));
    await tester.pump();

    Future<void> chord(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    await chord(LogicalKeyboardKey.arrowUp);
    expect(ctrl.text, 'two\none\nthree');
    expect(ctrl.selection.isCollapsed, isTrue);
    await chord(LogicalKeyboardKey.arrowDown);
    await chord(LogicalKeyboardKey.arrowDown);
    expect(ctrl.text, 'one\nthree\ntwo');
    expect(ctrl.cursorPosition.line, 2);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
