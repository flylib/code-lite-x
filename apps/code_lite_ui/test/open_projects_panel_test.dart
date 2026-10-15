import 'dart:io';

import 'package:code_lite_ui/core/lsp/lsp.dart' show LspService;
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
            onOpenPath: (path) => events.add('open ${path.split('/').last}'),
            onCloseGroup: (g) => events.add('closeGroup ${g.name}'),
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

  Future<void> newGroup(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('open-projects-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('group-name-field')), name);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('创建'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
  }

  /// 鼠标按住 [from] 拖到 [to] 松开。
  Future<void> dragTo(WidgetTester tester, Finder from, Finder to) async {
    final g = await tester.startGesture(tester.getCenter(from), kind: PointerDeviceKind.mouse);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(tester.getCenter(from), tester.getCenter(to), i / 10)!);
      await tester.pump();
    }
    await tester.runAsync(() async {
      await g.up();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('empty: a hint instead of a list; + creates a project group', (tester) async {
    await show(tester);
    expect(find.text('Opening'), findsOneWidget);
    expect(find.text('没有打开的项目'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-projects-count')), findsNothing);
    expect(find.byTooltip('新建项目组…'), findsOneWidget);
    await newGroup(tester, '  bcpoker ');
    expect(manager.groups.single.name, 'bcpoker', reason: '名字去掉首尾空白');
    expect(find.text('bcpoker'), findsOneWidget);
    expect(find.text('把项目拖到这里'), findsOneWidget, reason: '空组给个提示');
    expect(openDisk['groups'], [
      {'id': manager.groups.single.id, 'name': 'bcpoker', 'members': <String>[]},
    ]);

    // 重名(不分大小写)不让建
    await tester.tap(find.byKey(const ValueKey('open-projects-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('group-name-field')), 'BCPoker');
    await tester.pump();
    expect(find.text('已经有叫「BCPoker」的项目组了'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '创建')).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.groups.length, 1);
    await finish(tester);
  });

  testWidgets('drag a project onto a group to put it in, drag it out to take it out', (tester) async {
    await tester.runAsync(() async {
      await manager.open(a);
      await manager.open(b);
      await manager.createGroup('bcpoker');
    });
    await show(tester);
    await dragTo(tester, find.byKey(ValueKey('open-project-$a')), find.byKey(const ValueKey('group-bcpoker')));
    expect(manager.groupOf(a)?.name, 'bcpoker');
    expect(find.text('1/1'), findsOneWidget, reason: '打开数 / 成员数');
    // 组里的排在组标题下面、往里缩
    expect(tester.getTopLeft(find.text('alpha')).dy, greaterThan(tester.getTopLeft(find.text('bcpoker')).dy));
    expect(tester.getTopLeft(find.text('alpha')).dx, greaterThan(tester.getTopLeft(find.text('beta')).dx));
    expect((openDisk['groups'] as List).single['members'], [a]);

    // 拖到组外的空白处:移出
    await dragTo(tester, find.byKey(ValueKey('open-project-$a')), find.text('beta'));
    expect(manager.groupOf(a), isNull);
    expect(find.text('把项目拖到这里'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a closed member stays in the group, grayed; clicking it reopens; groups survive a restart', (tester) async {
    await tester.runAsync(() async {
      await manager.open(a);
      await manager.open(b);
      final g = await manager.createGroup('bcpoker');
      await manager.moveToGroup(a, g);
      await manager.moveToGroup(b, g);
      await manager.close(manager.find(a)!);
    });
    await show(tester);
    expect(find.byKey(ValueKey('closed-member-$a')), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('closed-member-$a')));
    expect(events, ['open alpha']);

    // 收起组:成员都藏起来
    await tester.runAsync(() => manager.setGroupCollapsed(manager.groups.single, true));
    await tester.pump();
    expect(find.text('alpha'), findsNothing);
    expect(find.text('beta'), findsNothing);

    // 重启:组、成员、收起状态都还在;目录没了的成员去掉
    Directory(a).deleteSync(recursive: true);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      manager.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    final id = manager.groups.single.id;
    manager = newManager();
    await tester.runAsync(() => manager.restore());
    expect(manager.groups.single.name, 'bcpoker');
    expect(manager.groups.single.id, id, reason: 'id 不变:组里共用的 jdtls 缓存按它放');
    expect(LspService.shareKeyFor!(b), id, reason: '组里的项目共用一个语言服务器');
    expect(LspService.shareKeyFor!(c), isNull);
    expect(manager.groups.single.members, [b]);
    expect(manager.groups.single.collapsed, isTrue);
    await show(tester);
    await finish(tester);
  });

  testWidgets('menus: move to group, rename, open all, close all, delete (projects stay open)', (tester) async {
    await tester.runAsync(() async {
      await manager.open(a);
      await manager.open(b);
      await manager.createGroup('bcpoker');
      await manager.createGroup('other');
    });
    await show(tester);

    await tester.tap(find.byKey(ValueKey('open-project-$a')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移到项目组'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(MenuItemButton, 'bcpoker'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(manager.groupOf(a)?.name, 'bcpoker');

    Future<void> groupMenu(String name, String item) async {
      await tester.tap(find.byKey(ValueKey('group-$name')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(item));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
    }

    await groupMenu('bcpoker', '全部关闭');
    expect(events, ['closeGroup bcpoker']);

    await groupMenu('bcpoker', '重命名…');
    await tester.enterText(find.byKey(const ValueKey('group-name-field')), 'other');
    await tester.pump();
    expect(find.text('已经有叫「other」的项目组了'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('group-name-field')), 'bcpoker2');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('重命名'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(manager.groupOf(a)?.name, 'bcpoker2');

    // 关掉成员后「全部打开」把它放回列表(先不加载,切过去才加载)
    await tester.runAsync(() => manager.close(manager.find(a)!));
    await tester.pump();
    await tester.runAsync(() async {
      await manager.openGroup(manager.groups.first);
    });
    await tester.pump();
    expect(manager.find(a), isNotNull);
    expect(manager.activeProject?.path, a);

    await groupMenu('bcpoker2', '删除项目组(项目不关)');
    expect(manager.groups.map((g) => g.name), ['other']);
    expect(manager.find(a), isNotNull, reason: '删组不关项目');
    expect(manager.groupOf(a), isNull);
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
