import 'dart:io';

import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/project_manager.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/projects/open_projects_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 左侧「Opening Projects」面板:列出打开的项目,点一个切换,× 才真正关闭。
void main() {
  late Directory tmp;
  late String a, b, c;
  late LayoutStore layout;
  late SettingsStore settings;
  late PluginManager plugins;
  late ProjectManager manager;
  late List<String> events;
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
    tmp = Directory.systemTemp.createTempSync('clx_panel_');
    for (final n in ['alpha', 'beta', 'gamma']) {
      Directory('${tmp.path}/$n').createSync();
      File('${tmp.path}/$n/one.txt').writeAsStringSync('$n\n');
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
    events = [];
  });

  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: OpenProjectsPanel(
            manager: manager,
            home: tmp.path,
            onSwitch: (p) => events.add('switch ${p.name}'),
            onClose: (p) => events.add('close ${p.name}'),
            onCloseOthers: (p) => events.add('closeOthers ${p.name}'),
            onOpenFolder: () => events.add('open'),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      manager.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    settings.dispose();
    plugins.dispose();
    layout.dispose();
    tmp.deleteSync(recursive: true);
  }

  Future<void> hover(WidgetTester tester, Finder target) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  testWidgets('empty: a hint instead of a list, and the + button still works', (tester) async {
    await show(tester);
    expect(find.text('Opening'), findsOneWidget);
    expect(find.text('没有打开的项目'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-projects-count')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('open-projects-add')));
    expect(events, ['open']);
    await finish(tester);
  });

  testWidgets('lists every open project with its folder; the active one is marked; the count follows', (tester) async {
    await tester.runAsync(() async {
      await manager.open(a);
      await manager.open(b);
    });
    await show(tester);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('~/alpha'), findsOneWidget, reason: '路径按主目录缩写');
    expect(tester.widget<Text>(find.byKey(const ValueKey('open-projects-count'))).data, '2');
    final active = tester.widget<Text>(find.text('beta'));
    final other = tester.widget<Text>(find.text('alpha'));
    expect(active.style!.fontWeight, FontWeight.w700, reason: '当前项目加粗');
    expect(other.style!.fontWeight, FontWeight.w400);

    await tester.runAsync(() => manager.open(c));
    await tester.pump();
    expect(find.text('gamma'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('open-projects-count'))).data, '3');
    await finish(tester);
  });

  testWidgets('click switches; × (on the active row, or on hover) closes; neither does the other one\'s job', (tester) async {
    await tester.runAsync(() async {
      await manager.open(a);
      await manager.open(b);
    });
    await show(tester);
    await tester.tap(find.byKey(ValueKey('open-project-$a')));
    expect(events, ['switch alpha']);

    // 当前项目(beta)的 × 一直显示;别的项目悬停才显示
    expect(find.byKey(ValueKey('close-project-$b')), findsOneWidget);
    expect(find.byKey(ValueKey('close-project-$a')), findsNothing);
    await hover(tester, find.byKey(ValueKey('open-project-$a')));
    expect(find.byKey(ValueKey('close-project-$a')), findsOneWidget);

    events.clear();
    await tester.tap(find.byKey(ValueKey('close-project-$a')));
    expect(events, ['close alpha'], reason: '× 只关闭,不触发切换');
    await finish(tester);
  });

  testWidgets('right click: switch / close / close others; switching is disabled on the active row, close others when alone', (tester) async {
    await tester.runAsync(() async {
      await manager.open(a);
      await manager.open(b);
    });
    await show(tester);

    Future<void> menuOn(String path) async {
      await tester.tap(find.byKey(ValueKey('open-project-$path')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    await menuOn(a);
    await tester.tap(find.text('切换到此项目'));
    await tester.pumpAndSettle();
    expect(events, ['switch alpha']);

    await menuOn(a);
    await tester.tap(find.text('关闭其它项目'));
    await tester.pumpAndSettle();
    expect(events.last, 'closeOthers alpha');

    await menuOn(b);
    expect(tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, '切换到此项目')).onPressed, isNull, reason: '已经是当前项目');
    await tester.tap(find.text('关闭项目'));
    await tester.pumpAndSettle();
    expect(events.last, 'close beta');

    // 只剩一个:没有「其它项目」可关
    await tester.runAsync(() => manager.close(manager.projects.first));
    await tester.pump();
    await menuOn(b);
    expect(tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, '关闭其它项目')).onPressed, isNull);
    await finish(tester);
  });

  testWidgets('a project with unsaved changes shows a dot; unloaded projects are dimmed until switched to', (tester) async {
    settings.setAutosave(false);
    await tester.runAsync(() async {
      await manager.open(a);
      await manager.active.workspace.openFile('one.txt');
      await manager.open(b);
    });
    await show(tester);
    expect(find.byKey(const ValueKey('project-dirty')), findsNothing);

    manager.projects.first.context!.sessions.tabs['one.txt']!.controller.insertText('x');
    await tester.pump();
    expect(find.byKey(const ValueKey('project-dirty')), findsOneWidget, reason: '没切到的项目里的未保存改动也看得到');
    expect(find.byTooltip('有未保存的改动'), findsOneWidget);
    await tester.runAsync(() => manager.saveAll());
    manager.projects.first.context!.sessions.tabs['one.txt']!.controller.markSaved();
    await tester.pump();
    expect(find.byKey(const ValueKey('project-dirty')), findsNothing);

    // 启动恢复出来的列表:只有当前项目加载了,别的暗一点
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      manager.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    manager = newManager();
    await tester.runAsync(() => manager.restore());
    await show(tester);
    expect(manager.projects.first.isLoaded, isFalse);
    final dimmed = find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.6);
    expect(dimmed, findsOneWidget, reason: '一个没加载的项目');
    await finish(tester);
  });
}
