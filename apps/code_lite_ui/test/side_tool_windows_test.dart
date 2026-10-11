import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/activity_stripe/activity_stripe_widget.dart';
import 'package:code_lite_ui/features/activity_stripe/stripe_button.dart';
import 'package:code_lite_ui/features/bottom_tools/bottom_tools_widget.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/tool_window/side_split_view.dart';
import 'package:code_lite_ui/features/tool_window/tool_window_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 侧边工具窗可以放到左 / 右两侧各自的上方或下方(IntelliJ 的 Move To ▸ Left / Right Top / Bottom)。
void main() {
  group('layout', () {
    test('moving an open tool to the bottom keeps it visible there; each half toggles on its own', () {
      final l = LayoutStore();
      expect(l.visibleTools, {SideTool.project});

      l.selectTool(SideTool.build);
      expect(l.visibleTools, {SideTool.build});
      l.moveTool(SideTool.build, ToolSide.left, ToolSlot.bottom);
      expect(l.slotOf(SideTool.build), ToolSlot.bottom);
      expect(l.visibleTool(ToolSide.left, ToolSlot.top), isNull, reason: '它原来占着上方,移走后上方空着');
      expect(l.visibleTool(ToolSide.left, ToolSlot.bottom), SideTool.build);

      l.selectTool(SideTool.project);
      expect(l.visibleTool(ToolSide.left, ToolSlot.top), SideTool.project);
      expect(l.visibleTool(ToolSide.left, ToolSlot.bottom), SideTool.build, reason: '上下同时显示');

      l.selectTool(SideTool.build); // 再点一次只收起下方
      expect(l.visibleTools, {SideTool.project});
      l.showTool(SideTool.build);
      l.hideTool(SideTool.project);
      expect(l.visibleTools, {SideTool.build});
      expect(l.isSideOpen(ToolSide.left), isTrue);

      // 移回上方:顶替上方的工具窗
      l.selectTool(SideTool.structure);
      l.moveTool(SideTool.build, ToolSide.left, ToolSlot.top);
      expect(l.visibleTool(ToolSide.left, ToolSlot.top), SideTool.build);
      expect(l.visibleTool(ToolSide.left, ToolSlot.bottom), isNull);

      l.resizeSplit(ToolSide.left, 0.01);
      expect(l.splitOf(ToolSide.left), LayoutStore.minSplit);
      l.resizeSplit(ToolSide.left, 0.99);
      expect(l.splitOf(ToolSide.left), 1 - LayoutStore.minSplit);
    });

    test('placement round-trips through json; a project view moved to the bottom opens there', () {
      final a = LayoutStore()
        ..moveTool(SideTool.project, ToolSide.left, ToolSlot.bottom)
        ..moveTool(SideTool.build, ToolSide.left, ToolSlot.bottom)
        ..resizeSplit(ToolSide.left, 0.634);
      expect(a.toJson(), {'leftBottomTools': ['project', 'build'], 'leftSplit': 0.63, 'rightTopTools': [], 'rightBottomTools': [], 'rightSplit': 0.5});
      final b = LayoutStore()..applyJson({'leftBottomTools': ['project', 'build', 'nonsense'], 'leftSplit': 0.63});
      expect(b.slotOf(SideTool.project), ToolSlot.bottom);
      expect(b.slotOf(SideTool.commit), ToolSlot.top);
      expect(b.visibleTool(ToolSide.left, ToolSlot.top), isNull);
      expect(b.visibleTool(ToolSide.left, ToolSlot.bottom), SideTool.project);
      expect(b.splitOf(ToolSide.left), 0.63);
    });

    test('right side: a tool moved there shows on the right and leaves the left alone; each side splits on its own', () {
      final l = LayoutStore();
      expect(l.hasToolsOn(ToolSide.right), isFalse);
      expect(l.isSideOpen(ToolSide.right), isFalse);

      l.selectTool(SideTool.structure);
      expect(l.visibleTool(ToolSide.left, ToolSlot.top), SideTool.structure);
      l.moveTool(SideTool.structure, ToolSide.right, ToolSlot.top);
      expect(l.sideOf(SideTool.structure), ToolSide.right);
      expect(l.visibleTool(ToolSide.right, ToolSlot.top), SideTool.structure, reason: '开着的话在右边接着显示');
      expect(l.visibleTool(ToolSide.left, ToolSlot.top), isNull);
      expect(l.hasToolsOn(ToolSide.right), isTrue);

      // 左右同时开着,互不影响
      l.selectTool(SideTool.project);
      expect(l.visibleTools, {SideTool.project, SideTool.structure});
      l.selectTool(SideTool.structure); // 再点一次收起右边
      expect(l.isSideOpen(ToolSide.right), isFalse);
      expect(l.isSideOpen(ToolSide.left), isTrue);
      l.selectTool(SideTool.structure);

      // 右侧也能上下拆分
      l.moveTool(SideTool.build, ToolSide.right, ToolSlot.bottom);
      l.showTool(SideTool.build);
      expect(l.visibleTool(ToolSide.right, ToolSlot.top), SideTool.structure);
      expect(l.visibleTool(ToolSide.right, ToolSlot.bottom), SideTool.build);
      l.resizeSplit(ToolSide.right, 0.7);
      expect(l.splitOf(ToolSide.right), 0.7);
      expect(l.splitOf(ToolSide.left), 0.5, reason: '两侧的拆分比例各算各的');

      // 宽度也是各一份
      l.resizeSide(ToolSide.right, 400, maxWidth: 1000);
      expect(l.widthOf(ToolSide.right), 400);
      expect(l.widthOf(ToolSide.left), 250);
      l.resizeSide(ToolSide.right, 10, maxWidth: 1000);
      expect(l.widthOf(ToolSide.right), LayoutStore.minSideWidth);

      // 移回左上方:右边就空了
      l.moveTool(SideTool.structure, ToolSide.left, ToolSlot.top);
      l.moveTool(SideTool.build, ToolSide.left, ToolSlot.top);
      expect(l.hasToolsOn(ToolSide.right), isFalse);
      expect(l.visibleTool(ToolSide.left, ToolSlot.top), SideTool.build, reason: '顶替左上方原来的工具窗');
    });

    test('right placement round-trips through json; the open project view moved to the right opens there', () {
      final a = LayoutStore()
        ..moveTool(SideTool.structure, ToolSide.right, ToolSlot.top)
        ..moveTool(SideTool.build, ToolSide.right, ToolSlot.bottom)
        ..moveTool(SideTool.commit, ToolSide.left, ToolSlot.bottom)
        ..resizeSplit(ToolSide.right, 0.3);
      final json = a.toJson();
      expect(json, {
        'leftBottomTools': ['commit'],
        'leftSplit': 0.5,
        'rightTopTools': ['structure'],
        'rightBottomTools': ['build'],
        'rightSplit': 0.3,
      });

      final b = LayoutStore()..applyJson(json);
      expect(b.sideOf(SideTool.structure), ToolSide.right);
      expect(b.slotOf(SideTool.structure), ToolSlot.top);
      expect(b.sideOf(SideTool.build), ToolSide.right);
      expect(b.slotOf(SideTool.build), ToolSlot.bottom);
      expect(b.sideOf(SideTool.commit), ToolSide.left);
      expect(b.splitOf(ToolSide.right), 0.3);

      final c = LayoutStore()..applyJson({'rightTopTools': ['project', 'nonsense']});
      expect(c.visibleTool(ToolSide.left, ToolSlot.top), isNull);
      expect(c.visibleTool(ToolSide.right, ToolSlot.top), SideTool.project);

      // 旧版本只存了左侧的布局,照样能读
      final d = LayoutStore()..applyJson({'leftBottomTools': ['structure'], 'leftSplit': 0.4});
      expect(d.slotOf(SideTool.structure), ToolSlot.bottom);
      expect(d.hasToolsOn(ToolSide.right), isFalse);
    });

    test('settings persist the placement only when it changes', () async {
      final client = ApiClient(initialRoot: '.');
      final sessions = EditorSessionManager(client: client);
      final layout = LayoutStore();
      final saved = <Map<String, dynamic>>[];
      final settings = SettingsStore(
        sessions: sessions,
        layout: layout,
        load: () async => {
          'layout': {'leftBottomTools': ['structure']},
        },
        save: (j) async => saved.add(j),
      );
      await settings.load();
      expect(layout.slotOf(SideTool.structure), ToolSlot.bottom);
      expect(saved, isEmpty, reason: '读回来的布局不需要再写');

      layout.selectTool(SideTool.commit);
      layout.resizeSide(ToolSide.left, 300, maxWidth: 1000);
      expect(saved, isEmpty, reason: '选工具窗 / 拖宽度不写盘');

      layout.moveTool(SideTool.build, ToolSide.left, ToolSlot.bottom);
      expect(saved, hasLength(1));
      expect(saved.single['layout'], {'leftBottomTools': ['structure', 'build'], 'leftSplit': 0.5, 'rightTopTools': [], 'rightBottomTools': [], 'rightSplit': 0.5});
      settings.dispose();
      sessions.dispose();
      await client.dispose();
    });
  });

  group('widgets', () {
    Widget header(LayoutStore layout, SideTool tool) => MaterialApp(
          home: Scaffold(
            body: ToolWindowScope(
              tool: tool,
              layout: layout,
              child: const Row(children: [Expanded(child: Text('Maven')), ToolWindowActions()]),
            ),
          ),
        );

    testWidgets('header: only the ⋮ menu (Move To ▸ Left Top / Left Bottom) and hide; no separate split button', (tester) async {
      final layout = LayoutStore()..selectTool(SideTool.build);
      await tester.pumpWidget(header(layout, SideTool.build));
      expect(find.byTooltip('拆分到左侧下方(与上方的工具窗同时显示)'), findsNothing, reason: '独立的拆分按钮已去掉');
      expect(find.byTooltip('选项'), findsOneWidget);
      expect(find.byTooltip('隐藏'), findsOneWidget);

      // ⋮ ▸ 移动到 ▸ 左侧下方
      Future<void> moveTo(String slot) async {
        await tester.tap(find.byTooltip('选项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('移动到'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(slot));
        await tester.pumpAndSettle();
      }

      await moveTo('左侧下方');
      expect(layout.visibleTool(ToolSide.left, ToolSlot.bottom), SideTool.build);
      expect(layout.visibleTool(ToolSide.left, ToolSlot.top), isNull);

      // 再回到左侧上方;菜单里的对勾跟着位置走
      await tester.tap(find.byTooltip('选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到'));
      await tester.pumpAndSettle();
      final checks = find.byIcon(Icons.check);
      expect(checks, findsOneWidget);
      await tester.tap(find.text('左侧上方'));
      await tester.pumpAndSettle();
      expect(layout.slotOf(SideTool.build), ToolSlot.top);
      expect(layout.visibleTool(ToolSide.left, ToolSlot.top), SideTool.build);

      await tester.tap(find.byTooltip('隐藏'));
      await tester.pump();
      expect(layout.isToolVisible(SideTool.build), isFalse);
    });

    testWidgets('header menu: move to the right side, check mark follows', (tester) async {
      final layout = LayoutStore()..selectTool(SideTool.build);
      await tester.pumpWidget(header(layout, SideTool.build));
      await tester.tap(find.byTooltip('选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到'));
      await tester.pumpAndSettle();
      expect(find.text('右侧上方'), findsOneWidget);
      expect(find.text('右侧下方'), findsOneWidget);
      await tester.tap(find.text('右侧下方'));
      await tester.pumpAndSettle();
      expect(layout.sideOf(SideTool.build), ToolSide.right);
      expect(layout.visibleTool(ToolSide.right, ToolSlot.bottom), SideTool.build);
      expect(layout.visibleTool(ToolSide.left, ToolSlot.top), isNull);
    });

    testWidgets('right stripe: only right-docked tools, hidden when there are none; left stripe leaves them out', (tester) async {
      final layout = LayoutStore();
      Widget stripes() => MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: layout,
                builder: (context, _) => Row(
                  children: [
                    ActivityStripeWidget(
                      leftTool: layout.leftTool,
                      isLeftOpen: layout.isLeftOpen,
                      visibleTools: layout.visibleTools,
                      slotOf: layout.slotOf,
                      sideOf: layout.sideOf,
                      bottomTab: BottomToolTab.git,
                      isBottomOpen: false,
                      onSelectTool: layout.selectTool,
                      onSelectBottomTab: (_) {},
                    ),
                    const Spacer(),
                    RightStripeWidget(
                      visibleTools: layout.visibleTools,
                      sideOf: layout.sideOf,
                      slotOf: layout.slotOf,
                      onSelectTool: layout.selectTool,
                    ),
                  ],
                ),
              ),
            ),
          );
      await tester.pumpWidget(stripes());
      expect(find.byType(RightStripeWidget), findsOneWidget);
      expect(tester.getSize(find.byType(RightStripeWidget)), Size.zero, reason: '右侧没有工具窗时不占地方');

      layout.moveTool(SideTool.structure, ToolSide.right, ToolSlot.top);
      await tester.pump();
      final right = find.descendant(of: find.byType(RightStripeWidget), matching: find.byTooltip('结构 (⌘7)'));
      final left = find.descendant(of: find.byType(ActivityStripeWidget), matching: find.byTooltip('结构 (⌘7)'));
      expect(right, findsOneWidget);
      expect(left, findsNothing, reason: '放到右边的按钮不再出现在左活动条');
      expect(tester.getSize(find.byType(RightStripeWidget)).width, greaterThan(0));

      // 点右边的按钮打开 / 收起它
      await tester.tap(right);
      await tester.pump();
      expect(layout.visibleTool(ToolSide.right, ToolSlot.top), SideTool.structure);
      final active = {for (final b in tester.widgetList<StripeButton>(find.byType(StripeButton))) if (b.isActive) b.tooltip};
      expect(active, {'项目 (⌘1)', '结构 (⌘7)'}, reason: '左右各一个高亮');
      await tester.tap(right);
      await tester.pump();
      expect(layout.isSideOpen(ToolSide.right), isFalse);
    });

    testWidgets('without a scope the header shows no tool window buttons', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Row(children: [ToolWindowActions()]))));
      expect(find.byTooltip('隐藏'), findsNothing);
    });

    testWidgets('split view: both halves shown, divider drags the ratio', (tester) async {
      await tester.binding.setSurfaceSize(const Size(300, 605));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final layout = LayoutStore();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: layout,
            builder: (context, _) => SideSplitView(side: ToolSide.left, 
              layout: layout,
              top: const ColoredBox(key: ValueKey('top'), color: Colors.red),
              bottom: const ColoredBox(key: ValueKey('bottom'), color: Colors.blue),
            ),
          ),
        ),
      ));
      expect(tester.getSize(find.byKey(const ValueKey('top'))).height, 300);
      expect(tester.getSize(find.byKey(const ValueKey('bottom'))).height, 300);
      await tester.drag(find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeRow), const Offset(0, 120));
      await tester.pump();
      expect(layout.splitOf(ToolSide.left), closeTo(0.7, 0.03));
      expect(tester.getSize(find.byKey(const ValueKey('top'))).height, closeTo(420, 18));
    });

    testWidgets('stripe: tools moved to the bottom sit below a divider; both halves highlight', (tester) async {
      final layout = LayoutStore()
        ..moveTool(SideTool.structure, ToolSide.left, ToolSlot.bottom)
        ..showTool(SideTool.structure);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ActivityStripeWidget(
            leftTool: layout.leftTool,
            isLeftOpen: layout.isLeftOpen,
            visibleTools: layout.visibleTools,
            slotOf: layout.slotOf,
            bottomTab: BottomToolTab.git,
            isBottomOpen: false,
            onSelectTool: (_) {},
            onSelectBottomTab: (_) {},
            buildToolTitle: 'Maven',
          ),
        ),
      ));
      final structure = tester.getCenter(find.byTooltip('结构 (⌘7)')).dy;
      expect(structure, greaterThan(tester.getCenter(find.byTooltip('Maven')).dy), reason: '左下方的工具窗排在上方那组后面');
      expect(structure, lessThan(tester.getCenter(find.byTooltip('终端 (⌥F12)')).dy));
      final active = {for (final b in tester.widgetList<StripeButton>(find.byType(StripeButton))) if (b.isActive) b.tooltip};
      expect(active, {'项目 (⌘1)', '结构 (⌘7)'}, reason: '上下两块各一个,都高亮');
    });
  });
}
