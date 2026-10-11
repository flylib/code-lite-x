import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/project_manager.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/disk_conflict_banner.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 别处(别的编辑器、格式化工具、脚本、git)改了磁盘上的文件:已打开的标签要跟上。
/// 没保存修改的直接换成新内容(可撤销);有没保存修改的不覆盖任何一边,等用户选。
void main() {
  late Directory tmp;
  late ApiClient client;
  late EditorSessionManager sessions;

  File file(String name) => File('${tmp.path}/$name');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clx_disk_sync_');
    file('a.txt').writeAsStringSync('one\ntwo\n');
    client = ApiClient(initialRoot: tmp.path);
    sessions = EditorSessionManager(client: client)..autosave = false;
  });

  tearDown(() async {
    sessions.dispose();
    await client.dispose();
    tmp.deleteSync(recursive: true);
  });

  group('session', () {
    test('a clean tab takes the new disk content, stays clean, and ⌘Z goes back to the old text', () async {
      final tab = await sessions.openFile('a.txt');
      file('a.txt').writeAsStringSync('one\nTWO changed elsewhere\n');
      await sessions.syncWithDisk();
      expect(tab.controller.text, 'one\nTWO changed elsewhere\n');
      expect(tab.isDirty, isFalse);
      expect(tab.diskConflict, isNull);

      expect(tab.controller.undo(), isTrue);
      expect(tab.controller.text, 'one\ntwo\n', reason: '载入外部改动是一次可撤销的编辑');
      expect(tab.isDirty, isTrue);
    });

    test('a tab with unsaved edits is not overwritten: it becomes a conflict and saving waits for the user', () async {
      final tab = await sessions.openFile('a.txt');
      tab.controller.insertText('MINE ');
      file('a.txt').writeAsStringSync('theirs\n');
      await sessions.syncWithDisk();
      expect(tab.controller.text, startsWith('MINE '), reason: '用户正在写的东西不能被盖掉');
      expect(tab.diskConflict, 'theirs\n');

      expect(await sessions.saveFile('a.txt'), isFalse, reason: '选之前不保存');
      expect(file('a.txt').readAsStringSync(), 'theirs\n', reason: '别处的改动也没被盖掉');

      // 选「保留我的修改」:写回磁盘
      expect(await sessions.keepMyChanges('a.txt'), isTrue);
      expect(file('a.txt').readAsStringSync(), 'MINE one\ntwo\n');
      expect(tab.diskConflict, isNull);
      expect(tab.isDirty, isFalse);
    });

    test('"load disk version" drops the unsaved edits (undoable)', () async {
      final tab = await sessions.openFile('a.txt');
      tab.controller.insertText('MINE ');
      file('a.txt').writeAsStringSync('theirs\n');
      await sessions.syncWithDisk();
      sessions.loadDiskVersion('a.txt');
      expect(tab.controller.text, 'theirs\n');
      expect(tab.isDirty, isFalse);
      expect(tab.diskConflict, isNull);
      expect(tab.controller.undo(), isTrue);
      expect(tab.controller.text, 'MINE one\ntwo\n');
    });

    test('saving checks the disk first: an external change the watcher has not reported yet is not overwritten', () async {
      final tab = await sessions.openFile('a.txt');
      file('a.txt').writeAsStringSync('theirs\n'); // 还没 sync
      tab.controller.insertText('MINE ');
      expect(await sessions.saveFile('a.txt'), isFalse);
      expect(file('a.txt').readAsStringSync(), 'theirs\n');
      expect(tab.diskConflict, 'theirs\n');
    });

    test('our own save is not mistaken for an external change; same content written elsewhere just clears the dirty mark', () async {
      final tab = await sessions.openFile('a.txt');
      tab.controller.insertText('x');
      expect(await sessions.saveFile('a.txt'), isTrue);
      await sessions.syncWithDisk();
      expect(tab.diskConflict, isNull);
      expect(tab.controller.text, 'xone\ntwo\n');

      tab.controller.insertText('y');
      file('a.txt').writeAsStringSync('xyone\ntwo\n'); // 别处保存了同样的内容
      await sessions.syncWithDisk();
      expect(tab.diskConflict, isNull);
      expect(tab.isDirty, isFalse);
    });

    test('a deleted file keeps the editor content', () async {
      final tab = await sessions.openFile('a.txt');
      file('a.txt').deleteSync();
      await sessions.syncWithDisk();
      expect(tab.controller.text, 'one\ntwo\n');
      expect(tab.diskConflict, isNull);
    });
  });

  test('the project file watcher brings an externally edited open file up to date by itself', () async {
    final layout = LayoutStore();
    final settings = SettingsStore(appearance: EditorAppearance(), layout: layout, load: () async => {}, save: (_) async {});
    final plugins = PluginManager(host: PluginHost(root: '${tmp.path}/.plugins'));
    final manager = ProjectManager(
      layout: layout,
      plugins: plugins,
      settings: settings,
      store: OpenProjectsStore(load: () async => {}, save: (_) async {}),
      sessionStore: SessionStore(load: () async => {}, save: (_) async {}),
      loadRecent: () async => [],
      saveRecent: (_) async {},
    );
    expect(await manager.open(tmp.path), isTrue);
    final ctx = manager.active;
    await ctx.workspace.openFile('a.txt');
    final tab = ctx.sessions.tabs['a.txt']!;
    await Future<void>.delayed(const Duration(milliseconds: 300)); // 监视器起来

    file('a.txt').writeAsStringSync('changed by another tool\n');
    for (var i = 0; i < 60 && tab.controller.text != 'changed by another tool\n'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(tab.controller.text, 'changed by another tool\n');
    expect(tab.isDirty, isFalse);

    manager.dispose();
    settings.dispose();
    plugins.dispose();
    layout.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  testWidgets('conflict banner: shown only while there is a conflict; its buttons resolve it', (tester) async {
    late EditorTabState tab;
    await tester.runAsync(() async {
      tab = await sessions.openFile('a.txt');
      tab.controller.insertText('MINE ');
      file('a.txt').writeAsStringSync('theirs\n');
    });
    Widget banner() => MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: sessions,
              builder: (context, _) => DiskConflictBanner(sessions: sessions, path: 'a.txt'),
            ),
          ),
        );
    await tester.pumpWidget(banner());
    expect(find.byKey(const ValueKey('disk-conflict-banner')), findsNothing);

    await tester.runAsync(() => sessions.syncWithDisk());
    await tester.pump();
    expect(find.byKey(const ValueKey('disk-conflict-banner')), findsOneWidget);

    await tester.tap(find.text('载入磁盘版本'));
    await tester.pump();
    expect(find.byKey(const ValueKey('disk-conflict-banner')), findsNothing);
    expect(tab.controller.text, 'theirs\n');
    await tester.pumpWidget(const SizedBox());
    sessions.closeTab('a.txt'); // 释放光标闪烁、发给语言服务器的防抖等定时器
  });
}
