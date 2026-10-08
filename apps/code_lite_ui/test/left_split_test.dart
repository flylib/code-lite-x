import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/activity_stripe/activity_stripe_widget.dart';
import 'package:code_lite_ui/features/activity_stripe/stripe_button.dart';
import 'package:code_lite_ui/features/bottom_tools/bottom_tools_widget.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/tool_window/left_split_view.dart';
import 'package:code_lite_ui/features/tool_window/tool_window_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 左侧工具窗可以移到左下方,与左上方的同时显示(IntelliJ 的 Move To ▸ Left Bottom)。
void main() {
  group('layout', () {
    test('moving an open tool to the bottom keeps it visible there; each half toggles on its own', () {
      final l = LayoutStore();
      expect(l.visibleLeftTools, {LeftTool.project});

      l.selectLeftTool(LeftTool.build);
      expect(l.visibleLeftTools, {LeftTool.build});
      l.moveLeftTool(LeftTool.build, ToolSlot.bottom);
      expect(l.slotOf(LeftTool.build), ToolSlot.bottom);
      expect(l.visibleTopTool, isNull, reason: '它原来占着上方,移走后上方空着');
      expect(l.visibleBottomTool, LeftTool.build);

      l.selectLeftTool(LeftTool.project);
      expect(l.visibleTopTool, LeftTool.project);
      expect(l.visibleBottomTool, LeftTool.build, reason: '上下同时显示');

      l.selectLeftTool(LeftTool.build); // 再点一次只收起下方
      expect(l.visibleLeftTools, {LeftTool.project});
      l.showLeftTool(LeftTool.build);
      l.hideLeftTool(LeftTool.project);
      expect(l.visibleLeftTools, {LeftTool.build});
      expect(l.isAnyLeftOpen, isTrue);

      // 移回上方:顶替上方的工具窗
      l.selectLeftTool(LeftTool.structure);
      l.moveLeftTool(LeftTool.build, ToolSlot.top);
      expect(l.visibleTopTool, LeftTool.build);
      expect(l.visibleBottomTool, isNull);

      l.resizeLeftSplit(0.01);
      expect(l.leftSplit, LayoutStore.minLeftSplit);
      l.resizeLeftSplit(0.99);
      expect(l.leftSplit, 1 - LayoutStore.minLeftSplit);
    });

    test('placement round-trips through json; a project view moved to the bottom opens there', () {
      final a = LayoutStore()
        ..moveLeftTool(LeftTool.project, ToolSlot.bottom)
        ..moveLeftTool(LeftTool.build, ToolSlot.bottom)
        ..resizeLeftSplit(0.634);
      expect(a.toJson(), {'leftBottomTools': ['project', 'build'], 'leftSplit': 0.63});
      final b = LayoutStore()..applyJson({'leftBottomTools': ['project', 'build', 'nonsense'], 'leftSplit': 0.63});
      expect(b.slotOf(LeftTool.project), ToolSlot.bottom);
      expect(b.slotOf(LeftTool.commit), ToolSlot.top);
      expect(b.visibleTopTool, isNull);
      expect(b.visibleBottomTool, LeftTool.project);
      expect(b.leftSplit, 0.63);
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
      expect(layout.slotOf(LeftTool.structure), ToolSlot.bottom);
      expect(saved, isEmpty, reason: '读回来的布局不需要再写');

      layout.selectLeftTool(LeftTool.commit);
      layout.resizeLeft(300, maxWidth: 1000);
      expect(saved, isEmpty, reason: '选工具窗 / 拖宽度不写盘');

      layout.moveLeftTool(LeftTool.build, ToolSlot.bottom);
      expect(saved, hasLength(1));
      expect(saved.single['layout'], {'leftBottomTools': ['structure', 'build'], 'leftSplit': 0.5});
      settings.dispose();
      sessions.dispose();
      await client.dispose();
    });
  });

  group('widgets', () {
    Widget header(LayoutStore layout, LeftTool tool) => MaterialApp(
          home: Scaffold(
            body: ToolWindowScope(
              tool: tool,
              layout: layout,
              child: const Row(children: [Expanded(child: Text('Maven')), ToolWindowActions()]),
            ),
          ),
        );

    testWidgets('header buttons: split to bottom / back to top, options menu, hide', (tester) async {
      final layout = LayoutStore()..selectLeftTool(LeftTool.build);
      await tester.pumpWidget(header(layout, LeftTool.build));

      await tester.tap(find.byTooltip('拆分到左侧下方(与上方的工具窗同时显示)'));
      await tester.pump();
      expect(layout.visibleBottomTool, LeftTool.build);
      expect(find.byTooltip('移到左侧上方'), findsOneWidget);

      // ⋮ ▸ 移动到 ▸ 左侧上方
      await tester.tap(find.byTooltip('选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('左侧上方'));
      await tester.pumpAndSettle();
      expect(layout.slotOf(LeftTool.build), ToolSlot.top);
      expect(layout.visibleTopTool, LeftTool.build);

      await tester.tap(find.byTooltip('隐藏'));
      await tester.pump();
      expect(layout.isLeftToolVisible(LeftTool.build), isFalse);
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
            builder: (context, _) => LeftSplitView(
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
      expect(layout.leftSplit, closeTo(0.7, 0.03));
      expect(tester.getSize(find.byKey(const ValueKey('top'))).height, closeTo(420, 18));
    });

    testWidgets('stripe: tools moved to the bottom sit below a divider; both halves highlight', (tester) async {
      final layout = LayoutStore()
        ..moveLeftTool(LeftTool.structure, ToolSlot.bottom)
        ..showLeftTool(LeftTool.structure);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ActivityStripeWidget(
            leftTool: layout.leftTool,
            isLeftOpen: layout.isLeftOpen,
            visibleLeftTools: layout.visibleLeftTools,
            slotOf: layout.slotOf,
            bottomTab: BottomToolTab.git,
            isBottomOpen: false,
            onSelectLeftTool: (_) {},
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
