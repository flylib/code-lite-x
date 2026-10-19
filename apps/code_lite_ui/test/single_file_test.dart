import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/project_manager.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:flutter_test/flutter_test.dart';

/// File → Open 选的是单个文件:像项目一样出现在 Opening 里,但不把它所在的目录当工程。
void main() {
  late Directory tmp;
  late String dir, file, other;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clx_single_');
    dir = '${tmp.path}/notes';
    Directory('$dir/sub').createSync(recursive: true);
    file = '$dir/zh.json';
    other = '$dir/other.json';
    File(file).writeAsStringSync('{\n  "reason": "原因",\n  "remark": "备注"\n}\n');
    File(other).writeAsStringSync('"reason" here too\n');
    File('$dir/sub/deep.txt').writeAsStringSync('reason\n');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('ApiClient', () {
    test('the folder is the working directory, but tree / search / index / watch only cover the file', () async {
      final client = ApiClient();
      expect(client.openSingleFile(file) || !client.isFfiAvailable, isTrue);
      expect(client.isSingleFile, isTrue);
      expect(client.rootPath, dir, reason: '终端、Git 在它所在的目录');

      final tree = await client.fetchWorkspaceTree();
      final children = tree['children'] as List;
      expect(children.map((c) => c['name']), ['zh.json'], reason: '文件树里只有它');
      expect(children.single['path'], file);

      final res = await client.searchWorkspace('reason');
      expect([for (final m in res['matches'] as List) m['file_path']], ['zh.json'], reason: '同目录别的文件里也有,但不搜');

      final idx = client.fileIndexQuery('other');
      expect(idx['results'], isEmpty, reason: '不给它所在的目录建文件清单');
      expect(client.startWatching(), isFalse, reason: '不监视它所在的目录');

      // 换回普通项目:一切照常
      expect(client.openWorkspace(dir) || !client.isFfiAvailable, isTrue);
      expect(client.isSingleFile, isFalse);
      final all = await client.searchWorkspace('reason');
      expect((all['matches'] as List).length, greaterThan(1));
      client.dispose();
    });
  });

  group('ProjectManager', () {
    late LayoutStore layout;
    late SettingsStore settings;
    late PluginManager plugins;
    Map<String, dynamic> openDisk = {};
    Map<String, dynamic> sessionDisk = {};
    List<String> recentDisk = [];

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
      layout = LayoutStore();
      settings = SettingsStore(appearance: EditorAppearance(), layout: layout, load: () async => {}, save: (_) async {});
      plugins = PluginManager(host: PluginHost(root: '${tmp.path}/plugins'));
      openDisk = {};
      sessionDisk = {};
      recentDisk = [];
    });

    tearDown(() async {
      settings.dispose();
      plugins.dispose();
      layout.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('opening a file lists it like a project, opens it, and comes back after a restart', () async {
      var manager = newManager();
      expect(await manager.open(file), isTrue);
      expect(manager.projects.single.path, file);
      expect(manager.projects.single.name, 'zh.json', reason: 'Opening 里和项目一样显示:名字 + 路径');
      final ctx = manager.active;
      expect(ctx.workspace.isSingleFile, isTrue);
      expect(ctx.workspace.projectName, 'zh.json');
      expect(ctx.sessions.activePath, file, reason: '打开就显示这个文件');
      expect(ctx.make.files, isEmpty);

      // 光标位置随会话记住(按文件自己的路径记)
      ctx.sessions.tabs[file]!.controller.setCursor(const EditorPosition(2, 4));
      await ctx.workspace.saveSession();
      expect(openDisk['open'], [file]);
      manager.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      manager = newManager();
      await manager.restore();
      expect(manager.projects.single.path, file);
      expect(manager.active.sessions.activePath, file);
      expect(manager.active.sessions.tabs[file]!.controller.cursorPosition, const EditorPosition(2, 4));

      // 同一个目录也能作为项目另外打开,两者互不影响
      expect(await manager.open(dir), isTrue);
      expect(manager.projects.map((p) => p.path), [file, dir]);
      expect(manager.active.workspace.isSingleFile, isFalse);
      manager.dispose();
    });

    test('a missing file cannot be opened', () async {
      final manager = newManager();
      expect(await manager.open('$dir/nope.txt'), isFalse);
      expect(manager.projects, isEmpty);
      manager.dispose();
    });
  });
}
