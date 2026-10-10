import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/workspace_store.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记住上次打开的标签、光标和滚动位置,下次打开项目时恢复。
void main() {
  group('snapshot', () {
    test('json round-trips; bad entries and duplicates are dropped; unknown active falls back to null', () {
      const s = SessionSnapshot(
        tabs: [TabSnapshot(path: 'a.txt', line: 3, col: 4, scroll: 120), TabSnapshot(path: 'dir/b.txt')],
        active: 'dir/b.txt',
      );
      expect(s.toJson(), {
        'tabs': [
          {'path': 'a.txt', 'line': 3, 'col': 4, 'scroll': 120},
          {'path': 'dir/b.txt'},
        ],
        'active': 'dir/b.txt',
      });
      final back = SessionSnapshot.fromJson(s.toJson());
      expect(back.signature, s.signature);

      final messy = SessionSnapshot.fromJson({
        'tabs': [
          {'path': 'a.txt', 'line': -2, 'col': 'x'},
          'nonsense',
          {'line': 1},
          {'path': ''},
          {'path': 'a.txt', 'line': 9},
        ],
        'active': 'gone.txt',
      });
      expect(messy.tabs.map((t) => t.path), ['a.txt']);
      expect(messy.tabs.single.line, 0);
      expect(messy.active, isNull);
      expect(SessionSnapshot.fromJson(null).isEmpty, isTrue);
    });

    test('store keeps projects apart, writes empty state too, caps the number of projects, serializes writes', () async {
      var disk = <String, dynamic>{};
      final store = SessionStore(load: () async => Map<String, dynamic>.from(disk), save: (m) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        disk = m;
      });
      // 并发写:不能互相覆盖
      await Future.wait([
        store.write('/p1', const SessionSnapshot(tabs: [TabSnapshot(path: 'a')], active: 'a')),
        store.write('/p2', const SessionSnapshot(tabs: [TabSnapshot(path: 'b')])),
      ]);
      expect((await store.read('/p1')).active, 'a');
      expect((await store.read('/p2')).tabs.single.path, 'b');
      expect((await store.read('/nope')).isEmpty, isTrue);

      await store.write('/p1', const SessionSnapshot());
      expect((await store.read('/p1')).isEmpty, isTrue, reason: '关光了标签也要记,否则下次恢复旧的');

      for (var i = 0; i < SessionStore.maxProjects + 5; i++) {
        await store.write('/x$i', const SessionSnapshot(tabs: [TabSnapshot(path: 'f')]));
      }
      expect(disk.length, SessionStore.maxProjects);
      expect(disk.containsKey('/p2'), isFalse, reason: '最久没用的先丢');
      expect(disk.containsKey('/x${SessionStore.maxProjects + 4}'), isTrue);
    });
  });

  group('workspace', () {
    late Directory tmp;
    late String projectA;
    late String projectB;
    late ApiClient client;
    late EditorSessionManager sessions;
    late Map<String, dynamic> disk;
    late int writes;
    late List<String> recent;

    WorkspaceStore store() => WorkspaceStore(
          client: client,
          sessions: sessions,
          sessionStore: SessionStore(load: () async => Map<String, dynamic>.from(disk), save: (m) async {
            writes++;
            disk = m;
          }),
          loadRecent: () async => recent,
          saveRecent: (l) async => recent = l,
        );

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('clx_sess_');
      projectA = '${tmp.path}/a';
      projectB = '${tmp.path}/b';
      for (final p in [projectA, projectB]) {
        Directory('$p/sub').createSync(recursive: true);
        for (final name in ['one.txt', 'two.txt', 'sub/three.txt']) {
          File('$p/$name').writeAsStringSync(List.generate(100, (i) => 'line $i of $name').join('\n'));
        }
      }
      client = ApiClient(initialRoot: projectA);
      sessions = EditorSessionManager(client: client);
      disk = {};
      writes = 0;
      recent = [];
    });

    tearDown(() async {
      sessions.dispose();
      await client.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('reopening a project brings back the tabs in order, the active tab, cursors and scroll', () async {
      final w = store();
      expect(await w.openFolder(projectA), isTrue);
      expect(w.openTabs, isEmpty, reason: '第一次打开:没有记录,什么也不恢复');

      await w.openFile('two.txt');
      await w.openFile('sub/three.txt');
      await w.openFile('one.txt');
      sessions.tabs['two.txt']!.controller.setCursor(const EditorPosition(7, 3));
      sessions.tabs['one.txt']!.controller.setCursor(const EditorPosition(42, 5));
      sessions.selectTab('two.txt');
      await w.saveSession();
      expect(disk.containsKey(projectA), isTrue);
      w.dispose();

      // 「重启应用」:新的会话管理器和 store,同一份记录
      sessions.dispose();
      sessions = EditorSessionManager(client: client);
      final w2 = store();
      await w2.bootstrap();
      expect(w2.rootPath, projectA, reason: '启动时先恢复上次的项目');
      expect(w2.openTabs, ['two.txt', 'sub/three.txt', 'one.txt']);
      expect(w2.activeFile, 'two.txt');
      expect(sessions.tabs['two.txt']!.controller.cursorPosition, const EditorPosition(7, 3));
      expect(sessions.tabs['one.txt']!.controller.cursorPosition, const EditorPosition(42, 5));
      expect(sessions.tabs['sub/three.txt']!.controller.cursorPosition, const EditorPosition(0, 0));
      expect(w2.isDirty('two.txt'), isFalse);
      w2.dispose();
    });

    test('scroll offset is remembered, including for tabs that are not on screen', () async {
      final w = store();
      await w.openFolder(projectA);
      await w.openFile('one.txt');
      // 没显示的标签读不到滚动控制器的偏移:用最后一次的值
      expect(sessions.tabs['one.txt']!.scrollOffset, 0);
      const snap = SessionSnapshot(tabs: [TabSnapshot(path: 'one.txt', line: 2, col: 1, scroll: 310)], active: 'one.txt');
      disk = {projectA: snap.toJson()};
      w.dispose();
      sessions.dispose();
      sessions = EditorSessionManager(client: client);
      final w2 = store();
      await w2.openFolder(projectA);
      expect(sessions.tabs['one.txt']!.scrollOffset, 310);
      expect(sessions.snapshot().tabs.single.scroll, 310, reason: '没显示也不会被记成 0');
      expect(sessions.snapshot().tabs.single.line, 2);
      w2.dispose();
    });

    test('tabs opened from the file tree are saved with absolute paths and restore (regression: the project root was joined on again)', () async {
      // 文件树给的标签路径是绝对的;恢复时曾经把项目根又拼了一遍,路径变成 <root>//<root>/x,当成「文件不存在」整条丢掉
      disk = {
        projectA: {
          'tabs': [
            {'path': '$projectA/one.txt', 'line': 4},
            {'path': '$projectA/sub/three.txt'},
            {'path': 'two.txt', 'line': 2}, // 同一个项目里相对路径的也照常恢复
          ],
          'active': '$projectA/sub/three.txt',
        },
      };
      final w = store();
      await w.openFolder(projectA);
      expect(w.openTabs, ['$projectA/one.txt', '$projectA/sub/three.txt', 'two.txt']);
      expect(w.activeFile, '$projectA/sub/three.txt');
      expect(sessions.tabs['$projectA/one.txt']!.controller.cursorPosition.line, 4);
      expect(sessions.tabs['two.txt']!.controller.cursorPosition.line, 2);

      // 存回去还是同样的写法,下次启动照样能恢复
      await w.saveSession();
      expect((disk[projectA] as Map)['tabs'].map((t) => t['path']).toList(), ['$projectA/one.txt', '$projectA/sub/three.txt', 'two.txt']);
      w.dispose();
    });

    test('files that no longer exist are skipped; the active tab falls back to the last one', () async {
      disk = {
        projectA: {
          'tabs': [
            {'path': 'one.txt'},
            {'path': 'deleted.txt'},
            {'path': 'two.txt', 'line': 5},
          ],
          'active': 'deleted.txt',
        },
      };
      final w = store();
      await w.openFolder(projectA);
      expect(w.openTabs, ['one.txt', 'two.txt']);
      expect(w.activeFile, 'two.txt');
      expect(sessions.tabs['two.txt']!.controller.cursorPosition.line, 5);
      w.dispose();
    });

    test('switching projects saves the old one first and restores the new one separately; no half-restored state is saved', () async {
      disk = {
        projectB: {
          'tabs': [
            {'path': 'sub/three.txt', 'line': 9},
            {'path': 'two.txt'},
          ],
          'active': 'sub/three.txt',
        },
      };
      final w = store();
      await w.openFolder(projectA);
      await w.openFile('one.txt');
      await w.openFile('two.txt');
      sessions.selectTab('one.txt');

      await w.openFolder(projectB);
      expect((disk[projectA] as Map)['tabs'].map((t) => t['path']).toList(), ['one.txt', 'two.txt'], reason: '离开前存下了 A');
      expect((disk[projectA] as Map)['active'], 'one.txt');
      expect(w.openTabs, ['sub/three.txt', 'two.txt']);
      expect(w.activeFile, 'sub/three.txt');
      expect(sessions.tabs['sub/three.txt']!.controller.cursorPosition.line, 9);

      // 恢复期间的标签变化不会触发保存(半开的状态不是用户的状态)
      final before = writes;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(writes, before, reason: '恢复完没有变化,不写盘');
      expect((disk[projectB] as Map)['tabs'], hasLength(2), reason: 'B 的记录没被半开状态覆盖');

      // 回到 A:A 的标签回来
      await w.openFolder(projectA);
      expect(w.openTabs, ['one.txt', 'two.txt']);
      expect(w.activeFile, 'one.txt');
      w.dispose();
    });

    test('opening / closing tabs is saved shortly after; closing the project saves and an emptied project restores nothing', () async {
      final w = store();
      await w.openFolder(projectA);
      await w.openFile('one.txt');
      await w.openFile('two.txt');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect((disk[projectA] as Map)['tabs'], hasLength(2), reason: '防抖后自动存了');

      w.closeTab('two.txt');
      w.closeTab('one.txt');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect((disk[projectA] as Map)['tabs'], isEmpty, reason: '关光了也要记');

      await w.openFile('one.txt');
      w.closeProject();
      await pumpEventQueue();
      expect((disk[projectA] as Map)['tabs'].map((t) => t['path']).toList(), ['one.txt'], reason: '关闭项目前存了');
      expect(w.openTabs, isEmpty);
      w.dispose();

      sessions.dispose();
      sessions = EditorSessionManager(client: client);
      disk = {projectA: const SessionSnapshot().toJson()};
      final w2 = store();
      await w2.openFolder(projectA);
      expect(w2.openTabs, isEmpty);
      w2.dispose();
    });

    testWidgets('a restored tab shows at the saved scroll position and keeps it', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      disk = {
        projectA: {
          'tabs': [
            {'path': 'one.txt', 'line': 60, 'col': 2, 'scroll': 900},
          ],
          'active': 'one.txt',
        },
      };
      final w = store();
      await tester.runAsync(() => w.openFolder(projectA));
      final tab = sessions.activeTab!;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorViewWidget(
            openTabs: const ['one.txt'],
            activeFile: 'one.txt',
            codeContent: '',
            controller: tab.controller,
            verticalScroll: tab.verticalScroll,
            horizontalScroll: tab.horizontalScroll,
            appearance: EditorAppearance(),
            onSelectTab: (_) {},
            onCloseTab: (_) {},
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tab.verticalScroll.offset, 900);
      expect(tab.scrollOffset, 900);
      expect(tab.controller.cursorPosition, const EditorPosition(60, 2));
      await tester.pumpWidget(const SizedBox());
      w.dispose();
    });

    test('special tabs (diff, PR) are not part of the saved state; the active file is chosen among real ones', () async {
      final w = store();
      await w.openFolder(projectA);
      await w.openFile('one.txt');
      w.openDiff('one.txt');
      final snap = sessions.snapshot();
      expect(snap.tabs.map((t) => t.path), ['one.txt']);
      expect(snap.active, isNull, reason: '当前是差异标签:恢复后停在最后一个真实文件');
      w.dispose();
    });
  });
}
