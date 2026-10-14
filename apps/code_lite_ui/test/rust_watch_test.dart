import 'dart:io';

import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/project_context.dart';
import 'package:code_lite_ui/core/state/project_manager.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:flutter_test/flutter_test.dart';

/// 文件监视在 Rust:构建产物的事件在那边就丢掉;外面新建 / 删掉文件时文件树自己刷新,Go to File 的清单就地跟上。
void main() {
  late Directory tmp;
  late String root;
  late ProjectManager manager;
  late LayoutStore layout;
  late SettingsStore settings;
  late PluginManager plugins;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clx_rust_watch_');
    root = '${tmp.path}/proj';
    Directory('$root/src').createSync(recursive: true);
    File('$root/src/App.java').writeAsStringSync('class App {}\n');
    layout = LayoutStore();
    settings = SettingsStore(appearance: EditorAppearance(), layout: layout, load: () async => {}, save: (_) async {});
    plugins = PluginManager(host: PluginHost(root: '${tmp.path}/.plugins'));
    manager = ProjectManager(
      layout: layout,
      plugins: plugins,
      settings: settings,
      store: OpenProjectsStore(load: () async => {}, save: (_) async {}),
      sessionStore: SessionStore(load: () async => {}, save: (_) async {}),
      loadRecent: () async => [],
      saveRecent: (_) async {},
    );
  });

  tearDown(() async {
    manager.dispose();
    settings.dispose();
    plugins.dispose();
    layout.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    tmp.deleteSync(recursive: true);
  });

  /// 文件树里所有文件的名字。
  Set<String> treeFiles(ProjectContext ctx) {
    final out = <String>{};
    void walk(Map<String, dynamic> n) {
      if (n['is_dir'] != true) out.add(n['name'] as String);
      for (final c in (n['children'] as List? ?? const [])) {
        walk(c as Map<String, dynamic>);
      }
    }

    walk(ctx.workspace.tree);
    return out;
  }

  Future<bool> waitUntil(bool Function() ok) async {
    for (var i = 0; i < 100; i++) {
      if (ok()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return ok();
  }

  test('files created / deleted elsewhere show up in the tree and in Go to File by themselves; build output does not reload the tree', () async {
    expect(await manager.open(root), isTrue);
    final ctx = manager.active;
    if (ctx.client.pollWatch() == null) return; // 没编出 Rust 库:用的是 Dart 的监视,这里不测
    expect(treeFiles(ctx), contains('App.java'));
    await Future<void>.delayed(const Duration(milliseconds: 400)); // FSEvents 起来

    // 构建产物:成批写进 target/,文件树不该刷新
    final before = ctx.workspace.tree;
    Directory('$root/target/classes').createSync(recursive: true);
    for (var i = 0; i < 200; i++) {
      File('$root/target/classes/C$i.class').writeAsStringSync('x');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(identical(ctx.workspace.tree, before), isTrue, reason: 'target/ 的事件在 Rust 里就丢掉了');

    // 外面新建一个文件:文件树自己刷新,Go to File 不用重扫就能找到
    File('$root/src/NewService.java').writeAsStringSync('class NewService {}\n');
    expect(await waitUntil(() => treeFiles(ctx).contains('NewService.java')), isTrue);
    final hits = ctx.client.fileIndexQuery('newserv')['results'] as List;
    expect(hits.single['path'], 'src/NewService.java');

    // 删掉:从文件树和清单里都消失
    File('$root/src/NewService.java').deleteSync();
    expect(await waitUntil(() => !treeFiles(ctx).contains('NewService.java')), isTrue);
    expect(ctx.client.fileIndexQuery('newserv')['results'], isEmpty);
  });
}
