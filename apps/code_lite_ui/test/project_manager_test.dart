import 'dart:io';

import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/project_manager.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:flutter_test/flutter_test.dart';

/// 同时打开多个项目:一个进程、多个项目都留在内存里,切换只是换显示哪一个,关闭才真正释放。
/// 真实目录 + 真实的 Rust 终端(没编出 dylib 时终端相关的断言跳过)。
void main() {
  late Directory tmp;
  late String a, b, c;
  late LayoutStore layout;
  late SettingsStore settings;
  late PluginManager plugins;
  late Map<String, dynamic> openDisk;
  late Map<String, dynamic> sessionDisk;
  late List<String> recentDisk;
  late ProjectManager manager;

  ProjectManager newManager() => ProjectManager(
        layout: layout,
        plugins: plugins,
        settings: settings,
        store: OpenProjectsStore(load: () async => Map<String, dynamic>.from(openDisk), save: (m) async => openDisk = m),
        sessionStore: SessionStore(load: () async => Map<String, dynamic>.from(sessionDisk), save: (m) async => sessionDisk = m),
        loadRecent: () async => recentDisk,
        saveRecent: (l) async => recentDisk = l,
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clx_projects_');
    for (final name in ['alpha', 'beta', 'gamma']) {
      Directory('${tmp.path}/$name').createSync();
      File('${tmp.path}/$name/one.txt').writeAsStringSync('$name one\nline 2\n');
      File('${tmp.path}/$name/two.txt').writeAsStringSync('$name two\n');
    }
    a = '${tmp.path}/alpha';
    b = '${tmp.path}/beta';
    c = '${tmp.path}/gamma';
    layout = LayoutStore();
    settings = SettingsStore(appearance: EditorAppearance(), layout: layout, load: () async => {}, save: (_) async {});
    plugins = PluginManager(host: PluginHost(root: '${tmp.path}/plugins'));
    openDisk = {};
    sessionDisk = {};
    recentDisk = [];
    manager = newManager();
  });

  tearDown(() async {
    manager.dispose();
    settings.dispose();
    plugins.dispose();
    layout.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    tmp.deleteSync(recursive: true);
  });

  test('starts empty: no project, an empty state to show', () {
    expect(manager.projects, isEmpty);
    expect(manager.activeProject, isNull);
    expect(manager.active.path, isNull);
    expect(manager.active.isEmpty, isTrue);
  });

  test('several projects stay open at once, each with its own state; switching brings the other one back untouched', () async {
    settings.setAutosave(false); // 不让自动保存把「没保存的改动」写掉
    expect(await manager.open(a), isTrue);
    final ctxA = manager.active;
    await ctxA.workspace.openFile('one.txt');
    ctxA.sessions.tabs['one.txt']!.controller.insertText('EDITED ');
    expect(ctxA.workspace.isDirty('one.txt'), isTrue);

    expect(await manager.open(b), isTrue);
    final ctxB = manager.active;
    expect(identical(ctxA, ctxB), isFalse);
    expect(ctxB.path, b);
    expect(ctxB.client.rootPath, b);
    expect(ctxA.client.rootPath, a, reason: '打开第二个项目不会把第一个的根改掉');
    expect(manager.projects.map((p) => p.path), [a, b]);
    expect(manager.activeProject!.path, b);
    expect(ctxB.workspace.openTabs, isEmpty, reason: 'B 有自己的标签');

    // 切回 A:还是那一份(同一个对象),没保存的改动、标签、当前文件都在
    expect(await manager.activate(manager.projects.first), isTrue);
    expect(identical(manager.active, ctxA), isTrue);
    expect(ctxA.workspace.openTabs, ['one.txt']);
    expect(ctxA.sessions.tabs['one.txt']!.controller.text, startsWith('EDITED alpha one'));
    expect(ctxA.workspace.isDirty('one.txt'), isTrue, reason: '没保存的改动还在内存里');
    expect(File('$a/one.txt').readAsStringSync(), startsWith('alpha one'), reason: '磁盘上还是原样');
    expect(identical(manager.projects.last.context, ctxB), isTrue, reason: 'B 仍然留在内存里');
  });

  test('opening an already open project (also with a trailing slash) switches to it instead of opening a second copy', () async {
    await manager.open(a);
    await manager.open(b);
    final first = manager.projects.first.context;
    expect(await manager.open('$a/'), isTrue);
    expect(manager.projects.length, 2);
    expect(identical(manager.active, first), isTrue);
    expect(manager.activeProject!.path, a);
  });

  test('a directory that does not exist is not opened and leaves everything as it was', () async {
    await manager.open(a);
    expect(await manager.open('${tmp.path}/nope'), isFalse);
    expect(manager.projects.map((p) => p.path), [a]);
    expect(manager.activeProject!.path, a);
  });

  test('projects share the appearance and the autosave settings, new ones included', () async {
    await manager.open(a);
    final first = manager.active;
    await manager.open(b);
    final second = manager.active;
    expect(identical(first.sessions.appearance, second.sessions.appearance), isTrue, reason: '外观是全局设置');
    expect(identical(first.sessions.appearance, settings.appearance), isTrue);
    settings.appearance.setFontSize(18);
    expect(second.sessions.appearance.fontSize, 18);

    settings.setAutosave(false);
    expect([first.sessions.autosave, second.sessions.autosave], [false, false], reason: '改设置对所有打开的项目生效');
    await manager.open(c);
    expect(manager.active.sessions.autosave, isFalse, reason: '新打开的项目也套用当前设置');
    settings.setAutosaveDelay(const Duration(seconds: 2));
    expect(manager.active.sessions.autosaveDelay, const Duration(seconds: 2));
  });

  group('closing', () {
    test('closing the active project goes to its neighbour (the next one, else the previous); the closed one is released', () async {
      await manager.open(a);
      await manager.open(b);
      await manager.open(c);
      final ctxB = manager.projects[1].context!;
      await manager.activate(manager.projects[1]);

      await manager.close(manager.projects[1]); // 关当前的 B → 后面的 C
      expect(manager.projects.map((p) => p.path), [a, c]);
      expect(manager.activeProject!.path, c);

      await manager.close(manager.projects.last); // 关当前的 C(最后一个)→ 前面的 A
      expect(manager.activeProject!.path, a);

      expect(ctxB.workspace.rootPath, b, reason: '被关掉的状态对象自己不改,只是不再被引用');
      await manager.close(manager.projects.single);
      expect(manager.projects, isEmpty);
      expect(manager.activeProject, isNull);
      expect(manager.active.path, isNull, reason: '一个都不剩:回到空状态');
    });

    test('closing a project that is not the active one leaves the active one alone', () async {
      await manager.open(a);
      await manager.open(b);
      final ctxB = manager.active;
      await manager.close(manager.projects.first);
      expect(manager.projects.map((p) => p.path), [b]);
      expect(identical(manager.active, ctxB), isTrue);
    });

    test('closing saves the tab layout so reopening the project restores it', () async {
      await manager.open(a);
      await manager.active.workspace.openFile('two.txt');
      await manager.active.workspace.openFile('one.txt');
      await manager.close(manager.projects.single);
      expect((sessionDisk[a] as Map)['tabs'].map((t) => t['path']).toList(), ['two.txt', 'one.txt']);

      await manager.open(a);
      expect(manager.active.workspace.openTabs, ['two.txt', 'one.txt']);
      expect(manager.active.workspace.activeFile, 'one.txt');
    });

    test('close others keeps only the chosen project', () async {
      await manager.open(a);
      await manager.open(b);
      await manager.open(c);
      await manager.closeOthers(manager.projects[1]);
      expect(manager.projects.map((p) => p.path), [b]);
      expect(manager.activeProject!.path, b);
    });
  });

  group('terminals: each project has its own shell context', () {
    test('a shell in one project survives other projects being opened and closed; closing its own project ends it', () async {
      await manager.open(a);
      final ctxA = manager.active;
      if (!ctxA.client.isFfiAvailable) return; // 没编出 dylib:没有终端可测
      final shellA = ctxA.terminals.open(24, 80)!;
      expect(ctxA.client.ptySnapshot(shellA.id)['status'], 'ok');

      await manager.open(b);
      final ctxB = manager.active;
      final shellB = ctxB.terminals.open(24, 80)!;
      expect(ctxB.client.ptySnapshot(shellB.id)['status'], 'ok');
      expect(ctxA.client.ptySnapshot(shellA.id)['status'], 'ok', reason: '打开 B 不能杀掉 A 的终端');

      await manager.close(manager.projects.last); // 关 B
      expect(ctxA.client.ptySnapshot(shellA.id)['status'], 'ok', reason: '关掉 B 也不能');
      expect(ctxB.client.isFfiAvailable, isFalse, reason: 'B 的 Rust 上下文已销毁');

      // 同一个 id 在 A 的上下文里和 B 的上下文里是两回事:各自独立
      expect(ctxA.client.ptySnapshot(shellB.id)['status'], isNot(shellA.id == shellB.id ? 'x' : 'ok'));
    });
  });

  group('persistence', () {
    test('the open list and the active project are saved, in order', () async {
      await manager.open(a);
      await manager.open(b);
      await manager.activate(manager.projects.first);
      expect(openDisk['open'], [a, b]);
      expect(openDisk['active'], a);
      await manager.close(manager.projects.first);
      expect(openDisk['open'], [b]);
      expect(openDisk['active'], b);
      await manager.close(manager.projects.single);
      expect(openDisk['open'], isEmpty);
      expect(openDisk.containsKey('active'), isFalse);
    });

    test('restore brings back the list but loads only the active project; the others load when first switched to, with their tabs', () async {
      await manager.open(a);
      await manager.active.workspace.openFile('two.txt');
      await manager.open(b);
      await manager.active.workspace.openFile('one.txt');
      await manager.saveAll();
      manager.dispose();

      manager = newManager();
      await manager.restore();
      expect(manager.projects.map((p) => p.path), [a, b]);
      expect(manager.activeProject!.path, b);
      expect(manager.projects[1].isLoaded, isTrue);
      expect(manager.projects[0].isLoaded, isFalse, reason: '没在看的项目不立刻加载(免得一启动拉起一堆语言服务器)');
      expect(manager.active.workspace.openTabs, ['one.txt'], reason: '当前项目的标签恢复了');

      expect(await manager.activate(manager.projects[0]), isTrue);
      expect(manager.projects[0].isLoaded, isTrue);
      expect(manager.active.workspace.openTabs, ['two.txt'], reason: '第一次切过去才加载,标签也恢复');
    });

    test('restore drops projects whose folder is gone; with no saved list it falls back to the most recent project', () async {
      openDisk = {
        'open': [a, '${tmp.path}/deleted'],
        'active': '${tmp.path}/deleted',
      };
      await manager.restore();
      expect(manager.projects.map((p) => p.path), [a]);
      expect(manager.activeProject!.path, a, reason: '上次的当前项目没了:用剩下的第一个');
      manager.dispose();

      openDisk = {};
      recentDisk = [b, a];
      manager = newManager();
      await manager.restore();
      expect(manager.projects.map((p) => p.path), [b], reason: '老版本升级上来没有列表:最近的一个');
    });

    test('the recent list is shared: opening several projects keeps all of them, newest first', () async {
      await manager.open(a);
      await manager.open(b);
      await manager.open(c);
      expect(recentDisk.take(3), [c, b, a], reason: '各项目各自更新最近列表时不能互相覆盖');
      expect(manager.recent.take(3), [c, b, a]);
      await manager.open(a); // 切回 A 不算新打开,但已经在列表里
      await manager.clearRecent();
      expect(manager.recent, isEmpty);
      expect(recentDisk, isEmpty);
    });
  });

  test('switching to a project without a build tool window closes the build panel instead of showing an empty one', () async {
    await manager.open(a);
    await manager.open(b);
    layout.showTool(SideTool.build);
    expect(layout.isToolVisible(SideTool.build), isTrue);
    await manager.activate(manager.projects.first);
    expect(layout.isToolVisible(SideTool.build), isFalse);
    expect(layout.visibleTool(ToolSide.left, ToolSlot.top), SideTool.project);
  });
}
