import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 编辑 ▸ 复制行 / 选中内容(IntelliJ 的 Duplicate Line or Selection,默认 ⌘D)。
void main() {
  group('controller', () {
    test('no selection: the line is copied below and the caret follows to the same column', () {
      final c = CodeEditorController(initialText: 'a\n  int x = 1;\nb');
      c.setCursor(const EditorPosition(1, 5));
      c.duplicateLineOrSelection();
      expect(c.text, 'a\n  int x = 1;\n  int x = 1;\nb');
      expect(c.cursorPosition, const EditorPosition(2, 5));
      c.duplicateLineOrSelection();
      expect(c.lines.where((l) => l == '  int x = 1;').length, 3, reason: '再按一次再复制一行');
      c.undo();
      expect(c.text, 'a\n  int x = 1;\n  int x = 1;\nb', reason: '一次撤销只撤一次复制');
      c.undo();
      expect(c.text, 'a\n  int x = 1;\nb');
      c.dispose();
    });

    test('the last line and an empty document', () {
      final c = CodeEditorController(initialText: 'x\nlast');
      c.setCursor(const EditorPosition(1, 4));
      c.duplicateLineOrSelection();
      expect(c.text, 'x\nlast\nlast');
      expect(c.cursorPosition, const EditorPosition(2, 4));
      c.dispose();
      final e = CodeEditorController(initialText: '');
      e.duplicateLineOrSelection();
      expect(e.lines, ['', '']);
      e.dispose();
    });

    test('selection: a copy goes right after it and becomes the selection', () {
      final c = CodeEditorController(initialText: 'foo(bar)');
      c.setSelection(const EditorPosition(0, 4), const EditorPosition(0, 7));
      c.duplicateLineOrSelection();
      expect(c.text, 'foo(barbar)');
      expect(c.selection.start, const EditorPosition(0, 7));
      expect(c.selection.end, const EditorPosition(0, 10));

      final m = CodeEditorController(initialText: 'one\ntwo\nthree');
      m.setSelection(const EditorPosition(0, 0), const EditorPosition(2, 0));
      m.duplicateLineOrSelection();
      expect(m.text, 'one\ntwo\none\ntwo\nthree', reason: '选中整行时就是复制那几行');
      expect(m.selection.start, const EditorPosition(2, 0));
      expect(m.selection.end, const EditorPosition(4, 0));
      c.dispose();
      m.dispose();
    });

    test('typing right after a duplicate is a separate undo step', () {
      final c = CodeEditorController(initialText: 'ab');
      c.setCursor(const EditorPosition(0, 2));
      c.insertText('c');
      c.duplicateLineOrSelection();
      c.insertText('d');
      c.undo();
      expect(c.text, 'abc\nabc');
      c.undo();
      expect(c.text, 'abc');
      c.dispose();
    });
  });

  group('editor', () {
    Future<CodeEditorController> show(WidgetTester tester, KeymapStore keymap) async {
      final c = CodeEditorController(initialText: 'first\nsecond');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorViewWidget(
            openTabs: const ['a.txt'],
            activeFile: 'a.txt',
            codeContent: '',
            controller: c,
            keymap: keymap,
            onSelectTab: (_) {},
            onCloseTab: (_) {},
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('first', findRichText: true));
      await tester.pump(const Duration(milliseconds: 400));
      c.setCursor(const EditorPosition(0, 2));
      return c;
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool meta = false, bool shift = false}) async {
      if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    testWidgets('⌘D in the editor duplicates the caret line', (tester) async {
      final keymap = KeymapStore(mac: true);
      final c = await show(tester, keymap);
      await press(tester, LogicalKeyboardKey.keyD, meta: true);
      expect(c.lines, ['first', 'first', 'second']);
      expect(c.cursorPosition, const EditorPosition(1, 2));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      keymap.dispose();
    });

    testWidgets('rebound in Keymap: the new shortcut works, ⌘D no longer does', (tester) async {
      final keymap = KeymapStore(mac: true);
      keymap.add(KeymapIds.duplicate, KeyStroke.parse('shift meta K')!);
      keymap.remove(KeymapIds.duplicate, KeyStroke.parse('meta D')!);
      final c = await show(tester, keymap);
      await press(tester, LogicalKeyboardKey.keyD, meta: true);
      expect(c.lines, ['first', 'second']);
      await press(tester, LogicalKeyboardKey.keyK, meta: true, shift: true);
      expect(c.lines, ['first', 'first', 'second']);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      keymap.dispose();
    });
  });
}
