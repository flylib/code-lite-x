import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/search/recent_files_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Recent Files(⌘E,同 IntelliJ):最近打开过的文件(关了的标签也在,新的在前)、改过的文件,
/// 弹窗左边工具窗、右边文件,⌘E 再按一次切换「仅显示已编辑」。
void main() {
  test('the default shortcut is Cmd+E (Ctrl+E elsewhere), under Navigation', () {
    final a = keymapActionById(KeymapIds.recentFiles)!;
    expect(a.mac, ['meta E']);
    expect(a.other, ['ctrl E']);
    expect(a.keymapGroup, KeymapGroup.navigation);
  });

  group('session', () {
    late Directory dir;
    late ApiClient client;
    late EditorSessionManager sessions;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('clx_recent_');
      for (final n in ['a.txt', 'b.txt', 'c.txt']) {
        File('${dir.path}/$n').writeAsStringSync('$n\n');
      }
      client = ApiClient(initialRoot: dir.path);
      sessions = EditorSessionManager(client: client)..autosave = false;
    });

    tearDown(() async {
      sessions.dispose();
      await client.dispose();
      dir.deleteSync(recursive: true);
    });

    test('opening / switching puts the file first; closed tabs stay in the list; edits are tracked', () async {
      await sessions.openFile('a.txt');
      await sessions.openFile('b.txt');
      final c = await sessions.openFile('c.txt');
      expect(sessions.recentFiles, ['c.txt', 'b.txt', 'a.txt']);

      sessions.selectTab('a.txt');
      expect(sessions.recentFiles, ['a.txt', 'c.txt', 'b.txt']);

      sessions.closeTab('a.txt'); // 落到最后一个标签 c.txt
      expect(sessions.recentFiles, ['c.txt', 'a.txt', 'b.txt'], reason: '关掉的 a.txt 还在');

      expect(sessions.editedFiles, isEmpty);
      c.controller.insertText('x');
      expect(sessions.editedFiles, ['c.txt']);

      sessions.openDiff('a.txt');
      expect(sessions.recentFiles.first, 'c.txt', reason: '差异标签不算');

      final snap = sessions.snapshot();
      expect(snap.recent, ['c.txt', 'a.txt', 'b.txt']);
      expect(snap.edited, ['c.txt']);
      final back = SessionSnapshot.fromJson(snap.toJson());
      expect(back.recent, snap.recent);
      expect(back.edited, snap.edited);
    });

    test('restoring puts the saved list back, the current tab first', () async {
      await sessions.openFile('b.txt');
      sessions.restoreRecent(['a.txt', 'c.txt', 'b.txt'], ['a.txt']);
      expect(sessions.recentFiles, ['b.txt', 'a.txt', 'c.txt']);
      expect(sessions.editedFiles, ['a.txt']);
    });

    test('files changed on disk by something else do not count as edited', () async {
      await sessions.openFile('a.txt');
      File('${dir.path}/a.txt').writeAsStringSync('changed elsewhere\n');
      await sessions.syncWithDisk();
      expect(sessions.activeTab!.controller.text, 'changed elsewhere\n');
      expect(sessions.editedFiles, isEmpty);
    });
  });

  group('popup', () {
    const files = [
      RecentFileItem(path: '/p/Current.java', name: 'Current.java', directory: '~/p'),
      RecentFileItem(path: '/p/Previous.java', name: 'Previous.java', directory: '~/p/src'),
      RecentFileItem(path: '/p/pom.xml', name: 'pom.xml', directory: '~/p', detail: 'sub'),
    ];
    const edited = [RecentFileItem(path: '/p/pom.xml', name: 'pom.xml', directory: '~/p')];
    final tools = [
      RecentToolItem(id: KeymapIds.commit, label: 'Commit', icon: (c, s) => Icon(Icons.task_alt, color: c, size: s), shortcut: '⌘0'),
      RecentToolItem(id: KeymapIds.terminal, label: 'Terminal', icon: (c, s) => Icon(Icons.terminal, color: c, size: s)),
    ];

    /// 弹出 Recent Files;返回的函数取选择结果(关掉之后)。
    Future<RecentFilesChoice? Function()> open(WidgetTester tester) async {
      RecentFilesChoice? chosen;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => chosen = await showRecentFilesDialog(
                context,
                files: files,
                editedFiles: edited,
                tools: tools,
                currentFile: '/p/Current.java',
                toggleKeys: const [SingleActivator(LogicalKeyboardKey.keyE, meta: true)],
                toggleLabel: '⌘E',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('最近的文件'), findsOneWidget);
      return () => chosen;
    }

    testWidgets('the previous file is preselected: Cmd+E then Enter goes back to it; the footer shows where it is', (tester) async {
      final chosen = await open(tester);
      expect(find.text('Commit'), findsOneWidget);
      expect(find.text('⌘0'), findsOneWidget, reason: '工具窗后面是它的快捷键');
      expect(find.text('sub'), findsOneWidget, reason: '同名文件后面的灰字');
      expect(tester.widget<Text>(find.byKey(const ValueKey('recent-files-location'))).data, '~/p/src');
      expect(find.byKey(const ValueKey('recent-file-split-/p/Previous.java')), findsOneWidget, reason: '选中的那行有「在右侧拆分中打开」');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen()?.file, '/p/Previous.java');
      expect(chosen()?.split, isFalse);
    });

    testWidgets('Cmd+E inside the popup toggles Show edited only; typing filters; Esc clears the search, then closes', (tester) async {
      final chosen = await open(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(find.text('最近编辑的文件'), findsOneWidget);
      expect(find.byKey(const ValueKey('recent-file-/p/Previous.java')), findsNothing);
      expect(find.byKey(const ValueKey('recent-file-/p/pom.xml')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('recent-files-edited-only')));
      await tester.pump();
      expect(find.text('最近的文件'), findsOneWidget);

      // 快速搜索:打 "pre" → 只剩 Previous.java
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.pump();
      expect(find.byKey(const ValueKey('recent-files-query')), findsOneWidget);
      expect(find.byKey(const ValueKey('recent-file-/p/Previous.java')), findsOneWidget);
      expect(find.byKey(const ValueKey('recent-file-/p/Current.java')), findsNothing);
      expect(find.byKey(const ValueKey('recent-tool-${KeymapIds.commit}')), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('recent-files-query')), findsNothing);
      expect(find.byKey(const ValueKey('recent-file-/p/Current.java')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('最近的文件'), findsNothing);
      expect(chosen(), isNull);
    });

    testWidgets('clicking a tool window picks it; Left / Enter picks one from the keyboard; the split icon opens in a split', (tester) async {
      var chosen = await open(tester);
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      expect(chosen()?.tool, KeymapIds.terminal);

      chosen = await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen()?.tool, KeymapIds.commit);

      chosen = await open(tester);
      await tester.tap(find.byKey(const ValueKey('recent-file-split-/p/Previous.java')));
      await tester.pumpAndSettle();
      expect(chosen()?.file, '/p/Previous.java');
      expect(chosen()?.split, isTrue);
    });
  });
}
