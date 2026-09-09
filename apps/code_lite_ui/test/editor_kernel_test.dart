import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    testWidgets('EditorViewWidget renders ghost text and handles Tab / Cmd+Right / Esc', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ctrl = CodeEditorController(initialText: 'let x =');
      ctrl.setCursor(const EditorPosition(0, 7));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditorViewWidget(
              openTabs: const ['src/main.rs'],
              activeFile: 'src/main.rs',
              codeContent: ctrl.text,
              controller: ctrl,
              onSelectTab: (_) {},
              onCloseTab: (_) {},
              onCodeChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Set ghost text
      ctrl.setGhostText(' 42;', position: const EditorPosition(0, 7));
      await tester.pump();

      // Verify ghost text rendered in widget tree
      expect(find.text(' 42;'), findsOneWidget);
      expect(find.text('FIM Suggestion'), findsOneWidget);

      // Press Tab to accept
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(ctrl.text, equals('let x = 42;'));
      expect(ctrl.hasGhostText, isFalse);
      expect(find.text('FIM Suggestion'), findsNothing);

      // Now test accept word
      ctrl.setGhostText(' // hello world', position: const EditorPosition(0, 11));
      await tester.pump();
      expect(find.text(' // hello world'), findsOneWidget);

      // Press Cmd+Right or Ctrl+Right
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pump();

      // First token ' ' accepted
      expect(ctrl.text, equals('let x = 42; '));
      expect(ctrl.hasGhostText, isTrue);
      expect(ctrl.ghostText, equals('// hello world'));

      // Press Esc to dismiss
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(ctrl.hasGhostText, isFalse);
      expect(ctrl.text, equals('let x = 42; '));

      ctrl.dispose();
    });
  });

  group('CodeEditorController Ghost Text & FIM Unit Tests', () {
    test('setGhostText and clearGhostText lifecycle', () {
      final ctrl = CodeEditorController(initialText: 'fn test()');
      ctrl.setCursor(const EditorPosition(0, 9));

      expect(ctrl.hasGhostText, isFalse);
      ctrl.setGhostText(' -> bool { true }', position: const EditorPosition(0, 9));
      expect(ctrl.hasGhostText, isTrue);
      expect(ctrl.ghostText, equals(' -> bool { true }'));
      expect(ctrl.ghostPosition, equals(const EditorPosition(0, 9)));

      ctrl.clearGhostText();
      expect(ctrl.hasGhostText, isFalse);
      expect(ctrl.ghostText, isNull);
      expect(ctrl.ghostPosition, isNull);
      ctrl.dispose();
    });

    test('acceptGhostText inserts suggestion and moves cursor', () {
      final ctrl = CodeEditorController(initialText: 'let value =');
      ctrl.setCursor(const EditorPosition(0, 11));
      ctrl.setGhostText(' 100;', position: const EditorPosition(0, 11));

      final accepted = ctrl.acceptGhostText();
      expect(accepted, isTrue);
      expect(ctrl.text, equals('let value = 100;'));
      expect(ctrl.cursorPosition, equals(const EditorPosition(0, 16)));
      expect(ctrl.hasGhostText, isFalse);
      ctrl.dispose();
    });

    test('acceptGhostTextWord accepts word by word token', () {
      final ctrl = CodeEditorController(initialText: 'let msg =');
      ctrl.setCursor(const EditorPosition(0, 9));
      ctrl.setGhostText(' "hello" + " world";', position: const EditorPosition(0, 9));

      // 1. Accept whitespace
      ctrl.acceptGhostTextWord();
      expect(ctrl.text, equals('let msg = '));
      expect(ctrl.ghostText, equals('"hello" + " world";'));

      // 2. Accept '"'
      ctrl.acceptGhostTextWord();
      expect(ctrl.text, equals('let msg = "'));
      expect(ctrl.ghostText, equals('hello" + " world";'));

      // 3. Accept 'hello'
      ctrl.acceptGhostTextWord();
      expect(ctrl.text, equals('let msg = "hello'));
      expect(ctrl.ghostText, equals('" + " world";'));

      ctrl.dispose();
    });

    test('getPrefixForFim and getSuffixForFim extract contextual windows', () {
      const text = 'Line 1\nLine 2\nLine 3\nLine 4';
      final ctrl = CodeEditorController(initialText: text);
      ctrl.setCursor(const EditorPosition(1, 4)); // In "Line 2" after "Line"

      final prefix = ctrl.getPrefixForFim(100);
      expect(prefix, equals('Line 1\nLine'));

      final suffix = ctrl.getSuffixForFim(100);
      expect(suffix, equals(' 2\nLine 3\nLine 4'));

      // Test maxChars truncation
      final shortPrefix = ctrl.getPrefixForFim(4);
      expect(shortPrefix, equals('Line'));

      ctrl.dispose();
    });
  });
}
