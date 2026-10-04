import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/git/git_service.dart';
import 'package:code_lite_ui/features/editor/blame.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bookmarks follow the code', () {
    late CodeEditorController c;
    setUp(() => c = CodeEditorController(initialText: 'a\nb\nc\nd'));
    tearDown(() => c.dispose());

    test('toggle, mnemonic uniqueness, lookup', () {
      c.toggleBookmark(1);
      expect(c.hasBookmark(1), isTrue);
      c.toggleBookmark(1);
      expect(c.hasBookmark(1), isFalse);

      c.setMnemonicBookmark(1, '3');
      c.setMnemonicBookmark(2, '3'); // 同一个助记符挪到新位置
      expect(c.bookmarks, {2: '3'});
      expect(c.lineOfMnemonic('3'), 2);
    });

    test('inserting and deleting lines above shifts bookmarks; undo/redo shift back', () {
      c.toggleBookmark(2); // "c"
      c.setCursor(const EditorPosition(0, 1));
      c.insertNewline(); // a | (new) | b | c | d
      expect(c.bookmarks.keys, [3]);
      c.undo();
      expect(c.bookmarks.keys, [2]);
      c.redo();
      expect(c.bookmarks.keys, [3]);

      // 删掉书签上方的整行
      c.setSelection(const EditorPosition(0, 1), const EditorPosition(1, 0));
      c.insertText('');
      c.deleteBackward(); // 删除选区
      expect(c.text, 'a\nb\nc\nd');
      expect(c.bookmarks.keys, [2]);
    });

    test('Enter at the start of a bookmarked line pushes the bookmark down with its text', () {
      c.toggleBookmark(2); // "c"
      c.setCursor(const EditorPosition(2, 0));
      c.insertNewline();
      expect(c.lines[3], 'c');
      expect(c.bookmarks.keys, [3]);
      c.undo();
      expect(c.bookmarks.keys, [2]);
    });

    test('deleting the bookmarked line merges it into the line where the deletion starts', () {
      c.toggleBookmark(2); // "c"
      c.setSelection(const EditorPosition(1, 1), const EditorPosition(2, 1)); // "b" 行尾 → "c" 行尾
      c.deleteBackward();
      expect(c.text, 'a\nb\nd');
      expect(c.bookmarks.keys, [1]);
    });
  });

  group('git.blame', () {
    late Directory repo;
    Future<void> git(List<String> args, {Map<String, String>? env}) async {
      final r = await Process.run('git', args, workingDirectory: repo.path, environment: env);
      if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
    }

    setUp(() async {
      repo = Directory.systemTemp.createTempSync('clx_blame_');
      await git(['init', '-q', '-b', 'main']);
      await git(['config', 'user.name', 'Ronnie Wood']);
      await git(['config', 'user.email', 'r@example.com']);
      File('${repo.path}/f.txt').writeAsStringSync('one\ntwo\n');
      await git(['add', 'f.txt']);
      await git(['commit', '-q', '-m', 'first'], env: {'GIT_AUTHOR_DATE': '@1776988800 +0000', 'GIT_COMMITTER_DATE': '@1776988800 +0000'});
      File('${repo.path}/f.txt').writeAsStringSync('one\nTWO\nthree\n');
      await git(['commit', '-q', '-am', 'second']);
    });
    tearDown(() => repo.deleteSync(recursive: true));

    test('per-line commits, previous revision and unsaved contents', () async {
      final g = GitService(repo.path);
      final r = await g.call('git.blame', {'path': 'f.txt'});
      expect(r['status'], 'ok');
      final lines = (r['lines'] as List).cast<String>();
      final commits = r['commits'] as Map;
      expect(lines, hasLength(3));
      expect(commits[lines[0]]['summary'], 'first');
      expect(commits[lines[1]]['summary'], 'second');
      expect(commits[lines[0]]['author'], 'Ronnie Wood');
      expect(commits[lines[0]]['email'], 'r@example.com');
      expect(commits[lines[0]]['time'], 1776988800);
      // "second" 改了这个文件,所以有上一版本可注释。
      expect(commits[lines[1]]['previous_path'], 'f.txt');
      expect(commits[lines[1]]['previous_hash'], commits[lines[0]]['hash']);

      // 编辑器里还没保存的内容:新插入的一行算"未提交",下面的行号顺延。
      final dirty = await g.call('git.blame', {'path': 'f.txt', 'contents': 'NEW\none\nTWO\nthree\n'});
      final dl = (dirty['lines'] as List).cast<String>();
      expect(dl, hasLength(4));
      expect(dl[0], '0' * 40);
      expect(dl[1], lines[0]);

      // 指定版本:注释第一个提交时的样子。
      final old = await g.call('git.blame', {'path': 'f.txt', 'rev': lines[0]});
      expect((old['lines'] as List), hasLength(2));
    });
  });

  group('gutter UI', () {
    // 光标闪烁是周期计时器:先卸载组件再释放 controller,测试结束时才没有挂起的计时器。
    Future<void> disposeEditor(WidgetTester tester, CodeEditorController ctrl) async {
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    }

    Future<CodeEditorController> pumpEditor(WidgetTester tester, EditorAppearance appearance) async {
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ctrl = CodeEditorController(initialText: 'fn a() {\n    let x = 1;\n}\n');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorViewWidget(
            openTabs: const ['a.rs'],
            activeFile: 'a.rs',
            codeContent: ctrl.text,
            controller: ctrl,
            appearance: appearance,
            onSelectTab: (_) {},
            onCloseTab: (_) {},
            onCodeChanged: (_) {},
          ),
        ),
      ));
      await tester.pump();
      return ctrl;
    }

    testWidgets('right-click the line numbers: bookmark + appearance toggles', (tester) async {
      final appearance = EditorAppearance();
      final ctrl = await pumpEditor(tester, appearance);

      await tester.tap(find.text('2'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Annotate with Git Blame'), findsOneWidget);
      expect(find.text('Add Bookmark'), findsOneWidget);
      expect(find.text('Add Mnemonic Bookmark…'), findsOneWidget);

      await tester.tap(find.text('Add Bookmark'));
      await tester.pumpAndSettle();
      expect(ctrl.hasBookmark(1), isTrue);
      expect(find.byIcon(Icons.bookmark), findsOneWidget);

      // 再次右键,同一行显示 Remove Bookmark;打开 Appearance 关掉行号。
      await tester.tap(find.text('2'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Remove Bookmark'), findsOneWidget);
      await tester.tap(find.text('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show Line Numbers'));
      await tester.pumpAndSettle();
      expect(appearance.showLineNumbers, isFalse);
      expect(find.text('2'), findsNothing);
      await disposeEditor(tester, ctrl);
    });

    testWidgets('F3 toggles a bookmark on the caret line', (tester) async {
      final ctrl = await pumpEditor(tester, EditorAppearance());
      await tester.tap(find.byType(EditorViewWidget));
      ctrl.setCursor(const EditorPosition(2, 0));
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.pump();
      expect(ctrl.hasBookmark(2), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.pump();
      expect(ctrl.hasBookmark(2), isFalse);
      await disposeEditor(tester, ctrl);
    });

    testWidgets('blame column labels and its context menu', (tester) async {
      final appearance = EditorAppearance();
      final data = BlameData(
        ['a' * 40, 'b' * 40],
        {
          'a' * 40: BlameCommit(hash: 'a' * 40, author: 'ronnie wood', email: 'r@x', time: DateTime(2026, 4, 24), summary: 's1', path: 'f.rs'),
          'b' * 40: BlameCommit(hash: 'b' * 40, author: 'zed', email: 'z@x', time: DateTime(2026, 5, 1), summary: 's2', path: 'f.rs', previousHash: 'a' * 40),
        },
      );
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: appearance,
            builder: (context, _) => Align(
              alignment: Alignment.topLeft,
              child: BlameColumn(
                data: data,
                appearance: appearance,
                totalLines: 2,
                menuBuilder: (line, c) => blameMenu(
                  context: context,
                  commit: c,
                  appearance: appearance,
                  client: ApiClient(),
                  onClose: () => closed = true,
                ),
              ),
            ),
          ),
        ),
      ));
      expect(find.text('2026/4/24  ronnie wood'), findsOneWidget);
      // 不弹悬停提示;列宽按实际字体计算,作者名不被截断。
      expect(find.byType(Tooltip), findsNothing);
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final box = tester.renderObject<RenderParagraph>(find.byWidget(t));
        expect(box.didExceedMaxLines, isFalse, reason: '"${t.data}" was truncated');
      }

      await tester.tap(find.text('2026/4/24  ronnie wood'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      for (final item in ['Close Annotations', 'Show Diff', 'View', 'Copy Revision Number', 'Annotate Revision', 'Annotate Previous Revision', 'Show in File History']) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revision'));
      await tester.pumpAndSettle();
      expect(find.text('aaaaaaaa  2026/4/24  ronnie wood'), findsOneWidget);

      await tester.tap(find.text('aaaaaaaa  2026/4/24  ronnie wood'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close Annotations'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });
  });
}
