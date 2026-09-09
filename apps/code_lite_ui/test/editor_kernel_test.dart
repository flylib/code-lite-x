import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/ime_text_input_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CodeEditorController Core Tests', () {
    test('Initializes with default and custom text', () {
      final ctrl = CodeEditorController(initialText: 'hello\nworld');
      expect(ctrl.text, equals('hello\nworld'));
      expect(ctrl.lineCount, equals(2));
      expect(ctrl.cursorPosition, equals(const EditorPosition(0, 0)));
      expect(ctrl.isDirty, isFalse);
      expect(ctrl.hasSelection, isFalse);
      ctrl.dispose();
    });

    test('insertText inserts at cursor and marks dirty', () {
      final ctrl = CodeEditorController(initialText: 'hello');
      ctrl.setCursor(const EditorPosition(0, 5));
      ctrl.insertText(' world');

      expect(ctrl.text, equals('hello world'));
      expect(ctrl.cursorPosition, equals(const EditorPosition(0, 11)));
      expect(ctrl.isDirty, isTrue);

      ctrl.markSaved();
      expect(ctrl.isDirty, isFalse);
      ctrl.dispose();
    });

    test('insertText replaces active selection', () {
      final ctrl = CodeEditorController(initialText: 'let foo = 42;');
      ctrl.setSelection(const EditorPosition(0, 4), const EditorPosition(0, 7)); // select 'foo'
      expect(ctrl.getSelectedText(), equals('foo'));

      ctrl.insertText('bar');
      expect(ctrl.text, equals('let bar = 42;'));
      expect(ctrl.cursorPosition, equals(const EditorPosition(0, 7)));
      expect(ctrl.hasSelection, isFalse);
      ctrl.dispose();
    });

    test('deleteBackward deletes character and merges lines', () {
      final ctrl = CodeEditorController(initialText: 'abc\ndef');
      ctrl.setCursor(const EditorPosition(0, 2)); // at 'c'
      ctrl.deleteBackward();
      expect(ctrl.text, equals('ac\ndef'));

      // Merge line 1 with line 0
      ctrl.setCursor(const EditorPosition(1, 0));
      ctrl.deleteBackward();
      expect(ctrl.text, equals('acdef'));
      expect(ctrl.cursorPosition, equals(const EditorPosition(0, 2)));
      ctrl.dispose();
    });

    test('deleteForward deletes character and merges lines', () {
      final ctrl = CodeEditorController(initialText: 'abc\ndef');
      ctrl.setCursor(const EditorPosition(0, 3)); // at end of line 0
      ctrl.deleteForward();
      expect(ctrl.text, equals('abcdef'));
      expect(ctrl.cursorPosition, equals(const EditorPosition(0, 3)));
      ctrl.dispose();
    });

    test('insertNewline applies auto-indentation and block indent', () {
      final ctrl = CodeEditorController(initialText: '    fn main() {');
      ctrl.setCursor(const EditorPosition(0, 15));
      ctrl.insertNewline();

      expect(ctrl.lineCount, equals(2));
      expect(ctrl.lines[1], equals('        ')); // 4 spaces from previous + 4 for '{'
      expect(ctrl.cursorPosition, equals(const EditorPosition(1, 8)));
      ctrl.dispose();
    });

    test('insertTab and unindent for single line and multi-line selection', () {
      final ctrl = CodeEditorController(initialText: 'line 1\nline 2');

      // Single line tab
      ctrl.setCursor(const EditorPosition(0, 0));
      ctrl.insertTab();
      expect(ctrl.lines[0], equals('    line 1'));

      // Multi-line indent
      ctrl.setSelection(const EditorPosition(0, 0), const EditorPosition(1, 4));
      ctrl.insertTab();
      expect(ctrl.lines[0], equals('        line 1'));
      expect(ctrl.lines[1], equals('    line 2'));

      // Unindent
      ctrl.unindent();
      expect(ctrl.lines[0], equals('    line 1'));
      expect(ctrl.lines[1], equals('line 2'));
      ctrl.dispose();
    });

    test('moveCursor arrow navigation, preferred col, and word jumps', () {
      final ctrl = CodeEditorController(initialText: 'first line of text\nshort\nthird long line');

      // Move right and down
      ctrl.setCursor(const EditorPosition(0, 10));
      ctrl.moveCursor(direction: NavigationDirection.down);
      // 'short' has length 5, so clamped to 5
      expect(ctrl.cursorPosition, equals(const EditorPosition(1, 5)));

      // Moving down again should restore preferredCol 10
      ctrl.moveCursor(direction: NavigationDirection.down);
      expect(ctrl.cursorPosition, equals(const EditorPosition(2, 10)));

      // Word jump right
      ctrl.setCursor(const EditorPosition(0, 0));
      ctrl.moveCursor(direction: NavigationDirection.right, wordJump: true);
      expect(ctrl.cursorPosition.col, equals(5)); // 'first'

      // Line jump right (End)
      ctrl.moveCursor(direction: NavigationDirection.right, lineJump: true);
      expect(ctrl.cursorPosition, equals(const EditorPosition(0, 18)));

      // Document jump (Doc end)
      ctrl.moveCursor(direction: NavigationDirection.down, documentJump: true);
      expect(ctrl.cursorPosition, equals(const EditorPosition(2, 15)));
      ctrl.dispose();
    });

    test('selectWord and selectAll', () {
      final ctrl = CodeEditorController(initialText: 'let my_variable = 100;');
      ctrl.selectWord(const EditorPosition(0, 8)); // inside 'my_variable'
      expect(ctrl.getSelectedText(), equals('my_variable'));

      ctrl.selectAll();
      expect(ctrl.getSelectedText(), equals('let my_variable = 100;'));
      ctrl.dispose();
    });
  });

  group('ImeTextInputBridge & IME Composite Input Tests', () {
    test('Synchronizes value and handles composition range', () {
      final ctrl = CodeEditorController(initialText: 'test');
      final focusNode = FocusNode();
      final bridge = ImeTextInputBridge(controller: ctrl, focusNode: focusNode);

      expect(bridge.isAttached, isFalse);
      focusNode.requestFocus();
      bridge.attach();
      expect(bridge.isAttached, isTrue);

      // Simulate IME composition (e.g. typing pinyin 'ni')
      bridge.updateEditingValue(const TextEditingValue(
        text: 'testni',
        composing: TextRange(start: 4, end: 6),
        selection: TextSelection.collapsed(offset: 6),
      ));
      expect(ctrl.composingRange, equals(const TextRange(start: 4, end: 6)));

      // Simulate IME commit (e.g. selecting '你')
      bridge.updateEditingValue(const TextEditingValue(
        text: 'test你',
        composing: TextRange.empty,
        selection: TextSelection.collapsed(offset: 5),
      ));
      expect(ctrl.text, contains('你'));
      expect(ctrl.composingRange, equals(TextRange.empty));

      bridge.detach();
      focusNode.dispose();
      ctrl.dispose();
    });
  });

  group('EditorSessionManager Multi-Tab Independence Tests', () {
    test('Maintains separate buffer, cursor, and scroll state per tab', () async {
      final client = ApiClient();
      final session = EditorSessionManager(client: client);

      // Open tab 1
      final tab1 = await session.openFile('file1.rs', defaultContent: 'fn foo() {}');
      expect(tab1.controller.text, equals('fn foo() {}'));
      tab1.controller.setCursor(const EditorPosition(0, 6));

      // Open tab 2
      final tab2 = await session.openFile('file2.rs', defaultContent: 'let a = 1;\nlet b = 2;');
      expect(tab2.controller.text, equals('let a = 1;\nlet b = 2;'));
      tab2.controller.setCursor(const EditorPosition(1, 4));

      // Verify independence
      expect(tab1.controller.cursorPosition, equals(const EditorPosition(0, 6)));
      expect(tab2.controller.cursorPosition, equals(const EditorPosition(1, 4)));

      // Edit tab 1
      tab1.controller.insertText('// comment\n');
      expect(tab1.isDirty, isTrue);
      expect(tab2.isDirty, isFalse);

      // Switch back to tab 1
      session.selectTab('file1.rs');
      expect(session.activePath, equals('file1.rs'));
      expect(session.activeTab?.controller.cursorPosition, equals(const EditorPosition(1, 0)));

      // Close tab 1
      session.closeTab('file1.rs');
      expect(session.openPaths, equals(['file2.rs']));
      expect(session.activePath, equals('file2.rs'));

      session.dispose();
    });
  });

  group('EditorViewWidget Interactive UI Tests', () {
    testWidgets('EditorViewWidget renders, accepts focus and key inputs', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ctrl = CodeEditorController(initialText: 'pub fn test() {\n    return;\n}');
      String changedText = '';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditorViewWidget(
              openTabs: const ['src/test.rs'],
              activeFile: 'src/test.rs',
              codeContent: ctrl.text,
              controller: ctrl,
              onSelectTab: (_) {},
              onCloseTab: (_) {},
              onCodeChanged: (val) => changedText = val,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify gutter numbers
      expect(find.text('1'), findsWidgets);
      expect(find.text('2'), findsWidgets);
      expect(find.text('3'), findsWidgets);

      // Tap on canvas to focus
      await tester.tap(find.byType(EditorViewWidget));
      await tester.pump();

      // Type character '!'
      ctrl.setCursor(const EditorPosition(0, 15));
      ctrl.insertText(' // ok');
      await tester.pump();

      expect(ctrl.text, contains('// ok'));
      expect(changedText, contains('// ok'));

      ctrl.dispose();
    });
  });
}
