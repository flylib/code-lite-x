import 'dart:math';

import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/folding.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FoldState', () {
    test('rows skip hidden lines; nested folds count once', () {
      final f = FoldState()..lineCount = 20;
      expect(f.rowCount, 20);
      expect(f.lineOfRow(7), 7);
      f.collapse(const FoldRange(2, 5)); // 藏 3..5
      f.collapse(const FoldRange(3, 4)); // 嵌在里面
      f.collapse(const FoldRange(10, 12)); // 藏 11..12
      expect(f.rowCount, 15);
      expect([for (var r = 0; r < f.rowCount; r++) f.lineOfRow(r)], [0, 1, 2, 6, 7, 8, 9, 10, 13, 14, 15, 16, 17, 18, 19]);
      expect(f.rowOfLine(4), f.rowOfLine(2), reason: 'a hidden line sits on its fold start');
      expect(f.isHidden(5), isTrue);
      expect(f.isHidden(6), isFalse);
      expect(f.reveal(4), isTrue);
      expect(f.isCollapsed(2), isFalse, reason: 'every fold hiding the line opens');
      expect(f.isCollapsed(3), isFalse);
      expect(f.isCollapsed(10), isTrue);
    });

    test('random folds: rowOfLine and lineOfRow agree with a brute-force map', () {
      final rnd = Random(5);
      for (var t = 0; t < 200; t++) {
        final n = 1 + rnd.nextInt(60);
        final f = FoldState()..lineCount = n;
        for (var k = 0; k < rnd.nextInt(6); k++) {
          final s = rnd.nextInt(n);
          f.collapse(FoldRange(s, s + 1 + rnd.nextInt(8)));
        }
        final hidden = List.filled(n, false);
        for (final r in f.collapsed) {
          for (var i = r.start + 1; i <= r.end && i < n; i++) {
            hidden[i] = true;
          }
        }
        final visible = [for (var i = 0; i < n; i++) if (!hidden[i]) i];
        expect(f.rowCount, visible.length);
        for (var r = 0; r < visible.length; r++) {
          expect(f.lineOfRow(r), visible[r]);
          expect(f.rowOfLine(visible[r]), r);
        }
        for (var i = 0; i < n; i++) {
          expect(f.isHidden(i), hidden[i]);
        }
      }
    });

    test('edits: folds below shift, typing on the header keeps the fold, touching the body opens it', () {
      final f = FoldState()..lineCount = 30;
      f.collapse(const FoldRange(5, 9));
      f.collapse(const FoldRange(20, 25));
      f.applyEdit(2, 2, 3); // 第 2 行变成 3 行
      expect(f.collapsed, [const FoldRange(5 + 2, 9 + 2), const FoldRange(22, 27)]);
      f.applyEdit(7, 7, 1); // 在起始行里打字
      expect(f.isCollapsed(7), isTrue);
      f.applyEdit(8, 8, 1); // 改到藏起来的行
      expect(f.isCollapsed(7), isFalse);
      expect(f.isCollapsed(22), isTrue);
      expect(f.lineCount, 32);
    });

    test('reconcile: the end follows the tree; folds that no longer exist open', () {
      final f = FoldState()..lineCount = 30;
      f.collapse(const FoldRange(1, 5));
      f.collapse(const FoldRange(10, 12));
      f.collapse(const FoldRange(25, 28));
      expect(f.reconcile(const [FoldRange(1, 6)], 0, 20), isTrue);
      expect(f.collapsed, [const FoldRange(1, 6), const FoldRange(25, 28)], reason: 'outside the checked range stays');
    });
  });

  group('controller', () {
    CodeEditorController make() => CodeEditorController(initialText: List.generate(20, (i) => 'line $i').join('\n'));

    test('up / down jump over a collapsed fold; collapsing moves the caret out', () {
      final c = make();
      c.setCursor(const EditorPosition(4, 2));
      c.collapseFold(const FoldRange(2, 6));
      expect(c.cursorPosition, const EditorPosition(2, 6), reason: 'caret was inside');
      c.moveCursor(direction: NavigationDirection.down);
      expect(c.cursorPosition.line, 7);
      c.moveCursor(direction: NavigationDirection.up);
      expect(c.cursorPosition.line, 2);
      expect(c.folds.isCollapsed(2), isTrue);
      c.dispose();
    });

    test('putting the caret into a fold opens it; edits above shift it', () {
      final c = make();
      c.collapseFold(const FoldRange(10, 14));
      c.setCursor(const EditorPosition(0, 0));
      c.insertNewline();
      expect(c.folds.isCollapsed(11), isTrue);
      c.setCursor(const EditorPosition(13, 0));
      expect(c.folds.hasCollapsed, isFalse);
      c.dispose();
    });

    test('collapse at caret takes the innermost open region; collapse all / expand all', () {
      final c = make();
      c.foldRegionsProvider = (from, to) => [
            for (final r in const [FoldRange(1, 15), FoldRange(3, 8), FoldRange(10, 12)])
              if (r.start >= from && r.start < to) r,
          ];
      c.setCursor(const EditorPosition(5, 0));
      c.collapseRegionAtCaret();
      expect(c.folds.collapsed, [const FoldRange(3, 8)]);
      c.collapseRegionAtCaret(); // 光标已到 3 行行尾,再按一次收起外层
      expect(c.folds.isCollapsed(1), isTrue);
      c.expandAllFolds();
      expect(c.folds.hasCollapsed, isFalse);
      c.collapseAllRegions();
      expect(c.folds.collapsed.length, 3);
      expect(c.folds.rowCount, 20 - 14);
      c.dispose();
    });
  });

  testWidgets('editor: hover the gutter, click the arrow to fold, click "..." to unfold', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final src = ['class A {', '  void f() {', '    g();', '    h();', '  }', '  int x;', '}'];
    final ctrl = CodeEditorController(initialText: src.join('\n'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['A.java'],
          activeFile: 'A.java',
          codeContent: '',
          controller: ctrl,
          appearance: EditorAppearance(),
          onSelectTab: (_) {},
          onCloseTab: (_) {},
        ),
      ),
    ));
    // 语法树在 Rust 的后台线程里解析:给它真实时间,再让轮询的定时器跑一下
    for (var i = 0; i < 20 && ctrl.foldRegionsProvider?.call(0, 7).isEmpty != false; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ctrl.foldRegionsProvider!(0, 7), [const FoldRange(0, 6), const FoldRange(1, 4)]);

    Finder line(String text) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text);
    expect(find.byKey(const ValueKey('fold-expanded')), findsNothing, reason: 'arrows only on hover');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('2')));
    await tester.pump();
    expect(find.byKey(const ValueKey('fold-expanded')), findsNWidgets(2));

    // 第 2 行(void f)的箭头
    final arrow = find.byKey(const ValueKey('fold-expanded')).at(1);
    await tester.tap(arrow);
    await tester.pump();
    expect(ctrl.folds.collapsed, [const FoldRange(1, 4)]);
    expect(line('    g();'), findsNothing);
    expect(line('  int x;'), findsOneWidget);
    expect(find.byKey(const ValueKey('fold-placeholder')), findsOneWidget);
    expect(find.text('}'), findsWidgets, reason: 'closing brace after the placeholder');
    // 收起后行号 6(int x)紧接在行号 2 下面
    expect(tester.getTopLeft(find.text('6')).dy - tester.getTopLeft(find.text('2')).dy, EditorAppearance().lineHeight);

    await tester.tap(find.byKey(const ValueKey('fold-placeholder')));
    await tester.pump(kDoubleTapTimeout);
    expect(ctrl.folds.hasCollapsed, isFalse);
    expect(line('    g();'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
