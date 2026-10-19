import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/find_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 编辑 ▸ 在当前文件中查找(IntelliJ 的 Find,⌘F)。
void main() {
  group('findMatches', () {
    final lines = ['Mysql 8.0', 'my mysql', 'nothing', 'MY_SQL myself'];

    test('case-insensitive by default; Cc matches case', () {
      expect(findMatches(lines, 'my').length, 5);
      expect(findMatches(lines, 'my', matchCase: true), [const FindMatch(1, 0, 2), const FindMatch(1, 3, 5), const FindMatch(3, 7, 9)]);
    });

    test('W keeps whole words only', () {
      expect(findMatches(lines, 'my', words: true), [const FindMatch(1, 0, 2)]);
      expect(findMatches(['a_b ab a-b'], 'a', words: true), [const FindMatch(0, 7, 8)], reason: '下划线算词的一部分,- 不算');
    });

    test('regex; a broken one throws; empty matches are skipped', () {
      expect(findMatches(lines, r'\d\.\d', regex: true), [const FindMatch(0, 6, 9)]);
      expect(() => findMatches(lines, '(', regex: true), throwsFormatException);
      expect(findMatches(['abc'], 'x*', regex: true), isEmpty);
      expect(findMatches(lines, '(', regex: false), isEmpty, reason: '不开正则时按字面找');
    });

    test('non-ASCII text, columns in UTF-16', () {
      expect(findMatches(['中文😀中文'], '中文'), [const FindMatch(0, 0, 2), const FindMatch(0, 4, 6)]);
    });
  });

  group('editor', () {
    const text = 'intro\n1. Unity3d\n7. Mysql 8.0.15\nend\nuse mysql here';

    Future<CodeEditorController> show(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = CodeEditorController(initialText: text);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorViewWidget(
            openTabs: const ['notes.txt'],
            activeFile: 'notes.txt',
            codeContent: '',
            controller: c,
            keymap: KeymapStore(mac: true),
            onSelectTab: (_) {},
            onCloseTab: (_) {},
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('intro', findRichText: true));
      await tester.pump(const Duration(milliseconds: 400));
      c.setCursor(const EditorPosition(0, 0));
      return c;
    }

    Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {bool meta = false, bool shift = false}) async {
      if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(k);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    String count(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('find-count'))).data!;
    int highlights(WidgetTester tester) => find
        .byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == const Color(0xFF32593D))
        .evaluate()
        .length;

    testWidgets('⌘F opens the bar; typing selects the first match; Enter / ⇧Enter / ⌘G move and wrap', (tester) async {
      final c = await show(tester);
      expect(find.byKey(const ValueKey('find-bar')), findsNothing);
      await key(tester, LogicalKeyboardKey.keyF, meta: true);
      await tester.pump();
      expect(find.byKey(const ValueKey('find-bar')), findsOneWidget);
      final f = find.byKey(const ValueKey('find-field'));
      expect(tester.widget<TextField>(f).focusNode!.hasFocus, isTrue, reason: '输入框拿到焦点');

      await tester.enterText(f, 'my');
      await tester.pump();
      expect(count(tester), '1/2');
      expect(c.selection.start, const EditorPosition(2, 3));
      expect(c.selection.end, const EditorPosition(2, 5));
      expect(highlights(tester), 2, reason: '两处都有底色');
      final boxes = tester.widgetList<Container>(find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == const Color(0xFF32593D)));
      expect(boxes.where((b) => (b.decoration as BoxDecoration).border != null).length, 1, reason: '只有当前那个带框');

      await key(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '2/2');
      expect(c.selection.start, const EditorPosition(4, 4));
      await key(tester, LogicalKeyboardKey.enter);
      expect(count(tester), '1/2', reason: '到底绕回开头');
      await key(tester, LogicalKeyboardKey.enter, shift: true);
      expect(count(tester), '2/2', reason: '⇧回车往上,也绕回');
      await key(tester, LogicalKeyboardKey.keyG, meta: true);
      expect(count(tester), '1/2', reason: '输入框里 ⌘G 也能用');

      // Cc:区分大小写后只剩小写的那个
      await tester.tap(find.byKey(const ValueKey('find-toggle-Cc')));
      await tester.pump();
      expect(count(tester), '1/1');
      expect(c.selection.start, const EditorPosition(4, 4));

      await tester.enterText(f, 'nope');
      await tester.pump();
      expect(count(tester), '0 results');

      // Esc:关掉查找条,焦点回到编辑器,高亮消失
      await tester.enterText(f, 'mysql');
      await tester.pump();
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byKey(const ValueKey('find-bar')), findsNothing);
      expect(highlights(tester), 0);
      expect(c.getSelectedText(), 'mysql', reason: '选区留在当前匹配上');
      // 关了以后 ⌘G 还能接着找(这次查询区分大小写,只有一个)
      await key(tester, LogicalKeyboardKey.keyG, meta: true);
      expect(c.selection.start, const EditorPosition(4, 4));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('⌘F with a selection searches for it', (tester) async {
      final c = await show(tester);
      c.setSelection(const EditorPosition(1, 3), const EditorPosition(1, 8));
      await key(tester, LogicalKeyboardKey.keyF, meta: true);
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('find-field'))).controller!.text, 'Unity');
      expect(count(tester), '1/1');
      expect(c.getSelectedText(), 'Unity', reason: '打开时不挪选区');
      await tester.tap(find.byKey(const ValueKey('find-close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('find-bar')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });
}
