import 'package:code_lite_ui/features/editor/blame.dart';
import 'package:code_lite_ui/features/git/merge_model.dart';
import 'package:code_lite_ui/features/git/merge_window.dart';
import 'package:flutter/gestures.dart';
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

  testWidgets('layout: titles, three columns, counter; buttons only where a side has a pending change', (tester) async {
    await open(tester);
    expect(find.text('合并 src/A.java 的修订'), findsOneWidget);
    expect(find.text('来自 ktest 的更改'), findsOneWidget);
    expect(find.text('来自 feat/x 的更改'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
    // import y(左)、v=2/v=3(冲突)、// end(右)
    expect(find.text('3 处改动。1 处冲突。'), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-left-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-right-0')), findsNothing, reason: '第一块只有左侧改了');
    expect(find.byKey(const ValueKey('apply-left-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-right-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-right-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-left-2')), findsNothing);
    final resultTexts = [for (final f in tester.widgetList<TextField>(find.descendant(of: find.byType(ListView), matching: find.byType(TextField)))) f.controller!.text];
    expect(resultTexts, contains('  int v = 1;'), reason: '还没处理:结果里是共同祖先的版本');
  });

  testWidgets('», « and × resolve chunks; a conflict can take both sides; Cmd+Z undoes; Apply returns the text', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('apply-left-0')));
    await tester.pump();
    expect(find.text('2 处改动。1 处冲突。'), findsOneWidget);
    expect(find.byKey(const ValueKey('apply-left-0')), findsNothing, reason: '处理过的块按钮消失');

    await tester.tap(find.byKey(const ValueKey('apply-right-1')));
    await tester.pump();
    expect(find.byTooltip('把左侧的改动追加到结果'), findsOneWidget, reason: '冲突:另一侧还可以追加');
    await tester.tap(find.byKey(const ValueKey('apply-left-1')));
    await tester.pump();
    expect(find.text('1 处改动。0 处冲突。'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('2 处改动。1 处冲突。'), findsOneWidget, reason: '撤销了追加左侧');
    await tester.tap(find.byKey(const ValueKey('ignore-left-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ignore-right-2')));
    await tester.pump();
    expect(find.text('所有改动都处理完了'), findsOneWidget);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(outcome!.kind, MergeOutcomeKind.apply);
    expect(outcome!.content, 'package a;\nimport x;\nimport y;\nclass A {\n  int v = 3;\n}\n');
  });

  Finder lineField(int line) => find.descendant(of: find.byKey(ValueKey('result-line-$line')), matching: find.byType(TextField));
  TextField fieldAt(WidgetTester tester, int line) => tester.widget<TextField>(lineField(line));

  Future<void> caretAt(WidgetTester tester, int line, int col) async {
    await tester.tap(lineField(line));
    await tester.pump();
    final text = fieldAt(tester, line).controller!.text;
    tester.testTextInput.updateEditingValue(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: col)));
    await tester.pump();
  }

  testWidgets('the result column is directly editable: typing in a conflict resolves it, Apply returns the typed text', (tester) async {
    await open(tester);
    // 结果:0 package a; 1 import x; 2 class A { 3 int v = 1; 4 }
    expect(fieldAt(tester, 3).controller!.text, '  int v = 1;');
    await tester.enterText(lineField(3), '  int v = 2 + 3;');
    await tester.pump();
    expect(find.text('2 处改动。0 处冲突。'), findsOneWidget, reason: '手改过的冲突算解决了');
    expect(find.byKey(const ValueKey('apply-left-1')), findsNothing);

    // 没变的行也能改
    await tester.enterText(lineField(0), 'package b;');
    await tester.pump();
    await tester.tap(find.byTooltip('采用两侧所有不冲突的改动'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(outcome!.content, 'package b;\nimport x;\nimport y;\nclass A {\n  int v = 2 + 3;\n}\n// end\n');
  });

  testWidgets('Enter splits a line, Backspace at the start joins it back, the caret follows; arrows move between lines', (tester) async {
    await open(tester);
    await caretAt(tester, 2, 7); // "class A| {"
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fieldAt(tester, 2).controller!.text, 'class A');
    expect(fieldAt(tester, 3).controller!.text, ' {');
    expect(fieldAt(tester, 3).focusNode!.hasFocus, isTrue, reason: '光标到了新的一行');
    expect(fieldAt(tester, 3).controller!.selection.baseOffset, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(fieldAt(tester, 2).controller!.text, 'class A {');
    expect(fieldAt(tester, 2).focusNode!.hasFocus, isTrue);
    expect(fieldAt(tester, 2).controller!.selection.baseOffset, 7, reason: '光标在接缝处');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(fieldAt(tester, 3).focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump(); // 光标在下一帧挪过去
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(fieldAt(tester, 1).focusNode!.hasFocus, isTrue);

    // ⌘Z 撤销的是整个合并的上一步,不是输入框自己的
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(fieldAt(tester, 2).controller!.text, 'class A');
    expect(fieldAt(tester, 3).controller!.text, ' {', reason: '撤销了合并行,回到拆开的状态');
  });

  testWidgets('pasting several lines splits them into result lines', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'one\ntwo'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester);
    await caretAt(tester, 1, 6); // "import| x;"
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(fieldAt(tester, 1).controller!.text, 'importone');
    expect(fieldAt(tester, 2).controller!.text, 'two x;');
    expect(fieldAt(tester, 2).focusNode!.hasFocus, isTrue);
    expect(fieldAt(tester, 2).controller!.selection.baseOffset, 3, reason: '光标在粘贴内容的末尾');
  });

  testWidgets('Apply with unresolved changes asks first; Back keeps merging', (tester) async {
    await open(tester);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还有 3 处改动没处理(其中 1 处冲突)'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '应用').last);
    await tester.pumpAndSettle();
    expect(outcome!.content, _base, reason: '没处理的地方保留共同祖先');
  });

  testWidgets('Accept Left / Right close with that choice; Cancel asks only when something was changed', (tester) async {
    await open(tester);
    await tester.tap(find.text('接受左侧'));
    await tester.pumpAndSettle();
    expect(outcome!.kind, MergeOutcomeKind.acceptLeft);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接受右侧'));
    await tester.pumpAndSettle();
    expect(outcome!.kind, MergeOutcomeKind.acceptRight);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    closed = false;
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(closed, isTrue, reason: '没改过:直接关');
    expect(outcome, isNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    closed = false;
    await tester.tap(find.byTooltip('采用两侧所有不冲突的改动'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('放弃这次合并里做的修改'), findsOneWidget);
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(outcome, isNull);
  });

  testWidgets('next / previous jump between pending changes in a long file', (tester) async {
    final base = [for (var i = 0; i < 300; i++) 'line $i'];
    final yours = [...base]..[20] = 'mine 20';
    final theirs = [...base]..[250] = 'theirs 250';
    await open(tester, base: '${base.join('\n')}\n', yours: '${yours.join('\n')}\n', theirs: '${theirs.join('\n')}\n');
    expect(find.text('2 处改动。0 处冲突。'), findsOneWidget);
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
    expect(find.text('3 处改动。1 处冲突。'), findsOneWidget);
  });

  testWidgets('right-click a side\'s line numbers ▸ Annotate: each line shows "date author"; Close Annotations hides it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    BlameCommit commit(String hash, String author, DateTime t) => BlameCommit.fromJson({
          'hash': hash * 40,
          'author': author,
          'email': '$author@x',
          'time': t.millisecondsSinceEpoch ~/ 1000,
          'summary': '$author edits',
        }, 'src/A.java');
    final base = commit('a', 'tester', DateTime(2026, 9, 1, 10));
    final bob = commit('b', 'bob', DateTime(2026, 10, 9, 10));
    final alice = commit('c', 'alice', DateTime(2026, 10, 13, 10));
    final loaded = <MergeSide>[];
    Future<BlameData?> load(MergeSide side) async {
      loaded.add(side);
      final mine = side == MergeSide.left;
      final lines = (mine ? _yours : _theirs).split('\n')..removeLast();
      final who = mine ? bob : alice;
      return BlameData(
        [for (final l in lines) l.contains('v =') || l.contains('import y') || l.contains('// end') ? who.hash : base.hash],
        {base.hash: base, who.hash: who},
      );
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMergeWindow(context,
                path: 'src/A.java', base: _base, yours: _yours, theirs: _theirs, yoursTitle: 'ktest', theirsTitle: 'feat/x', loadBlame: load),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    Future<void> menu(String key, String item) async {
      await tester.tapAt(tester.getCenter(find.byKey(ValueKey(key))), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const ValueKey('blame-left-0')), findsNothing);
    await menu('nums-left-0', '使用 Git Blame 注解');
    expect(loaded, [MergeSide.left]);
    expect(find.text('2026/9/1  tester'), findsWidgets, reason: '左栏没改的行:共同祖先的作者');
    expect(find.text('2026/10/9  bob'), findsWidgets, reason: '左栏改过的行:自己这边的作者');
    expect(find.text('2026/10/13  alice'), findsNothing, reason: '右栏还没打开注释');
    // 注释在左栏的文字和行号之间
    expect(tester.getTopRight(find.byKey(const ValueKey('blame-left-0'))).dx,
        lessThanOrEqualTo(tester.getTopLeft(find.byKey(const ValueKey('nums-left-0'))).dx + 200));
    // 悬停看提交
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byKey(const ValueKey('blame-left-3'))));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byTooltip('bob\nbbbbbbbb · 2026/10/9 · bob edits'), findsWidgets, reason: 'bob 改的两行都带这个提示(第一行是完整的作者名)');
    await mouse.removePointer();

    await menu('nums-right-0', '使用 Git Blame 注解');
    expect(find.text('2026/10/13  alice'), findsWidgets, reason: '右栏:合进来那边的作者');

    await menu('nums-left-0', '关闭注解');
    expect(find.text('2026/10/9  bob'), findsNothing);
    expect(find.text('2026/10/13  alice'), findsWidgets, reason: '只关了左栏');
  });
}
