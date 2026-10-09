import 'package:code_lite_ui/features/git/merge_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三方合并窗口的交互(拆块与结果的正确性由 merge_model_test 覆盖)。
const _base = 'package a;\nimport x;\nclass A {\n  int v = 1;\n}\n';
const _yours = 'package a;\nimport x;\nimport y;\nclass A {\n  int v = 2;\n}\n';
const _theirs = 'package a;\nimport x;\nclass A {\n  int v = 3;\n}\n// end\n';

void main() {
  late MergeOutcome? outcome;
  late bool closed;

  Future<void> open(WidgetTester tester, {String base = _base, String yours = _yours, String theirs = _theirs}) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    outcome = null;
    closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              outcome = await showMergeWindow(context, path: 'src/A.java', base: base, yours: yours, theirs: theirs, yoursTitle: 'ktest', theirsTitle: 'feat/x');
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder resultCell(String text) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text);

  testWidgets('layout: titles, three columns, counter; buttons only where a side has a pending change', (tester) async {
    await open(tester);
    expect(find.text('Merge Revisions for src/A.java'), findsOneWidget);
    expect(find.text('Changes from ktest'), findsOneWidget);
    expect(find.text('Changes from feat/x'), findsOneWidget);
    expect(find.text('Result'), findsOneWidget);
    // import y(左)、v=2/v=3(冲突)、// end(右)
    expect(find.text('3 changes. 1 conflict.'), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-left-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-right-0')), findsNothing, reason: '第一块只有左侧改了');
    expect(find.byKey(const ValueKey('apply-left-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-right-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-right-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-left-2')), findsNothing);
    expect(resultCell('  int v = 1;'), findsWidgets, reason: '还没处理:结果里是共同祖先的版本');
  });

  testWidgets('», « and × resolve chunks; a conflict can take both sides; Cmd+Z undoes; Apply returns the text', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('apply-left-0')));
    await tester.pump();
    expect(find.text('2 changes. 1 conflict.'), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-left-0')), findsNothing, reason: '处理过的块按钮消失');

    await tester.tap(find.byKey(const ValueKey('apply-right-1')));
    await tester.pump();
    expect(find.byTooltip('把左侧的改动追加到结果'), findsOneWidget, reason: '冲突:另一侧还可以追加');
    await tester.tap(find.byKey(const ValueKey('apply-left-1')));
    await tester.pump();
    expect(find.text('1 change. 0 conflicts.'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('2 changes. 1 conflict.'), findsOneWidget, reason: '撤销了追加左侧');
    await tester.tap(find.byKey(const ValueKey('ignore-left-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ignore-right-2')));
    await tester.pump();
    expect(find.text('所有改动都处理完了'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(outcome!.kind, MergeOutcomeKind.apply);
    expect(outcome!.content, 'package a;\nimport x;\nimport y;\nclass A {\n  int v = 3;\n}\n');
  });

  testWidgets('double-click a result chunk to edit it by hand', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('apply-left-1')));
    await tester.pump();
    final cell = resultCell('  int v = 2;').last; // 左栏也有这一行,结果栏在它后面
    await tester.tap(cell);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.text('编辑这一块的合并结果'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  int v = 2 + 3;');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(resultCell('  int v = 2 + 3;'), findsOneWidget);
    expect(find.text('2 changes. 0 conflicts.'), findsOneWidget, reason: '手改过的冲突算解决了');
  });

  testWidgets('Apply with unresolved changes asks first; Back keeps merging', (tester) async {
    await open(tester);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还有 3 处改动没处理(其中 1 处冲突)'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply').last);
    await tester.pumpAndSettle();
    expect(outcome!.content, _base, reason: '没处理的地方保留共同祖先');
  });

  testWidgets('Accept Left / Right close with that choice; Cancel asks only when something was changed', (tester) async {
    await open(tester);
    await tester.tap(find.text('Accept Left'));
    await tester.pumpAndSettle();
    expect(outcome!.kind, MergeOutcomeKind.acceptLeft);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept Right'));
    await tester.pumpAndSettle();
    expect(outcome!.kind, MergeOutcomeKind.acceptRight);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    closed = false;
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue, reason: '没改过:直接关');
    expect(outcome, isNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    closed = false;
    await tester.tap(find.byTooltip('采用两侧所有不冲突的改动'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('放弃这次合并里做的修改'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(outcome, isNull);
  });

  testWidgets('next / previous jump between pending changes in a long file', (tester) async {
    final base = [for (var i = 0; i < 300; i++) 'line $i'];
    final yours = [...base]..[20] = 'mine 20';
    final theirs = [...base]..[250] = 'theirs 250';
    await open(tester, base: '${base.join('\n')}\n', yours: '${yours.join('\n')}\n', theirs: '${theirs.join('\n')}\n');
    expect(find.text('2 changes. 0 conflicts.'), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-left-0')), findsOneWidget, reason: '打开时停在第一处');
    expect(find.byKey(const ValueKey('apply-right-1')), findsNothing, reason: '第二处在 250 行,还在屏幕外');
    await tester.tap(find.byTooltip('下一处改动'));
    await tester.pump();
    expect(find.byKey(const ValueKey('apply-right-1')), findsOneWidget, reason: '跳到了文件后面的第二处');
    expect(find.byKey(const ValueKey('apply-left-0')), findsNothing);
    await tester.tap(find.byTooltip('下一处改动'));
    await tester.pump();
    expect(find.byKey(const ValueKey('apply-left-0')), findsOneWidget, reason: '到最后一处后绕回第一处');
    await tester.tap(find.byTooltip('上一处改动'));
    await tester.pump();
    expect(find.byKey(const ValueKey('apply-right-1')), findsOneWidget, reason: '往前也绕');
  });

  testWidgets('a small window lays out without overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showMergeWindow(context, path: 'a/very/long/path/to/some/deeply/nested/package/MigrationHoconBuilder.java', base: _base, yours: _yours, theirs: _theirs, yoursTitle: 'ktest', theirsTitle: 'feat/retention-archive-before-delete'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('3 changes. 1 conflict.'), findsOneWidget);
  });
}
