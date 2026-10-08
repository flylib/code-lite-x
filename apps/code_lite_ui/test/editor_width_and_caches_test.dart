import 'dart:math';

import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

int bruteForceWidest(CodeEditorController c) =>
    c.lines.map(CodeEditorController.displayColumns).fold(0, (a, b) => a > b ? a : b);

void main() {
  group('display columns', () {
    test('tabs count 4, CJK / full-width / emoji 2, the rest 1', () {
      expect(CodeEditorController.displayColumns(''), 0);
      expect(CodeEditorController.displayColumns('abc'), 3);
      expect(CodeEditorController.displayColumns('\tx'), 5);
      expect(CodeEditorController.displayColumns('中文'), 4);
      expect(CodeEditorController.displayColumns('ａ'), 2, reason: '全角字母');
      expect(CodeEditorController.displayColumns('a😀b'), 4, reason: 'emoji 是代理对,只记一次 2 列');
    });
  });

  group('widest line, kept up to date edit by edit', () {
    test('typing, deleting and splitting lines move the widest line', () {
      final c = CodeEditorController(initialText: 'short\nmedium line\nx');
      expect(c.maxColumns, 11);
      c.setCursor(const EditorPosition(2, 1));
      for (final ch in 'yyyyyyyyyyyyyyy'.split('')) {
        c.insertText(ch);
      }
      expect(c.maxColumns, 16, reason: '第 3 行变成最宽');
      // 把最宽的那行删短:要退回到次宽的 11
      for (var i = 0; i < 10; i++) {
        c.deleteBackward();
      }
      expect(c.maxColumns, 11);
      // 在 medium line 中间回车:最宽变成拆开后较长的一半
      c.setCursor(const EditorPosition(1, 6));
      c.insertNewline();
      expect(c.maxColumns, bruteForceWidest(c));
      c.dispose();
    });

    test('loading new text rebuilds it; an empty document is 0 wide', () {
      final c = CodeEditorController(initialText: 'a\nbbbb');
      expect(c.maxColumns, 4);
      c.setText('only\nthis is the widest now');
      expect(c.maxColumns, 22);
      c.setText('');
      expect(c.maxColumns, 0);
      c.dispose();
    });

    test('thousands of random edits, undo and redo always agree with a full scan', () {
      final rnd = Random(7);
      const alphabet = ['a', 'b', ' ', '\t', '中', '😀', '\n', 'xyz', '\n\n', '长一点的中文'];
      final c = CodeEditorController(initialText: [for (var i = 0; i < 60; i++) 'line $i ${'x' * rnd.nextInt(40)}'].join('\n'));
      expect(c.maxColumns, bruteForceWidest(c));
      EditorPosition randomPos() {
        final line = rnd.nextInt(c.lines.length);
        return EditorPosition(line, rnd.nextInt(c.lines[line].length + 1));
      }

      for (var step = 0; step < 4000; step++) {
        switch (rnd.nextInt(10)) {
          case 0 || 1 || 2 || 3:
            c.setCursor(randomPos());
            c.insertText(alphabet[rnd.nextInt(alphabet.length)]);
          case 4 || 5:
            c.setCursor(randomPos());
            c.deleteBackward();
          case 6:
            final a = randomPos(), b = randomPos();
            c.replaceRange(a <= b ? a : b, a <= b ? b : a, alphabet[rnd.nextInt(alphabet.length)]);
          case 7:
            c.undo();
          case 8:
            c.redo();
          case 9:
            if (rnd.nextInt(40) == 0) c.setText([for (var i = 0; i < rnd.nextInt(30); i++) 'z' * rnd.nextInt(50)].join('\n'));
        }
        expect(c.maxColumns, bruteForceWidest(c), reason: 'step $step');
      }
      c.dispose();
    });

    test('a 20k-line file: each keystroke touches one line, not the whole file', () {
      final c = CodeEditorController(initialText: [for (var i = 0; i < 20000; i++) 'val v$i = "line $i" // comment'].join('\n'));
      expect(c.maxColumns, bruteForceWidest(c));
      c.setCursor(const EditorPosition(10000, 0));
      final watch = Stopwatch()..start();
      for (var i = 0; i < 2000; i++) {
        c.insertText('x');
        c.maxColumns;
      }
      watch.stop();
      expect(c.maxColumns, bruteForceWidest(c));
      // 以前每次按键扫全文 ~60 万字符;现在只算改动的那一行。宽松上限,只防退回全量扫描
      expect(watch.elapsedMilliseconds, lessThan(2000), reason: '2000 次按键用了 ${watch.elapsedMilliseconds} ms');
      c.dispose();
    });
  });

  test('a disposed document says so', () {
    final c = CodeEditorController(initialText: 'x');
    expect(c.isDisposed, isFalse);
    c.dispose();
    expect(c.isDisposed, isTrue);
  });

  testWidgets('the editor lets go of a closed document', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final first = CodeEditorController(initialText: [for (var i = 0; i < 2000; i++) 'fun f$i() = $i'].join('\n'));
    final second = CodeEditorController(initialText: 'val x = 1');

    Widget editorFor(CodeEditorController c, String path) => MaterialApp(
          home: Scaffold(
            body: EditorViewWidget(
              openTabs: [path],
              activeFile: path,
              codeContent: '',
              controller: c,
              onSelectTab: (_) {},
              onCloseTab: (_) {},
            ),
          ),
        );

    await tester.pumpWidget(editorFor(first, 'A.kt'));
    await tester.pump();
    final state = tester.state(find.byType(EditorViewWidget)) as dynamic;
    expect((state.debugCachedDocuments as Set).contains(first), isTrue);

    // 换到另一个标签,并关掉第一个(会话层这时会释放它的 controller)
    await tester.pumpWidget(editorFor(second, 'B.kt'));
    first.dispose();
    await tester.pump();
    second.insertText('!'); // 触发一次重建
    await tester.pump();

    final cached = state.debugCachedDocuments as Set;
    expect(cached.contains(first), isFalse, reason: '关掉的文档不能再挂在高亮缓存里');
    expect(cached.contains(second), isTrue);

    await tester.pumpWidget(const SizedBox());
    second.dispose();
  });
}
